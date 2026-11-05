/*
 * hakuX HLE GPU — what the push-buffer front end (pb/) uses of the GPU back
 * end, whichever it is: Vulkan (vk/gpu_vk.c) or Metal (mtl/). No API types.
 */
#ifndef HW_XBOX_HLE_GPU_H
#define HW_XBOX_HLE_GPU_H

#include <stdbool.h>
#include <stdint.h>

#include "hw/xbox/hle/front/arena.h"

/* The upload arena (§5.3): its allocator and the CPU's view of it. */
HleArena *hle_gpu_arena(void);
uint8_t *hle_gpu_arena_map(void);
/* The landing buffer, host-cached, for readbacks the CPU reads (hle_tl_land);
 * NULL when there is none and the arena serves. */
HleArena *hle_gpu_land(void);
/* The GPU reads and writes guest RAM in place (§5.2); false: copy fallback. */
bool hle_gpu_zero_copy(void);
/* DXT (BC1-3) textures sampled as they are; false: decoded on the way in. */
bool hle_gpu_has_bc(void);
/* The A4R4G4B4 formats; false: expanded to A8R8G8B8. */
bool hle_gpu_has_4444(void);
/* Vertex attributes must sit at offsets aligned to their size
 * (HLE_QUIRK_VB_ALIGN on Vulkan; always on Metal). */
bool hle_gpu_vb_align(void);
/* With hle_gpu_vb_align: every attribute at a 4-byte-aligned offset and
 * every stride a multiple of 4, whatever the size (Metal's vertex fetch). */
bool hle_gpu_vb_align_words(void);

/* The app's settings for pipeline builds (before the back end starts):
 * built on worker threads, and the title's recorded ones built first; and
 * the prebuild's progress (done of total). */
void hle_pipe_set_options(bool async, bool prebuild);
void hle_pipe_progress(uint32_t *done, uint32_t *total);

#endif
