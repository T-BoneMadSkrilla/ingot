/*
 * hakuX native core — guest memory.
 */
#include "native/core/vm.h"
#include "hw/xbox/hle/uma/uma.h"

#include <dlfcn.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static uint8_t *g_na;   /* per physical page: no guest access (nc_vm_noaccess), made on first use */
/* Write tracking's flag and the views' protection change together: a page
 * opened by a guest store's fault while the GPU thread protects it again
 * otherwise ends read-only with its flag clear, the next store a crash. */
static pthread_mutex_t g_prot_mu = PTHREAD_MUTEX_INITIALIZER;
#ifdef NC_VM16K
/* per physical page: held for the unmapped guest page at its place in a
 * host page mapped direct (nc_vm_regroup), until that guest page is mapped */
static uint8_t *g_fill;
static uint32_t g_nfill;
#define NC_FILL_MAX 1024u
#endif

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 1u
#endif

#define NC_GUARD (64u * 1024u)

static int memfd(const char *name)
{
#ifdef __APPLE__
    /* a shared-memory object, unlinked at once: as anonymous as a memfd */
    char path[64];
    snprintf(path, sizeof(path), "/%s-%d", name, (int)getpid());
    const int fd = shm_open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) {
        shm_unlink(path);
        fcntl(fd, F_SETFD, FD_CLOEXEC);
    }
    return fd;
#else
    return (int)syscall(__NR_memfd_create, name, MFD_CLOEXEC);
#endif
}

/* The guest's view of [va, va + len) gets prot (one page or a run of them). */
static void guest_protect(NcVm *vm, uint32_t va, size_t len, int prot)
{
#ifdef NC_VM16K
    nc_vm16k_protect(vm, va, (uint32_t)len, prot);
#else
    mprotect(vm->base + va, len, prot);
#endif
}

