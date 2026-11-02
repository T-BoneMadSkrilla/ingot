/*
 * hakuX macOS prototype — emulating the JIT's accesses to trapped blocks.
 *
 * A trapped 16 KiB block is PROT_NONE; a guest load or store there faults.
 * The handler decodes the arm64 instruction FEX emitted (the decoder of
 * native/core/mmio.c, plus the LSE atomics and CAS that x86 LOCK
 * instructions become, and the RCpc forms), translates each byte range
 * through the 4 KiB page table and makes the access against the host's view
 * of RAM, then resumes after the instruction.
 *
 * The atomics are made with the host's own atomics on the RAM view, so
 * another thread touching the same physical bytes through a direct block
 * still sees them atomically.
 */
#include "hostctx.h"
#include "vm16k.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct Access {
    unsigned bytes, count;
    bool store, sign, to64, fp, prefetch;
    unsigned rt, rt2, rn, rs;
    int wb;            /* 0 none, 1 post-index, 2 pre-index */
    int64_t imm;       /* writeback amount; for pairs also the offset of the first element */
    int64_t off;       /* the first element's offset from Rn, writeback aside */
    int atomic;        /* AT_* */
    unsigned atomic_op; /* LSE: o3:opc */
} Access;

enum { AT_NONE, AT_LSE, AT_CAS };

static int64_t sext(uint64_t v, unsigned bits)
{
    return (int64_t)(v << (64 - bits)) >> (64 - bits);
}

/* LDR/STR family (single register), as mmio.c. */
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

/* LDP/STP/LDNP/STNP/LDPSW, as mmio.c. */
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

/* LSE atomics (LDADD/LDCLR/LDEOR/LDSET/LDSMAX.../SWP), CAS, and the
 * acquire/release and RCpc loads and stores, which act as plain ones here. */
