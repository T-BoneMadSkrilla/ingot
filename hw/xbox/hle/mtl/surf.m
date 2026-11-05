/*
 * hakuX HLE GPU — render-target and depth surfaces on Metal (vk/surf.c):
 * textures by front-end object id. A texture with levels or faces that is
 * rendered to owns one texture; its level and face surfaces are views.
 * Command buffers hold what they use, so a destroy needs no parking.
 */
#include "hw/xbox/hle/mtl/mtl_int.h"

#include "hw/xbox/hle/hle.h"
#include "hw/xbox/hle/tex/xdk.h"

#define HLE_MAX_MTL_SURF 256
/* vk/surf.c SURF_UNSCALED_MAX: small render-to-texture targets render at
 * guest resolution */
#define SURF_UNSCALED_MAX 128

static HleMtlSurf g_surf[HLE_MAX_MTL_SURF];
uint32_t g_hle_rscale = 1;

static bool owner_kind(const HleSurfDesc *d)
{
    return !d->parent && (d->levels > 1 || d->faces > 1);
}

/* The Vulkan back end's formats (vk/surf.c surf_format) as MoltenVK maps
 * them; Apple GPUs have no 24-bit depth: D24S8 is Depth32Float_Stencil8. */
static MTLPixelFormat surf_format(uint32_t xfmt, bool *depth, bool *stencil)
{
    *depth = *stencil = false;
    switch (xfmt) {
    case HLE_XFMT_A8R8G8B8: case HLE_XFMT_LIN_A8R8G8B8:
    case HLE_XFMT_X8R8G8B8: case HLE_XFMT_LIN_X8R8G8B8:
        return MTLPixelFormatBGRA8Unorm;
    case HLE_XFMT_R5G6B5: case HLE_XFMT_LIN_R5G6B5:
        return MTLPixelFormatB5G6R5Unorm;
    case HLE_XFMT_A1R5G5B5: case HLE_XFMT_LIN_A1R5G5B5:
    case HLE_XFMT_X1R5G5B5: case HLE_XFMT_LIN_X1R5G5B5:
        return MTLPixelFormatA1BGR5Unorm;
    case HLE_XFMT_L8: case HLE_XFMT_LIN_L8:
        return MTLPixelFormatR8Unorm;
    case HLE_XFMT_G8B8: case HLE_XFMT_LIN_G8B8:
        return MTLPixelFormatRG8Unorm;
    case HLE_XFMT_L16: case HLE_XFMT_LIN_L16:
        return MTLPixelFormatR16Unorm;
    case HLE_XFMT_D24S8: case HLE_XFMT_LIN_D24S8:
    case HLE_XFMT_F24S8: case HLE_XFMT_LIN_F24S8:
        *depth = *stencil = true;
        return MTLPixelFormatDepth32Float_Stencil8;
    case HLE_XFMT_D16: case HLE_XFMT_LIN_D16:
        *depth = true;
        return MTLPixelFormatDepth16Unorm;
    case HLE_XFMT_F16: case HLE_XFMT_LIN_F16:
        *depth = true;
        return MTLPixelFormatDepth32Float;
    default:
        return MTLPixelFormatInvalid;
    }
}

static uint32_t surf_scale(const HleSurfDesc *d, bool depth)
{
    bool small = !d->role && !d->pitch && !d->parent && d->levels <= 1 && d->faces <= 1 &&
                 !depth && MAX(d->w, d->h) <= SURF_UNSCALED_MAX;
    return small ? 1 : g_hle_rscale;
}

static void clear_slot(HleMtlSurf *s)
{
    s->tex = nil;
    s->sview = nil;
    s->alive = false;
    s->id = 0;
    s->written = false;
    s->drawn_cur = s->drawn_prev = 0;
}

HleMtlSurf *hle_mtl_surf_get(uint32_t id)
{
    if (!id) {
        return NULL;
    }
    for (unsigned i = 0; i < HLE_MAX_MTL_SURF; i++) {
        if (g_surf[i].alive && g_surf[i].id == id) {
            return &g_surf[i];
        }
    }
    return NULL;
}

