/*
 * hakuX HLE GPU — the timeline on Metal (vk/timeline.c): an MTLSharedEvent
 * is GPU time; a watcher thread publishes completions, and landings reach
 * guest memory before any thread sees their value (spec §4.7, §5.12).
 */
#include "hw/xbox/hle/mtl/mtl_int.h"

#include "hw/xbox/hle/hle.h"
#include "hw/xbox/hle/hitch.h"
#include "hw/xbox/hle/mem/barrier.h"
#include "hw/xbox/hle/mem/guestmem.h"
#include "hw/xbox/hle/tex/xg_swizzle.h"

static struct {
    bool inited;
    uint64_t submitted, completed, timeouts;
    HleThread thread;
    HleEvent ev;
    void (*on_complete)(uint64_t);
    int64_t busy_since;
    uint32_t gap;
    int64_t gap_hold_ns;
} g_tl;

enum { LAND_ROWS, LAND_SWZ, LAND_COPY, LAND_NOTE };
#define LAND_MAX 256
typedef struct LandEnt {
    uint64_t value;
    uint8_t kind;
    bool copied;
    uint32_t off, pa, len;
    uint32_t pitch, row, rows;
    uint32_t w, h, bpp;
    uint32_t dpitch;
    HleLandDone done;
    uint32_t token;
} LandEnt;
static struct {
    HleMutex lock;
    LandEnt q[LAND_MAX];
    unsigned n;
    uint64_t landed;
} g_land;

static void land_one(const LandEnt *e);

static bool land_add(const LandEnt *e)
{
    bool ok = true;
    hle_mutex_lock(&g_land.lock);
    if (e->value <= g_land.landed) {
        land_one(e);
    } else if (g_land.n < LAND_MAX) {
        g_land.q[g_land.n] = *e;
        hle_atomic_set(&g_land.n, g_land.n + 1);
    } else {
        ok = false;
    }
    hle_mutex_unlock(&g_land.lock);
    return ok;
}

bool hle_tl_land_room(unsigned n)
{
    return hle_atomic_read(&g_land.n) + n <= LAND_MAX;
}

uint64_t hle_tl_land_oldest(void)
{
    uint64_t v = 0;
    hle_mutex_lock(&g_land.lock);
    for (unsigned i = 0; i < g_land.n; i++) {
        v = !v || g_land.q[i].value < v ? g_land.q[i].value : v;
    }
    hle_mutex_unlock(&g_land.lock);
    return v;
}

bool hle_tl_land(uint64_t value, uint32_t arena_off, uint32_t pa, uint32_t len)
{
    const LandEnt e = { .value = value, .kind = LAND_ROWS, .off = arena_off, .pa = pa, .len = len };
    return land_add(&e);
}

bool hle_tl_land_swz(uint64_t value, uint32_t off, uint32_t pa, uint32_t w, uint32_t h, uint32_t bpp,
                     HleLandDone done, uint32_t token)
{
    const LandEnt e = { .value = value, .kind = LAND_SWZ, .off = off, .pa = pa, .len = w * h * bpp,
                        .w = w, .h = h, .bpp = bpp, .done = done, .token = token };
    return land_add(&e);
}

bool hle_tl_land_copy(uint64_t value, uint32_t spa, uint32_t spitch, uint32_t dpa, uint32_t dpitch,
                      uint32_t row, uint32_t rows, HleLandDone done, uint32_t token)
{
    const LandEnt e = { .value = value, .kind = LAND_COPY, .off = spa, .pa = dpa, .pitch = spitch,
                        .dpitch = dpitch, .row = row, .rows = rows, .done = done, .token = token };
    return land_add(&e);
}

bool hle_tl_land_note(uint64_t value, HleLandDone done, uint32_t token)
{
    const LandEnt e = { .value = value, .kind = LAND_NOTE, .done = done, .token = token };
    return land_add(&e);
}

void hle_tl_land_copied(uint32_t arena_off, uint32_t pitch, uint32_t row, uint32_t rows)
{
    hle_mutex_lock(&g_land.lock);
    for (unsigned i = 0; i < g_land.n; i++) {
        LandEnt *e = &g_land.q[i];
        if (e->off != arena_off || e->copied || (e->kind != LAND_ROWS && e->kind != LAND_SWZ)) {
            continue;
        }
        if (e->kind == LAND_SWZ || (rows && (uint64_t)pitch * (rows - 1) + row <= e->len)) {
            e->pitch = pitch;
            e->row = row;
            e->rows = rows;
            e->copied = true;
        }
    }
    hle_mutex_unlock(&g_land.lock);
}

/* shared storage on unified memory: coherent, nothing to invalidate */
static const uint8_t *land_src(uint32_t off)
{
    return (g_mtl.land ? hle_mtl_land_map() : (uint8_t *)g_mtl.arena.contents) + off;
}