static bool decode_ordered(uint32_t insn, Access *a)
{
    memset(a, 0, sizeof(*a));
    a->count = 1;
    a->rt = insn & 31;
    a->rn = (insn >> 5) & 31;
    a->rs = (insn >> 16) & 31;
    a->bytes = 1u << (insn >> 30);
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

/* Every guest page [gva, gva+n) touches mapped, and writable for a store. */
static bool guest_ok(const V16 *v, uint32_t gva, unsigned n, bool store)
{
    for (uint64_t p = gva & ~(V16_GPAGE - 1); p < (uint64_t)gva + n; p += V16_GPAGE) {
        const uint32_t e = v->pte[p / V16_GPAGE];
        if (!(e & V16_PTE_VALID) || (store && (e & V16_PTE_RO))) {
            return false;
        }
    }
    return true;
}

/* Copies between buf and guest [gva, gva+n), page by page (the physical pages need not be adjacent). */
static void guest_copy(V16 *v, uint32_t gva, void *buf, unsigned n, bool store)
{
    uint8_t *b = buf;
    while (n) {
        const unsigned chunk = V16_GPAGE - (gva & (V16_GPAGE - 1)) < n ? V16_GPAGE - (gva & (V16_GPAGE - 1)) : n;
        uint8_t *m = v->phys + v16_phys(v, gva);
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
    case 0: return old + s;                         /* LDADD */
    case 1: return old & ~s;                        /* LDCLR */
    case 2: return old ^ s;                         /* LDEOR */
    case 3: return old | s;                         /* LDSET */
    case 4: return so > ss ? old : s;               /* LDSMAX */
    case 5: return so < ss ? old : s;               /* LDSMIN */
    case 6: return (old & mask) > (s & mask) ? old : s; /* LDUMAX */
    case 7: return (old & mask) < (s & mask) ? old : s; /* LDUMIN */
    default: return s;                              /* SWP */
    }
}

/* An atomic on one naturally aligned element inside a page: the host's atomics on the RAM view. */
static bool atomic_rmw(V16 *v, const Access *a, uint32_t gva, uint64_t *x)
{
    if (gva & (a->bytes - 1)) {
        return false; /* split atomics: not in the prototype */
    }
    uint8_t *m = v->phys + v16_phys(v, gva);
    const uint64_t mask = a->bytes < 8 ? (1ull << (8 * a->bytes)) - 1 : ~0ull;
    const uint64_t s = (a->rs == 31 ? 0 : x[a->rs]) & mask;
    uint64_t old;
    if (a->atomic == AT_CAS) {
        const uint64_t want = s, nv = (a->rt == 31 ? 0 : x[a->rt]) & mask;
        old = want;
        switch (a->bytes) {
        case 1: { uint8_t o = (uint8_t)want; __atomic_compare_exchange_n((uint8_t *)m, &o, (uint8_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); old = o; break; }
        case 2: { uint16_t o = (uint16_t)want; __atomic_compare_exchange_n((uint16_t *)m, &o, (uint16_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); old = o; break; }
        case 4: { uint32_t o = (uint32_t)want; __atomic_compare_exchange_n((uint32_t *)m, &o, (uint32_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); old = o; break; }
        default: { uint64_t o = want; __atomic_compare_exchange_n((uint64_t *)m, &o, nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); old = o; break; }
        }
        if (a->rs != 31) {
            x[a->rs] = old;
        }
        return true;
    }
    for (;;) {
        uint64_t cur = 0;
        memcpy(&cur, m, a->bytes);
        const uint64_t nv = lse_apply(a->atomic_op, cur, s, a->bytes) & mask;
        bool done;
        switch (a->bytes) {
        case 1: { uint8_t o = (uint8_t)cur; done = __atomic_compare_exchange_n((uint8_t *)m, &o, (uint8_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); break; }
        case 2: { uint16_t o = (uint16_t)cur; done = __atomic_compare_exchange_n((uint16_t *)m, &o, (uint16_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); break; }
        case 4: { uint32_t o = (uint32_t)cur; done = __atomic_compare_exchange_n((uint32_t *)m, &o, (uint32_t)nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); break; }
        default: { uint64_t o = cur; done = __atomic_compare_exchange_n((uint64_t *)m, &o, nv, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); break; }
        }
        if (done) {
            old = cur;
            break;
        }
    }
    if (a->rt != 31) {
        x[a->rt] = old;
    }
    return true;
}

static V16 *g_v;
static struct sigaction g_prev_segv, g_prev_bus;
static uint64_t g_unknown;

static bool emulate(V16 *v, const siginfo_t *info, ucontext_t *uc)
{
    const uint64_t fa = (uint64_t)(uintptr_t)info->si_addr, b = (uint64_t)(uintptr_t)v->base;
    if (fa - b >= (1ull << 32) || v->block[(fa - b) / V16_HPAGE] != V16_TRAPPED) {
        return false;
    }
    uint64_t *x = hc_regs(uc), *pc = hc_pc(uc);
    const uint32_t insn = *(const uint32_t *)(uintptr_t)*pc;
    Access a;
    if (!decode_single(insn, x, &a) && !decode_pair(insn, &a) && !decode_ordered(insn, &a)) {
        if (g_unknown++ < 8) {
            fprintf(stderr, "vm16k: unknown access insn %08x at %llx (guest %08llx)\n", insn, (unsigned long long)*pc,
                    (unsigned long long)(fa - b));
        }
        return false;
    }
    if (a.prefetch) {
        *pc += 4;
        return true;
    }
    uint64_t *rn = a.rn == 31 ? hc_sp(uc) : &x[a.rn];
    const uint64_t ea = *rn + (uint64_t)a.off;
    if (ea - b >= (1ull << 32)) {
        return false;
    }
    const uint32_t gva = (uint32_t)(ea - b);
    const unsigned n = a.count * a.bytes;
    if (!guest_ok(v, gva, n, a.store)) {
        return false; /* a real guest fault: unmapped, or a store to a read-only page */
    }
    if (a.atomic) {
        if (!atomic_rmw(v, &a, gva, x)) {
            return false;
        }
    } else {
        for (unsigned e = 0; e < a.count; e++) {
            const unsigned rt = e ? a.rt2 : a.rt;
            const uint32_t at = gva + e * a.bytes;
            if (a.fp) {
                __uint128_t *q = hc_vreg(uc, rt);
                if (a.store) {
                    guest_copy(v, at, q, a.bytes, true);
                } else {
                    __uint128_t t = 0;
                    guest_copy(v, at, &t, a.bytes, false); /* a scalar load clears the rest */
                    *q = t;
                }
                continue;
            }
            if (a.store) {
                uint64_t val = rt == 31 ? 0 : x[rt];
                guest_copy(v, at, &val, a.bytes, true);
                continue;
            }
            uint64_t val = 0;
            guest_copy(v, at, &val, a.bytes, false);
            if (a.sign) {
                const int64_t sv = sext(val, 8 * a.bytes);
                val = a.to64 ? (uint64_t)sv : (uint32_t)sv;
            }
            if (rt != 31) {
                x[rt] = val;
            }
        }
    }
    if (a.wb) {
        *rn += (uint64_t)a.imm;
    }
    *pc += 4;
    v->trapped++;
    return true;
}

static void chain(int sig, siginfo_t *info, void *ctx)
{
    const struct sigaction *p = sig == SIGBUS ? &g_prev_bus : &g_prev_segv;
    if (p->sa_flags & SA_SIGINFO && p->sa_sigaction) {
        p->sa_sigaction(sig, info, ctx);
        return;
    }
    if (p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN && p->sa_handler) {
        p->sa_handler(sig);
        return;
    }
    char line[160];
    const int len = snprintf(line, sizeof(line), "vm16k: unhandled %s at %p, pc %llx\n", sig == SIGBUS ? "SIGBUS" : "SIGSEGV",
                             info->si_addr, (unsigned long long)*hc_pc(ctx));
    write(2, line, (size_t)len);
    signal(sig, SIG_DFL);
}

static void handler(int sig, siginfo_t *info, void *ctx)
{
    if (g_v && emulate(g_v, info, ctx)) {
        return;
    }
    chain(sig, info, ctx);
}

void v16_trap_install(V16 *v)
{
    g_v = v;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &g_prev_segv);
    sigaction(SIGBUS, &sa, &g_prev_bus);
}