HleMtlSurf *hle_mtl_surf_define(const HleSurfDesc *d)
{
    HleMtlSurf *s = hle_mtl_surf_get(d->id);
    if (s && s->d.xfmt == d->xfmt && s->d.w == d->w && s->d.h == d->h &&
        s->d.parent == d->parent && s->d.levels == d->levels && s->d.faces == d->faces &&
        s->d.level == d->level && s->d.face == d->face) {
        /* the same image: pa / pitch are readback metadata, and the role
         * DEVICE_CREATE set survives an OBJ_CREATE with role 0 */
        uint32_t role = s->d.role;
        s->d = *d;
        if (!d->role) {
            s->d.role = role;
        }
        return s;
    }
    if (s) {
        clear_slot(s);
    }
    for (unsigned i = 0; i < HLE_MAX_MTL_SURF; i++) {
        if (!g_surf[i].alive) {
            s = &g_surf[i];
            clear_slot(s);
            s->alive = true;
            s->id = d->id;
            s->d = *d;
            s->fmt = surf_format(d->xfmt, &s->depth, &s->stencil);
            s->scale = surf_scale(d, s->depth);
            s->w = d->w * s->scale;
            s->h = d->h * s->scale;
            if (s->fmt == MTLPixelFormatInvalid) {
                hle_log("hakuX-hle-back", "surface %u: format 0x%x not renderable", d->id, d->xfmt);
            }
            return s;
        }
    }
    static unsigned s_full;
    if (s_full++ < 4) {
        hle_log("hakuX-hle-back", "surface table full: %u not defined", d->id);
    }
    return NULL;
}

static id<MTLTexture> owner_texture(const HleMtlSurf *s)
{
    uint32_t levels = 1;
    while ((MAX(s->d.w, s->d.h) >> levels) && levels < 16) {
        levels++;
    }
    levels = MIN(MAX((uint32_t)s->d.levels, 1u), levels);
    bool cube = s->d.faces == 6 && s->d.w == s->d.h;
    MTLTextureDescriptor *td = cube ?
        [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:s->fmt size:s->w
                                                         mipmapped:levels > 1] :
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:s->fmt width:s->w height:s->h
                                                       mipmapped:levels > 1];
    td.mipmapLevelCount = levels;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsagePixelFormatView;
    td.storageMode = MTLStorageModePrivate;
    return [g_mtl.dev newTextureWithDescriptor:td];
}

void hle_mtl_surf_written(HleMtlSurf *s)
{
    s->written = true;
    if (s->d.parent) {
        HleMtlSurf *o = hle_mtl_surf_get(s->d.parent);
        if (o) {
            o->written = true;
        }
    }
}

bool hle_mtl_surf_ensure(HleMtlSurf *s)
{
    if (s->tex) {
        return true;
    }
    if (s->fmt == MTLPixelFormatInvalid || !s->w || !s->h) {
        return false;
    }
    if (s->d.parent) {
        HleMtlSurf *o = hle_mtl_surf_get(s->d.parent);
        if (!o || !hle_mtl_surf_ensure(o) || o->fmt != s->fmt ||
            s->d.level >= o->tex.mipmapLevelCount) {
            return false;
        }
        NSUInteger slices = o->tex.textureType == MTLTextureTypeCube ? 6 : 1;
        if (s->d.face >= slices) {
            return false;
        }
        s->tex = [o->tex newTextureViewWithPixelFormat:s->fmt textureType:MTLTextureType2D
                                                levels:NSMakeRange(s->d.level, 1)
                                                slices:NSMakeRange(s->d.face, 1)];
        s->w = (uint32_t)s->tex.width;
        s->h = (uint32_t)s->tex.height;
        return s->tex != nil;
    }
    if (owner_kind(&s->d)) {
        s->tex = owner_texture(s);
    } else {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:s->fmt width:s->w height:s->h mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                   MTLTextureUsagePixelFormatView;
        td.storageMode = MTLStorageModePrivate;
        s->tex = [g_mtl.dev newTextureWithDescriptor:td];
    }
    if (!s->tex) {
        hle_log("hakuX-hle-back", "surface %u: %ux%u texture failed", s->id, s->w, s->h);
    }
    return s->tex != nil;
}

void hle_mtl_surf_destroy(uint32_t id)
{
    HleMtlSurf *s = hle_mtl_surf_get(id);
    if (s) {
        clear_slot(s);
    }
}

void hle_mtl_surf_destroy_all(void)
{
    for (unsigned i = 0; i < HLE_MAX_MTL_SURF; i++) {
        clear_slot(&g_surf[i]);
    }
}