bool nc_vm_init(NcVm *vm, uint32_t ram_size)
{
    memset(vm, 0, sizeof(*vm));
    vm->ram_fd = -1;

    /* 4 GiB of guest address space with PROT_NONE guards on both sides. */
    vm->reservation_len = (1ull << 32) + 2 * NC_GUARD;
    void *r = mmap(NULL, vm->reservation_len, PROT_NONE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (r == MAP_FAILED) {
        nc_log("hakuX-native", "vm: reserve failed: %s", strerror(errno));
        return false;
    }
    vm->reservation = r;
    vm->base = (uint8_t *)r + NC_GUARD;

    /* Guest RAM is an AHB's memory when the platform gives its fd (the
     * GPU imports the same buffer: vertices, uploads and readbacks in place,
     * as UMA allows), else a memfd. NC_RAM_MEMFD=1: the memfd (A/B). */
    const char *mf = getenv("NC_RAM_MEMFD");
    vm->ram_fd = mf && atoi(mf) ? -1 : hle_uma_ram_fd(ram_size);
    if (vm->ram_fd < 0) {
        vm->ram_fd = memfd("hakux-ram");
        if (vm->ram_fd < 0 || ftruncate(vm->ram_fd, ram_size) != 0) {
            nc_log("hakuX-native", "vm: guest RAM memfd failed: %s", strerror(errno));
            return false;
        }
    }
    vm->ram_size = ram_size;
    vm->page_used = calloc(ram_size / NC_PAGE, 1);
    vm->pte = calloc((1ull << 32) / NC_PAGE, sizeof(uint32_t));
    vm->rmap = calloc(ram_size / NC_PAGE, sizeof(uint32_t));
    vm->wp = calloc(ram_size / NC_PAGE, 1);
    vm->pin = calloc(ram_size / NC_PAGE, 1);
    if (!vm->page_used || !vm->pte || !vm->rmap || !vm->wp || !vm->pin) {
        return false;
    }
#ifdef NC_VM16K
    if (!nc_vm16k_init(vm)) {
        return false;
    }
#endif

    /* Host code's own view of RAM, outside the guest's address space: never
     * write-protected (dirty tracking applies to guest accesses). */
    void *phys = mmap(NULL, ram_size, PROT_READ | PROT_WRITE, MAP_SHARED, vm->ram_fd, 0);
    if (phys == MAP_FAILED) {
        nc_log("hakuX-native", "vm: RAM view failed: %s", strerror(errno));
        return false;
    }
    vm->phys = phys;

    /* The contiguous window: VA 0x80000000 + pa for all of RAM. And the
     * NV2A's BAR1 aperture at 0xF0000000, another view of RAM, where D3D's
     * tiled locks point (D3DLOCK_TILED). */
    if (!nc_vm_map(vm, NC_CONTIG_WINDOW, 0, ram_size) || !nc_vm_map(vm, NC_GPU_WINDOW, 0, ram_size)) {
        return false;
    }
    vm->ram = vm->base + NC_CONTIG_WINDOW;

    /* Physical memory below the kernel image (0x10000) is never handed out,
     * as on the Xbox: devices whose DMA pointers the title hasn't set yet
     * (the APU's notifiers and FE writes, for one) write near address 0. */
    nc_vm_claim_phys(vm, 0, 0x10000);
    nc_log("hakuX-native", "vm: guest base %p, RAM %u MiB", (void *)vm->base, ram_size >> 20);
    return true;
}

bool nc_vm_map(NcVm *vm, uint32_t va, uint32_t pa, uint32_t len)
{
    if ((va | pa | len) & (NC_PAGE - 1) || (uint64_t)pa + len > vm->ram_size ||
        (uint64_t)va + len > (1ull << 32)) {
        nc_log("hakuX-native", "vm: bad map va=%08x pa=%08x len=%x", va, pa, len);
        return false;
    }
#ifndef NC_VM16K
    void *want = vm->base + va;
    void *m = mmap(want, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, vm->ram_fd, pa);
    if (m != want) {
        nc_log("hakuX-native", "vm: map va=%08x pa=%08x len=%x failed: %s", va, pa, len,
               strerror(errno));
        return false;
    }
#endif
    const bool window = va == NC_CONTIG_WINDOW || va == NC_GPU_WINDOW;
    for (uint32_t off = 0; off < len; off += NC_PAGE) {
        const uint32_t page = (pa + off) / NC_PAGE;
        vm->pte[(va + off) / NC_PAGE] = (pa + off) | NC_PTE_VALID;
        if (!window) {
            /* A page at a second address: two allocations sharing it corrupt each other. */
            const uint32_t prev = vm->rmap[page];
            if (prev && prev != va + off && vm->pte[prev / NC_PAGE] == ((pa + off) | NC_PTE_VALID)) {
                static unsigned s_warned;
                if (s_warned++ < 16) {
                    nc_log("hakuX-native", "vm: pa %08x mapped at %08x is mapped again at %08x", pa + off, prev,
                           va + off);
                }
            }
            vm->rmap[page] = va + off;
        }
#ifdef NC_VM16K
        vm->vprot[(va + off) / NC_PAGE] = g_na && g_na[page] ? PROT_NONE
                                          : vm->wp[page] == NC_WP_CLEAN ? PROT_READ : PROT_READ | PROT_WRITE;
#else
        if (g_na && g_na[page]) {
            mprotect(vm->base + va + off, NC_PAGE, PROT_NONE); /* still no access (nc_vm_noaccess) */
        } else if (vm->wp[page] == NC_WP_CLEAN) {
            mprotect(vm->base + va + off, NC_PAGE, PROT_READ); /* still tracked */
        }
#endif
    }
#ifdef NC_VM16K
    nc_vm16k_sync(vm, va, len);
#endif
    return true;
}

void (*nc_vm_write_hook)(uint32_t va, uint32_t len);
void (*nc_vm_read_hook)(uint32_t va, uint32_t len);
void (*nc_vm_free_hook)(uint32_t pa, uint32_t len);
NcVmDma nc_vm_dma;

/* Pages [page, page + n)'s guest views (the contiguous and GPU windows, the
 * user mappings in rmap as runs of consecutive VAs): prot. */

static void prot_views(NcVm *vm, uint32_t page, uint32_t n, int prot)
{
    guest_protect(vm, NC_CONTIG_WINDOW + page * NC_PAGE, (size_t)n * NC_PAGE, prot);
    guest_protect(vm, NC_GPU_WINDOW + page * NC_PAGE, (size_t)n * NC_PAGE, prot);
    uint32_t run_va = 0, run_n = 0;
    for (uint32_t i = 0; i <= n; i++) {
        uint32_t va = 0;
        if (i < n) {
            va = vm->rmap[page + i];
            if (va && nc_vm_phys(vm, va) != (page + i) * NC_PAGE) {
                va = 0;
            }
        }
        if (run_n && va == run_va + run_n * NC_PAGE) {
            run_n++;
            continue;
        }
        if (run_n) {
            guest_protect(vm, run_va, (size_t)run_n * NC_PAGE, prot);
        }
        run_va = va;
        run_n = va ? 1 : 0;
    }
}

void nc_vm_protect_pages(NcVm *vm, uint32_t pa, uint32_t n, bool ro)
{
    if (!n) {
        return;
    }
    const uint32_t page = pa / NC_PAGE;
    const int prot = ro ? PROT_READ : PROT_READ | PROT_WRITE;
    pthread_mutex_lock(&g_prot_mu);
    /* The flag is set before the pages are protected and cleared after
     * they're writable again: a guest store that faults on another thread
     * meanwhile always finds its page marked (dirty.c takes the fault as a
     * tracking one), never protected and unmarked. */
    if (ro) {
        for (uint32_t i = 0; i < n; i++) {
            __atomic_store_n(&vm->wp[page + i], NC_WP_CLEAN, __ATOMIC_RELEASE);
        }
    }
    /* pages without access stay so (nc_vm_noaccess): only the runs between
     * them change, none opened even for a moment (a guest store there
     * would go untracked); one closed meanwhile is closed again after */
    for (uint32_t i = 0; i < n;) {
        if (g_na && __atomic_load_n(&g_na[page + i], __ATOMIC_ACQUIRE)) {
            i++;
            continue;
        }
        uint32_t k = 1;
        while (i + k < n && !(g_na && __atomic_load_n(&g_na[page + i + k], __ATOMIC_ACQUIRE))) {
            k++;
        }
        prot_views(vm, page + i, k, prot);
        for (uint32_t j = i; g_na && j < i + k; j++) {
            if (__atomic_load_n(&g_na[page + j], __ATOMIC_ACQUIRE)) {
                prot_views(vm, page + j, 1, PROT_NONE);
            }
        }
        i += k;
    }
    if (!ro) {
        for (uint32_t i = 0; i < n; i++) {
            __atomic_store_n(&vm->wp[page + i], 0, __ATOMIC_RELEASE);
        }
    }
    pthread_mutex_unlock(&g_prot_mu);
}

void nc_vm_noaccess(NcVm *vm, uint32_t pa, uint32_t n, bool on)
{
    const uint32_t page = pa / NC_PAGE;
    if (!n || (uint64_t)page + n > vm->ram_size / NC_PAGE) {
        return;
    }
    if (!g_na) {
        if (!on) {
            return;
        }
        uint8_t *na = calloc(vm->ram_size / NC_PAGE, 1);
        uint8_t *none = NULL;
        if (!na || !__atomic_compare_exchange_n(&g_na, &none, na, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            free(na);
        }
    }
    pthread_mutex_lock(&g_prot_mu);
    if (on) {
        /* marked first: a fault meanwhile finds its page marked */
        for (uint32_t i = 0; i < n; i++) {
            __atomic_store_n(&g_na[page + i], 1, __ATOMIC_RELEASE);
        }
        prot_views(vm, page, n, PROT_NONE);
        pthread_mutex_unlock(&g_prot_mu);
        return;
    }
    /* back to what write tracking wants, in runs of the same */
    for (uint32_t i = 0; i < n;) {
        const uint8_t wp = __atomic_load_n(&vm->wp[page + i], __ATOMIC_ACQUIRE);
        uint32_t k = 1;
        while (i + k < n && __atomic_load_n(&vm->wp[page + i + k], __ATOMIC_ACQUIRE) == wp) {
            k++;
        }
        prot_views(vm, page + i, k, wp == NC_WP_CLEAN ? PROT_READ : PROT_READ | PROT_WRITE);
        i += k;
    }
    for (uint32_t i = 0; i < n; i++) {
        __atomic_store_n(&g_na[page + i], 0, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_prot_mu);
}

bool nc_vm_noaccess_has(NcVm *vm, uint32_t pa)
{
    return g_na && pa < vm->ram_size && __atomic_load_n(&g_na[pa / NC_PAGE], __ATOMIC_ACQUIRE);
}

void nc_vm_protect_page(NcVm *vm, uint32_t pa, bool ro)
{
    nc_vm_protect_pages(vm, pa & ~(NC_PAGE - 1), 1, ro);
}

bool nc_vm_unmap(NcVm *vm, uint32_t va, uint32_t len)
{
#ifndef NC_VM16K
    void *want = vm->base + va;
    if (mmap(want, len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE, -1,
             0) != want) {
        return false;
    }
#endif
    for (uint32_t off = 0; off < len; off += NC_PAGE) {
        const uint32_t e = vm->pte[(va + off) / NC_PAGE];
        if ((e & NC_PTE_VALID) && vm->rmap[e / NC_PAGE] == va + off) {
            vm->rmap[e / NC_PAGE] = 0;
        }
        vm->pte[(va + off) / NC_PAGE] = 0;
    }
#ifdef NC_VM16K
    nc_vm16k_sync(vm, va, len);
#endif
    return true;
}

/* A page an address still maps, handed out again: its owner and the new one
 * both write it (the new one zeroes it, mostly). Logged, the first 16, with
 * the caller as an offset in this library (llvm-addr2line). */
static void check_unmapped(const NcVm *vm, uint32_t p, uint32_t pages, void *ra)
{
    static unsigned warned;
    for (uint32_t i = 0; i < pages && warned < 16; i++) {
        const uint32_t va = vm->rmap[p + i];
        if (va && vm->pte[va / NC_PAGE] == (((p + i) * NC_PAGE) | NC_PTE_VALID)) {
            warned++;
            Dl_info di;
            const uintptr_t base = dladdr((void *)check_unmapped, &di) ? (uintptr_t)di.dli_fbase : 0;
            nc_log("hakuX-native", "vm: allocated pa %08x (of %u pages) while %08x still maps it, from +%lx",
                   (p + i) * NC_PAGE, pages, va, (unsigned long)((uintptr_t)ra - base));
        }
    }
}

uint32_t nc_vm_alloc_phys_ex(NcVm *vm, uint32_t len, uint32_t lo, uint32_t hi, uint32_t align,
                             bool top_down)
{
    const uint32_t pages = nc_align_up(len ? len : 1, NC_PAGE) / NC_PAGE;
    const uint32_t step = (align > NC_PAGE ? align : NC_PAGE) / NC_PAGE;
    const uint32_t first = nc_align_up(lo, step * NC_PAGE) / NC_PAGE;
    const uint32_t last = (hi && hi < vm->ram_size ? hi : vm->ram_size) / NC_PAGE;
    if (last < pages || first > last - pages) {
        return UINT32_MAX;
    }
    const uint32_t top = (last - pages) / step * step;
    /* A window [p, p + pages) that meets a used page u fails, and so does
     * every other window over u: the next candidate is the first past u
     * (bottom-up) or the last that ends at u (top-down), not the next step.
     * Stepping one alignment at a time rescanned the run for every start:
     * The Warriors sizes its heap with ~2000 requests larger than the free
     * run, ~13 ms each that way. */
    uint32_t p = top_down ? top : first;
    for (;;) {
        if (p < first || p > top) {
            return UINT32_MAX;
        }
        uint32_t run = 0;
        while (run < pages && !vm->page_used[p + run]) {
            run++;
        }
        if (run == pages) {
            check_unmapped(vm, p, pages, __builtin_return_address(0));
            memset(vm->page_used + p, 1, pages);
            return p * NC_PAGE;
        }
        const uint32_t u = p + run;     /* the used page */
        if (top_down) {
            if (u < pages) {
                return UINT32_MAX;
            }
            const uint32_t q = (u - pages) / step * step;
            if (q >= p) {               /* (can't happen: u < p + pages) */
                return UINT32_MAX;
            }
            p = q;
        } else {
            p = (u + 1 + step - 1) / step * step;
        }
    }
}

static uint32_t free_pages(const NcVm *vm);
#ifdef NC_VM16K
static void fill_release(NcVm *vm, uint32_t first, uint32_t pages);
#endif

void nc_vm_free_phys(NcVm *vm, uint32_t pa, uint32_t len)
{
    const uint32_t pages = nc_align_up(len, NC_PAGE) / NC_PAGE;
    if ((uint64_t)pa + (uint64_t)pages * NC_PAGE <= vm->ram_size) {
        for (uint32_t p = pa / NC_PAGE; p < pa / NC_PAGE + pages; p++) {
            /* A page freed while an address still maps it is handed out twice. */
            const uint32_t va = vm->rmap[p];
            if (va && vm->pte[va / NC_PAGE] == ((p * NC_PAGE) | NC_PTE_VALID)) {
                static unsigned s_warned;
                if (s_warned++ < 16) {
                    nc_log("hakuX-native", "vm: pa %08x freed while %08x still maps it", p * NC_PAGE, va);
                }
            }
        }
        memset(vm->page_used + pa / NC_PAGE, 0, pages);
        memset(vm->pin + pa / NC_PAGE, 0, pages);
#ifdef NC_VM16K
        fill_release(vm, pa / NC_PAGE, pages);
#endif
        if (nc_vm_free_hook) {
            nc_vm_free_hook(pa, pages * NC_PAGE);
        }
    }
}

void nc_vm_pin(NcVm *vm, uint32_t pa, bool known, int lock)
{
    if (pa >= vm->ram_size) {
        return;
    }
    uint8_t *p = &vm->pin[pa / NC_PAGE];
    const unsigned count = *p & 0x7Fu;
    if (lock > 0 && count < 0x7F) {
        *p = (uint8_t)((*p & NC_PIN_KNOWN) | (count + 1));
    } else if (lock < 0 && count) {
        *p = (uint8_t)((*p & NC_PIN_KNOWN) | (count - 1));
    }
    if (known) {
        *p |= NC_PIN_KNOWN;
    }
}

/* A used page that can move: mapped at exactly the one VA its reverse map
 * names, not pinned, with guest access (without it, its RAM is older than
 * what the HLE puts there at the next access: nc_vm_noaccess). Tracked
 * pages move too (relocate). */
static bool movable(const NcVm *vm, uint32_t p)
{
    const uint32_t va = vm->rmap[p];
    return va && !vm->pin[p] && !(g_na && g_na[p]) && vm->pte[va / NC_PAGE] == ((p * NC_PAGE) | NC_PTE_VALID);
}

/* A free page a moved one can go to: one without guest access may still get
 * what the HLE owes it. */
static bool takes_move(const NcVm *vm, uint32_t p)
{
    return !vm->page_used[p] && !(g_na && g_na[p]);
}

#ifdef NC_VM16K
#define NC_HOST_PAGES (16384u / NC_PAGE)

/* The free physical page that, at va, completes the host block the other
 * pages of va's host page are mapped from (native/core/vm16k.c maps a host
 * page straight through only when it is one such block), or UINT32_MAX. */
bool nc_vm16k_plain(void)   /* NC_VM16K_PLAIN: no host-page-aware layout (A/B) */
{
    static int on = -1;
    if (on < 0) {
        on = getenv("NC_VM16K_PLAIN") != NULL;
    }
    return on;
}

bool nc_vm_is_fill(uint32_t page)
{
    return g_fill && g_fill[page];
}

/* A held page given to the guest page it was held for (page_used stays set) */
static void fill_take(uint32_t page)
{
    if (g_fill && g_fill[page]) {
        g_fill[page] = 0;
        g_nfill--;
    }
}

static uint32_t neighbor_page(const NcVm *vm, uint32_t va)
{
    if (nc_vm16k_plain()) {
        return UINT32_MAX;
    }
    const uint32_t vp = va / NC_PAGE, off = vp & (NC_HOST_PAGES - 1), ram_pages = vm->ram_size / NC_PAGE;
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        const uint32_t e = vm->pte[vp - off + i];
        if (i == off || !(e & NC_PTE_VALID)) {
            continue;
        }
        const uint32_t pp = e / NC_PAGE, t = pp - i + off;
        if ((pp & (NC_HOST_PAGES - 1)) == i && t < ram_pages && (takes_move(vm, t) || nc_vm_is_fill(t))) {
            return t;
        }
    }
    return UINT32_MAX;
}

static bool block_free(const NcVm *vm, uint32_t b, uint32_t w0, uint32_t w1)
{
    const uint32_t p = b * NC_HOST_PAGES;
    if (p < w1 && p + NC_HOST_PAGES > w0) {
        return false;
    }
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        if (!takes_move(vm, p + i)) {
            return false;
        }
    }
    return true;
}

/* The highest wholly free host block below *b and at or above lo, outside
 * pages [w0, w1): *b, from which the next search goes on (what it passed
 * stays taken while a window's pages move), or UINT32_MAX. */
static uint32_t free_block_down(const NcVm *vm, uint32_t *b, uint32_t lo, uint32_t w0, uint32_t w1)
{
    while (*b > lo) {
        if (block_free(vm, --*b, w0, w1)) {
            return *b;
        }
    }
    return UINT32_MAX;
}

static uint32_t free_block_up(const NcVm *vm, uint32_t *b, uint32_t hi, uint32_t w0, uint32_t w1)
{
    for (; *b < hi; ++*b) {
        if (block_free(vm, *b, w0, w1)) {
            return (*b)++;
        }
    }
    return UINT32_MAX;
}

/* Where moved page q goes so its host page stays one block: beside its
 * neighbors, else in a wholly free block at its offset (its neighbors
 * follow it there), or UINT32_MAX. */
static uint32_t move_target(const NcVm *vm, uint32_t q, uint32_t w0, uint32_t w1, uint32_t *down, uint32_t *up,
                            uint32_t below)
{
    if (nc_vm16k_plain()) {
        return UINT32_MAX;
    }
    const uint32_t va = vm->rmap[q], off = (va / NC_PAGE) & (NC_HOST_PAGES - 1);
    uint32_t t = neighbor_page(vm, va);
    if (t != UINT32_MAX && (t < w0 || t >= w1)) {
        return t;
    }
    uint32_t b = UINT32_MAX;
    if (down) {
        b = free_block_down(vm, &down[0], 0, w0, w1);
        if (b == UINT32_MAX) {
            b = free_block_down(vm, &down[1], below / NC_HOST_PAGES, w0, w1);
        }
    } else {
        b = free_block_up(vm, up, vm->ram_size / NC_PAGE / NC_HOST_PAGES, w0, w1);
    }
    return b != UINT32_MAX ? b * NC_HOST_PAGES + off : UINT32_MAX;
}
#endif

/* Movable page q's contents, and the VA mapping it, to free page `to`.
 * Write tracking follows physical pages, freed ones too, and the HLE knows
 * them by physical address: GPU work may still read either page in place,
 * and what the HLE saw in them is neither page's contents from here on (q
 * goes to the new block, `to` holds the VA's page). A tracked one waits for
 * that GPU work, and both are reported written: dirty, untracked. Copied
 * unreported, a page took over the tracking of what `to` held, faulted as
 * the guest wrote it and never moved again: Project Gotham Racing 2's
 * image pages, moved out of earlier blocks' way onto freed textures,
 * left no window for its attract replay's 20 MiB. */
static bool relocate(NcVm *vm, uint32_t q, uint32_t to)
{
    const bool tracked = vm->wp[q] || vm->wp[to];
    if (tracked && nc_vm_dma.fence) {
        const uint64_t a = nc_vm_dma.fence(q * NC_PAGE, NC_PAGE), b = nc_vm_dma.fence(to * NC_PAGE, NC_PAGE);
        nc_vm_dma.wait(a > b ? a : b);
    }
    const uint32_t va = vm->rmap[q];
    memcpy(vm->ram + (size_t)to * NC_PAGE, vm->ram + (size_t)q * NC_PAGE, NC_PAGE);
#ifdef NC_VM16K
    fill_take(to);
#endif
    vm->page_used[to] = 1;
    if (!nc_vm_map(vm, va, to * NC_PAGE, NC_PAGE)) {
        vm->page_used[to] = 0;
        return false;
    }
    vm->rmap[q] = 0;
    vm->page_used[q] = 0;
    if (tracked && nc_vm_dma.wrote) {
        nc_vm_dma.wrote(q * NC_PAGE, NC_PAGE);
        nc_vm_dma.wrote(to * NC_PAGE, NC_PAGE);
    }
    return true;
}

#ifdef NC_VM16K
/* Virtual memory committed a page at a time as RAM runs short scatters over
 * whatever pages are free, and its host pages are trapped: Halo's heap,
 * filled through the first level's load, had each of its accesses emulated
 * (450k a second, 7 fps). From the highest wholly free blocks below the
 * top reserve, as virtual memory packs at the top. */
/* Held pages go back once none of their block is in use. */
static void fill_release(NcVm *vm, uint32_t first, uint32_t pages)
{
    if (!g_nfill) {
        return;
    }
    for (uint32_t b = first / NC_HOST_PAGES; b <= (first + pages - 1) / NC_HOST_PAGES; b++) {
        bool held = false, used = false;
        for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
            const uint32_t p = b * NC_HOST_PAGES + i;
            held |= g_fill[p] != 0;
            used |= vm->page_used[p] && !g_fill[p];
        }
        if (held && !used) {
            for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
                const uint32_t p = b * NC_HOST_PAGES + i;
                if (g_fill[p]) {
                    g_fill[p] = 0;
                    vm->page_used[p] = 0;
                    g_nfill--;
                }
            }
        }
    }
}

