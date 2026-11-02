/*
 * hakuX macOS prototype — 4 KiB guest pages on a 16 KiB-page host.
 */
#include "vm16k.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define GUARD (64u * 1024u)
#define BLOCKS ((1ull << 32) / V16_HPAGE)

/* Guest RAM as one shared-memory object, unlinked at once (as a memfd would be). */
static int ram_file(uint32_t size)
{
    char name[32];
    snprintf(name, sizeof(name), "/hakux-ram-%d", (int)getpid());
    const int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        return -1;
    }
    shm_unlink(name);
    if (ftruncate(fd, size) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

bool v16_init(V16 *v, uint32_t ram_size)
{
    memset(v, 0, sizeof(*v));
    if (sysconf(_SC_PAGESIZE) != V16_HPAGE) {
        fprintf(stderr, "vm16k: host page is %ld, built for %u\n", sysconf(_SC_PAGESIZE), V16_HPAGE);
        return false;
    }
    v->reservation_len = (1ull << 32) + 2 * GUARD;
    void *r = mmap(NULL, v->reservation_len, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (r == MAP_FAILED) {
        fprintf(stderr, "vm16k: reserve failed: %s\n", strerror(errno));
        return false;
    }
    v->reservation = r;
    v->base = (uint8_t *)r + GUARD;
    v->ram_fd = ram_file(ram_size);
    if (v->ram_fd < 0) {
        fprintf(stderr, "vm16k: RAM file failed: %s\n", strerror(errno));
        return false;
    }
    v->ram_size = ram_size;
    v->phys = mmap(NULL, ram_size, PROT_READ | PROT_WRITE, MAP_SHARED, v->ram_fd, 0);
    v->pte = calloc((1ull << 32) / V16_GPAGE, sizeof(uint32_t));
    v->block = calloc(BLOCKS, 1);
    v->page_used = calloc(ram_size / V16_GPAGE, 1);
    return v->phys != MAP_FAILED && v->pte && v->block && v->page_used;
}

/* What block b can be: direct when its four pages are one aligned physical
 * block in order with one protection, unmapped when none is mapped. */
static int block_kind(const V16 *v, uint32_t b, uint32_t *pa, bool *ro)
{
    const uint32_t *p = &v->pte[b * V16_PER_BLOCK];
    unsigned valid = 0;
    for (unsigned i = 0; i < V16_PER_BLOCK; i++) {
        valid += p[i] & V16_PTE_VALID;
    }
    if (!valid) {
        return V16_UNMAPPED;
    }
    const uint32_t pa0 = p[0] & ~(V16_GPAGE - 1);
    if (valid != V16_PER_BLOCK || (pa0 & (V16_HPAGE - 1))) {
        return V16_TRAPPED;
    }
    for (unsigned i = 1; i < V16_PER_BLOCK; i++) {
        if (p[i] != (p[0] + i * V16_GPAGE)) {
            return V16_TRAPPED; /* scattered, or a different protection */
        }
    }
    *pa = pa0;
    *ro = p[0] & V16_PTE_RO;
    return V16_DIRECT;
}

static bool remap_block(V16 *v, uint32_t b)
{
    uint32_t pa = 0;
    bool ro = false;
    const int kind = block_kind(v, b, &pa, &ro);
    void *at = v->base + (uint64_t)b * V16_HPAGE;
    void *m;
    if (kind == V16_DIRECT) {
        m = mmap(at, V16_HPAGE, PROT_READ | (ro ? 0 : PROT_WRITE), MAP_SHARED | MAP_FIXED, v->ram_fd, pa);
    } else {
        m = mmap(at, V16_HPAGE, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    }
    if (m != at) {
        fprintf(stderr, "vm16k: block %08x remap failed: %s\n", b * V16_HPAGE, strerror(errno));
        return false;
    }
    v->block[b] = (uint8_t)kind;
    v->remaps++;
    return true;
}

static bool remap_range(V16 *v, uint32_t va, uint32_t len)
{
    const uint32_t b0 = va / V16_HPAGE, b1 = (uint32_t)(((uint64_t)va + len - 1) / V16_HPAGE);
    /* Whole runs of direct blocks in order: one mmap, as vm.c maps a run. */
    for (uint32_t b = b0; b <= b1;) {
        uint32_t pa;
        bool ro;
        if (block_kind(v, b, &pa, &ro) == V16_DIRECT) {
            uint32_t n = 1, pa_n;
            bool ro_n;
            while (b + n <= b1 && block_kind(v, b + n, &pa_n, &ro_n) == V16_DIRECT && pa_n == pa + n * V16_HPAGE &&
                   ro_n == ro) {
                n++;
            }
            void *at = v->base + (uint64_t)b * V16_HPAGE;
            if (mmap(at, (size_t)n * V16_HPAGE, PROT_READ | (ro ? 0 : PROT_WRITE), MAP_SHARED | MAP_FIXED, v->ram_fd,
                     pa) != at) {
                fprintf(stderr, "vm16k: run %08x+%x failed: %s\n", b * V16_HPAGE, n * V16_HPAGE, strerror(errno));
                return false;
            }
            memset(&v->block[b], V16_DIRECT, n);
            v->remaps++;
            b += n;
            continue;
        }
        if (!remap_block(v, b)) {
            return false;
        }
        b++;
    }
    return true;
}

bool v16_map(V16 *v, uint32_t va, uint32_t pa, uint32_t len, bool ro)
{
    if ((va | pa | len) & (V16_GPAGE - 1) || !len || (uint64_t)pa + len > v->ram_size ||
        (uint64_t)va + len > (1ull << 32)) {
        return false;
    }
    for (uint32_t off = 0; off < len; off += V16_GPAGE) {
        v->pte[(va + off) / V16_GPAGE] = (pa + off) | V16_PTE_VALID | (ro ? V16_PTE_RO : 0);
    }
    return remap_range(v, va, len);
}

bool v16_unmap(V16 *v, uint32_t va, uint32_t len)
{
    if ((va | len) & (V16_GPAGE - 1) || !len) {
        return false;
    }
    for (uint32_t off = 0; off < len; off += V16_GPAGE) {
        v->pte[(va + off) / V16_GPAGE] = 0;
    }
    return remap_range(v, va, len);
}

uint32_t v16_alloc_phys(V16 *v, uint32_t va, uint32_t len)
{
    len = (len + V16_GPAGE - 1) & ~(V16_GPAGE - 1);
    const uint32_t want = va & (V16_HPAGE - 1);
    const uint32_t pages = len / V16_GPAGE, total = v->ram_size / V16_GPAGE;
    for (uint32_t pa = want; pa + len <= v->ram_size; pa += V16_HPAGE) {
        uint32_t p = pa / V16_GPAGE, n = 0;
        while (n < pages && p + n < total && !v->page_used[p + n]) {
            n++;
        }
        if (n == pages) {
            memset(&v->page_used[p], 1, pages);
            return pa;
        }
    }
    return UINT32_MAX;
}

void v16_census(const V16 *v, uint32_t *direct, uint32_t *trapped)
{
    *direct = *trapped = 0;
    for (uint64_t b = 0; b < BLOCKS; b++) {
        *direct += v->block[b] == V16_DIRECT;
        *trapped += v->block[b] == V16_TRAPPED;
    }
}
