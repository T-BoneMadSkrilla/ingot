/*
 * vm16k_diff — the 16 KiB-page access emulator (native/core/vm16k.c) against
 * the CPU: random loads, stores and atomics of each form it decodes, run once
 * on plain memory and once on guest memory whose host pages are trapped (four
 * scattered physical pages each), registers and memory compared after.
 *
 *   vm16k_diff [iterations per form] [seed]
 */
#include "native/core/hostctx.h"
#include "native/core/vm.h"

#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define WIN    0x10000u         /* the window an access lands in, base at its middle */
#define GVA    0x00100000u

typedef struct {
    uint64_t x[8];
    uint64_t pad[8];
    __uint128_t v[8];
} Ctx;

/* x16 holds the context; the access uses x0-x7 and v0-v7 */
__asm__(".text\n.p2align 2\n.globl _tramp_begin\n_tramp_begin:\n"
        "stp x29, x30, [sp, #-16]!\n"
        "mov x16, x0\n"
        "ldp q0, q1, [x16, #128]\nldp q2, q3, [x16, #160]\nldp q4, q5, [x16, #192]\nldp q6, q7, [x16, #224]\n"
        "ldp x0, x1, [x16, #0]\nldp x2, x3, [x16, #16]\nldp x4, x5, [x16, #32]\nldp x6, x7, [x16, #48]\n"
        ".globl _tramp_slot\n_tramp_slot:\nnop\n"
        "stp x0, x1, [x16, #0]\nstp x2, x3, [x16, #16]\nstp x4, x5, [x16, #32]\nstp x6, x7, [x16, #48]\n"
        "stp q0, q1, [x16, #128]\nstp q2, q3, [x16, #160]\nstp q4, q5, [x16, #192]\nstp q6, q7, [x16, #224]\n"
        "ldp x29, x30, [sp], #16\nret\n.globl _tramp_end\n_tramp_end:\n");
extern const uint32_t tramp_begin[], tramp_slot[], tramp_end[];

static NcVm g_vm;
static uint32_t *g_code, *g_slot;
static uint8_t *g_plain;
static volatile int g_trapped_unhandled, g_sigill;

static void on_fault(int sig, siginfo_t *info, void *uc)
{
    NcHostRegs *r = nc_host_regs(uc);
    if (sig == SIGILL) {
        g_sigill = 1;
        r->pc += 4;
        return;
    }
    uintptr_t deny = 0;
    const int k = nc_vm16k_fault(&g_vm, info, uc, &deny);
    if (k == NC_VM16K_DONE) {
        return;
    }
    if ((uintptr_t)r->pc != (uintptr_t)g_slot) {
        fprintf(stderr, "fault outside the access: pc %llx addr %p\n", (unsigned long long)r->pc, info->si_addr);
        abort();
    }
    g_trapped_unhandled = k == NC_VM16K_DENIED ? 2 : 1;
    r->pc += 4;
}

static uint64_t g_rng;
static uint64_t rnd(void)
{
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
}
static unsigned rn(unsigned n)
{
    return (unsigned)(rnd() % n);
}

static void run(uint32_t insn, Ctx *c)
{
    pthread_jit_write_protect_np(0);
    *g_slot = insn;
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(g_slot, 4);
    ((void (*)(Ctx *))g_code)(c);
}

/* the guest window's bytes, through the physical pages */
static void guest_bytes(uint8_t *out)
{
    for (uint32_t o = 0; o < WIN; o += NC_PAGE) {
        memcpy(out + o, g_vm.phys + nc_vm_phys(&g_vm, GVA + o), NC_PAGE);
    }
}
static void guest_fill(const uint8_t *in)
{
    for (uint32_t o = 0; o < WIN; o += NC_PAGE) {
        memcpy(g_vm.phys + nc_vm_phys(&g_vm, GVA + o), in + o, NC_PAGE);
    }
}

typedef struct {
    const char *name;
    uint32_t (*gen)(unsigned *align, bool *xreg3_unsigned);
    unsigned tried, passed, invalid, unhandled, failed;
} Form;

/* ---- the forms: Rn x1, Rt x2 / v2, Rt2 x4 / v4, Rm x3, Rs x5 ---- */