/* Held pages of blocks no longer mapped straight through (their pages
 * freed, moved, or a gap mapped from elsewhere) go back: the host pages they
 * were held for are trapped already. */
static bool needs_hold(const NcVm *vm, uint32_t vp);

static void fill_sweep(NcVm *vm)
{
    const uint32_t blocks = vm->ram_size / NC_PAGE / NC_HOST_PAGES;
    for (uint32_t b = 0; b < blocks && g_nfill; b++) {
        const uint32_t p0 = b * NC_HOST_PAGES;
        bool held = false;
        for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
            held |= g_fill[p0 + i] != 0;
        }
        if (!held) {
            continue;
        }
        /* live: every other page of the block mapped at its offset of one
         * host page, whose gaps are the held pages' places */
        bool live = true;
        uint32_t vbase = UINT32_MAX;
        for (uint32_t i = 0; i < NC_HOST_PAGES && live; i++) {
            const uint32_t p = p0 + i, va = vm->rmap[p];
            if (g_fill[p]) {
                continue;
            }
            live = vm->page_used[p] && va && vm->pte[va / NC_PAGE] == ((p * NC_PAGE) | NC_PTE_VALID) &&
                   (va / NC_PAGE) % NC_HOST_PAGES == i && (vbase == UINT32_MAX || vbase == va / NC_PAGE - i);
            vbase = va / NC_PAGE - i;
        }
        for (uint32_t i = 0; i < NC_HOST_PAGES && live; i++) {
            live = vbase != UINT32_MAX && (!g_fill[p0 + i] || needs_hold(vm, vbase + i));
        }
        if (live) {
            continue;
        }
        for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
            if (g_fill[p0 + i]) {
                g_fill[p0 + i] = 0;
                vm->page_used[p0 + i] = 0;
                g_nfill--;
            }
        }
    }
}

