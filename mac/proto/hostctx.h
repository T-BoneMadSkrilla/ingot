/*
 * hakuX macOS prototype — the arm64 host context in a signal handler.
 *
 * Linux keeps x0-x30, sp, pc in uc_mcontext and the SIMD registers in a
 * record of its extension area; Darwin keeps them all in uc_mcontext's
 * thread and NEON state (x0-x28, fp, lr contiguous: 31 registers in a row).
 */
#ifndef MAC_PROTO_HOSTCTX_H
#define MAC_PROTO_HOSTCTX_H

#include <signal.h>
#include <stdint.h>
#ifdef __APPLE__
#include <sys/ucontext.h> /* the type only: <ucontext.h> wants the deprecated routines */
#else
#include <ucontext.h>
#endif

#ifdef __APPLE__
static inline uint64_t *hc_regs(ucontext_t *uc)
{
    return (uint64_t *)&uc->uc_mcontext->__ss.__x[0];
}
static inline uint64_t *hc_pc(ucontext_t *uc)
{
    return (uint64_t *)&uc->uc_mcontext->__ss.__pc;
}
static inline uint64_t *hc_sp(ucontext_t *uc)
{
    return (uint64_t *)&uc->uc_mcontext->__ss.__sp;
}
static inline __uint128_t *hc_vreg(ucontext_t *uc, unsigned i)
{
    return &uc->uc_mcontext->__ns.__v[i];
}
#else
#include <asm/sigcontext.h>
static inline uint64_t *hc_regs(ucontext_t *uc)
{
    return (uint64_t *)uc->uc_mcontext.regs;
}
static inline uint64_t *hc_pc(ucontext_t *uc)
{
    return (uint64_t *)&uc->uc_mcontext.pc;
}
static inline uint64_t *hc_sp(ucontext_t *uc)
{
    return (uint64_t *)&uc->uc_mcontext.sp;
}
static inline __uint128_t *hc_vreg(ucontext_t *uc, unsigned i)
{
    struct _aarch64_ctx *h = (struct _aarch64_ctx *)uc->uc_mcontext.__reserved;
    while (h->magic && h->magic != FPSIMD_MAGIC) {
        h = (struct _aarch64_ctx *)((uint8_t *)h + h->size);
    }
    return h->magic ? &((struct fpsimd_context *)h)->vregs[i] : 0;
}
#endif

#endif
