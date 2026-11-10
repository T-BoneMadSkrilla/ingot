/*
 * hakuX native core — 4 KiB guest pages on a 16 KiB-page host.
 *
 * The guest's page table (vm->pte) and its protections (vm->vprot) stay at
 * 4 KiB. A host page of the guest space is mapped straight onto RAM
 * (direct) when its four guest pages are one 16 KiB-aligned physical block
 * in order with one protection; else it's PROT_NONE (trapped), and the
 * guest's (and the host's) accesses there fault into nc_vm16k_fault, which
 * decodes the load or store and makes it through the RAM view, page by page,
 * when the guest pages it touches allow it. What they don't allow is the
 * guest's own fault: dirty tracking, MMIO and paging take it as on a 4 KiB
 * host, and change the pages' protections through here.
 */
#include "native/core/vm.h"

#ifdef NC_VM16K
#include "native/core/hostctx.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define HOST_PAGE 16384u
#define PER_BLOCK (HOST_PAGE / NC_PAGE)
#define BLOCKS    ((1ull << 32) / HOST_PAGE)

enum { B_UNMAPPED, B_DIRECT, B_TRAPPED };

typedef struct NcVmBlock {
    uint32_t pa;
    uint8_t kind, prot;
} NcVmBlock;

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_emulated, g_denied, g_unknown;
static NcVm *g_vm;

bool nc_vm16k_init(NcVm *vm)
{
    if (sysconf(_SC_PAGESIZE) != HOST_PAGE) {
        nc_log("hakuX-native", "vm16k: host page %ld, built for %u", sysconf(_SC_PAGESIZE), HOST_PAGE);
        return false;
    }
    vm->vprot = calloc((1ull << 32) / NC_PAGE, 1);
    vm->blk = calloc(BLOCKS, sizeof(NcVmBlock));
    g_vm = vm;
    return vm->vprot && vm->blk;
}

/* Host memory p..p+n inside the guest space, copied to or from buf through
 * the guest's pages (each allowing it), as the kernel can't through a
 * trapped host page. False: not guest memory, or a page that doesn't allow it. */
static bool guest_xfer(void *p, void *buf, size_t n, bool to_guest)
{
    NcVm *vm = g_vm;
    const uintptr_t b = vm ? (uintptr_t)vm->base : 0, h = (uintptr_t)p;
    if (!vm || h < b || h - b + n > (1ull << 32)) {
        return false;
    }
    const uint8_t need = to_guest ? PROT_WRITE : PROT_READ;
    for (uint64_t g = h - b, end = h - b + n; g < end;) {
        const uint32_t e = vm->pte[g / NC_PAGE];
        if (!(e & NC_PTE_VALID) || !(vm->vprot[g / NC_PAGE] & need)) {
            return false;
        }
        g = (g & ~(uint64_t)(NC_PAGE - 1)) + NC_PAGE;
    }
    uint8_t *q = buf;
    for (uint64_t g = h - b, end = h - b + n; g < end;) {
        const uint64_t room = NC_PAGE - (g & (NC_PAGE - 1)), chunk = room < end - g ? room : end - g;
        uint8_t *m = vm->phys + nc_vm_phys(vm, (uint32_t)g);
        memcpy(to_guest ? m : q, to_guest ? q : m, chunk);
        q += chunk;
        g += chunk;
    }
    return true;
}

ssize_t nc_vm16k_read_slow(int fd, void *buf, size_t n, off_t off, bool positioned)
{
    void *bounce = malloc(n ? n : 1);
    if (!bounce) {
        errno = ENOMEM;
        return -1;
    }
    const ssize_t r = positioned ? pread(fd, bounce, n, off) : read(fd, bounce, n);
    if (r > 0 && !guest_xfer(buf, bounce, (size_t)r, true)) {
        free(bounce);
        errno = EFAULT;
        return -1;
    }
    free(bounce);
    return r;
}

ssize_t nc_vm16k_write_slow(int fd, const void *buf, size_t n, off_t off, bool positioned)
{
    void *bounce = malloc(n ? n : 1);
    if (!bounce) {
        errno = ENOMEM;
        return -1;
    }
    if (!guest_xfer((void *)buf, bounce, n, false)) {
        free(bounce);
        errno = EFAULT;
        return -1;
    }
    const ssize_t r = positioned ? pwrite(fd, bounce, n, off) : write(fd, bounce, n);
    free(bounce);
    return r;
}

/* What block b can be: direct when its four pages are one aligned physical
 * block in order, with the protection all four allow (an access past it is
 * emulated against each page's own: write tracking keeps clean pages beside
 * written ones, and trapped whole, every read of them was emulated too),
 * unmapped when none is mapped. */
static int block_want(const NcVm *vm, uint32_t b, uint32_t *pa, uint8_t *prot)
{
    const uint32_t *p = &vm->pte[b * PER_BLOCK];
    const uint8_t *vp = &vm->vprot[b * PER_BLOCK];
    unsigned valid = 0;
    for (unsigned i = 0; i < PER_BLOCK; i++) {
        valid += p[i] & NC_PTE_VALID;
    }
    if (!valid) {
        return B_UNMAPPED;
    }
    if (valid != PER_BLOCK) {
        /* the mapped pages in place in an aligned block: direct, when each
         * unmapped page is one the guest has no access to (reserved, never
         * committed: Forza commits one page of each 64 KiB it reserves,
         * thousands of them) or its place is held for it (nc_vm_regroup).
         * The guest's access to a page it has no access to, a fault on the
         * Xbox, reaches the block's other page there. */
        uint32_t base = UINT32_MAX;
        uint8_t all = PROT_READ | PROT_WRITE;
        for (unsigned i = 0; i < PER_BLOCK; i++) {
            if (p[i] & NC_PTE_VALID) {
                const uint32_t b0 = (p[i] & ~(NC_PAGE - 1)) - i * NC_PAGE;
                if ((b0 & (HOST_PAGE - 1)) || (base != UINT32_MAX && b0 != base)) {
                    return B_TRAPPED;
                }
                base = b0;
                all &= vp[i];
            }
        }
        for (unsigned i = 0; i < PER_BLOCK; i++) {
            if (!(p[i] & NC_PTE_VALID) && vp[i] && !nc_vm_is_fill(base / NC_PAGE + i)) {
                return B_TRAPPED;
            }
        }
        *pa = base;
        *prot = all;
        return B_DIRECT;
    }
    const uint32_t pa0 = p[0] & ~(NC_PAGE - 1);
    if (pa0 & (HOST_PAGE - 1)) {
        return B_TRAPPED;
    }
    uint8_t all = vp[0];
    for (unsigned i = 1; i < PER_BLOCK; i++) {
        if (p[i] != p[0] + i * NC_PAGE) {
            return B_TRAPPED;
        }
        all &= vp[i];
    }
    *pa = pa0;
    *prot = all;
    return B_DIRECT;
}