/* RAM run out: every held page back to the title, their host pages trapped
 * again (synced before the pages are handed out). False if none was held. */
static bool fill_drop_all(NcVm *vm)
{
    if (!g_nfill) {
        return false;
    }
    const uint32_t blocks = vm->ram_size / NC_PAGE / NC_HOST_PAGES;
    for (uint32_t b = 0; b < blocks; b++) {
        const uint32_t p0 = b * NC_HOST_PAGES;
        uint32_t va = 0;
        bool held = false;
        for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
            const uint32_t p = p0 + i;
            if (g_fill[p]) {
                g_fill[p] = 0;
                vm->page_used[p] = 0;
                held = true;
            } else if (vm->page_used[p] && vm->rmap[p]) {
                va = vm->rmap[p] & ~(NC_HOST_PAGES * NC_PAGE - 1);
            }
        }
        if (held && va) {
            nc_vm16k_sync(vm, va, NC_HOST_PAGES * NC_PAGE);
        }
    }
    nc_log("hakuX-native-vm16k", "RAM short: %u held pages given back", g_nfill);
    g_nfill = 0;
    return true;
}

/* At most an eighth of the free pages held, the title running short first. */
static bool fill_room(NcVm *vm, uint32_t need)
{
    const uint32_t room = g_nfill + free_pages(vm) / 8, cap = room < NC_FILL_MAX ? room : NC_FILL_MAX;
    if (g_nfill + need > cap) {
        fill_sweep(vm);
    }
    return g_nfill + need <= cap;
}

/* An unmapped guest page whose place in its host block needs holding: one
 * the guest may access (committed, its page not in yet). One it has no
 * access to may share its place with any page (native/core/vm16k.c). */