static uint32_t g_imm12(unsigned *al, bool *u)
{
    for (;;) {
        const unsigned v = rn(2), size = rn(4), opc = rn(4);
        if (!v && ((size == 3 && opc == 3) || (size == 2 && opc == 3))) {
            continue;
        }
        if (v && (opc & 2) && size) {
            continue;
        }
        return size << 30 | 7u << 27 | v << 26 | 1u << 24 | opc << 22 | rn(64) << 10 | 1u << 5 | 2;
    }
}
static uint32_t g_imm9(unsigned *al, bool *u)
{
    for (;;) {
        const unsigned v = rn(2), size = rn(4), opc = rn(4), mode = (unsigned[]){0, 1, 3}[rn(3)];
        if (!v && ((size == 3 && opc == 3) || (size == 2 && opc == 3) || (size == 3 && opc == 2 && mode))) {
            continue;
        }
        if (v && (opc & 2) && size) {
            continue;
        }
        return size << 30 | 7u << 27 | v << 26 | opc << 22 | (rn(512) & 0x1ff) << 12 | mode << 10 | 1u << 5 | 2;
    }
}
static uint32_t g_regoff(unsigned *al, bool *u)
{
    for (;;) {
        const unsigned v = rn(2), size = rn(4), opc = rn(4), option = (unsigned[]){2, 3, 6, 7}[rn(4)];
        if (!v && ((size == 3 && opc == 3) || (size == 2 && opc == 3))) {
            continue;
        }
        if (v && (opc & 2) && size) {
            continue;
        }
        *u = option == 2;
        return size << 30 | 7u << 27 | v << 26 | opc << 22 | 1u << 21 | 3u << 16 | option << 13 | rn(2) << 12 |
               2u << 10 | 1u << 5 | 2;
    }
}
static uint32_t g_pair(unsigned *al, bool *u)
{
    for (;;) {
        const unsigned v = rn(2), opc = rn(3), idx = rn(4), l = rn(2);
        if (!v && opc == 1 && (!l || idx == 0)) {
            continue;
        }
        return opc << 30 | 5u << 27 | v << 26 | idx << 23 | l << 22 | rn(128) << 15 | 4u << 10 | 1u << 5 | 2;
    }
}
static uint32_t g_lse(unsigned *al, bool *u)
{
    const unsigned size = rn(4), o3opc = rn(9);
    *al = 1u << size;
    return size << 30 | 7u << 27 | rn(4) << 22 | 1u << 21 | 5u << 16 | (o3opc >> 3) << 15 | (o3opc & 7) << 12 |
           1u << 5 | 2;
}
static uint32_t g_cas(unsigned *al, bool *u)
{
    const unsigned size = rn(4);
    *al = 1u << size;
    return size << 30 | 0x08a07c00u | rn(2) << 22 | 5u << 16 | rn(2) << 15 | 1u << 5 | 2;
}
static uint32_t g_ldar(unsigned *al, bool *u)
{
    const unsigned size = rn(4), kind = rn(3);
    *al = 1u << size;
    const uint32_t base = kind == 0 ? 0x08dffc00u : kind == 1 ? 0x089ffc00u : 0x38bfc000u;
    return size << 30 | base | 1u << 5 | 2;
}
static uint32_t g_rcpc2(unsigned *al, bool *u)
{
    for (;;) {
        const unsigned size = rn(4), opc = rn(4);
        if ((opc == 2 && size == 3) || (opc == 3 && size >= 2)) {
            continue;
        }
        *al = 1;
        return size << 30 | 0x19000000u | opc << 22 | (rn(512) & 0x1ff) << 12 | 1u << 5 | 2;
    }
}
static uint32_t g_ld1_multi(unsigned *al, bool *u)
{
    static const unsigned ops[4] = {7, 10, 6, 2};
    const unsigned post = rn(2);
    return rn(2) << 30 | (post ? 0x0c800000u : 0x0c000000u) | rn(2) << 22 | (post ? (rn(2) ? 31u : 3u) << 16 : 0) |
           ops[rn(4)] << 12 | rn(4) << 10 | 1u << 5 | 2;
}
static uint32_t g_ld1_single(unsigned *al, bool *u)
{
    for (;;) {
        const unsigned post = rn(2), l = rn(2), op = (unsigned[]){0, 2, 4, 6}[rn(4)], s = rn(2), size = rn(4);
        if ((op == 2 && (size & 1)) || (op == 4 && size >= 2) || (op == 4 && size == 1 && s) ||
            (op == 6 && (!l || s))) {
            continue;
        }
        *u = true;
        return rn(2) << 30 | (post ? 0x0d800000u : 0x0d000000u) | l << 22 |
               (post ? (rn(2) ? 31u : 3u) << 16 : 0) | op << 13 | s << 12 | size << 10 | 1u << 5 | 2;
    }
}
static uint32_t g_zva(unsigned *al, bool *u)
{
    *al = 1;
    return 0xd50b7421u;
}

static Form g_forms[] = {
    {"LDR/STR imm12", g_imm12},      {"LDUR/STUR, pre/post", g_imm9},  {"LDR/STR register", g_regoff},
    {"LDP/STP", g_pair},             {"LSE atomics", g_lse},           {"CAS", g_cas},
    {"LDAR/STLR/LDAPR", g_ldar},     {"LDAPUR/STLUR", g_rcpc2},        {"LD1/ST1 registers", g_ld1_multi},
    {"LD1/ST1 lane, LD1R", g_ld1_single}, {"DC ZVA", g_zva},
};

