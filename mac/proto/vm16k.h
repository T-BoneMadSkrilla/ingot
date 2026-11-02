/*
 * hakuX macOS prototype — 4 KiB guest pages on a 16 KiB-page host.
 *
 * The guest's page table stays at 4 KiB (pte, as native/core/vm does). Each
 * 16 KiB host block of the guest reservation is then one of:
 *  - unmapped: none of its four guest pages is mapped (accesses are faults);
 *  - direct: its four pages are one 16 KiB-aligned physical block in order,
 *    with one protection: the RAM file is mapped there and the JIT's loads
 *    and stores run at full speed;
 *  - trapped: anything else (a lone 4 KiB page, pages from scattered physical
 *    addresses, mixed protections): PROT_NONE, and every access faults and is
 *    emulated through the page table against the host's view of RAM
 *    (trap.c). Correct, but each access costs a signal.
 * The kernel's allocator keeps trapped blocks rare by handing out physical
 * memory in aligned 16 KiB runs congruent with the VA (v16_alloc_phys).
 */
#ifndef MAC_PROTO_VM16K_H
#define MAC_PROTO_VM16K_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define V16_GPAGE 4096u  /* guest page */
#define V16_HPAGE 16384u /* host page: one block */
#define V16_PER_BLOCK (V16_HPAGE / V16_GPAGE)

#define V16_PTE_VALID 1u
#define V16_PTE_RO    2u

enum { V16_UNMAPPED = 0, V16_DIRECT = 1, V16_TRAPPED = 2 };

typedef struct V16 {
    uint8_t *base; /* host address of guest VA 0 */
    uint8_t *reservation;
    size_t reservation_len;
    int ram_fd;
    uint32_t ram_size;
    uint8_t *phys;        /* host view of all of RAM, never protected */
    uint32_t *pte;        /* per guest page: pa | V16_PTE_* or 0 */
    uint8_t *block;       /* per host block: V16_UNMAPPED / DIRECT / TRAPPED */
    uint8_t *page_used;   /* physical allocator: per guest page */
    uint64_t trapped;     /* accesses emulated */
    uint64_t remaps;      /* block mappings changed */
} V16;

bool v16_init(V16 *v, uint32_t ram_size);
/* Guest VA [va, va+len) onto physical [pa, pa+len), 4 KiB-aligned, read-only or not. */
bool v16_map(V16 *v, uint32_t va, uint32_t pa, uint32_t len, bool ro);
bool v16_unmap(V16 *v, uint32_t va, uint32_t len);
/* Physical memory for len bytes at va: 16 KiB-aligned runs placed so the VA's
 * blocks come out direct when va is block-aligned too. UINT32_MAX if none. */
uint32_t v16_alloc_phys(V16 *v, uint32_t va, uint32_t len);
/* Blocks of each kind across the 4 GiB space. */
void v16_census(const V16 *v, uint32_t *direct, uint32_t *trapped);

static inline uint32_t v16_phys(const V16 *v, uint32_t va)
{
    const uint32_t e = v->pte[va / V16_GPAGE];
    return e & V16_PTE_VALID ? (e & ~(V16_GPAGE - 1)) | (va & (V16_GPAGE - 1)) : UINT32_MAX;
}

/* The SIGSEGV/SIGBUS handler for trapped blocks (trap.c). Chains to the previous
 * handler for anything else. */
void v16_trap_install(V16 *v);

#ifdef __cplusplus
}
#endif

#endif