static bool needs_hold(const NcVm *vm, uint32_t vp)
{
    return !(vm->pte[vp] & NC_PTE_VALID) && vm->vprot[vp];
}

/* A partly mapped host page whose pages already sit at their offsets in an
 * aligned block, the block's other pages free: those held, no copy (the
 * pages needn't be movable). */
static bool fill_in_place(NcVm *vm, uint32_t vp)
{
    const uint32_t ram_pages = vm->ram_size / NC_PAGE;
    uint32_t base = UINT32_MAX, holes = 0;
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        const uint32_t e = vm->pte[vp + i];
        if (!(e & NC_PTE_VALID)) {
            holes++;
            continue;
        }
        const uint32_t b0 = e / NC_PAGE - i;
        if (e / NC_PAGE < i || (b0 & (NC_HOST_PAGES - 1)) || (base != UINT32_MAX && b0 != base)) {
            return false;
        }
        base = b0;
    }
    if (base == UINT32_MAX || !holes || base + NC_HOST_PAGES > ram_pages) {
        return false;
    }
    uint32_t need = 0;
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        if (needs_hold(vm, vp + i) && !g_fill[base + i]) {
            if (vm->page_used[base + i]) {
                return false;
            }
            need++;
        }
    }
    if (!fill_room(vm, need)) {
        return false;
    }
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        if (needs_hold(vm, vp + i) && !g_fill[base + i]) {
            vm->page_used[base + i] = 1;
            g_fill[base + i] = 1;
            g_nfill++;
        }
    }
    return true;
}

/* A host page's pages gathered into one aligned block with no wholly free
 * block needed: the block its fixed pages (pinned: the title has their
 * physical addresses, or DMA does) sit in, else the one most of them do.
 * What holds their places moves out first, to free pages at the same
 * offset elsewhere. Forza's race buffers, pinned by MmGetPhysicalAddress,
 * had each a page or two in other blocks, and its race load, RAM short and
 * no block free, scattered pages a page at a time making room for
 * contiguous memory. */
static uint32_t congruent_fit(const NcVm *vm, uint32_t first, uint32_t last, uint32_t pages, uint32_t want,
                              bool highest);

static unsigned s_done, s_skipped;   /* regroup's, for its summary */
static unsigned s_why[6];
static const char *const k_why[6] = { "fixed pages disagree", "none in place", "a place fixed", "no room to hold",
                                      "a place direct", "nowhere to move out" };

static bool anchor_fail(unsigned why)
{
    s_why[why]++;
    return false;
}
static time_t s_since;

static bool regroup_anchor(NcVm *vm, uint32_t vp)
{
    const uint32_t ram_pages = vm->ram_size / NC_PAGE;
    uint32_t base = UINT32_MAX;
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        const uint32_t e = vm->pte[vp + i], p = e / NC_PAGE;
        if (!(e & NC_PTE_VALID) || (p < ram_pages && movable(vm, p))) {
            continue;
        }
        const uint32_t b0 = p - i;
        if (p >= ram_pages || p < i || (b0 & (NC_HOST_PAGES - 1)) || (base != UINT32_MAX && b0 != base)) {
            return anchor_fail(0);
        }
        base = b0;
    }
    if (base == UINT32_MAX) {
        /* none fixed: the block most of its pages already sit in place in */
        unsigned best = 0;
        for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
            const uint32_t e = vm->pte[vp + i], p = e / NC_PAGE;
            if (!(e & NC_PTE_VALID) || p < i || ((p - i) & (NC_HOST_PAGES - 1))) {
                continue;
            }
            unsigned n = 0;
            for (uint32_t j = 0; j < NC_HOST_PAGES; j++) {
                n += (vm->pte[vp + j] & NC_PTE_VALID) && vm->pte[vp + j] / NC_PAGE == p - i + j;
            }
            if (n > best) {
                best = n;
                base = p - i;
            }
        }
        if (base == UINT32_MAX || base + NC_HOST_PAGES > ram_pages) {
            return anchor_fail(1);
        }
    }
    /* each place: its page already, free, held, or a movable page (moved
     * out; one of this host page's own moves on to its place after) */
    uint32_t need = 0;
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        const uint32_t e = vm->pte[vp + i], t = base + i;
        if ((e & NC_PTE_VALID) && e / NC_PAGE == t) {
            continue;
        }
        if (!(e & NC_PTE_VALID) && !needs_hold(vm, vp + i)) {
            continue;
        }
        /* not a page of another host page mapped straight through: they'd
         * take each other's places in turn */
        if (vm->page_used[t] && !g_fill[t] && !movable(vm, t)) {
            return anchor_fail(2);
        }
        if (vm->page_used[t] && !g_fill[t] && vm->rmap[t] / NC_PAGE - vp >= NC_HOST_PAGES &&
            nc_vm16k_direct(vm, vm->rmap[t])) {
            return anchor_fail(4);
        }
        need += !(e & NC_PTE_VALID) && !g_fill[t];
    }
    if (need && !fill_room(vm, need)) {
        return anchor_fail(3);
    }
    /* the free places taken first, so no page moving out goes there */
    bool act[NC_HOST_PAGES] = {false}, claimed[NC_HOST_PAGES] = {false};
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        const uint32_t e = vm->pte[vp + i], t = base + i;
        act[i] = !((e & NC_PTE_VALID) && e / NC_PAGE == t) && ((e & NC_PTE_VALID) || needs_hold(vm, vp + i));
        if (act[i] && !vm->page_used[t]) {
            vm->page_used[t] = 1;
            claimed[i] = true;
        }
    }
    bool ok = true;
    for (uint32_t i = 0; i < NC_HOST_PAGES && ok; i++) {
        const uint32_t t = base + i;
        if (act[i] && !claimed[i] && !g_fill[t]) {   /* another host page's: out */
            const uint32_t dest = congruent_fit(vm, 0, ram_pages, 1, t & (NC_HOST_PAGES - 1), true);
            ok = dest != UINT32_MAX && relocate(vm, t, dest);
            if (!ok) {
                anchor_fail(5);
            }
            if (ok) {
                vm->page_used[t] = 1;
                claimed[i] = true;
            }
        }
    }
    for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
        const uint32_t e = vm->pte[vp + i], t = base + i;
        if (!act[i]) {
            continue;
        }
        if (!ok) {
            if (claimed[i]) {
                vm->page_used[t] = 0;
            }
        } else if (e & NC_PTE_VALID) {
            ok = relocate(vm, e / NC_PAGE, t);   /* onto its claimed or held place */
        } else if (!g_fill[t]) {
            g_fill[t] = 1;
            g_nfill++;
        }
    }
    return ok;
}

