/*
 * hakuX HLE GPU — hw/xbox/hle/gpu.h on the Vulkan back end.
 */
#include "hw/xbox/hle/base.h"
#include "hw/xbox/hle/gpu.h"
#include "hw/xbox/hle/vk/guest_ram.h"
#include "hw/xbox/hle/vk/quirks.h"

HleArena *hle_gpu_arena(void)
{
    return &g_harena.alloc;
}

uint8_t *hle_gpu_arena_map(void)
{
    return g_harena.map;
}

HleArena *hle_gpu_land(void)
{
    return g_hland.buf ? &g_hland.alloc : NULL;
}

bool hle_gpu_zero_copy(void)
{
    return g_hram.zero_copy;
}

bool hle_gpu_has_bc(void)
{
    return g_hvk.caps.bc;
}

bool hle_gpu_has_4444(void)
{
    return g_hvk.caps.x4444;
}

bool hle_gpu_vb_align(void)
{
    return hle_quirk(HLE_QUIRK_VB_ALIGN);
}

bool hle_gpu_vb_align_words(void)
{
    return false;
}