int main(int argc, char **argv)
{
    const unsigned iters = argc > 1 ? (unsigned)atoi(argv[1]) : 3000;
    g_rng = argc > 2 ? strtoull(argv[2], NULL, 0) : 0x9e3779b97f4a7c15ull;
    if (!nc_vm_init(&g_vm, 16u << 20)) {
        fprintf(stderr, "nc_vm_init failed\n");
        return 1;
    }
    /* each host page of the window from four scattered physical pages: trapped */
    for (uint32_t i = 0; i < WIN / NC_PAGE; i++) {
        const uint32_t pa = 0x200000u + ((i * 7u + 3u) % 16u) * 2u * NC_PAGE;
        if (!nc_vm_map(&g_vm, GVA + i * NC_PAGE, pa, NC_PAGE)) {
            fprintf(stderr, "map failed\n");
            return 1;
        }
    }
    uint32_t direct, trapped;
    uint64_t emulated;
    nc_vm16k_census(&g_vm, &direct, &trapped, &emulated);
    printf("guest window: %u trapped host pages\n", trapped);

    const size_t n = (size_t)(tramp_end - tramp_begin);
    g_code = mmap(NULL, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    pthread_jit_write_protect_np(0);
    memcpy(g_code, tramp_begin, n * 4);
    pthread_jit_write_protect_np(1);
    g_slot = g_code + (tramp_slot - tramp_begin);
    g_plain = mmap(NULL, WIN, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);

    struct sigaction sa = {0};
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);

    static uint8_t init[WIN], got_plain[WIN], got_guest[WIN];
    uint8_t *const guest = g_vm.base + GVA;
    unsigned shown = 0;
    int bad = 0;
    for (unsigned f = 0; f < sizeof(g_forms) / sizeof(g_forms[0]); f++) {
        Form *F = &g_forms[f];
        for (unsigned it = 0; it < iters; it++) {
            unsigned al = 1;
            bool u3 = false;
            const uint32_t insn = F->gen(&al, &u3);
            for (unsigned i = 0; i < WIN; i += 8) {
                const uint64_t r = rnd();
                memcpy(init + i, &r, 8);
            }
            Ctx c0;
            for (unsigned i = 0; i < 8; i++) {
                c0.x[i] = rnd();
                c0.v[i] = (__uint128_t)rnd() << 64 | rnd();
            }
            const uint64_t off = (WIN / 2 + rn(512)) & ~(uint64_t)(al - 1);
            c0.x[3] = u3 ? rn(256) : (uint64_t)(int64_t)((int)rn(512) - 256);

            Ctx a = c0, b = c0;
            a.x[1] = (uint64_t)(uintptr_t)g_plain + off;
            b.x[1] = (uint64_t)(uintptr_t)guest + off;
            memcpy(g_plain, init, WIN);
            guest_fill(init);
            F->tried++;
            g_sigill = 0;
            g_trapped_unhandled = 0;
            run(insn, &a);
            if (g_sigill || g_trapped_unhandled) { /* not an instruction, or it faults on plain memory (alignment) */
                F->invalid++;
                continue;
            }
            g_trapped_unhandled = 0;
            run(insn, &b);
            if (g_trapped_unhandled) {
                F->unhandled++;
                if (shown++ < 20) {
                    printf("  %-22s %08x: %s\n", F->name, insn,
                           g_trapped_unhandled == 2 ? "denied" : "not emulated");
                }
                continue;
            }
            memcpy(got_plain, g_plain, WIN);
            guest_bytes(got_guest);
            a.x[1] -= (uint64_t)(uintptr_t)g_plain;
            b.x[1] -= (uint64_t)(uintptr_t)guest;
            bool ok = !memcmp(got_plain, got_guest, WIN) && !memcmp(a.x, b.x, sizeof(a.x)) &&
                      !memcmp(a.v, b.v, sizeof(a.v));
            if (ok) {
                F->passed++;
                continue;
            }
            F->failed++;
            bad = 1;
            if (shown++ < 40) {
                printf("  %-22s %08x MISMATCH (base +%llx, x3 %llx):", F->name, insn, (unsigned long long)off,
                       (unsigned long long)c0.x[3]);
                for (unsigned i = 0; i < 8; i++) {
                    if (a.x[i] != b.x[i]) {
                        printf(" x%u %llx/%llx", i, (unsigned long long)a.x[i], (unsigned long long)b.x[i]);
                    }
                    if (a.v[i] != b.v[i]) {
                        printf(" v%u %016llx%016llx/%016llx%016llx", i, (unsigned long long)(a.v[i] >> 64),
                               (unsigned long long)a.v[i], (unsigned long long)(b.v[i] >> 64),
                               (unsigned long long)b.v[i]);
                    }
                }
                for (unsigned i = 0; i < WIN; i++) {
                    if (got_plain[i] != got_guest[i]) {
                        printf(" mem +%x %02x/%02x", i, got_plain[i], got_guest[i]);
                        break;
                    }
                }
                printf("\n");
            }
        }
    }
    printf("\n%-22s %7s %7s %7s %7s %7s\n", "form", "tried", "passed", "faults", "not emu", "WRONG");
    for (unsigned f = 0; f < sizeof(g_forms) / sizeof(g_forms[0]); f++) {
        const Form *F = &g_forms[f];
        printf("%-22s %7u %7u %7u %7u %7u\n", F->name, F->tried, F->passed, F->invalid, F->unhandled, F->failed);
    }
    return bad;
}
