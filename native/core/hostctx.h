/*
 * hakuX native core — the arm64 registers in a signal handler's context, as
 * Linux and Darwin lay them out: x0-x30, sp and pc in a row on both.
 */
#ifndef NATIVE_CORE_HOSTCTX_H
#define NATIVE_CORE_HOSTCTX_H

#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __APPLE__
#include <sys/ucontext.h>
#else
#include <ucontext.h>
#endif

typedef struct NcHostRegs {
    uint64_t regs[31];
    uint64_t sp;
    uint64_t pc;
} NcHostRegs;

#ifdef __APPLE__
_Static_assert(offsetof(struct __darwin_arm_thread_state64, __fp) == 29 * 8 &&
                   offsetof(struct __darwin_arm_thread_state64, __lr) == 30 * 8 &&
                   offsetof(struct __darwin_arm_thread_state64, __sp) == 31 * 8 &&
                   offsetof(struct __darwin_arm_thread_state64, __pc) == 32 * 8,
               "Darwin's thread state isn't x0-x30, sp, pc");

static inline NcHostRegs *nc_host_regs(void *uc)
{
    return (NcHostRegs *)&((ucontext_t *)uc)->uc_mcontext->__ss;
}

/* v0-v31, or NULL */
static inline __uint128_t *nc_host_vregs(void *uc)
{
    return ((ucontext_t *)uc)->uc_mcontext->__ns.__v;
}

static inline uint64_t nc_host_fault_addr(void *uc)
{
    return ((ucontext_t *)uc)->uc_mcontext->__es.__far;
}
#else
#include <asm/sigcontext.h>

static inline NcHostRegs *nc_host_regs(void *uc)
{
    return (NcHostRegs *)&((ucontext_t *)uc)->uc_mcontext.regs[0];
}

static inline __uint128_t *nc_host_vregs(void *uc)
{
    struct _aarch64_ctx *h = (struct _aarch64_ctx *)((ucontext_t *)uc)->uc_mcontext.__reserved;
    while (h->magic) {
        if (h->magic == FPSIMD_MAGIC) {
            return ((struct fpsimd_context *)h)->vregs;
        }
        h = (struct _aarch64_ctx *)((uint8_t *)h + h->size);
    }
    return NULL;
}

static inline uint64_t nc_host_fault_addr(void *uc)
{
    return ((ucontext_t *)uc)->uc_mcontext.fault_address;
}
#endif

#endif
