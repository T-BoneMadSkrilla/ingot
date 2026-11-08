/*
 * hakuX HLE GPU — the display images on Metal (vk/display.c): RGBA8
 * textures the render thread writes at its swaps and the window's presenter
 * (mtl/present.m) samples. The slot states are vk/display.c's.
 */
#include "hw/xbox/hle/mtl/mtl_int.h"

#include "hw/xbox/hle/hle.h"
#include "hw/xbox/hle/hitch.h"
#include "hw/xbox/hle/vk/display.h"

enum { SLOT_FREE = 0, SLOT_PENDING, SLOT_READY, SLOT_FRONT };

typedef struct HleDispSlot {
    id<MTLTexture> tex;
    int state;
    bool held;
    uint32_t swap_id;
    uint64_t value;
} HleDispSlot;

static struct {
    HleMutex lock;
    HleCond cond;
    HleMutex use;
    bool inited;
    uint32_t w, h, gen;
    HleDispSlot s[HLE_DISP_SLOTS];
    HleDispStats st;
    bool present_late;
    uint32_t want;
} g_disp;

void hle_disp_setup(void)
{
    if (!g_disp.inited) {
        hle_mutex_init(&g_disp.lock);
        hle_cond_init(&g_disp.cond);
        hle_mutex_init(&g_disp.use);
        hle_smp_wmb();
        hle_atomic_set(&g_disp.inited, true);
    }
}

/* Command buffers hold the textures they use: the old images live until
 * the work reading or writing them is done, so a resize waits for nothing
 * but the presenter's look (use). */