static void land_one(const LandEnt *e)
{
    bool landed = e->kind == LAND_NOTE;
    if (e->kind == LAND_ROWS || e->kind == LAND_SWZ) {
        uint8_t *dst = e->copied ? hle_pa_ptr(e->pa, e->len) : NULL;
        const uint8_t *src = dst ? land_src(e->off) : NULL;
        if (dst && e->kind == LAND_ROWS) {
            for (uint32_t y = 0; y < e->rows; y++) {
                memcpy(dst + (size_t)y * e->pitch, src + (size_t)y * e->pitch, e->row);
            }
        } else if (dst) {
            const HleXgRect r = { 0, 0, e->w, e->h };
            hle_xg_swizzle_rect(src, e->w * e->bpp, &r, dst, e->w, e->h, 0, 0, e->bpp);
            hle_mem_mark_landed(e->pa, e->len);
        }
        landed = dst != NULL;
    } else if (e->kind == LAND_COPY) {
        for (uint32_t y = 0; y < e->rows; y++) {
            const uint8_t *s = hle_pa_ptr(e->off + y * e->pitch, e->row);
            uint8_t *d = hle_pa_ptr(e->pa + y * e->dpitch, e->row);
            if (s && d) {
                memmove(d, s, e->row);
                hle_mem_mark_written(e->pa + y * e->dpitch, e->row);
            }
        }
        landed = true;
    }
    if (e->done) {
        e->done(e->token, landed);
    }
}

static void land(uint64_t v)
{
    if (v <= __atomic_load_n(&g_land.landed, __ATOMIC_ACQUIRE)) {
        return;
    }
    hle_mutex_lock(&g_land.lock);
    if (v > g_land.landed) {
        unsigned keep = 0;
        for (unsigned i = 0; i < g_land.n; i++) {
            if (g_land.q[i].value > v) {
                g_land.q[keep++] = g_land.q[i];
                continue;
            }
            land_one(&g_land.q[i]);
        }
        g_land.n = keep;
        hle_atomic_set(&g_land.n, keep);
        __atomic_store_n(&g_land.landed, v, __ATOMIC_RELEASE);
    }
    hle_mutex_unlock(&g_land.lock);
}

static void publish(uint64_t v)
{
    land(v);
    uint64_t cur = hle_atomic_read(&g_tl.completed);
    while (v > cur) {
        uint64_t prev = hle_atomic_cmpxchg(&g_tl.completed, cur, v);
        if (prev == cur) {
            break;
        }
        cur = prev;
    }
}

void hle_mtl_tl_signal(id<MTLCommandBuffer> cb, uint64_t value)
{
    [cb encodeSignalEvent:g_mtl.tl value:value];
}

static void *watch_thread(void *opaque)
{
    uint64_t done = 0;
    for (;;) {
        @autoreleasepool {
            hle_event_reset(&g_tl.ev);
            if (done >= hle_atomic_read(&g_tl.submitted)) {
                hle_event_wait(&g_tl.ev);
                continue;
            }
            uint64_t want = done + 1;
            if (![g_mtl.tl waitUntilSignaledValue:want timeoutMS:100]) {
                if (++g_tl.timeouts % 10 == 0) {
                    hle_log("hakuX-hle-back", "GPU has not reached %llu for %llu s",
                            (unsigned long long)want, (unsigned long long)(g_tl.timeouts / 10));
                }
                continue;
            }
            uint64_t v = g_mtl.tl.signaledValue;
            done = v;
            publish(v);
            if (g_tl.on_complete) {
                g_tl.on_complete(v);
            }
        }
    }
    return NULL;
}

int hle_tl_init(void (*on_complete)(uint64_t))
{
    g_mtl.tl = [g_mtl.dev newSharedEvent];
    if (!g_mtl.tl) {
        return -1;
    }
    g_mtl.tl.signaledValue = 0;
    g_tl.on_complete = on_complete;
    g_tl.gap_hold_ns = 4000000;
    hle_mutex_init(&g_land.lock);
    hle_event_init(&g_tl.ev, false);
    g_tl.inited = true;
    hle_thread_create(&g_tl.thread, "hle.timeline", watch_thread, NULL, HLE_THREAD_DETACHED);
    return 0;
}

void hle_tl_signaled(uint64_t value)
{
    if (hle_atomic_read(&g_tl.completed) >= hle_atomic_read(&g_tl.submitted)) {
        hle_atomic_set(&g_tl.busy_since, hle_now_ns());
    }
    hle_atomic_set(&g_tl.submitted, value);
    hle_event_set(&g_tl.ev);
}

int64_t hle_tl_busy_ns(void)
{
    if (!g_tl.inited || hle_atomic_read(&g_tl.completed) >= hle_atomic_read(&g_tl.submitted)) {
        return 0;
    }
    return hle_now_ns() - hle_atomic_read(&g_tl.busy_since);
}

void hle_tl_gap(void)
{
    hle_atomic_set(&g_tl.gap, 1);
}

void hle_tl_gap_serve(void)
{
    if (likely(!hle_atomic_read(&g_tl.gap))) {
        return;
    }
    hle_atomic_set(&g_tl.gap, 0);
    hle_tl_wait(hle_atomic_read(&g_tl.submitted));
    if (g_tl.gap_hold_ns > 0) {
        struct timespec ts = { g_tl.gap_hold_ns / 1000000000, g_tl.gap_hold_ns % 1000000000 };
        nanosleep(&ts, NULL);
    }
}

uint64_t hle_tl_completed(void)
{
    return hle_atomic_read(&g_tl.completed);
}

uint64_t hle_tl_submitted(void)
{
    return hle_atomic_read(&g_tl.submitted);
}

void hle_tl_lose(void)
{
    publish(UINT64_MAX);
    hle_event_set(&g_tl.ev);
}

void hle_tl_wait(uint64_t value)
{
    if (hle_tl_completed() >= value) {
        return;
    }
    uint32_t pa = hle_hitch_enter(HLE_ACT_GPU);
    @autoreleasepool {
        while (hle_tl_completed() < value) {
            [g_mtl.tl waitUntilSignaledValue:value timeoutMS:100];
            publish(g_mtl.tl.signaledValue);
        }
    }
    hle_hitch_leave(pa);
}