void nc_vm_regroup(NcVm *vm)
{
    uint32_t want[32];
    const unsigned n = nc_vm16k_want_take(want, 32);
    if (!n || nc_vm16k_plain()) {
        return;
    }
    const uint32_t ram_pages = vm->ram_size / NC_PAGE;
    const uint32_t below = NC_TOP_RESERVE / NC_PAGE < ram_pages ? ram_pages - NC_TOP_RESERVE / NC_PAGE : ram_pages;
    uint32_t down = below / NC_HOST_PAGES;
    unsigned done = 0;
    if (!g_fill) {
        g_fill = calloc(ram_pages, 1);
    }
    for (unsigned w = 0; w < n; w++) {
        const uint32_t vp = want[w] / NC_PAGE;
        if (fill_in_place(vm, vp) || regroup_anchor(vm, vp)) {
            nc_vm16k_sync(vm, want[w], NC_HOST_PAGES * NC_PAGE);
            done++;
            continue;
        }
        bool ok = true;
        uint32_t holes = 0;
        for (uint32_t i = 0; i < NC_HOST_PAGES && ok; i++) {
            const uint32_t e = vm->pte[vp + i];
            holes += needs_hold(vm, vp + i);
            ok = !(e & NC_PTE_VALID) || (e / NC_PAGE < ram_pages && movable(vm, e / NC_PAGE));
        }
        /* a host page only partly mapped: its unmapped guest pages' places
         * held (a few, as they're RAM the title doesn't get) */
        bool any = false;
        for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
            any |= (vm->pte[vp + i] & NC_PTE_VALID) != 0;
        }
        if (!ok || !any || (holes && (!g_fill || !fill_room(vm, holes)))) {
            s_skipped++;
            static uint32_t s_seen[32];
            static unsigned s_logged;
            bool seen = false;
            for (unsigned i = 0; i < s_logged && i < 32; i++) {
                seen |= s_seen[i] == want[w];
            }
            if (!seen && s_logged < 32) {
                s_seen[s_logged++] = want[w];
                char why[160];
                int o = 0;
                for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
                    const uint32_t e = vm->pte[vp + i], p = e / NC_PAGE;
                    o += snprintf(why + o, sizeof why - o, " %08x%s", e,
                                  !(e & NC_PTE_VALID) ? ""
                                  : p >= ram_pages    ? "(rom)"
                                  : vm->pin[p]        ? "(pinned)"
                                  : movable(vm, p)    ? ""
                                                      : "(fixed)");
                }
                nc_log("hakuX-native-vm16k", "regroup %08x skipped:%s, %u held", want[w], why, g_nfill);
            }
            continue;
        }
        const uint32_t b = free_block_down(vm, &down, 0, 0, 0);
        if (b == UINT32_MAX) {
            s_skipped += n - w;
            break;
        }
        for (uint32_t i = 0; i < NC_HOST_PAGES; i++) {
            const uint32_t to = b * NC_HOST_PAGES + i;
            if (needs_hold(vm, vp + i)) {
                vm->page_used[to] = 1;
                g_fill[to] = 1;
                g_nfill++;
            }
        }
        for (uint32_t i = 0; i < NC_HOST_PAGES && ok; i++) {
            if (vm->pte[vp + i] & NC_PTE_VALID) {
                ok = relocate(vm, vm->pte[vp + i] / NC_PAGE, b * NC_HOST_PAGES + i);
            }
        }
        nc_vm16k_sync(vm, want[w], NC_HOST_PAGES * NC_PAGE);
        done += ok;
    }
    s_done += done;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - s_since >= 5) {
        nc_log("hakuX-native-vm16k",
               "regroup: %u host pages regrouped, %u not, in %lld s (%u pages held, %u KiB free); in place: "
               "%s %u, %s %u, %s %u, %s %u, %s %u, %s %u",
               s_done, s_skipped, (long long)(now.tv_sec - s_since), g_nfill, free_pages(vm) * (NC_PAGE >> 10),
               k_why[0], s_why[0], k_why[1], s_why[1], k_why[2], s_why[2], k_why[3], s_why[3], k_why[4], s_why[4],
               k_why[5], s_why[5]);
        uint64_t runs, copies, backs;
        unsigned sites;
        uint32_t direct, trapped;
        uint64_t emulated;
        nc_vm16k_site_stats(&runs, &copies, &backs, &sites);
        nc_vm16k_census(vm, &direct, &trapped, &emulated);
        nc_log("hakuX-native-vm16k", "sites: %u patched, %llu runs, %llu copies run, %llu sent back; %llu accesses emulated",
               sites, (unsigned long long)runs, (unsigned long long)copies, (unsigned long long)backs, (unsigned long long)emulated);
        s_since = now.tv_sec;
        s_done = s_skipped = 0;
        memset(s_why, 0, sizeof(s_why));
    }
}
#endif

uint32_t nc_vm_alloc_phys_compact(NcVm *vm, uint32_t len, uint32_t lo, uint32_t hi, uint32_t align, uint32_t *moved)
{
    *moved = 0;
    const uint32_t pages = nc_align_up(len ? len : 1, NC_PAGE) / NC_PAGE;
    const uint32_t step = (align > NC_PAGE ? align : NC_PAGE) / NC_PAGE;
    const uint32_t first = nc_align_up(lo, step * NC_PAGE) / NC_PAGE;
    const uint32_t last = (hi && hi < vm->ram_size ? hi : vm->ram_size) / NC_PAGE;
    if (last < pages || first > last - pages) {
        return UINT32_MAX;
    }
    const uint32_t free_all = free_pages(vm);
    /* The window needing the fewest moves, the highest of equals. */
    uint32_t best = UINT32_MAX, best_used = UINT32_MAX;
    for (int64_t s = (int64_t)((last - pages) / step * step); s >= first; s -= step) {
        uint32_t used = 0;
        bool ok = true;
        for (uint32_t i = 0; i < pages && ok; i++) {
            const uint32_t p = (uint32_t)s + i;
            if (vm->page_used[p]) {
                ok = movable(vm, p);
                used++;
            }
        }
        if (ok && free_all - (pages - used) >= used && used < best_used) {
            best = (uint32_t)s;
            best_used = used;
        }
    }
    if (best == UINT32_MAX) {
        return UINT32_MAX;
    }
    /* Each used page goes to the lowest free page outside the window, anywhere
     * in RAM: the range bounds the new block, not the virtual pages moved out
     * of its way (a 16 MiB bound ran the search to page `last`, in use, and
     * mapped two addresses onto it: Blinx's model data). */
    const uint32_t ram_pages = vm->ram_size / NC_PAGE;
    uint32_t to = 0;
#ifdef NC_VM16K
    uint32_t up = 0;
#endif
    for (uint32_t p = best; p < best + pages; p++) {
        if (!vm->page_used[p]) {
            continue;
        }
#ifdef NC_VM16K
        const uint32_t t = move_target(vm, p, best, best + pages, NULL, &up, 0);
        if (t != UINT32_MAX) {
            if (!relocate(vm, p, t)) {
                return UINT32_MAX;
            }
            (*moved)++;
            continue;
        }
#endif
        while (to < ram_pages && (!takes_move(vm, to) || (to >= best && to < best + pages))) {
            to++;
        }
        if (to >= ram_pages || !relocate(vm, p, to)) {
            return UINT32_MAX;
        }
        (*moved)++;
    }
    memset(vm->page_used + best, 1, pages);
    return best * NC_PAGE;
}

/* As the Xbox kernel's MmAllocateContiguousMemory: the highest window in
 * [lo, hi) whose pages are free or can move, the ones that can moved to the
 * highest free pages outside it (below the top reserve while there are
 * any). What never moves (contiguous blocks, the kernel's own) packs at the
 * top of RAM, virtual memory below it, and what is free gathers in one run
 * at the bottom. Taking only free windows put such blocks under the virtual
 * pages (which take the highest free pages first), and once the memory
 * around them was freed they were stranded in the middle: Fable's new game
 * asks for 6.7 MiB with 15 MiB free, and a 56 KiB contiguous block and a
 * 24 KiB kernel block at 0x650000 left no window. */