static void sync_locked(NcVm *vm, uint32_t va, uint32_t len)
{
    if (!len) {
        return;
    }
    const uint32_t b0 = va / HOST_PAGE, b1 = (uint32_t)(((uint64_t)va + len - 1) / HOST_PAGE);
    for (uint32_t b = b0; b <= b1;) {
        NcVmBlock *cur = &vm->blk[b];
        uint32_t pa = 0;
        uint8_t prot = 0;
        const int kind = block_want(vm, b, &pa, &prot);
        uint8_t *at = vm->base + (uint64_t)b * HOST_PAGE;
        if (kind == B_DIRECT && cur->kind == B_DIRECT && cur->pa == pa) {
            if (cur->prot != prot) {
                mprotect(at, HOST_PAGE, prot);
                cur->prot = prot;
            }
            b++;
            continue;
        }
        if (kind == B_DIRECT) {
            /* the run of blocks that map on from it, in one mmap */
            uint32_t n = 1;
            while (b + n <= b1) {
                uint32_t pa_n;
                uint8_t prot_n;
                const NcVmBlock *c = &vm->blk[b + n];
                if (block_want(vm, b + n, &pa_n, &prot_n) != B_DIRECT || pa_n != pa + n * HOST_PAGE ||
                    prot_n != prot || (c->kind == B_DIRECT && c->pa == pa_n)) {
                    break;
                }
                n++;
            }
            if (mmap(at, (size_t)n * HOST_PAGE, prot, MAP_SHARED | MAP_FIXED, vm->ram_fd, pa) != at) {
                nc_log("hakuX-native", "vm16k: map %08x+%x pa %08x failed: %s", b * HOST_PAGE, n * HOST_PAGE, pa,
                       strerror(errno));
                return;
            }
            for (uint32_t i = 0; i < n; i++) {
                vm->blk[b + i] = (NcVmBlock){ .pa = pa + i * HOST_PAGE, .kind = B_DIRECT, .prot = prot };
            }
            b += n;
            continue;
        }
        if (cur->kind == B_DIRECT) {
            mmap(at, HOST_PAGE, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        }
        *cur = (NcVmBlock){ .kind = (uint8_t)kind };
        b++;
    }
}

void nc_vm16k_sync(NcVm *vm, uint32_t va, uint32_t len)
{
    pthread_mutex_lock(&g_mu);
    sync_locked(vm, va, len);
    pthread_mutex_unlock(&g_mu);
}

void nc_vm16k_protect(NcVm *vm, uint32_t va, uint32_t len, int prot)
{
    if (!len) {
        return;
    }
    pthread_mutex_lock(&g_mu);
    memset(&vm->vprot[va / NC_PAGE], prot & (PROT_READ | PROT_WRITE), len / NC_PAGE);
    sync_locked(vm, va, len);
    pthread_mutex_unlock(&g_mu);
}

/* Every 256th emulated access's host page, tallied (nc_vm16k_dump). */
#define HOT_SLOTS 64
static struct {
    uint32_t block, n;
} g_hot[HOT_SLOTS];

static void hot_sample(uint32_t block)
{
    unsigned h = (block * 2654435761u) % HOT_SLOTS;
    for (unsigned i = 0; i < 8; i++, h = (h + 1) % HOT_SLOTS) {
        if (!g_hot[h].n || g_hot[h].block == block) {
            g_hot[h].block = block;
            g_hot[h].n++;
            return;
        }
    }
}

/* Trapped host pages emulated often, for nc_vm_regroup to make direct:
 * every 256th emulated access counts for its host page, and one counted
 * REGROUP_AT times is queued. Taken in the fault handler and by the vCPU's
 * kernel calls, which don't run at once: no lock. */
#define WANT_SLOTS 32
#define REGROUP_AT 4
static struct {
    uint32_t block, n;
} g_count[WANT_SLOTS];
static uint32_t g_want[WANT_SLOTS];
static unsigned g_nwant;
static bool g_want_any;

static void want_note(uint32_t block)
{
    unsigned h = (block * 2654435761u) % WANT_SLOTS;
    for (unsigned i = 0; i < 4; i++, h = (h + 1) % WANT_SLOTS) {
        if (g_count[h].n && g_count[h].block != block) {
            continue;
        }
        g_count[h].block = block;
        if (++g_count[h].n == REGROUP_AT && g_nwant < WANT_SLOTS) {
            g_want[g_nwant++] = block;
            __atomic_store_n(&g_want_any, true, __ATOMIC_RELEASE);
        }
        return;
    }
    memset(g_count, 0, sizeof(g_count));   /* full of pages hot once: start over */
}

bool nc_vm16k_direct(const NcVm *vm, uint32_t va)
{
    return vm->blk[va / HOST_PAGE].kind == B_DIRECT;
}

unsigned nc_vm16k_want_take(uint32_t *va, unsigned max)
{
    if (!__atomic_load_n(&g_want_any, __ATOMIC_ACQUIRE)) {
        return 0;
    }
    unsigned n = 0;
    for (; n < g_nwant && n < max; n++) {
        va[n] = g_want[n] * HOST_PAGE;
    }
    g_nwant = 0;
    memset(g_count, 0, sizeof(g_count));
    __atomic_store_n(&g_want_any, false, __ATOMIC_RELEASE);
    return n;
}

/* why block b is trapped */
enum { WHY_PARTLY, WHY_UNALIGNED, WHY_SCATTERED, WHY_PROT, WHY_NONE };
static const char *const g_why[] = { "partly mapped", "pa not 16K-aligned", "pa scattered", "protections differ", "?" };

static int trap_reason(const NcVm *vm, uint32_t b)
{
    const uint32_t *p = &vm->pte[b * PER_BLOCK];
    const uint8_t *vp = &vm->vprot[b * PER_BLOCK];
    unsigned valid = 0;
    for (unsigned i = 0; i < PER_BLOCK; i++) {
        valid += p[i] & NC_PTE_VALID;
    }
    if (valid != PER_BLOCK) {
        return WHY_PARTLY;
    }
    if (p[0] & (HOST_PAGE - 1) & ~(NC_PAGE - 1)) {
        return WHY_UNALIGNED;
    }
    for (unsigned i = 1; i < PER_BLOCK; i++) {
        if (p[i] != p[0] + i * NC_PAGE) {
            return WHY_SCATTERED;
        }
    }
    for (unsigned i = 1; i < PER_BLOCK; i++) {
        if (vp[i] != vp[0]) {
            return WHY_PROT;
        }
    }
    return WHY_NONE;
}

void nc_vm16k_dump(const NcVm *vm)
{
    unsigned why[WHY_NONE + 1] = {0};
    for (uint64_t b = 0; b < BLOCKS; b++) {
        if (vm->blk[b].kind == B_TRAPPED) {
            why[trap_reason(vm, (uint32_t)b)]++;
        }
    }
    nc_log("hakuX-native-vm16k", "trapped: %u partly mapped, %u pa not 16K-aligned, %u pa scattered, %u protections differ",
           why[WHY_PARTLY], why[WHY_UNALIGNED], why[WHY_SCATTERED], why[WHY_PROT]);
    for (unsigned k = 0; k < 12; k++) {
        int best = -1;
        for (unsigned i = 0; i < HOT_SLOTS; i++) {
            if (g_hot[i].n && (best < 0 || g_hot[i].n > g_hot[best].n)) {
                best = (int)i;
            }
        }
        if (best < 0) {
            break;
        }
        const uint32_t b = g_hot[best].block;
        const uint32_t *p = &vm->pte[b * PER_BLOCK];
        const uint8_t *vp = &vm->vprot[b * PER_BLOCK];
        nc_log("hakuX-native-vm16k", "  hot %08x x%u (%s): pte %08x/%x %08x/%x %08x/%x %08x/%x", b * HOST_PAGE,
               g_hot[best].n * 256, vm->blk[b].kind == B_TRAPPED ? g_why[trap_reason(vm, b)] : "now direct", p[0],
               vp[0], p[1], vp[1], p[2], vp[2], p[3], vp[3]);
        g_hot[best].n = 0;
    }
    memset(g_hot, 0, sizeof(g_hot));
}

void nc_vm16k_census(const NcVm *vm, uint32_t *direct, uint32_t *trapped, uint64_t *emulated)
{
    *direct = *trapped = 0;
    for (uint64_t b = 0; b < BLOCKS; b++) {
        *direct += vm->blk[b].kind == B_DIRECT;
        *trapped += vm->blk[b].kind == B_TRAPPED;
    }
    *emulated = __atomic_load_n(&g_emulated, __ATOMIC_RELAXED);
}

/* ------------------------------------------------- the access emulator */

typedef struct Access {
    unsigned bytes, count;
    bool store, sign, to64, fp, prefetch, zva;
    unsigned rt, rt2, rn, rs;
    int wb;             /* 0 none, 1 post-index, 2 pre-index */
    int64_t imm;        /* writeback amount */
    int64_t off;        /* the first element's offset from Rn, writeback aside */
    int atomic;         /* AT_* */
    unsigned atomic_op; /* LSE: o3:opc */
    int simd;           /* SIMD_*: then bytes is the element's (the register's for SIMD_REGS) */
    unsigned lane;
    bool q;
} Access;

enum { AT_NONE, AT_LSE, AT_CAS };
enum { SIMD_NONE, SIMD_REGS, SIMD_LANE, SIMD_REPL };

static int64_t sext(uint64_t v, unsigned bits)
{
    return (int64_t)(v << (64 - bits)) >> (64 - bits);
}

/* LDR/STR (single register): immediate, register offset, unscaled, pre/post-indexed. */
static bool decode_single(uint32_t insn, const uint64_t *x, Access *a)
{
    const bool imm12 = (insn & 0x3b000000u) == 0x39000000u;
    const bool regoff = (insn & 0x3b200c00u) == 0x38200800u;
    const bool unscaled = (insn & 0x3b200c00u) == 0x38000000u;
    const bool post = (insn & 0x3b200c00u) == 0x38000400u;
    const bool pre = (insn & 0x3b200c00u) == 0x38000c00u;
    if (!imm12 && !regoff && !unscaled && !post && !pre) {
        return false;
    }
    const unsigned size = insn >> 30, opc = (insn >> 22) & 3;
    memset(a, 0, sizeof(*a));
    a->count = 1;
    a->rt = insn & 31;
    a->rn = (insn >> 5) & 31;
    a->fp = (insn >> 26) & 1;
    if (a->fp) {
        if (opc & 2) {
            if (size != 0) {
                return false;
            }
            a->bytes = 16;
            a->store = opc == 2;
        } else {
            a->bytes = 1u << size;
            a->store = opc == 0;
        }
    } else {
        a->bytes = 1u << size;
        switch (opc) {
        case 0:
            a->store = true;
            break;
        case 1:
            a->to64 = size == 3;
            break;
        case 2:
            if (size == 3) {
                a->prefetch = true;
            } else {
                a->sign = a->to64 = true;
            }
            break;
        default:
            if (size >= 2) {
                return false;
            }
            a->sign = true;
            break;
        }
    }
    if (post || pre) {
        a->wb = post ? 1 : 2;
        a->imm = sext((insn >> 12) & 0x1ff, 9);
        a->off = post ? 0 : a->imm;
    } else if (imm12) {
        a->off = (int64_t)(((insn >> 10) & 0xfff) * a->bytes);
    } else if (unscaled) {
        a->off = sext((insn >> 12) & 0x1ff, 9);
    } else {
        const unsigned rm = (insn >> 16) & 31;
        uint64_t o = rm == 31 ? 0 : x[rm];
        switch ((insn >> 13) & 7) {
        case 2:
            o = (uint32_t)o; /* UXTW */
            break;
        case 6:
            o = (uint64_t)(int64_t)(int32_t)o; /* SXTW */
            break;
        case 3:
        case 7:
            break; /* LSL, SXTX */
        default:
            return false;
        }
        a->off = (int64_t)(((insn >> 12) & 1) ? o << __builtin_ctz(a->bytes) : o);
    }
    return true;
}

/* LDP/STP/LDNP/STNP/LDPSW. */
static bool decode_pair(uint32_t insn, Access *a)
{
    if ((insn & 0x3a000000u) != 0x28000000u) {
        return false;
    }
    const unsigned opc = insn >> 30, idx = (insn >> 23) & 3;
    memset(a, 0, sizeof(*a));
    a->count = 2;
    a->fp = (insn >> 26) & 1;
    a->store = !((insn >> 22) & 1);
    a->rt = insn & 31;
    a->rt2 = (insn >> 10) & 31;
    a->rn = (insn >> 5) & 31;
    if (a->fp) {
        if (opc == 3) {
            return false;
        }
        a->bytes = 4u << opc;
    } else {
        if (opc == 3 || (opc == 1 && a->store)) {
            return false;
        }
        a->bytes = opc == 2 ? 8 : 4;
        a->sign = a->to64 = opc == 1;
        a->to64 |= opc == 2;
    }
    a->imm = sext((insn >> 15) & 0x7f, 7) * (int64_t)a->bytes;
    a->wb = idx == 1 ? 1 : idx == 3 ? 2 : 0;
    a->off = a->wb == 1 ? 0 : a->imm;
    return true;
}

/* LSE atomics, CAS, the acquire/release and RCpc loads and stores (plain
 * ones here), and DC ZVA (memset's). */
static bool decode_other(uint32_t insn, Access *a)
{
    memset(a, 0, sizeof(*a));
    a->count = 1;
    a->rt = insn & 31;
    a->rn = (insn >> 5) & 31;
    a->rs = (insn >> 16) & 31;
    a->bytes = 1u << (insn >> 30);
    if ((insn & 0xffffffe0u) == 0xd50b7420u) { /* DC ZVA, Xt */
        a->zva = true;
        a->rn = a->rt;
        a->bytes = 64;
        a->store = true;
        return true;
    }
    if ((insn & 0x3f200c00u) == 0x38200000u) {
        const unsigned o3opc = (insn >> 12) & 15;
        if (o3opc == 0xc) { /* LDAPR */
            a->to64 = a->bytes == 8;
            return true;
        }
        if (o3opc > 8) {
            return false;
        }
        a->atomic = AT_LSE;
        a->atomic_op = o3opc;
        a->store = true;
        return true;
    }
    if ((insn & 0x3fa07c00u) == 0x08a07c00u) {
        a->atomic = AT_CAS;
        a->store = true;
        return true;
    }
    if ((insn & 0x3fbffc00u) == 0x089ffc00u) { /* LDAR / STLR */
        a->store = !((insn >> 22) & 1);
        a->to64 = !a->store && a->bytes == 8;
        return true;
    }
    if ((insn & 0x3f200c00u) == 0x19000000u) { /* STLUR / LDAPUR(S) */
        const unsigned opc = (insn >> 22) & 3;
        a->off = sext((insn >> 12) & 0x1ff, 9);
        a->store = opc == 0;
        a->sign = opc >= 2;
        a->to64 = opc == 2 || (opc == 1 && a->bytes == 8);
        return true;
    }
    return false;
}

/* LD1/ST1 (Advanced SIMD): multiple registers, one lane, LD1R; no offset
 * or post-indexed. */
static bool decode_simd(uint32_t insn, const uint64_t *x, Access *a)
{
    const bool multi = (insn & 0xbfbf0000u) == 0x0c000000u, multi_post = (insn & 0xbfa00000u) == 0x0c800000u;
    const bool one = (insn & 0xbfbf0000u) == 0x0d000000u, one_post = (insn & 0xbfa00000u) == 0x0d800000u;
    if (!multi && !multi_post && !one && !one_post) {
        return false;
    }
    memset(a, 0, sizeof(*a));
    a->fp = true;
    a->q = (insn >> 30) & 1;
    a->store = !((insn >> 22) & 1);
    a->rt = insn & 31;
    a->rn = (insn >> 5) & 31;
    const unsigned opcode = (insn >> 12) & 15, size = (insn >> 10) & 3, s = (insn >> 12) & 1;
    unsigned total;
    if (multi || multi_post) {
        static const uint8_t regs[16] = { [7] = 1, [10] = 2, [6] = 3, [2] = 4 };
        if (!regs[opcode]) {
            return false;
        }
        a->simd = SIMD_REGS;
        a->count = regs[opcode];
        a->bytes = a->q ? 16 : 8;
        total = a->count * a->bytes;
    } else {
        const unsigned op = (insn >> 13) & 7, qs = (a->q << 1) | s;
        a->count = 1;
        switch (op) {
        case 0:
            a->bytes = 1;
            a->lane = (qs << 2) | size;
            break;
        case 2:
            if (size & 1) {
                return false;
            }
            a->bytes = 2;
            a->lane = (qs << 1) | (size >> 1);
            break;
        case 4:
            if (size == 0) {
                a->bytes = 4;
                a->lane = qs;
            } else if (size == 1 && !s) {
                a->bytes = 8;
                a->lane = a->q;
            } else {
                return false;
            }
            break;
        case 6:
            if (a->store || s) {
                return false;
            }
            a->bytes = 1u << size;
            break;
        default:
            return false; /* LD2-LD4 */
        }
        a->simd = op == 6 ? SIMD_REPL : SIMD_LANE;
        total = a->bytes;
    }
    if (multi_post || one_post) {
        const unsigned rm = (insn >> 16) & 31;
        a->wb = 1;
        a->imm = rm == 31 ? (int64_t)total : (int64_t)x[rm];
    }
    return true;
}

static unsigned access_bytes(const Access *a)
{
    return a->simd == SIMD_REGS ? a->count * a->bytes : a->simd ? a->bytes : a->count * a->bytes;
}

/* The first byte in guest [gva, gva + n) whose page doesn't allow the
 * access, or UINT64_MAX. */
static uint64_t guest_denied(const NcVm *vm, uint32_t gva, unsigned n, bool store)
{
    const uint8_t need = store ? PROT_WRITE : PROT_READ;
    for (uint64_t p = gva & ~(uint64_t)(NC_PAGE - 1); p < (uint64_t)gva + n; p += NC_PAGE) {
        if (p >= (1ull << 32)) {
            return p;
        }
        if (!(vm->pte[p / NC_PAGE] & NC_PTE_VALID) || !(vm->vprot[p / NC_PAGE] & need)) {
            return p > gva ? p : gva;
        }
    }
    return UINT64_MAX;
}

static void guest_copy(NcVm *vm, uint32_t gva, void *buf, unsigned n, bool store)
{
    uint8_t *b = buf;
    while (n) {
        const unsigned room = NC_PAGE - (gva & (NC_PAGE - 1)), chunk = room < n ? room : n;
        uint8_t *m = vm->phys + nc_vm_phys(vm, gva);
        if (store) {
            memcpy(m, b, chunk);
        } else {
            memcpy(b, m, chunk);
        }
        gva += chunk;
        b += chunk;
        n -= chunk;
    }
}

static uint64_t lse_apply(unsigned op, uint64_t old, uint64_t s, unsigned bytes)
{
    const unsigned bits = 8 * bytes;
    const uint64_t mask = bytes < 8 ? (1ull << bits) - 1 : ~0ull;
    const int64_t so = sext(old & mask, bits), ss = sext(s & mask, bits);
    switch (op) {
    case 0: return old + s;                             /* LDADD */
    case 1: return old & ~s;                            /* LDCLR */
    case 2: return old ^ s;                             /* LDEOR */
    case 3: return old | s;                             /* LDSET */
    case 4: return so > ss ? old : s;                   /* LDSMAX */
    case 5: return so < ss ? old : s;                   /* LDSMIN */
    case 6: return (old & mask) > (s & mask) ? old : s; /* LDUMAX */
    case 7: return (old & mask) < (s & mask) ? old : s; /* LDUMIN */
    default: return s;                                  /* SWP */
    }
}

static bool cas_n(uint8_t *m, unsigned bytes, uint64_t *expect, uint64_t nv)
{
    switch (bytes) {
    case 1: { uint8_t o = (uint8_t)*expect; bool r = __atomic_compare_exchange_n(m, &o, (uint8_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); *expect = o; return r; }
    case 2: { uint16_t o = (uint16_t)*expect; bool r = __atomic_compare_exchange_n((uint16_t *)m, &o, (uint16_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); *expect = o; return r; }
    case 4: { uint32_t o = (uint32_t)*expect; bool r = __atomic_compare_exchange_n((uint32_t *)m, &o, (uint32_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); *expect = o; return r; }
    default: return __atomic_compare_exchange_n((uint64_t *)m, expect, nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }
}

/* An atomic on one aligned element (inside a page): the host's atomics on
 * the RAM view, so a thread on a direct view of the same bytes sees it whole. */
static bool atomic_rmw(NcVm *vm, const Access *a, uint32_t gva, uint64_t *x)
{
    if (gva & (a->bytes - 1)) {
        return false;
    }
    uint8_t *m = vm->phys + nc_vm_phys(vm, gva);
    const uint64_t mask = a->bytes < 8 ? (1ull << (8 * a->bytes)) - 1 : ~0ull;
    const uint64_t s = (a->rs == 31 ? 0 : x[a->rs]) & mask;
    if (a->atomic == AT_CAS) {
        uint64_t old = s;
        cas_n(m, a->bytes, &old, (a->rt == 31 ? 0 : x[a->rt]) & mask);
        if (a->rs != 31) {
            x[a->rs] = old & mask;
        }
        return true;
    }
    uint64_t cur = 0;
    memcpy(&cur, m, a->bytes);
    while (!cas_n(m, a->bytes, &cur, lse_apply(a->atomic_op, cur, s, a->bytes) & mask)) {
    }
    if (a->rt != 31) {
        x[a->rt] = cur & mask;
    }
    return true;
}

/* The access on the registers x (sp the stack pointer's, v the vector
 * registers', NULL if there are none) at its address, *ea. trapped: only if
 * the access is to a trapped host page, else EMU_DIRECT (the guest's pages
 * allow it: the host's mapping does). */
enum { EMU_DIRECT = NC_VM16K_DENIED + 1 };

static int emulate(NcVm *vm, const Access *a, uint64_t *x, uint64_t *sp, __uint128_t *v, bool trapped,
                   uintptr_t *deny, uint64_t *ea_out)
{
    const uint64_t b = (uint64_t)(uintptr_t)vm->base;
    uint64_t *rn = a->rn == 31 ? sp : &x[a->rn];
    uint64_t ea = *rn + (uint64_t)a->off;
    if (a->zva) {
        ea &= ~63ull;
    }
    if (ea - b >= (1ull << 32)) {
        return NC_VM16K_NOT_MINE;
    }
    const uint32_t gva = (uint32_t)(ea - b);
    const unsigned n = access_bytes(a);
    const uint64_t d = guest_denied(vm, gva, n, a->store);
    if (d != UINT64_MAX) {
        __atomic_fetch_add(&g_denied, 1, __ATOMIC_RELAXED);
        *deny = (uintptr_t)(b + d);
        return NC_VM16K_DENIED;
    }
    if (trapped) {
        /* a direct host page its protection opens to the access: the host
         * makes it; one closed to it (a guarded neighbour's, a tracked
         * one's) is emulated here as on a trapped page, no signal each time */
        const NcVmBlock *bk = &vm->blk[(ea - b) / HOST_PAGE];
        const uint8_t kind = __atomic_load_n(&bk->kind, __ATOMIC_ACQUIRE);
        const uint8_t need = a->store || a->atomic || a->zva ? PROT_READ | PROT_WRITE : PROT_READ;
        if (kind != B_TRAPPED &&
            (kind != B_DIRECT || (__atomic_load_n(&bk->prot, __ATOMIC_ACQUIRE) & need) == need)) {
            return EMU_DIRECT;
        }
    }
    if ((a->fp || a->simd) && !v) {
        return NC_VM16K_NOT_MINE;
    }
    if (a->zva) {
        static const uint8_t zero[64];
        guest_copy(vm, gva, (void *)zero, 64, true);
    } else if (a->atomic) {
        if (!atomic_rmw(vm, a, gva, x)) {
            return NC_VM16K_NOT_MINE;
        }
    } else if (a->simd) {
        if (a->simd == SIMD_REGS) {
            for (unsigned e = 0; e < a->count; e++) {
                __uint128_t *vr = &v[(a->rt + e) & 31], t = 0;
                if (a->store) {
                    guest_copy(vm, gva + e * a->bytes, vr, a->bytes, true);
                } else {
                    guest_copy(vm, gva + e * a->bytes, &t, a->bytes, false); /* a D form clears the top half */
                    *vr = t;
                }
            }
        } else if (a->simd == SIMD_LANE) {
            guest_copy(vm, gva, (uint8_t *)&v[a->rt] + a->lane * a->bytes, a->bytes, a->store);
        } else {
            uint8_t el[8], t[16] = { 0 };
            guest_copy(vm, gva, el, a->bytes, false);
            for (unsigned i = 0; i < (a->q ? 16u : 8u); i += a->bytes) {
                memcpy(t + i, el, a->bytes);
            }
            memcpy(&v[a->rt], t, 16);
        }
    } else {
        for (unsigned e = 0; e < a->count; e++) {
            const unsigned rt = e ? a->rt2 : a->rt;
            const uint32_t at = gva + e * a->bytes;
            if (a->fp) {
                if (a->store) {
                    guest_copy(vm, at, &v[rt], a->bytes, true);
                } else {
                    __uint128_t t = 0;
                    guest_copy(vm, at, &t, a->bytes, false); /* a scalar load clears the rest */
                    v[rt] = t;
                }
                continue;
            }
            if (a->store) {
                uint64_t val = rt == 31 ? 0 : x[rt];
                guest_copy(vm, at, &val, a->bytes, true);
                continue;
            }
            uint64_t val = 0;
            guest_copy(vm, at, &val, a->bytes, false);
            if (a->sign) {
                const int64_t sv = sext(val, 8 * a->bytes);
                val = a->to64 ? (uint64_t)sv : (uint32_t)sv;
            }
            if (rt != 31) {
                x[rt] = val;
            }
        }
    }
    if (a->wb) {
        *rn += (uint64_t)a->imm;
    }
    *ea_out = ea;
    return NC_VM16K_DONE;
}

static void emulated_note(NcVm *vm, uint64_t fa);
static void site_hit(NcVm *vm, uintptr_t pc, uint32_t insn, const Access *a);

int nc_vm16k_fault(NcVm *vm, const siginfo_t *info, void *ucontext, uintptr_t *deny)
{
    const uint64_t fa = (uint64_t)(uintptr_t)info->si_addr, b = (uint64_t)(uintptr_t)vm->base;
    if (fa - b >= (1ull << 32)) {
        return NC_VM16K_NOT_MINE;
    }
    NcHostRegs *r = nc_host_regs(ucontext);
    const uint32_t insn = *(const uint32_t *)(uintptr_t)r->pc;
    Access a;
    const bool decoded = decode_single(insn, r->regs, &a) || decode_pair(insn, &a) ||
                         decode_other(insn, &a) || decode_simd(insn, r->regs, &a);
    NcVmBlock *blk = &vm->blk[(fa - b) / HOST_PAGE];
    if (__atomic_load_n(&blk->kind, __ATOMIC_ACQUIRE) != B_TRAPPED) {
        /* sync_locked remaps a host page before it records the block's kind:
         * an access meanwhile faults on the page's new mapping with the old
         * kind. Settled under the lock: trapped now, it's emulated; direct
         * and allowing the access, it runs again (a bounded number of times,
         * so a fault that isn't this one still reaches the others); direct
         * and not, it's emulated against the guest's pages (the host page's
         * protection is the one all four allow: the access may be one
         * its own page allows, and if not, the guest's fault is its page's). */
        static __thread unsigned retries;
        static __thread uint64_t last_fa;
        if (fa != last_fa) {
            last_fa = fa;
            retries = 0;
        }
        pthread_mutex_lock(&g_mu);
        const uint8_t kind = blk->kind, prot = blk->prot;
        pthread_mutex_unlock(&g_mu);
        if (kind != B_TRAPPED) {
            const uint8_t need = decoded && !a.store ? PROT_READ : PROT_READ | PROT_WRITE;
            if (kind != B_DIRECT || ((prot & need) == need && retries++ >= 64)) {
                return NC_VM16K_NOT_MINE;
            }
            if ((prot & need) == need) {
                return NC_VM16K_DONE;
            }
            if (!decoded) {
                return NC_VM16K_NOT_MINE;
            }
        }
    }
    if (!decoded) {
        if (__atomic_fetch_add(&g_unknown, 1, __ATOMIC_RELAXED) < 16) {
            nc_log("hakuX-native", "vm16k: access %08x at pc %llx (guest %08llx) not emulated", insn,
                   (unsigned long long)r->pc, (unsigned long long)(fa - b));
        }
        return NC_VM16K_NOT_MINE;
    }
    if (a.prefetch) {
        r->pc += 4;
        return NC_VM16K_DONE;
    }
    uint64_t ea;
    const int k = emulate(vm, &a, r->regs, &r->sp, nc_host_vregs(ucontext), false, deny, &ea);
    if (k != NC_VM16K_DONE) {
        return k;
    }
    emulated_note(vm, fa);
    site_hit(vm, r->pc, insn, &a);
    r->pc += 4;
    return NC_VM16K_DONE;
}

/* ------------------------------------------------- patched sites
 *
 * Signal delivery costs far more than the access it emulates. A JIT load or
 * store that keeps faulting on trapped host pages is overwritten with a
 * branch to a stub of its own. The stub saves x0, x1 and x30 and calls its
 * arena's trampoline, which saves the rest in NcHostRegs's layout (x0-x30,
 * sp, pc, then NZCV and q0-q31) and calls nc_vm16k_site_run. On its answer
 * the stub goes on after the access (made), runs its copy of it (a direct
 * page's, which the host makes), or goes back to it, restored (the guest's
 * fault, one it can't make, or a site that's stopped trapping). Only the vCPU thread runs the JIT's code,
 * and it makes the patches (from its fault handler) and undoes them (from
 * a stub), so a site can't change under a thread running it. */

#define SITE_HITS   32u
#define SITE_COPIES 4096u               /* direct pages' in a row: the site's restored */
#define SITE_MAX    (1u << 17)
#define SITE_SLOTS  (1u << 18)
#define STUB_WORDS  56u                 /* even: its literals 8-byte aligned */
#define REACH       (120ll << 20)
#define FRAME       800u                /* NcHostRegs, NZCV, q0-q31, the stub's return */
#define FRAME_ALL   (FRAME + 128u)      /* the code's red zone stays below its sp */
#define F_NZCV      264u
#define F_Q         272u
#define F_RET       784u

enum { RUN_MADE, RUN_COPY, RUN_BACK };

typedef struct Site {
    uintptr_t pc;
    uint32_t insn;
    uint32_t copies; /* in a row */
    uint32_t *stub;
} Site;

static struct {
    uintptr_t pc;
    uint32_t insn, hits;
} g_sitehot[4096];
static Site g_site[SITE_MAX];
static uint32_t g_site_slot[SITE_SLOTS]; /* site + 1, by pc */
static unsigned g_nsite;
static struct {
    uint8_t *base;
    uint32_t *tramp;
    size_t used, size;
    uint64_t gen;
} g_arena;
static const NcCodeTail *g_tail;
static bool (*g_is_jit)(uintptr_t pc);
static uint64_t g_site_runs, g_site_copies, g_site_backs;
static unsigned g_site_fails;

int nc_vm16k_site_run(NcHostRegs *r, __uint128_t *v, uint64_t site);

void nc_vm16k_reset(NcVm *vm)
{
    memset(vm->vprot, 0, (1ull << 32) / NC_PAGE);
    memset(vm->blk, 0, BLOCKS * sizeof(NcVmBlock));
    memset(g_want, 0, sizeof(g_want));
    g_nwant = 0;
    g_want_any = false;
    memset(g_sitehot, 0, sizeof(g_sitehot));
    memset(g_site_slot, 0, sizeof(g_site_slot));
    g_nsite = 0;
    g_arena.gen = 0;    /* the stubs went with the JIT's code buffers */
}

void nc_vm16k_set_jit(bool (*is_jit)(uintptr_t pc), const NcCodeTail *tail)
{
    g_tail = tail;
    g_is_jit = is_jit;
}

void nc_vm16k_site_stats(uint64_t *runs, uint64_t *copies, uint64_t *backs, unsigned *sites)
{
    *runs = __atomic_load_n(&g_site_runs, __ATOMIC_RELAXED);
    *copies = __atomic_load_n(&g_site_copies, __ATOMIC_RELAXED);
    *backs = __atomic_load_n(&g_site_backs, __ATOMIC_RELAXED);
    *sites = g_nsite;
}

static void emulated_note(NcVm *vm, uint64_t fa)
{
    const uint64_t b = (uint64_t)(uintptr_t)vm->base;
    if (!(__atomic_fetch_add(&g_emulated, 1, __ATOMIC_RELAXED) & 255)) {
        hot_sample((uint32_t)((fa - b) / HOST_PAGE));
        if (vm->blk[(fa - b) / HOST_PAGE].kind == B_TRAPPED) {
            want_note((uint32_t)((fa - b) / HOST_PAGE));
        }
    }
}

static void code_write(uint32_t *at, const uint32_t *w, unsigned n)
{
#if defined(__APPLE__)
    pthread_jit_write_protect_np(0);
#endif
    memcpy(at, w, n * 4u);
#if defined(__APPLE__)
    pthread_jit_write_protect_np(1);
#endif
    __builtin___clear_cache((char *)at, (char *)(at + n));
}

static bool in_reach(uintptr_t from, uintptr_t to)
{
    const int64_t d = (int64_t)(to - from);
    return d > -REACH && d < REACH;
}

/* A64 encodings the stubs use. */
static uint32_t a_rel26(uint32_t op, const uint32_t *from, uintptr_t to)
{
    return op | ((uint32_t)(((int64_t)(to - (uintptr_t)from)) >> 2) & 0x3ffffffu);
}
static uint32_t a_stp_x(unsigned t, unsigned t2, unsigned off) { return 0xa9000000u | ((off / 8) << 15) | (t2 << 10) | (31u << 5) | t; }
static uint32_t a_ldp_x(unsigned t, unsigned t2, unsigned off) { return 0xa9400000u | ((off / 8) << 15) | (t2 << 10) | (31u << 5) | t; }
static uint32_t a_stp_q(unsigned t, unsigned t2, unsigned off) { return 0xad000000u | ((off / 16) << 15) | (t2 << 10) | (31u << 5) | t; }
static uint32_t a_ldp_q(unsigned t, unsigned t2, unsigned off) { return 0xad400000u | ((off / 16) << 15) | (t2 << 10) | (31u << 5) | t; }
static uint32_t a_str_x(unsigned t, unsigned off) { return 0xf9000000u | ((off / 8) << 10) | (31u << 5) | t; }
static uint32_t a_ldr_x(unsigned t, unsigned off) { return 0xf9400000u | ((off / 8) << 10) | (31u << 5) | t; }
static uint32_t a_add_sp(unsigned d, unsigned imm) { return 0x91000000u | (imm << 10) | (31u << 5) | d; }
static uint32_t a_sub_sp(unsigned imm) { return 0xd1000000u | (imm << 10) | (31u << 5) | 31u; }

/* The arena's trampoline: from a stub, with sp lowered by FRAME_ALL, x0
 * and x1 at its bottom, x30 in its slot, x0 the site and x30 the stub's
 * return. Back with x0 nc_vm16k_site_run's answer, x1 and x30 the stub's to
 * restore, the rest as they were or as the access made them. */
static unsigned tramp_make(uint32_t *t)
{
    uint32_t w[128];
    unsigned n = 0;
    for (unsigned x = 2; x < 30; x += 2) {
        w[n++] = a_stp_x(x, x + 1, x * 8);
    }
    w[n++] = a_str_x(30, F_RET);
    w[n++] = 0xaa0003e2u; /* mov x2, x0 */
    w[n++] = 0xd53b4200u; /* mrs x0, nzcv */
    w[n++] = a_str_x(0, F_NZCV);
    w[n++] = a_add_sp(0, FRAME_ALL);
    w[n++] = a_str_x(0, 248);
    for (unsigned q = 0; q < 32; q += 2) {
        w[n++] = a_stp_q(q, q + 1, F_Q + q * 16);
    }
    w[n++] = a_add_sp(0, 0);   /* mov x0, sp */
    w[n++] = a_add_sp(1, F_Q);
    const unsigned lit = n++;  /* ldr x16, =nc_vm16k_site_run */
    w[n++] = 0xd63f0200u;      /* blr x16 */
    for (unsigned q = 0; q < 32; q += 2) {
        w[n++] = a_ldp_q(q, q + 1, F_Q + q * 16);
    }
    w[n++] = a_ldr_x(1, F_NZCV);
    w[n++] = 0xd51b4201u; /* msr nzcv, x1 */
    for (unsigned x = 2; x < 30; x += 2) {
        w[n++] = a_ldp_x(x, x + 1, x * 8);
    }
    w[n++] = a_ldr_x(30, F_RET);
    w[n++] = 0xd65f03c0u; /* ret */
    n += n & 1;
    w[lit] = 0x58000000u | (((n - lit) & 0x7ffffu) << 5) | 16u;
    const uint64_t fn = (uint64_t)(uintptr_t)&nc_vm16k_site_run;
    memcpy(&w[n], &fn, 8);
    n += 2;
    code_write(t, w, n);
    return (n * 4u + 63u) & ~63u;
}

/* The room past the JIT's latest code buffer, a new buffer's when it's made:
 * the sites' lookup is dropped with the old one (its stubs go with it). */
static bool arena_sync(void)
{
    const uint64_t gen = g_tail ? __atomic_load_n(&g_tail->gen, __ATOMIC_ACQUIRE) : 0;
    if (!gen) {
        return false;
    }
    if (gen != g_arena.gen) {
        g_arena.gen = gen;
        g_arena.base = g_tail->base;
        g_arena.size = g_tail->size;
        g_arena.tramp = (uint32_t *)g_arena.base;
        g_arena.used = tramp_make(g_arena.tramp);
        memset(g_site_slot, 0, sizeof(g_site_slot));
    }
    return true;
}

/* Room for a stub a branch at pc reaches. */
static uint32_t *stub_room(uintptr_t pc, uint32_t **tramp)
{
    if (g_arena.used + STUB_WORDS * 4u > g_arena.size || !in_reach(pc, (uintptr_t)g_arena.base) ||
        !in_reach(pc, (uintptr_t)g_arena.base + g_arena.size)) {
        return NULL;
    }
    uint32_t *s = (uint32_t *)(g_arena.base + g_arena.used);
    g_arena.used += STUB_WORDS * 4u;
    *tramp = g_arena.tramp;
    return s;
}

/* The stub's way in when the access's host page is direct and open to it
 * (a site's most common case: its copy, no call): the address into x16
 * as the access makes it, then its block's kind and protection checked,
 * x16 and x17 kept below the red zone, NZCV untouched. Its words before
 * the slow way's, *slow the cbnz/tbz words to point there; 0 when the
 * access's address isn't one these words make. */
#define FAST_PAD 144u
static unsigned fast_make(uint32_t *w, uint32_t insn, const Access *a, unsigned lit, unsigned *slow, unsigned *nslow)
{
    unsigned n = 0, ns = 0;
    const unsigned rn = a->rn, tmp = rn == 17 ? 16 : 17;
    const unsigned total = a->bytes * a->count;
    if (a->simd || a->atomic || total > 32 || total == 0) {
        return 0;
    }
    const bool regoff = a->count == 1 && (insn & 0x3b200c00u) == 0x38200800u;
    w[n++] = a_sub_sp(FAST_PAD);
    w[n++] = a_stp_x(16, 17, 0);
    if (regoff) {
        const unsigned rm = (insn >> 16) & 31, opt = (insn >> 13) & 7;
        const unsigned sh = ((insn >> 12) & 1) ? (unsigned)__builtin_ctz(a->bytes) : 0;
        if (sh > 4) {
            return 0;
        }
        w[n++] = 0x8b200000u | (rm << 16) | (opt << 13) | (sh << 10) | (rn << 5) | 16u; /* add x16, xn, wm, ext #sh */
    } else {
        const int64_t off = a->off;
        if (off >= 0 && off < 65536) {
            w[n++] = 0xd2800000u | ((uint32_t)off << 5) | tmp;               /* movz xtmp, #off */
        } else if (off < 0 && off >= -65536) {
            w[n++] = 0x92800000u | ((uint32_t)(~off & 0xffff) << 5) | tmp;   /* movn xtmp, #~off */
        } else {
            return 0;
        }
        w[n++] = 0x8b000000u | (tmp << 16) | (rn << 5) | 16u;                 /* add x16, xn, xtmp */
    }
    w[n] = 0x58000000u | (((lit - n) & 0x7ffffu) << 5) | 17u;                 /* ldr x17, =base */
    n++;
    w[n++] = 0xcb000000u | (17u << 16) | (16u << 5) | 16u;                    /* sub x16, x16, x17 */
    w[n++] = 0xd3400000u | (32u << 16) | (63u << 10) | (16u << 5) | 17u;      /* lsr x17, x16, #32 */
    slow[ns++] = n;
    w[n++] = 0xb5000000u | 17u;                                               /* cbnz x17, slow */
    w[n++] = 0x91000000u | ((total - 1) << 10) | (16u << 5) | 17u;            /* add x17, x16, #total-1 */
    w[n++] = 0xca000000u | (16u << 16) | (17u << 5) | 17u;                    /* eor x17, x17, x16 */
    w[n++] = 0xd3400000u | (14u << 16) | (63u << 10) | (17u << 5) | 17u;      /* lsr x17, x17, #14 */
    slow[ns++] = n;
    w[n++] = 0xb5000000u | 17u;                                               /* cbnz x17, slow */
    w[n++] = 0xd3400000u | (14u << 16) | (63u << 10) | (16u << 5) | 16u;      /* lsr x16, x16, #14 */
    w[n] = 0x58000000u | (((lit + 2 - n) & 0x7ffffu) << 5) | 17u;             /* ldr x17, =blk */
    n++;
    w[n++] = 0x8b000000u | (16u << 16) | (3u << 10) | (17u << 5) | 16u;       /* add x16, x17, x16, lsl #3 */
    w[n++] = 0x79400000u | (2u << 10) | (16u << 5) | 16u;                     /* ldrh w16, [x16, #4] */
    w[n++] = 0x12001c00u | (16u << 5) | 17u;                                  /* and w17, w16, #0xff */
    w[n++] = 0x51000000u | ((unsigned)B_DIRECT << 10) | (17u << 5) | 17u;     /* sub w17, w17, #B_DIRECT */
    slow[ns++] = n;
    w[n++] = 0x35000000u | 17u;                                               /* cbnz w17, slow */
    slow[ns++] = n;
    w[n++] = 0x36000000u | (8u << 19) | 16u;                                  /* tbz w16, #8 (read), slow */
    if (a->store) {
        slow[ns++] = n;
        w[n++] = 0x36000000u | (9u << 19) | 16u;                              /* tbz w16, #9 (write), slow */
    }
    w[n++] = a_ldp_x(16, 17, 0);
    w[n++] = a_add_sp(31, FAST_PAD);
    *nslow = ns;
    return n;
}

static void stub_make(uint32_t *s, const uint32_t *tramp, uintptr_t pc, uint32_t insn, uint32_t site,
                      const Access *a)
{
    uint32_t w[STUB_WORDS];
    unsigned n = 0;
    /* literals (the guest space's base, its blocks) at the stub's end */
    const unsigned lit = STUB_WORDS - 4;
    unsigned slow[8], ns = 0;
    n = fast_make(w, insn, a, lit, slow, &ns);
    if (n) {
        w[n++] = insn;
        w[n] = a_rel26(0x14000000u, s + n, pc + 4);
        n++;
        for (unsigned i = 0; i < ns; i++) {
            const unsigned at = slow[i], d = n - at;
            w[at] |= (w[at] & 0x7e000000u) == 0x36000000u ? (d & 0x3fffu) << 5 : (d & 0x7ffffu) << 5;
        }
        w[n++] = a_ldp_x(16, 17, 0);
        w[n++] = a_add_sp(31, FAST_PAD);
    }
    w[n++] = a_sub_sp(FRAME_ALL);
    w[n++] = a_stp_x(0, 1, 0);
    w[n++] = a_str_x(30, 240);
    w[n++] = 0xd2800000u | ((site & 0xffffu) << 5);     /* movz x0, #site */
    w[n++] = 0xf2a00000u | ((site >> 16) << 5);         /* movk x0, #site >> 16, lsl 16 */
    w[n] = a_rel26(0x94000000u, s + n, (uintptr_t)tramp); /* bl tramp */
    n++;
    const unsigned made = n++, back = n++;              /* cbz x0, made; tbnz x0, #1, back */
    const unsigned restore[3] = { a_ldp_x(0, 1, 0), a_ldr_x(30, 240), a_add_sp(31, FRAME_ALL) };
    for (unsigned i = 0; i < 3; i++) {
        w[n++] = restore[i];
    }
    w[n++] = insn;
    w[n] = a_rel26(0x14000000u, s + n, pc + 4);
    n++;
    w[back] = 0x37080000u | (((n - back) & 0x3fffu) << 5);
    for (unsigned i = 0; i < 3; i++) {
        w[n++] = restore[i];
    }
    w[n] = a_rel26(0x14000000u, s + n, pc);
    n++;
    w[made] = 0xb4000000u | (((n - made) & 0x7ffffu) << 5);
    for (unsigned i = 0; i < 3; i++) {
        w[n++] = restore[i];
    }
    w[n] = a_rel26(0x14000000u, s + n, pc + 4);
    n++;
    const uint64_t lits[2] = { (uint64_t)(uintptr_t)g_vm->base, (uint64_t)(uintptr_t)g_vm->blk };
    while (n < lit) {
        w[n++] = 0xd4200000u; /* brk #0 */
    }
    memcpy(&w[lit], lits, sizeof(lits));
    code_write(s, w, STUB_WORDS);
}

/* A load or store the stub can make, and run a copy of: its base isn't sp
 * (moved under the stub), and it's no atomic (exclusive monitors, LSE),
 * DC ZVA, nor a prefetch. */
static bool site_ok(const Access *a)
{
    return a->rn != 31 && !a->atomic && !a->zva && !a->prefetch;
}

static unsigned site_find(uintptr_t pc, uint32_t insn, bool *found)
{
    unsigned h = (unsigned)(((pc >> 2) * 0x9e3779b97f4a7c15ull) >> 46);
    for (;; h = (h + 1) & (SITE_SLOTS - 1)) {
        const uint32_t i = g_site_slot[h];
        if (!i) {
            *found = false;
            return h;
        }
        if (g_site[i - 1].pc == pc && g_site[i - 1].insn == insn) {
            *found = true;
            return h;
        }
    }
}

static void site_hit(NcVm *vm, uintptr_t pc, uint32_t insn, const Access *a)
{
    (void)vm;
    if (!g_is_jit || !site_ok(a)) {
        return;
    }
    const unsigned h = (unsigned)((pc >> 2) * 0x9e3779b1u) >> 20;
    if (g_sitehot[h].pc != pc || g_sitehot[h].insn != insn) {
        g_sitehot[h].pc = pc;
        g_sitehot[h].insn = insn;
        g_sitehot[h].hits = 0;
    }
    if (++g_sitehot[h].hits < SITE_HITS) {
        return;
    }
    g_sitehot[h].hits = 0;
    if (!g_is_jit(pc) || !arena_sync()) {
        return;
    }
    bool found;
    const unsigned slot = site_find(pc, insn, &found);
    if (!found) {
        uint32_t *tramp = NULL, *s = g_nsite < SITE_MAX - 1 ? stub_room(pc, &tramp) : NULL;
        if (!s) {
            if (g_site_fails++ < 4) {
                nc_log("hakuX-native", "vm16k: no stub for the access at %llx (%u sites)", (unsigned long long)pc,
                       g_nsite);
            }
            return;
        }
        const unsigned i = g_nsite;
        stub_make(s, tramp, pc, insn, i, a);
        g_site[i] = (Site){ .pc = pc, .insn = insn, .stub = s };
        g_site_slot[slot] = i + 1;
        __atomic_store_n(&g_nsite, i + 1, __ATOMIC_RELEASE);
    }
    const Site *s = &g_site[g_site_slot[slot] - 1];
    const uint32_t br = a_rel26(0x14000000u, (const uint32_t *)pc, (uintptr_t)s->stub);
    code_write((uint32_t *)pc, &br, 1);
}

/* A patched site's access, from its stub (RUN_*). */
int nc_vm16k_site_run(NcHostRegs *r, __uint128_t *v, uint64_t site)
{
    NcVm *vm = g_vm;
    Site *s = &g_site[site];
    Access a;
    const bool decoded = decode_single(s->insn, r->regs, &a) || decode_pair(s->insn, &a) ||
                         decode_simd(s->insn, r->regs, &a);
    uintptr_t deny = 0;
    uint64_t ea = 0;
    r->pc = s->pc;
    const int k = decoded ? emulate(vm, &a, r->regs, &r->sp, v, true, &deny, &ea) : NC_VM16K_NOT_MINE;
    if (k == NC_VM16K_DONE) {
        __atomic_fetch_add(&g_site_runs, 1, __ATOMIC_RELAXED);
        emulated_note(vm, ea);
        s->copies = 0;
        return RUN_MADE;
    }
    if (k == EMU_DIRECT && ++s->copies < SITE_COPIES) {
        __atomic_fetch_add(&g_site_copies, 1, __ATOMIC_RELAXED);
        return RUN_COPY;
    }
    s->copies = 0;
    __atomic_fetch_add(&g_site_backs, 1, __ATOMIC_RELAXED);
    code_write((uint32_t *)s->pc, &s->insn, 1);
    return RUN_BACK;
}
#endif
