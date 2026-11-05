/*
 * hakuX HLE GPU — the Metal back end's internals (mtl/, CONFIG_METAL only).
 * The front end's commands (front/cmd.h) and the back end's interface
 * (vk/back.h, vk/display.h, vk/swapchain.h, gpu.h: no API types) are the
 * same as the Vulkan back end's; vk/ is the reference for what each does.
 */
#ifndef HW_XBOX_HLE_MTL_MTL_INT_H
#define HW_XBOX_HLE_MTL_MTL_INT_H

#include "hw/xbox/hle/base.h"
#include "hw/xbox/hle/front/arena.h"
#include "hw/xbox/hle/front/cmd.h"
#include "hw/xbox/hle/vk/back.h"

#ifdef __OBJC__
#import <Metal/Metal.h>

typedef struct HleMtl {
    id<MTLDevice> dev;
    id<MTLCommandQueue> queue;
    id<MTLCommandQueue> present_queue; /* the window's presents, not behind the game's work */
    id<MTLSharedEvent> tl;          /* the render timeline (timeline.m) */
    id<MTLBuffer> arena;            /* the upload arena (§5.3), shared */
    id<MTLBuffer> land;             /* readbacks the CPU reads, shared */
    id<MTLLibrary> lib;             /* the back end's own shaders (dev.m k_msl) */
    id<MTLSamplerState> linear;     /* bilinear, clamped */
    bool bc;                        /* BC1-3 textures */
} HleMtl;
extern HleMtl g_mtl;
/* Pipelines built off the render thread (the app's setting, dev.m) */
extern bool g_mtl_pipe_async;

/* A render pipeline of the back end's shaders (fs: fragment function),
 * colour format cf (Invalid: none), depth format df (stencil: it has one),
 * colour write mask wm; nil on failure. Cached. */
id<MTLRenderPipelineState> hle_mtl_pipe(NSString *vs, NSString *fs, MTLPixelFormat cf,
                                        MTLPixelFormat df, bool stencil, MTLColorWriteMask wm);

/* surf.m */
typedef struct HleMtlSurf {
    bool alive;
    uint32_t id;
    HleSurfDesc d;
    uint32_t w, h;              /* texture extent, scaled */
    uint32_t scale;             /* host pixels per guest pixel */
    MTLPixelFormat fmt;         /* Invalid: not renderable */
    bool depth, stencil;
    bool written;               /* a pass or clear stored into it */
    id<MTLTexture> tex;
    id<MTLTexture> sview;       /* sampled as a texture (draw.m), its swizzle; nil: tex */
    /* asynchronous pipeline builds (draw.m target_note): the last swap a
     * draw targeted it and the one before (swap count + 1, 0: never) */
    uint64_t drawn_cur, drawn_prev;
} HleMtlSurf;

HleMtlSurf *hle_mtl_surf_get(uint32_t id);
HleMtlSurf *hle_mtl_surf_define(const HleSurfDesc *d);
/* Its texture made on first use; false: none can be. */
bool hle_mtl_surf_ensure(HleMtlSurf *s);
/* A pass or copy stored into s: a level's or face's parent holds it too
 * (sampled whole: a cube drawn face by face). */
void hle_mtl_surf_written(HleMtlSurf *s);
void hle_mtl_surf_destroy(uint32_t id);
void hle_mtl_surf_destroy_all(void);
/* An 8-bit (NV2A B8) or G8B8 target stores blue where red is: shaders and
 * clears write .bgra to it (vk/back_int.h hle_surf_out_bgra). */
static inline bool hle_mtl_out_bgra(MTLPixelFormat f)
{
    return f == MTLPixelFormatR8Unorm || f == MTLPixelFormatRG8Unorm;
}

/* display.m */
typedef struct HleDispFrame {
    int slot;
    uint32_t gen, swap_id, w, h;
    uint64_t value;
    __unsafe_unretained id<MTLTexture> tex;
} HleDispFrame;
id<MTLTexture> hle_disp_texture(int slot);
bool hle_disp_acquire(HleDispFrame *f);
uint32_t hle_disp_gen(void);
void hle_disp_use_begin(void);
void hle_disp_use_end(void);

/* timeline.m: cb signals value when it completes */
void hle_mtl_tl_signal(id<MTLCommandBuffer> cb, uint64_t value);

/* A 256 x 1 texture of a gamma ramp's three channels (r, g, b), for the
 * hle_copy_gamma / hle_present shaders; nil: identity. */
id<MTLTexture> hle_mtl_ramp_texture(const uint8_t rgb[3][256]);

/* draw.m (vk/draw.c): the draw state, textures and programs the front end
 * sends, and the draws into the open pass (its targets rt, ds: NULL none) */
int hle_mtl_draw_init(void);
void hle_mtl_draw_state(const HleCmdState *s);
void hle_mtl_draw_state_part(const HleCmdStatePart *p);
void hle_mtl_draw_vsh(const HleCmdVsh *c);
void hle_mtl_draw_tex(const HleCmdTex *c);
void hle_mtl_draw_forget(uint32_t id);
void hle_mtl_draw_upload_flush(void);
void hle_mtl_draw_submitted(uint64_t value);
uint64_t hle_tl_completed(void);
/* a new pass: the encoder has none of the draws' state */
void hle_mtl_draw_pass(void);
void hle_mtl_draw(const HleCmdDraw *c, id<MTLRenderCommandEncoder> e, HleMtlSurf *rt,
                  HleMtlSurf *ds, const HleCmdViewport *vp);
void hle_mtl_draw_diag(void);
#endif

/* timeline.m */
int hle_tl_init(void (*on_complete)(uint64_t completed));
void hle_tl_signaled(uint64_t value);
void hle_tl_gap_serve(void);

/* dev.m */
int hle_mtl_init(void);
int hle_mtl_arena_init(uint32_t size);
/* a failure leaves no landing buffer (the arena serves) */
int hle_mtl_land_init(uint32_t size);
uint8_t *hle_mtl_land_map(void);
/* Nothing more goes to the GPU (a command buffer failed): every timeline
 * value counts as reached and the host hears why. */
void hle_mtl_lose(const char *what);
bool hle_mtl_lost(void);
bool hle_mtl_ready(void);
void hle_mtl_set_ready(void);

/* surf.m: the resolution scale (vk/back_int.h g_hle_rscale) */
extern uint32_t g_hle_rscale;

#endif