uint32_t nc_vm_alloc_phys_top(NcVm *vm, uint32_t len, uint32_t lo, uint32_t hi, uint32_t align, uint32_t *moved)
{
    *moved = 0;
    const uint32_t pages = nc_align_up(len ? len : 1, NC_PAGE) / NC_PAGE;
    const uint32_t step = (align > NC_PAGE ? align : NC_PAGE) / NC_PAGE;
    const uint32_t first = nc_align_up(lo, step * NC_PAGE) / NC_PAGE;
    const uint32_t last = (hi && hi < vm->ram_size ? hi : vm->ram_size) / NC_PAGE;
    if (last < pages || first > last - pages) {
        return UINT32_MAX;
    }
    /* A window over a page that can't move fails, and so does every other
     * window over it: the next candidate is the highest that ends below it,
     * so each page is looked at once. */
    uint32_t p = (last - pages) / step * step, used;
    for (;;) {
        if (p < first) {
            return UINT32_MAX;
        }
        uint32_t i = pages;
        used = 0;
        for (; i > 0; i--) {
            const uint32_t q = p + i - 1;
            if (vm->page_used[q]) {
                if (!movable(vm, q)) {
                    break;
                }
                used++;
            }
        }
        if (i == 0) {
            break;
        }
        const uint32_t u = p + i - 1;   /* the page that can't move */
        if (u < first + pages) {
            return UINT32_MAX;
        }
        p = (u - pages) / step * step;
    }
    if (used && free_pages(vm) - (pages - used) < used) {
        return UINT32_MAX;              /* nowhere to move them */
    }
    const uint32_t ram_pages = vm->ram_size / NC_PAGE;
    const uint32_t below = NC_TOP_RESERVE / NC_PAGE < ram_pages ? ram_pages - NC_TOP_RESERVE / NC_PAGE : ram_pages;
    int64_t to = below;
    bool reserve = false;
#ifdef NC_VM16K
    uint32_t down[2] = {below / NC_HOST_PAGES, ram_pages / NC_HOST_PAGES};
#endif
    for (uint32_t q = p; used && q < p + pages; q++) {
        if (!vm->page_used[q]) {
            continue;
        }
#ifdef NC_VM16K
        const uint32_t t = move_target(vm, q, p, p + pages, down, NULL, below);
        if (t != UINT32_MAX) {
            if (!relocate(vm, q, t)) {
                return UINT32_MAX;
            }
            (*moved)++;
            continue;
        }
#endif
        for (;;) {
            if (--to < (reserve ? (int64_t)below : 0)) {
                if (reserve) {
                    return UINT32_MAX;
                }
                reserve = true;         /* then in the reserve */
                to = ram_pages;
                continue;
            }
            if (takes_move(vm, (uint32_t)to) && (to < p || to >= p + pages)) {
                break;
            }
        }
        if (!relocate(vm, q, (uint32_t)to)) {
            return UINT32_MAX;
        }
        (*moved)++;
    }
    check_unmapped(vm, p, pages, __builtin_return_address(0));
    memset(vm->page_used + p, 1, pages);
    return p * NC_PAGE;
}

bool nc_vm_claim_phys(NcVm *vm, uint32_t pa, uint32_t len)
{
    if ((pa | len) & (NC_PAGE - 1) || (uint64_t)pa + len > vm->ram_size) {
        return false;
    }
    for (uint32_t p = pa / NC_PAGE; p < (pa + len) / NC_PAGE; p++) {
        if (vm->page_used[p]) {
            return false;
        }
        vm->page_used[p] = 1;
    }
    return true;
}

/* The smallest free run in pages [first, last) of at least want pages
 * (the highest of equals): its first page, its length in *run. */
static uint32_t smallest_run(const NcVm *vm, uint32_t first, uint32_t last, uint32_t want, uint32_t *run)
{
    uint32_t best = UINT32_MAX, best_len = UINT32_MAX;
    for (uint32_t p = first; p < last;) {
        if (vm->page_used[p]) {
            p++;
            continue;
        }
        uint32_t q = p;
        while (q < last && !vm->page_used[q]) {
            q++;
        }
        if (q - p >= want && q - p <= best_len) {
            best = p;
            best_len = q - p;
        }
        p = q;
    }
    *run = best_len;
    return best;
}

/* Best fit: the smallest free run that holds it, so that small and
 * long-lived allocations (page tables) fill holes and leave the
 * large runs whole for MmAllocateContiguousMemory; from the top end of the
 * run, the highest of equals, so the kernel's own memory stays high (low RAM
 * is the title's: nc_vm_alloc_at; the pool's first range sits just above
 * the kernel, kernel.c POOL_BASE). */
uint32_t nc_vm_alloc_phys(NcVm *vm, uint32_t len, uint32_t lo, uint32_t hi)
{
    const uint32_t pages = nc_align_up(len ? len : 1, NC_PAGE) / NC_PAGE;
    const uint32_t first = lo / NC_PAGE, last = (hi < vm->ram_size ? hi : vm->ram_size) / NC_PAGE;
    uint32_t run;
    uint32_t p = smallest_run(vm, first, last, pages, &run);
#ifdef NC_VM16K
    if (p == UINT32_MAX && fill_drop_all(vm)) {
        p = smallest_run(vm, first, last, pages, &run);
    }
#endif
    if (p == UINT32_MAX) {
        return UINT32_MAX;
    }
    p += run - pages;
    check_unmapped(vm, p, pages, __builtin_return_address(0));
    memset(vm->page_used + p, 1, pages);
    return p * NC_PAGE;
}

#ifdef NC_VM16K
/* The highest start s in free run [p, q) for `pages` pages with s = want
 * (mod NC_HOST_PAGES), or UINT32_MAX. */
static uint32_t congruent_start(uint32_t p, uint32_t q, uint32_t pages, uint32_t want)
{
    if (q - p < pages) {
        return UINT32_MAX;
    }
    const uint32_t s = q - pages, t = s - ((s - want) & (NC_HOST_PAGES - 1));
    return t >= p && t <= s ? t : UINT32_MAX;
}

/* In pages [first, last): the best fit (smallest run, the highest of equals)
 * or the highest start, among starts congruent to want. */
static uint32_t congruent_fit(const NcVm *vm, uint32_t first, uint32_t last, uint32_t pages, uint32_t want,
                              bool highest)
{
    uint32_t best = UINT32_MAX, best_len = UINT32_MAX;
    for (uint32_t p = first; p < last;) {
        if (vm->page_used[p]) {
            p++;
            continue;
        }
        uint32_t q = p;
        while (q < last && !vm->page_used[q]) {
            q++;
        }
        const uint32_t s = congruent_start(p, q, pages, want);
        if (s != UINT32_MAX && (highest || q - p <= best_len)) {
            best = s;
            best_len = q - p;
        }
        p = q;
    }
    return best;
}
#endif