int hle_disp_init(uint32_t w, uint32_t h)
{
    hle_disp_setup();
    if (g_disp.w == w && g_disp.h == h && g_disp.s[0].tex) {
        return 0;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    hle_mutex_lock(&g_disp.use);
    hle_mutex_lock(&g_disp.lock);
    g_disp.w = w;
    g_disp.h = h;
    g_disp.gen++;
    int ok = 0;
    for (int i = 0; i < HLE_DISP_SLOTS; i++) {
        g_disp.s[i].tex = [g_mtl.dev newTextureWithDescriptor:td];
        g_disp.s[i].state = SLOT_FREE;
        g_disp.s[i].held = false;
        ok |= g_disp.s[i].tex ? 0 : -1;
    }
    if (ok) {
        for (int i = 0; i < HLE_DISP_SLOTS; i++) {
            g_disp.s[i].tex = nil;
        }
        hle_log("hakuX-hle-back", "display disabled: slot creation failed");
    }
    hle_mutex_unlock(&g_disp.lock);
    hle_mutex_unlock(&g_disp.use);
    hle_log("hakuX-hle-back", "display %ux%u gen %u (%d slots)", w, h, g_disp.gen, HLE_DISP_SLOTS);
    return ok;
}

void hle_disp_use_begin(void)
{
    hle_mutex_lock(&g_disp.use);
}

uint32_t hle_disp_gen(void)
{
    return g_disp.gen;
}

void hle_disp_use_end(void)
{
    hle_mutex_unlock(&g_disp.use);
}

void hle_disp_size(uint32_t *w, uint32_t *h)
{
    *w = g_disp.w;
    *h = g_disp.h;
}

id<MTLTexture> hle_disp_texture(int slot)
{
    return g_disp.s[slot].tex;
}

static void to_front(int i, uint32_t swap_id)
{
    for (int j = 0; j < HLE_DISP_SLOTS; j++) {
        HleDispSlot *o = &g_disp.s[j];
        if (j != i && (o->state == SLOT_FRONT ||
                       (o->state != SLOT_FREE && o->swap_id < swap_id))) {
            if (o->state != SLOT_FRONT) {
                g_disp.st.dropped++;
            }
            o->state = SLOT_FREE;
        }
    }
    g_disp.s[i].state = SLOT_FRONT;
    g_disp.st.presented++;
    hle_hitch_frame(swap_id, HLE_FR_FRONT);
}

int hle_disp_begin_write(uint32_t swap_id, uint64_t value)
{
    static unsigned s_none;
    hle_mutex_lock(&g_disp.lock);
    int pick = -1;
    if (!g_disp.s[0].tex) {
        hle_mutex_unlock(&g_disp.lock);
        return -1;
    }
    int64_t t0 = g_get_monotonic_time();
    for (;;) {
        for (int i = 0; i < HLE_DISP_SLOTS && pick < 0; i++) {
            const HleDispSlot *s = &g_disp.s[i];
            if (s->state == SLOT_FREE && !s->held) {
                pick = i;
            }
        }
        int64_t waited = g_get_monotonic_time() - t0;
        if (pick >= 0 || waited >= 300000) {
            break;
        }
        if (waited >= 100000) {
            uint32_t oldest = UINT32_MAX;
            for (int i = 0; i < HLE_DISP_SLOTS; i++) {
                HleDispSlot *s = &g_disp.s[i];
                if ((s->state == SLOT_PENDING || s->state == SLOT_READY) && !s->held &&
                    s->swap_id < oldest) {
                    oldest = s->swap_id;
                    pick = i;
                }
            }
            if (pick >= 0) {
                g_disp.st.dropped++;
                break;
            }
        }
        g_disp.st.write_waits++;
        uint32_t pa = hle_hitch_enter(HLE_ACT_DISPLAY);
        hle_cond_timedwait(&g_disp.cond, &g_disp.lock, 50);
        hle_hitch_leave(pa);
    }
    if (pick >= 0) {
        HleDispSlot *s = &g_disp.s[pick];
        s->state = SLOT_PENDING;
        s->swap_id = swap_id;
        hle_hitch_frame(swap_id, HLE_FR_WRITE);
        s->value = value;
        g_disp.st.written++;
        if (g_disp.present_late && swap_id <= g_disp.want) {
            to_front(pick, swap_id);
        }
    } else if (s_none++ < 8) {
        hle_log("hakuX-hle-back", "display: no free slot for swap %u (frame skipped)", swap_id);
    }
    hle_mutex_unlock(&g_disp.lock);
    return pick;
}

void hle_disp_on_complete(uint64_t completed)
{
    if (!g_disp.inited) {
        return;
    }
    hle_mutex_lock(&g_disp.lock);
    for (int i = 0; i < HLE_DISP_SLOTS; i++) {
        if (g_disp.s[i].state == SLOT_PENDING && g_disp.s[i].value <= completed) {
            g_disp.s[i].state = SLOT_READY;
            hle_hitch_frame(g_disp.s[i].swap_id, HLE_FR_READY);
        }
    }
    hle_mutex_unlock(&g_disp.lock);
}

void hle_disp_present_late(bool on)
{
    hle_mutex_lock(&g_disp.lock);
    g_disp.present_late = on;
    g_disp.want = 0;
    hle_mutex_unlock(&g_disp.lock);
}

bool hle_disp_present(uint32_t swap_id)
{
    bool found = false;
    if (!g_disp.inited) {
        return false;
    }
    hle_mutex_lock(&g_disp.lock);
    for (int i = 0; i < HLE_DISP_SLOTS; i++) {
        HleDispSlot *s = &g_disp.s[i];
        if (s->state != SLOT_FREE && s->swap_id == swap_id) {
            to_front(i, swap_id);
            found = true;
            break;
        }
    }
    if (!found && g_disp.present_late && swap_id > g_disp.want) {
        g_disp.want = swap_id;
    }
    hle_cond_broadcast(&g_disp.cond);
    hle_mutex_unlock(&g_disp.lock);
    return found;
}

bool hle_disp_acquire(HleDispFrame *f)
{
    bool found = false;
    uint32_t shown = 0;
    if (!hle_atomic_load_acquire(&g_disp.inited)) {
        return false;
    }
    hle_mutex_lock(&g_disp.lock);
    for (int i = 0; i < HLE_DISP_SLOTS; i++) {
        HleDispSlot *s = &g_disp.s[i];
        if (s->state == SLOT_FRONT && s->tex) {
            static uint32_t s_last_shown;
            if (s->swap_id != s_last_shown) {
                s_last_shown = s->swap_id;
                shown = s_last_shown;
            }
            s->held = true;
            *f = (HleDispFrame){ i, g_disp.gen, s->swap_id, g_disp.w, g_disp.h, s->value, s->tex };
            found = true;
            break;
        }
    }
    hle_mutex_unlock(&g_disp.lock);
    if (shown) {
        hle_hitch_frame(shown, HLE_FR_SHOWN);
    }
    return found;
}

uint8_t *hle_disp_read_front(uint32_t *w, uint32_t *h)
{
    HleDispFrame f;
    if (!hle_mtl_ready()) {
        return NULL;
    }
    hle_disp_use_begin();               /* f.tex isn't retained: a resize frees it */
    if (!hle_disp_acquire(&f)) {
        hle_disp_use_end();
        return NULL;
    }
    uint8_t *out = NULL;
    @autoreleasepool {
        const NSUInteger row = (NSUInteger)f.w * 4, size = row * f.h;
        id<MTLBuffer> buf = [g_mtl.dev newBufferWithLength:size options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [g_mtl.queue commandBuffer];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:f.tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(f.w, f.h, 1) toBuffer:buf destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:size];
        [be endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        hle_disp_use_end();
        if (buf && cb.status == MTLCommandBufferStatusCompleted) {
            out = g_malloc(size);
            memcpy(out, buf.contents, size);
            *w = f.w;
            *h = f.h;
        }
    }
    hle_disp_release(f.slot);
    return out;
}

void hle_disp_release(int slot)
{
    hle_mutex_lock(&g_disp.lock);
    g_disp.s[slot].held = false;
    hle_cond_broadcast(&g_disp.cond);
    hle_mutex_unlock(&g_disp.lock);
}

HleDispStats hle_disp_stats(void)
{
    return g_disp.st;
}

static struct {
    uint8_t rgb[3][256];
    bool identity;
    uint32_t seq;
    bool by_consumer;
} g_gamma = { .identity = true };

void hle_disp_gamma_by_consumer(bool on)
{
    hle_atomic_set(&g_gamma.by_consumer, on);
}

bool hle_disp_gamma_consumer(void)
{
    return hle_atomic_read(&g_gamma.by_consumer);
}

void hle_disp_set_gamma(const uint8_t rgb[3][256], bool identity)
{
    if (identity && g_gamma.identity) {
        return;
    }
    hle_atomic_set(&g_gamma.seq, g_gamma.seq + 1);
    hle_smp_wmb();
    memcpy(g_gamma.rgb, rgb, sizeof(g_gamma.rgb));
    g_gamma.identity = identity;
    hle_smp_wmb();
    hle_atomic_set(&g_gamma.seq, g_gamma.seq + 1);
}

uint32_t hle_disp_gamma_seq(void)
{
    return hle_atomic_load_acquire(&g_gamma.seq);
}

bool hle_disp_front(uint32_t *gen, uint32_t *swap_id)
{
    bool found = false;
    if (!hle_atomic_load_acquire(&g_disp.inited)) {
        return false;
    }
    hle_mutex_lock(&g_disp.lock);
    for (int i = 0; i < HLE_DISP_SLOTS && !found; i++) {
        const HleDispSlot *s = &g_disp.s[i];
        if (s->state == SLOT_FRONT && s->tex) {
            *gen = g_disp.gen;
            *swap_id = s->swap_id;
            found = true;
        }
    }
    hle_mutex_unlock(&g_disp.lock);
    return found;
}

bool hle_disp_gamma(uint8_t rgb[3][256], bool *identity, uint32_t *gen)
{
    const uint32_t s0 = hle_atomic_load_acquire(&g_gamma.seq);
    if ((s0 & 1) || s0 == *gen) {
        return false;
    }
    memcpy(rgb, g_gamma.rgb, sizeof(g_gamma.rgb));
    *identity = g_gamma.identity;
    hle_smp_rmb();
    if (hle_atomic_read(&g_gamma.seq) != s0) {
        return false;
    }
    *gen = s0;
    return true;
}