uint32_t nc_vm_alloc_phys_va(NcVm *vm, uint32_t va, uint32_t len, uint32_t lo, uint32_t hi)
{
#ifdef NC_VM16K
    const uint32_t pages = nc_align_up(len ? len : 1, NC_PAGE) / NC_PAGE;
    const uint32_t first = lo / NC_PAGE, last = (hi < vm->ram_size ? hi : vm->ram_size) / NC_PAGE;
    const uint32_t n = neighbor_page(vm, va);
    if (n != UINT32_MAX && n >= first && n + pages <= last &&
        (n & (NC_HOST_PAGES - 1)) + pages <= NC_HOST_PAGES) {
        uint32_t i = 1;
        while (i < pages && (takes_move(vm, n + i) || nc_vm_is_fill(n + i))) {
            i++;
        }
        if (i == pages) {
            for (i = 0; i < pages; i++) {
                fill_take(n + i);
            }
            check_unmapped(vm, n, pages, __builtin_return_address(0));
            memset(vm->page_used + n, 1, pages);
            return n * NC_PAGE;
        }
    }
    const uint32_t p = congruent_fit(vm, first, last, pages, (va / NC_PAGE) & (NC_HOST_PAGES - 1), false);
    if (p != UINT32_MAX) {
        check_unmapped(vm, p, pages, __builtin_return_address(0));
        memset(vm->page_used + p, 1, pages);
        return p * NC_PAGE;
    }
#endif
    return nc_vm_alloc_phys(vm, len, lo, hi);
}

/* The kernel's own blocks of more than a page (large Ex blocks, pool chunks)
 * never move (they are reached through the contiguous window): placed as a
 * contiguous allocation (nc_vm_alloc_phys_top), below the top reserve if
 * they can. */
uint32_t nc_vm_alloc_phys_high(NcVm *vm, uint32_t len)
{
    uint32_t moved;
    const uint32_t pa = nc_vm_alloc_phys_top(vm, len, 0, vm->ram_size - NC_TOP_RESERVE, NC_PAGE, &moved);
    return pa != UINT32_MAX ? pa : nc_vm_alloc_phys_top(vm, len, 0, vm->ram_size, NC_PAGE, &moved);
}

static uint32_t free_pages(const NcVm *vm)
{
    uint32_t n = 0;
    for (uint32_t p = 0; p < vm->ram_size / NC_PAGE; p++) {
        n += !vm->page_used[p];
    }
    return n;
}

uint32_t nc_vm_free_bytes(const NcVm *vm)
{
    return free_pages(vm) * NC_PAGE;
}

void nc_vm_free_runs(const NcVm *vm, char *buf, size_t len)
{
    const uint32_t pages = vm->ram_size / NC_PAGE;
    uint32_t runs = 0, largest = 0;
    int n = 0;
    buf[0] = 0;
    for (uint32_t p = 0; p < pages;) {
        if (vm->page_used[p]) {
            p++;
            continue;
        }
        uint32_t q = p;
        while (q < pages && !vm->page_used[q]) {
            q++;
        }
        runs++;
        largest = q - p > largest ? q - p : largest;
        if (q - p >= 16 && n >= 0 && (size_t)n < len - 40) { /* runs of 64 KiB or more */
            n += snprintf(buf + n, len - (size_t)n, " %x+%uK", p * NC_PAGE, (q - p) * (NC_PAGE >> 10));
        }
        p = q;
    }
    if (n >= 0 && (size_t)n < len - 48) {
        snprintf(buf + n, len - (size_t)n, " | %u runs, largest %u KiB", runs, largest * (NC_PAGE >> 10));
    }
}

/* Zeroed pages at va. With pa_out the memory is one physical run; without,
 * any free pages back it: the highest free pages first, below the top
 * NC_TOP_RESERVE (the GPU's instance memory), so that virtual memory packs at
 * the top of RAM with the contiguous allocations (which also come from the
 * top) and what is free gathers in one run at the bottom (pages strewn over
 * RAM left Fable no 3.6 MiB run with 7 MiB free). Low RAM stays free for the
 * title, as on the Xbox: Halo asks for its game state at physical 0x61000,
 * just above the kernel, and 0x3A6000 (25 MiB in all) at start, after its
 * image, heap and stacks have their pages. */
bool nc_vm_alloc_at(NcVm *vm, uint32_t va, uint32_t len, uint32_t *pa_out)
{
    len = nc_align_up(len, NC_PAGE);
    const uint32_t ram_pages = vm->ram_size / NC_PAGE;
    for (uint32_t done = 0; done < len;) {
        uint32_t piece = len - done, pa = UINT32_MAX;
#ifdef NC_VM16K
        /* beside the pages of its host page already mapped; else the
         * highest free run that lands in va's host pages (below the reserve,
         * else in it), halved until one does */
        if (!pa_out && (pa = neighbor_page(vm, va + done)) != UINT32_MAX) {
            piece = NC_PAGE;
            fill_take(pa);
            vm->page_used[pa] = 1;
            pa *= NC_PAGE;
        }
        if (!pa_out && pa == UINT32_MAX) {
            const uint32_t want = ((va + done) / NC_PAGE) & (NC_HOST_PAGES - 1);
            const uint32_t reserve = NC_TOP_RESERVE / NC_PAGE < ram_pages ? NC_TOP_RESERVE / NC_PAGE : 0;
            for (uint32_t n = piece; n >= NC_PAGE && pa == UINT32_MAX;
                 n = n > NC_PAGE ? nc_align_up(n / 2, NC_PAGE) : 0) {
                uint32_t p = congruent_fit(vm, 0, ram_pages - reserve, n / NC_PAGE, want, true);
                if (p == UINT32_MAX) {
                    p = congruent_fit(vm, ram_pages - reserve, ram_pages, n / NC_PAGE, want, true);
                }
                if (p != UINT32_MAX) {
                    piece = n;
                    memset(vm->page_used + p, 1, piece / NC_PAGE);
                    pa = p * NC_PAGE;
                }
            }
        }
#endif
        if (pa_out) {
            pa = nc_vm_alloc_phys_va(vm, va + done, piece, 0, vm->ram_size);
        } else if (pa == UINT32_MAX) {
            /* the highest free page below the reserve, else in it */
            const uint32_t reserve = NC_TOP_RESERVE / NC_PAGE < ram_pages ? NC_TOP_RESERVE / NC_PAGE : 0;
            uint32_t top = UINT32_MAX;
            for (uint32_t p = ram_pages - reserve; p-- > 0;) {
                if (!vm->page_used[p]) {
                    top = p;
                    break;
                }
            }
            for (uint32_t p = ram_pages; top == UINT32_MAX && p-- > ram_pages - reserve;) {
                if (!vm->page_used[p]) {
                    top = p;
                }
            }
            if (top != UINT32_MAX) {
                uint32_t q = top + 1, p = top;   /* the run [p, q) down from it */
                while (p > 0 && !vm->page_used[p - 1] && (q - p) * NC_PAGE < piece) {
                    p--;
                }
                piece = (q - p) * NC_PAGE;
                memset(vm->page_used + p, 1, q - p);
                pa = p * NC_PAGE;
            }
        }
#ifdef NC_VM16K
        if (pa == UINT32_MAX && fill_drop_all(vm)) {
            continue;
        }
#endif
        if (pa == UINT32_MAX) {
            nc_log("hakuX-native", "vm: out of physical memory for %u KiB at %08x (%u KiB free)", len >> 10, va,
                   free_pages(vm) * (NC_PAGE >> 10));
            for (uint32_t p = va; p < va + done; p += NC_PAGE) {
                const uint32_t got = nc_vm_phys(vm, p);
                if (got != UINT32_MAX) {
                    nc_vm_unmap(vm, p, NC_PAGE);
                    nc_vm_free_phys(vm, got & ~(NC_PAGE - 1), NC_PAGE);
                }
            }
            return false;
        }
        if (!nc_vm_map(vm, va + done, pa, piece)) {
            return false;
        }
        memset(vm->ram + pa, 0, piece);
        if (pa_out) {
            *pa_out = pa;
        }
        done += piece;
    }
    return true;
}
