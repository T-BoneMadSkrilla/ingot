/*
 * hakuX HLE GPU — the Metal back end's render thread (vk/back.c): consumes
 * the command ring, records clears into lazily opened render passes,
 * commits at FENCE / SWAP / KICK / READBACK with the front end's timeline
 * value (spec §5.3, §5.10-5.12).
 *
 * Surfaces, clears, draws (draw.m), uploads, copies, readbacks, swaps into
 * the display and the timeline. Not yet: depth conversions (dropped,
 * counted).
 */
#include "hw/xbox/hle/mtl/mtl_int.h"

#include "hw/xbox/hle/gpu.h"
#include "hw/xbox/hle/hle.h"
#include "hw/xbox/hle/hitch.h"
#include "hw/xbox/hle/host.h"
#include "hw/xbox/hle/prof.h"
#include "hw/xbox/hle/front/fe.h"
#include "hw/xbox/hle/mem/barrier.h"
#include "hw/xbox/hle/mem/guestmem.h"
#include "hw/xbox/hle/tex/xdk.h"
#include "hw/xbox/hle/tex/xdk_res.h"
#include "hw/xbox/hle/vk/display.h"

static struct {
    bool running;
    HleThread thread;
    HleEvent kick;
    int sleeping;                       /* about to wait on kick (atomic) */
    id<MTLCommandBuffer> cb;            /* the open recording, nil none */
    id<MTLRenderCommandEncoder> enc;    /* the open pass, nil none */
    HleMtlSurf *prt, *pds;              /* its targets (NULL: none) */
    uint32_t rt, ds;
    bool pend_clear;
    uint32_t pend_flags, pend_s;
    float pend_color[4], pend_z;
    HleCmdViewport vp;
    uint32_t disp_w, disp_h, present_id;
    HleBackStats st;
    uint64_t dropped[32];               /* commands not done yet, by op */
} g_back;

/* ---- recording -------------------------------------------------------------- */

static id<MTLCommandBuffer> cb_get(void)
{
    if (!g_back.cb) {
        g_back.cb = [g_mtl.queue commandBuffer];
        [g_back.cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
            if (b.status == MTLCommandBufferStatusError) {
                hle_log("hakuX-hle-back", "mtl: command buffer failed: %s",
                        b.error.localizedDescription.UTF8String);
                hle_mtl_lose("a command buffer failed");
            }
        }];
    }
    return g_back.cb;
}

/* The clear colour of the current target: an 8-bit (B8) target keeps blue */
static void color_of(uint32_t argb, float out[4])
{
    float r = ((argb >> 16) & 0xFF) / 255.0f, b = (argb & 0xFF) / 255.0f;
    HleMtlSurf *rt = hle_mtl_surf_get(g_back.rt);
    bool bgra = rt && hle_mtl_out_bgra(rt->fmt);
    out[0] = bgra ? b : r;
    out[1] = ((argb >> 8) & 0xFF) / 255.0f;
    out[2] = bgra ? r : b;
    out[3] = (argb >> 24) / 255.0f;
}

static void vis_pass_end(void);
static void vis_stamp(uint64_t value);
static id<MTLBuffer> vis_buffer(void);

static bool open_pass(void)
{
    HleMtlSurf *rt = hle_mtl_surf_get(g_back.rt), *ds = hle_mtl_surf_get(g_back.ds);
    if (rt && (rt->depth || !hle_mtl_surf_ensure(rt))) {
        rt = NULL;
    }
    if (ds && (!ds->depth || !hle_mtl_surf_ensure(ds))) {
        ds = NULL;
    }
    if (!rt && !ds) {
        g_back.pend_clear = false;
        return false;
    }
    uint32_t pf = g_back.pend_clear ? g_back.pend_flags : 0;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    uint32_t w = rt ? rt->w : ds->w, h = rt ? rt->h : ds->h;
    if (rt) {
        /* nothing written yet and no clear: zeros, not undefined contents */
        bool clear = (pf & HLE_CLEAR_TARGET) || !rt->written;
        const float *c = (pf & HLE_CLEAR_TARGET) ? g_back.pend_color : (const float[4]){ 0 };
        rp.colorAttachments[0].texture = rt->tex;
        rp.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(c[0], c[1], c[2], c[3]);
        hle_mtl_surf_written(rt);
    }
    if (ds) {
        w = MIN(w, ds->w);
        h = MIN(h, ds->h);
        /* a depth buffer's first pass starts at the far end, stencil 0
         * (vk/back.c open_pass: PGR2's shadow map) */
        bool fresh = !ds->written;
        bool zc = (pf & HLE_CLEAR_ZBUFFER) || fresh, sc = (pf & HLE_CLEAR_STENCIL) || fresh;
        rp.depthAttachment.texture = ds->tex;
        rp.depthAttachment.loadAction = zc ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        /* reversed depth (shader/ff.h HLE_ZNORM_REV_GLSL): the far end is 0 */
        rp.depthAttachment.clearDepth = (pf & HLE_CLEAR_ZBUFFER) ? 1.0 - g_back.pend_z : 0.0;
        if (ds->stencil) {
            rp.stencilAttachment.texture = ds->tex;
            rp.stencilAttachment.loadAction = sc ? MTLLoadActionClear : MTLLoadActionLoad;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
            rp.stencilAttachment.clearStencil = (pf & HLE_CLEAR_STENCIL) ? g_back.pend_s : 0;
        }
        hle_mtl_surf_written(ds);
    }
    rp.renderTargetWidth = w;
    rp.renderTargetHeight = h;
    rp.visibilityResultBuffer = vis_buffer();
    g_back.enc = [cb_get() renderCommandEncoderWithDescriptor:rp];
    g_back.prt = rt;
    g_back.pds = ds;
    g_back.pend_clear = false;
    hle_mtl_draw_pass();
    return g_back.enc != nil;
}

static void close_pass(void)
{
    if (!g_back.enc && g_back.pend_clear) {
        open_pass();                    /* a clear-only pass: its load actions */
    }
    if (g_back.enc) {
        vis_pass_end();
        [g_back.enc endEncoding];
        g_back.enc = nil;
        g_back.prt = g_back.pds = NULL;
        g_back.st.passes++;
    }
}

/* ---- submissions (vk/back.c pend_*, submit) ------------------------------------ */

#define HLE_PEND_NS 1000000
static struct {
    uint64_t value;
    unsigned n;
    int64_t since;
    int urgent;
} g_pend;

static void submit(uint64_t value)
{
    if (g_pend.n && value >= g_pend.value) {
        g_pend.n = 0;                   /* this submit signals past them */
    }
    close_pass();
    hle_mtl_draw_upload_flush();
    id<MTLCommandBuffer> cb = cb_get();
    hle_tl_gap_serve();
    hle_mtl_tl_signal(cb, value);
    uint32_t pa = hle_hitch_enter(HLE_ACT_SUBMIT);
    [cb commit];
    hle_hitch_leave(pa);
    hle_mtl_draw_submitted(value);
    vis_stamp(value);
    g_back.cb = nil;
    hle_tl_signaled(value);
    g_back.st.submits++;
}

static void pend_flush(void)
{
    hle_atomic_set(&g_pend.urgent, 0);
    if (g_pend.n) {
        g_pend.n = 0;
        submit(g_pend.value);
    }
}

static void pend_boundary(uint64_t value)
{
    int64_t now = hle_now_ns();
    if (!g_pend.n) {
        g_pend.since = now;
    }
    g_pend.value = value;
    if (++g_pend.n >= 16 || now - g_pend.since >= HLE_PEND_NS || hle_atomic_read(&g_pend.urgent)) {
        pend_flush();
    }
}

static inline void pend_age_check(void)
{
    if (unlikely(g_pend.n) && (hle_now_ns() - g_pend.since >= HLE_PEND_NS ||
                               hle_atomic_read(&g_pend.urgent))) {
        pend_flush();
    }
}

/* ---- device and targets ------------------------------------------------------ */

static void cmd_device(const HleCmdDevice *c, bool reset)
{
    uint32_t scale = MIN(MAX(hle_host_render_scale(), 1), 4);
    if (reset || scale != g_hle_rscale) {
        close_pass();
    }
    if (scale != g_hle_rscale) {
        hle_mtl_surf_destroy_all();
    }
    g_hle_rscale = scale;
    for (uint32_t i = 0; i < c->nsurf && i < HLE_CMD_MAX_SURF; i++) {
        hle_mtl_surf_define(&c->surf[i]);
    }
    g_back.disp_w = c->disp_w;
    g_back.disp_h = c->disp_h;
    g_back.present_id = c->present_id;
    hle_disp_init(c->disp_w * scale, c->disp_h * scale);
    hle_log("hakuX-hle-back", "DEVICE_%s %ux%u surfaces=%u present=%u scale=%u",
            reset ? "RESET" : "CREATE", c->disp_w, c->disp_h, c->nsurf, c->present_id, scale);
}

static void cmd_set_rt(const HleCmdSetRt *c)
{
    if (c->rt != g_back.rt || c->ds != g_back.ds) {
        close_pass();
        g_back.rt = c->rt;
        g_back.ds = c->ds;
    }
}

/* ---- clears -------------------------------------------------------------------- */

static id<MTLDepthStencilState> clear_dss(bool z, bool s)
{
    static id<MTLDepthStencilState> dss[4];
    unsigned i = z | s << 1;
    if (!dss[i]) {
        MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
        d.depthCompareFunction = MTLCompareFunctionAlways;
        d.depthWriteEnabled = z;
        if (s) {
            MTLStencilDescriptor *st = [MTLStencilDescriptor new];
            st.stencilCompareFunction = MTLCompareFunctionAlways;
            st.depthStencilPassOperation = MTLStencilOperationReplace;
            st.writeMask = 0xFF;
            d.frontFaceStencil = d.backFaceStencil = st;
        }
        dss[i] = [g_mtl.dev newDepthStencilStateWithDescriptor:d];
    }
    return dss[i];
}

static MTLColorWriteMask clear_mask(uint32_t flags, MTLPixelFormat f)
{
    bool bgra = hle_mtl_out_bgra(f);
    MTLColorWriteMask m = MTLColorWriteMaskNone;
    m |= (flags & 0x10) ? (bgra ? MTLColorWriteMaskBlue : MTLColorWriteMaskRed) : 0;
    m |= (flags & 0x20) ? MTLColorWriteMaskGreen : 0;
    m |= (flags & 0x40) ? (bgra ? MTLColorWriteMaskRed : MTLColorWriteMaskBlue) : 0;
    m |= (flags & 0x80) ? MTLColorWriteMaskAlpha : 0;
    return m;
}

/* A clear in the open pass (Metal clears only at a pass's load): a full
 * triangle through the masks, scissored to each rectangle. */
static void clear_drawn(const HleCmdClear *c, HleMtlSurf *rt, HleMtlSurf *ds, uint32_t flags)
{
    MTLPixelFormat cf = rt && rt->tex ? rt->fmt : MTLPixelFormatInvalid;
    MTLPixelFormat df = ds && ds->tex ? ds->fmt : MTLPixelFormatInvalid;
    id<MTLRenderPipelineState> p = hle_mtl_pipe(@"hle_clear_tri", @"hle_clear_fs", cf, df,
                                                ds && ds->stencil, clear_mask(flags, cf));
    if (!p) {
        return;
    }
    id<MTLRenderCommandEncoder> e = g_back.enc;
    float col[4], z = 1.0f - c->z;      /* reversed depth */
    color_of(c->color, col);
    [e setRenderPipelineState:p];
    [e setDepthStencilState:clear_dss(flags & HLE_CLEAR_ZBUFFER, flags & HLE_CLEAR_STENCIL)];
    [e setStencilReferenceValue:c->stencil & 0xFF];
    [e setVertexBytes:col length:16 atIndex:0];
    [e setVertexBytes:&z length:4 atIndex:1];
    [e setFragmentBytes:col length:16 atIndex:0];
    uint32_t w = rt ? rt->w : ds->w, h = rt ? rt->h : ds->h;
    if (rt && ds) {
        w = MIN(w, ds->w);
        h = MIN(h, ds->h);
    }
    int32_t sc = (int32_t)(rt ? rt->scale : ds->scale);
    [e setViewport:(MTLViewport){ 0, 0, w, h, 0, 1 }];
    for (uint32_t i = 0; i < MAX(c->nrects, 1u) && i < HLE_CMD_MAX_RECTS; i++) {
        MTLScissorRect r = { 0, 0, w, h };
        if (c->nrects) {
            int32_t x1 = MAX(c->rect[i].x1 * sc, 0), y1 = MAX(c->rect[i].y1 * sc, 0);
            int32_t x2 = MIN(c->rect[i].x2 * sc, (int32_t)w);
            int32_t y2 = MIN(c->rect[i].y2 * sc, (int32_t)h);
            if (x2 <= x1 || y2 <= y1) {
                continue;
            }
            r = (MTLScissorRect){ (NSUInteger)x1, (NSUInteger)y1, (NSUInteger)(x2 - x1),
                                  (NSUInteger)(y2 - y1) };
        }
        [e setScissorRect:r];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [e setScissorRect:(MTLScissorRect){ 0, 0, w, h }];
}

static void cmd_clear(const HleCmdClear *c)
{
    HleMtlSurf *rt = hle_mtl_surf_get(g_back.rt), *ds = hle_mtl_surf_get(g_back.ds);
    uint32_t flags = c->flags;
    if (!rt || rt->depth) {
        flags &= ~HLE_CLEAR_TARGET;
    }
    if (!ds || !ds->depth) {
        flags &= ~(HLE_CLEAR_ZBUFFER | HLE_CLEAR_STENCIL);
    } else if (!ds->stencil) {
        flags &= ~HLE_CLEAR_STENCIL;
    }
    if (!flags) {
        return;
    }
    g_back.st.clears++;
    if ((flags & HLE_CLEAR_TARGET) && g_back.rt == g_back.present_id) {
        g_back.st.last_color = c->color;
        g_back.st.last_rt = g_back.rt;
    }
    bool partial = (flags & HLE_CLEAR_TARGET) && (flags & HLE_CLEAR_TARGET) != HLE_CLEAR_TARGET;
    if (c->nrects == 0 && !partial) {
        /* a whole-target clear is the next pass's load action (§5.10); in an
         * open pass, that pass ends here and the next loads the rest */
        close_pass();
        g_back.pend_flags = (g_back.pend_clear ? g_back.pend_flags : 0) | flags;
        if (flags & HLE_CLEAR_TARGET) {
            color_of(c->color, g_back.pend_color);
        }
        if (flags & HLE_CLEAR_ZBUFFER) {
            g_back.pend_z = c->z;
        }
        if (flags & HLE_CLEAR_STENCIL) {
            g_back.pend_s = c->stencil;
        }
        g_back.pend_clear = true;
        return;
    }
    if (!g_back.enc && !open_pass()) {
        return;
    }
    clear_drawn(c, rt, ds, flags);
    hle_mtl_draw_pass();
}

/* ---- the swap ------------------------------------------------------------------ */

static struct {
    uint8_t rgb[3][256];
    bool identity;
    id<MTLTexture> tex;
} g_gamma = { .identity = true };

static void cmd_gamma(const HleCmdGamma *c)
{
    memcpy(g_gamma.rgb, c->rgb, sizeof(g_gamma.rgb));
    bool ident = true;
    for (unsigned ch = 0; ch < 3 && ident; ch++) {
        for (unsigned i = 0; i < 256 && ident; i++) {
            ident = c->rgb[ch][i] == i;
        }
    }
    g_gamma.identity = ident;
    g_gamma.tex = ident ? nil : hle_mtl_ramp_texture(c->rgb);
    hle_disp_set_gamma(c->rgb, ident);
}

static struct {
    HleFrameHook hook;
    bool armed;
    id<MTLBuffer> buf;
    uint32_t w, h;
} g_fh;

void hle_back_set_frame_hook(const HleFrameHook *hook)
{
    g_fh.hook = hook ? *hook : (HleFrameHook){ 0 };
}

void hle_back_save_caches(void)
{
}

static void overlay_draw(id<MTLCommandBuffer> cb, id<MTLTexture> frame);

static void cmd_swap(const HleCmdSwap *c)
{
    const uint64_t n = g_back.st.swaps + 1;
    g_fh.armed = g_fh.hook.want && g_fh.hook.want(n, g_fh.hook.opaque);
    close_pass();
    HleMtlSurf *src = hle_mtl_surf_get(c->surf);
    int slot = hle_disp_begin_write(c->swap_id, c->value);
    if (src && slot >= 0 && !src->depth && hle_mtl_surf_ensure(src)) {
        id<MTLTexture> dst = hle_disp_texture(slot);
        const uint32_t sw = c->src_w ? MIN(src->w, c->src_w * src->scale) : src->w;
        const uint32_t sh = c->src_h ? MIN(src->h, c->src_h * src->scale) : src->h;
        bool gamma = !g_gamma.identity && !hle_disp_gamma_consumer() && g_gamma.tex;
        id<MTLRenderPipelineState> p = hle_mtl_pipe(@"hle_tri", gamma ? @"hle_copy_gamma" : @"hle_copy",
                                                    MTLPixelFormatRGBA8Unorm, MTLPixelFormatInvalid,
                                                    false, MTLColorWriteMaskAll);
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = dst;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = cb_get();
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        if (p) {
            const float k[2] = { (float)sw / src->w, (float)sh / src->h };
            [e setRenderPipelineState:p];
            [e setFragmentTexture:src->tex atIndex:0];
            [e setFragmentTexture:g_gamma.tex atIndex:1];
            [e setFragmentSamplerState:g_mtl.linear atIndex:0];
            [e setFragmentBytes:k length:sizeof(k) atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [e endEncoding];
        overlay_draw(cb, dst);
        if (g_fh.armed) {
            g_fh.w = (uint32_t)dst.width;
            g_fh.h = (uint32_t)dst.height;
            const NSUInteger row = (NSUInteger)g_fh.w * 4;
            g_fh.buf = [g_mtl.dev newBufferWithLength:row * g_fh.h options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(g_fh.w, g_fh.h, 1) toBuffer:g_fh.buf destinationOffset:0
            destinationBytesPerRow:row destinationBytesPerImage:row * g_fh.h];
            [be endEncoding];
        }
    }
    submit(c->value);
    g_back.st.swaps++;
    if (g_fh.armed) {
        hle_tl_wait(c->value);
        const uint8_t *px = g_fh.buf ? g_fh.buf.contents : NULL;
        g_fh.hook.got(n, px, px ? g_fh.w : 0, px ? g_fh.h : 0, g_fh.hook.opaque);
        g_fh.buf = nil;
        g_fh.armed = false;
    }
}

/* ---- uploads and copies (vk/back.c cmd_upload, cmd_copy) ---------------------------- */

static uint32_t texel_bytes(MTLPixelFormat f)
{
    switch (f) {
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatDepth32Float: return 4;
    case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatRG8Unorm:
    case MTLPixelFormatR16Unorm: case MTLPixelFormatDepth16Unorm: return 2;
    case MTLPixelFormatR8Unorm: return 1;
    default: return 0;
    }
}

static id<MTLSamplerState> nearest(void)
{
    static id<MTLSamplerState> s;
    if (!s) {
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.sAddressMode = d.tAddressMode = MTLSamplerAddressModeClampToEdge;
        s = [g_mtl.dev newSamplerStateWithDescriptor:d];
    }
    return s;
}

/* src's rectangle (texels) drawn over dst's (texels), converting its format and scale */
static void draw_rect(id<MTLCommandBuffer> cb, id<MTLTexture> src, MTLRegion from, HleMtlSurf *d,
                      MTLRegion to)
{
    id<MTLRenderPipelineState> p = hle_mtl_pipe(@"hle_tri", @"hle_copy_rect", d->fmt, MTLPixelFormatInvalid,
                                                false, MTLColorWriteMaskAll);
    if (!p) {
        return;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = d->tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    const float r[4] = { (float)from.origin.x / src.width, (float)from.origin.y / src.height,
                         (float)from.size.width / src.width, (float)from.size.height / src.height };
    [e setRenderPipelineState:p];
    [e setViewport:(MTLViewport){ to.origin.x, to.origin.y, to.size.width, to.size.height, 0, 1 }];
    [e setFragmentTexture:src atIndex:0];
    [e setFragmentSamplerState:nearest() atIndex:0];
    [e setFragmentBytes:r length:sizeof(r) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

/* Texels the CPU wrote, from their copy in the arena (the native core's RAM
 * isn't the GPU's: hle_gpu_zero_copy), into a surface: copied at scale 1,
 * else through a guest-size scratch texture drawn up. Forza's intro movie
 * is uploaded a frame at a time. */
static void cmd_upload(const HleCmdUpload *c)
{
    close_pass();
    HleMtlSurf *d = hle_mtl_surf_get(c->dst);
    const uint32_t tb = d ? texel_bytes(d->fmt) : 0;
    const char *why = !d ? "no surface" : !c->arena ? "not in the arena" : d->d.parent ? "a level or face" :
                      !hle_mtl_surf_ensure(d) ? "no texture" : d->depth ? "not colour" :
                      !tb || c->pitch % tb ? "pitch" : NULL;
    const uint32_t k = d ? MAX(d->scale, 1u) : 1;
    id<MTLCommandBuffer> cb = why ? nil : cb_get();
    unsigned n = 0;
    for (uint32_t i = 0; !why && i < c->nrects && i < HLE_CMD_MAX_RECTS; i++) {
        const HleRect *r = &c->rect[i];
        const int32_t w = MIN(r->x2 - r->x1, (int32_t)(d->w / k) - c->x[i]);
        const int32_t h = MIN(r->y2 - r->y1, (int32_t)(d->h / k) - c->y[i]);
        if (r->x1 < 0 || r->y1 < 0 || c->x[i] < 0 || c->y[i] < 0 || w <= 0 || h <= 0) {
            continue;
        }
        const uint32_t at = c->pa + (uint32_t)r->y1 * c->pitch + (uint32_t)r->x1 * tb;
        const NSUInteger off = (NSUInteger)(c->arena - 1) + (at - c->lo);
        id<MTLTexture> into = d->tex;
        if (k > 1) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:d->fmt
                                                                                          width:w height:h
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            into = [g_mtl.dev newTextureWithDescriptor:td];
        }
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromBuffer:g_mtl.arena sourceOffset:off sourceBytesPerRow:c->pitch
         sourceBytesPerImage:(NSUInteger)c->pitch * h sourceSize:MTLSizeMake(w, h, 1) toTexture:into
            destinationSlice:0 destinationLevel:0
           destinationOrigin:MTLOriginMake(k > 1 ? 0 : c->x[i], k > 1 ? 0 : c->y[i], 0)];
        [be endEncoding];
        if (k > 1) {
            draw_rect(cb, into, MTLRegionMake2D(0, 0, w, h), d,
                      MTLRegionMake2D(c->x[i] * k, c->y[i] * k, w * k, h * k));
        }
        n++;
    }
    if (why) {
        if (g_back.dropped[HLE_OP_UPLOAD]++ < 8) {
            hle_log("hakuX-hle-back", "mtl: upload into %u skipped: %s", c->dst, why);
        }
        return;
    }
    if (n) {
        hle_mtl_surf_written(d);
    }
}

/* CopyRects between surfaces: a blit where the format and scale match, else
 * drawn (colour only); a resolve, the whole source filtered over the whole
 * destination. */
static void cmd_copy(const HleCmdCopy *c)
{
    close_pass();
    HleMtlSurf *s = hle_mtl_surf_get(c->src), *d = hle_mtl_surf_get(c->dst);
    const char *why = !s || !d ? "no surface" : !hle_mtl_surf_ensure(s) || !hle_mtl_surf_ensure(d) ? "no texture" :
                      s->tex == d->tex ? "same texture" : s->depth != d->depth ? "depth and colour" :
                      s->depth && s->fmt != d->fmt ? "depth formats differ" : NULL;
    const bool same = !why && s->fmt == d->fmt && s->scale == d->scale;
    if (!why && !same && (d->depth || d->fmt == MTLPixelFormatInvalid)) {
        why = "a draw can't convert into it";
    }
    if (why) {
        if (g_back.dropped[HLE_OP_COPY]++ < 8) {
            hle_log("hakuX-hle-back", "mtl: copy %u -> %u skipped: %s", c->src, c->dst, why);
        }
        return;
    }
    id<MTLCommandBuffer> cb = cb_get();
    if (c->resolve) {
        draw_rect(cb, s->tex, MTLRegionMake2D(0, 0, s->w, s->h), d, MTLRegionMake2D(0, 0, d->w, d->h));
        hle_mtl_surf_written(d);
        return;
    }
    const int32_t k = (int32_t)MAX(s->scale, 1u), kd = (int32_t)MAX(d->scale, 1u);
    for (uint32_t i = 0; i < c->nrects && i < HLE_CMD_MAX_RECTS; i++) {
        const HleRect *r = &c->rect[i];
        const int32_t w = MIN(MIN(r->x2, (int32_t)s->w / k) - r->x1, (int32_t)d->w / kd - c->x[i]);
        const int32_t h = MIN(MIN(r->y2, (int32_t)s->h / k) - r->y1, (int32_t)d->h / kd - c->y[i]);
        if (r->x1 < 0 || r->y1 < 0 || c->x[i] < 0 || c->y[i] < 0 || w <= 0 || h <= 0) {
            continue;
        }
        if (same) {
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromTexture:s->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(r->x1 * k, r->y1 * k, 0)
                     sourceSize:MTLSizeMake(w * k, h * k, 1) toTexture:d->tex destinationSlice:0
               destinationLevel:0 destinationOrigin:MTLOriginMake(c->x[i] * k, c->y[i] * k, 0)];
            [be endEncoding];
        } else {
            draw_rect(cb, s->tex, MTLRegionMake2D(r->x1 * k, r->y1 * k, w * k, h * k), d,
                      MTLRegionMake2D(c->x[i] * kd, c->y[i] * kd, w * kd, h * kd));
        }
        hle_mtl_surf_written(d);
    }
}

/* ---- readbacks (vk/back.c cmd_readback) --------------------------------------------- */

/* Level / slice of tex (fmt) drawn down to w x h guest texels; nil: failed. */
static id<MTLTexture> rb_down(id<MTLCommandBuffer> cb, id<MTLTexture> tex, MTLPixelFormat fmt,
                              uint32_t level, uint32_t slice, uint32_t w, uint32_t h)
{
    id<MTLTexture> src = tex;
    if (tex.mipmapLevelCount > 1 || tex.textureType != MTLTextureType2D) {
        src = [tex newTextureViewWithPixelFormat:fmt textureType:MTLTextureType2D
                                          levels:NSMakeRange(level, 1) slices:NSMakeRange(slice, 1)];
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    HleMtlSurf tmp = { .fmt = fmt, .tex = [g_mtl.dev newTextureWithDescriptor:td] };
    if (!src || !tmp.tex) {
        return nil;
    }
    draw_rect(cb, src, MTLRegionMake2D(0, 0, src.width, src.height), &tmp, MTLRegionMake2D(0, 0, w, h));
    return tmp.tex;
}

static void rb_copy(id<MTLCommandBuffer> cb, id<MTLTexture> img, uint32_t level, uint32_t slice, uint32_t w,
                    uint32_t h, id<MTLBuffer> buf, NSUInteger at, NSUInteger pitch)
{
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:img sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:at destinationBytesPerRow:pitch
    destinationBytesPerImage:pitch * h];
    [be endEncoding];
}

/* A GPU-rendered texture subresource the CPU locks, tightly packed into buf at at. */
static bool readback_packed(const HleCmdReadback *c, id<MTLBuffer> buf, NSUInteger at)
{
    HleMtlSurf *s = hle_mtl_surf_get(c->surf);
    if (!s || !hle_mtl_surf_ensure(s) || s->depth) {
        return false;
    }
    HleMtlSurf *o = s->d.parent ? hle_mtl_surf_get(s->d.parent) : s;
    uint32_t level = s->d.parent ? s->d.level : c->level;
    uint32_t slice = s->d.parent ? s->d.face : c->face;
    const uint32_t tb = o ? texel_bytes(o->fmt) : 0;
    if (!o || !o->tex || !tb || level >= o->tex.mipmapLevelCount ||
        slice >= (o->tex.textureType == MTLTextureTypeCube ? 6u : 1u) ||
        MAX(o->d.w >> level, 1u) != c->w || MAX(o->d.h >> level, 1u) != c->h) {
        return false;
    }
    if (!o->written) {
        return false;                           /* never rendered: guest memory is current */
    }
    id<MTLCommandBuffer> cb = cb_get();
    id<MTLTexture> img = o->tex;
    if (o->scale > 1) {
        img = rb_down(cb, o->tex, o->fmt, level, slice, c->w, c->h);
        if (!img) {
            return false;
        }
        level = slice = 0;
    }
    rb_copy(cb, img, level, slice, c->w, c->h, buf, at, (NSUInteger)c->w * tb);
    return true;
}

static void cmd_readback(const HleCmdReadback *c)
{
    close_pass();
    id<MTLBuffer> land = g_mtl.land ? g_mtl.land : g_mtl.arena;
    if (c->arena_off == HLE_RB_PACKED) {
        if (c->fb && readback_packed(c, land, c->fb - 1)) {
            hle_tl_land_copied(c->fb - 1, 0, 0, 0);
            g_back.st.readbacks++;
        } else {
            g_back.st.readback_skips++;
        }
    } else if (c->arena_off != HLE_RB_DIRECT) {
        if (readback_packed(c, g_mtl.arena, c->arena_off)) {
            g_back.st.readbacks++;
        } else {
            g_back.st.readback_skips++;
        }
    } else {
        /* linear rows into the landing buffer at fb - 1, landed at pa */
        HleMtlSurf *s = hle_mtl_surf_get(c->surf);
        const HleFmtInfo *fi = s ? hle_fmt_info(s->d.xfmt) : NULL;
        const bool linear = s && s->d.pitch && fi && (fi->flags & HLE_FI_LIN);
        const bool written = s && s->tex && s->written;
        const uint32_t w = s ? (c->w ? c->w : s->d.w) : 0, h = s ? (c->h ? c->h : s->d.h) : 0;
        const uint32_t tb = s ? texel_bytes(s->fmt) : 0;
        const bool fits = c->fb && tb && h && (uint64_t)c->pitch * (h - 1) + (uint64_t)w * tb <= c->fb_len;
        if (linear && written && fits && !s->depth && c->pitch % tb == 0) {
            id<MTLCommandBuffer> cb = cb_get();
            id<MTLTexture> img = s->tex;
            if (s->scale > 1 || w != s->d.w || h != s->d.h) {
                img = rb_down(cb, s->tex, s->fmt, 0, 0, w, h);
            }
            if (img) {
                rb_copy(cb, img, 0, 0, w, h, land, c->fb - 1, c->pitch);
                hle_tl_land_copied(c->fb - 1, c->pitch, w * tb, h);
                g_back.st.readbacks++;
            }
        } else if (s && !written) {
            /* nothing rendered yet: guest memory is already current */
        } else if (g_back.st.readback_skips++ < 8) {
            hle_log("hakuX-hle-back", "mtl: readback of surface %u skipped (linear=%d arena copy=%s fmt=0x%x "
                    "%ux%u depth=%d pitch %u fb_len %u)", c->surf, linear, !c->fb ? "none" : fits ? "yes" : "too small",
                    s ? s->d.xfmt : 0, s ? s->d.w : 0, s ? s->d.h : 0, s ? s->depth : 0, c->pitch, c->fb_len);
        }
    }
    if (c->value) {
        submit(c->value);
    }
}

/* ---- the video overlay (vk/back.c cmd_overlay, overlay_blit) ------------------------ */

/* Its image, drawn over each presented frame: Forza's and other titles' movies
 * play on the overlay, not in the back buffer. */
static HleCmdOverlay g_ovl;
static id<MTLTexture> g_ovl_tex;

static void cmd_overlay(const HleCmdOverlay *c)
{
    g_ovl = *c;
    if (!c->on || !c->w || !c->h) {
        return;
    }
    if (!g_ovl_tex || g_ovl_tex.width != c->w || g_ovl_tex.height != c->h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:c->w height:c->h
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        g_ovl_tex = [g_mtl.dev newTextureWithDescriptor:td];
    }
    close_pass();
    id<MTLBlitCommandEncoder> be = [cb_get() blitCommandEncoder];
    [be copyFromBuffer:g_mtl.arena sourceOffset:c->arena_off sourceBytesPerRow:(NSUInteger)c->w * 4
     sourceBytesPerImage:(NSUInteger)c->w * 4 * c->h sourceSize:MTLSizeMake(c->w, c->h, 1) toTexture:g_ovl_tex
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [be endEncoding];
}

/* Its src rectangle over dst's (fb_w x fb_h back-buffer pixels, scaled to the frame) */
static void overlay_draw(id<MTLCommandBuffer> cb, id<MTLTexture> frame)
{
    if (!g_ovl.on || !g_ovl_tex || !g_ovl.fb_w || !g_ovl.fb_h) {
        return;
    }
    const int32_t tw = (int32_t)g_ovl_tex.width, th = (int32_t)g_ovl_tex.height;
    const int32_t fw = (int32_t)frame.width, fh = (int32_t)frame.height;
    const int32_t s0x = MAX(g_ovl.src[0], 0), s0y = MAX(g_ovl.src[1], 0);
    const int32_t s1x = MIN(g_ovl.src[2], tw), s1y = MIN(g_ovl.src[3], th);
    const float sx = (float)fw / g_ovl.fb_w, sy = (float)fh / g_ovl.fb_h;
    const int32_t d0x = MAX((int32_t)(g_ovl.dst[0] * sx), 0), d1x = MIN((int32_t)(g_ovl.dst[2] * sx), fw);
    const int32_t d0y = MAX((int32_t)(g_ovl.dst[1] * sy), 0), d1y = MIN((int32_t)(g_ovl.dst[3] * sy), fh);
    if (s1x <= s0x || s1y <= s0y || d1x <= d0x || d1y <= d0y) {
        return;
    }
    id<MTLRenderPipelineState> p = hle_mtl_pipe(@"hle_tri", @"hle_copy_rect", frame.pixelFormat,
                                                MTLPixelFormatInvalid, false, MTLColorWriteMaskAll);
    if (!p) {
        return;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = frame;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    const float r[4] = { (float)s0x / tw, (float)s0y / th, (float)(s1x - s0x) / tw, (float)(s1y - s0y) / th };
    [e setRenderPipelineState:p];
    [e setViewport:(MTLViewport){ d0x, d0y, d1x - d0x, d1y - d0y, 0, 1 }];
    [e setFragmentTexture:g_ovl_tex atIndex:0];
    [e setFragmentSamplerState:g_mtl.linear atIndex:0];
    [e setFragmentBytes:r length:sizeof(r) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

/* ---- visibility tests ------------------------------------------------------------- */

/* vk/back.c's: a test's draws counted in one visibility result slot per
 * pass they fall in (the pass descriptor's buffer, Metal's counts reset at
 * each pass's start), the test parked at VIS_END till the submission after
 * it completes, then its slots summed into the guest's report.
 * HAKUX_HLE_VISALL reports every test fully visible, at once. */
#define VIS_SLOTS     4096
#define VIS_MAX_PARTS 16
#define VIS_PENDING   1024
#define VIS_PARKED    UINT64_MAX

static struct {
    id<MTLBuffer> buf;
    uint32_t next;
    bool active;
    int32_t in_pass;                    /* the open pass's slot, -1 none */
    uint32_t parts[VIS_MAX_PARTS], nparts;
    struct {
        uint32_t div, nparts, parts[VIS_MAX_PARTS];
        uint32_t report;
        uint64_t after;
    } pend[VIS_PENDING];
    uint32_t npend;                     /* (read by the timeline's thread: atomic) */
    uint64_t lost;
    int all;                            /* -1: environment not read yet */
} g_vis = { .in_pass = -1, .all = -1 };

static bool vis_on(void)
{
    if (g_vis.all < 0) {
        g_vis.all = getenv("HAKUX_HLE_VISALL") != NULL;
    }
    if (!g_vis.all && !g_vis.buf) {
        g_vis.buf = [g_mtl.dev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared];
    }
    return !g_vis.all && g_vis.buf;
}

static id<MTLBuffer> vis_buffer(void)
{
    return vis_on() ? g_vis.buf : nil;
}

static void vis_report(uint32_t pa, uint32_t count)
{
    uint8_t *p = pa ? hle_pa_ptr(pa, 16) : NULL;
    if (p) {
        hle_stl_le(p, (uint32_t)HLE_VIS_TIMESTAMP);
        hle_stl_le(p + 4, (uint32_t)(HLE_VIS_TIMESTAMP >> 32));
        hle_stl_le(p + 8, count);
        hle_smp_wmb();
        hle_atomic_set((uint32_t *)(p + 12), 0);
        hle_barrier_report_written(pa);
    }
}

/* A draw in the open pass while a test is open: its slot counts from here. */
static void vis_draw(void)
{
    if (!g_vis.active || g_vis.in_pass >= 0 || g_vis.nparts >= VIS_MAX_PARTS || !g_back.enc || !vis_on()) {
        return;
    }
    const uint32_t slot = g_vis.next++ % VIS_SLOTS;
    [g_back.enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:slot * 8];
    g_vis.in_pass = (int32_t)slot;
}

/* The pass ends, or the test does: its slot stops counting. */
static void vis_pass_end(void)
{
    if (g_vis.in_pass >= 0) {
        if (g_back.enc) {
            [g_back.enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
        }
        g_vis.parts[g_vis.nparts++] = (uint32_t)g_vis.in_pass;
        g_vis.in_pass = -1;
    }
}

static void vis_reap(uint64_t completed)
{
    if (!g_vis.npend) {
        return;
    }
    const uint64_t *res = g_vis.buf ? (const uint64_t *)g_vis.buf.contents : NULL;
    uint32_t j = 0;
    for (uint32_t i = 0; i < g_vis.npend; i++) {
        typeof(g_vis.pend[0]) *p = &g_vis.pend[i];
        if (p->after == VIS_PARKED || p->after > completed) {
            g_vis.pend[j++] = *p;
            continue;
        }
        uint64_t sum = 0;
        for (uint32_t k = 0; res && k < p->nparts; k++) {
            sum += res[p->parts[k]];
        }
        vis_report(p->report, (uint32_t)(sum / p->div));
    }
    __atomic_store_n(&g_vis.npend, j, __ATOMIC_RELEASE);
}

static void vis_stamp(uint64_t value)
{
    for (uint32_t i = 0; i < g_vis.npend; i++) {
        if (g_vis.pend[i].after == VIS_PARKED) {
            g_vis.pend[i].after = value;
        }
    }
}

static void cmd_vis_end(const HleCmdVis *c)
{
    vis_pass_end();
    g_vis.active = false;
    if (!vis_on()) {
        g_vis.nparts = 0;
        vis_report(c->report, 640 * 480);
        return;
    }
    if (!c->report) {
        g_vis.nparts = 0;
        return;
    }
    if (g_vis.npend >= VIS_PENDING) {
        vis_reap(hle_tl_completed());
    }
    if (g_vis.npend >= VIS_PENDING) {
        if (g_vis.lost++ == 0) {
            hle_log("hakuX-hle-back", "mtl: vis: %u tests pending, one reported occluded", g_vis.npend);
        }
        g_vis.nparts = 0;
        vis_report(c->report, 0);
        return;
    }
    typeof(g_vis.pend[0]) *p = &g_vis.pend[g_vis.npend];
    HleMtlSurf *rt = hle_mtl_surf_get(g_back.rt);
    const uint32_t sc = rt ? rt->scale : g_hle_rscale;
    p->div = MAX(c->div, 1u) * MAX(sc, 1u) * MAX(sc, 1u);
    p->report = c->report;
    p->after = VIS_PARKED;
    p->nparts = g_vis.nparts;
    memcpy(p->parts, g_vis.parts, sizeof(p->parts));
    g_vis.nparts = 0;
    __atomic_store_n(&g_vis.npend, g_vis.npend + 1, __ATOMIC_RELEASE);
}

/* ---- the ring ---------------------------------------------------------------------- */

static void dropped(uint16_t op)
{
    static const char *const names[32] = {
        [HLE_OP_TEX] = "TEX", [HLE_OP_DRAW] = "DRAW", [HLE_OP_UPLOAD] = "UPLOAD",
        [HLE_OP_COPY] = "COPY", [HLE_OP_ZREAD] = "ZREAD", [HLE_OP_ZWRITE] = "ZWRITE",
        [HLE_OP_OVERLAY] = "OVERLAY", [HLE_OP_READBACK] = "READBACK" };
    if (op < 32 && g_back.dropped[op]++ == 0) {
        hle_log("hakuX-hle-back", "mtl: %s not done yet (dropped)", names[op] ? names[op] : "?");
    }
}

static void dispatch(const HleCmdHdr *h)
{
    const void *p = hle_cmd_payload(h);
    switch (h->op) {
    case HLE_OP_DEVICE_CREATE:  cmd_device(p, false); break;
    case HLE_OP_DEVICE_RESET:   cmd_device(p, true); break;
    case HLE_OP_OBJ_CREATE:     hle_mtl_surf_define(&((const HleCmdObj *)p)->s); break;
    case HLE_OP_OBJ_DESTROY: {
        const HleCmdObjDestroy *d = p;
        if (d->id == g_back.rt || d->id == g_back.ds) {
            close_pass();
        }
        hle_mtl_surf_destroy(d->id);
        hle_mtl_draw_forget(d->id);
        break;
    }
    case HLE_OP_SET_RT:   cmd_set_rt(p); break;
    case HLE_OP_VIEWPORT: g_back.vp = *(const HleCmdViewport *)p; break;
    case HLE_OP_CLEAR:    cmd_clear(p); break;
    case HLE_OP_SWAP:     cmd_swap(p); break;
    case HLE_OP_KICK:
        if (((const HleCmdFence *)p)->value) {
            pend_boundary(((const HleCmdFence *)p)->value);
        } else {
            close_pass();
        }
        break;
    case HLE_OP_READBACK: cmd_readback(p); break;
    case HLE_OP_GAMMA:     cmd_gamma(p); break;
    case HLE_OP_VIS_BEGIN:
        g_vis.active = true;
        g_vis.nparts = 0;
        g_vis.in_pass = -1;
        break;
    case HLE_OP_VIS_END:   cmd_vis_end(p); break;
    case HLE_OP_STATE:      hle_mtl_draw_state(p); break;
    case HLE_OP_STATE_PART: hle_mtl_draw_state_part(p); break;
    case HLE_OP_VSH:        hle_mtl_draw_vsh(p); break;
    case HLE_OP_TEX:        hle_mtl_draw_tex(p); break;
    case HLE_OP_DRAW:
        if (g_back.enc || open_pass()) {
            vis_draw();
            hle_mtl_draw(p, g_back.enc, g_back.prt, g_back.pds, &g_back.vp);
        }
        g_back.st.draws++;
        break;
    case HLE_OP_UPLOAD: cmd_upload(p); break;
    case HLE_OP_COPY:   cmd_copy(p); break;
    case HLE_OP_OVERLAY: cmd_overlay(p); break;
    case HLE_OP_ZREAD: case HLE_OP_ZWRITE:
        dropped(h->op);
        break;
    default:
        hle_log("hakuX-hle-back", "unknown op %u (len %u)", h->op, h->len);
        break;
    }
}

/* vk/back.c ring_wait_brief: up to ~200 us in WFE on the ring head before
 * sleeping on the kick event */
static bool ring_wait_brief(HleRing *r, uint32_t seen)
{
    uint64_t f, t0, t;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t0));
    for (;;) {
        uint32_t h;
        __asm__ volatile("ldaxr %w0, [%1]" : "=r"(h) : "r"(&r->head) : "memory");
        if (h != seen) {
            return true;
        }
        if (hle_atomic_read(&g_pend.urgent)) {
            return false;
        }
        __asm__ volatile("wfe" ::: "memory");
        __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t));
        if (t - t0 > f / 5000) {
            return false;
        }
    }
}

static void *render_thread(void *opaque)
{
    HleRing *r = hle_fe_ring();
    hle_hitch_thread(HLE_HT_RENDER);
    for (;;) {
        @autoreleasepool {
            hle_event_reset(&g_back.kick);
            vis_reap(hle_tl_completed());
            const HleCmdHdr *h;
            int64_t t0 = hle_prof_begin();
            while ((h = hle_ring_peek(r)) != NULL) {
                if (unlikely(hle_mtl_lost())) {
                    hle_ring_consume(r);
                    continue;
                }
                dispatch(h);
                hle_ring_consume(r);
                g_back.st.cmds++;
                pend_age_check();
            }
            hle_prof_end(HLE_PROF_BACK, t0);
            uint32_t used = hle_ring_used(r);
            if (used > g_back.st.ring_hw) {
                g_back.st.ring_hw = used;
            }
            uint32_t seen = __atomic_load_n(&r->head, __ATOMIC_ACQUIRE);
            if (hle_ring_peek(r) || ring_wait_brief(r, seen)) {
                continue;
            }
            if (!hle_mtl_lost()) {
                pend_flush();
            }
            if (hle_ring_peek(r)) {
                continue;
            }
            __atomic_store_n(&g_back.sleeping, 1, __ATOMIC_SEQ_CST);
            __atomic_thread_fence(__ATOMIC_SEQ_CST);
            if (hle_ring_peek(r)) {
                __atomic_store_n(&g_back.sleeping, 0, __ATOMIC_RELAXED);
                continue;
            }
            uint32_t pa = hle_hitch_enter(HLE_ACT_IDLE);
            hle_event_wait(&g_back.kick);
            __atomic_store_n(&g_back.sleeping, 0, __ATOMIC_RELAXED);
            hle_hitch_leave(pa);
        }
    }
    return NULL;
}

static void on_complete(uint64_t completed)
{
    hle_hitch_gpu_done();
    if (__atomic_load_n(&g_vis.npend, __ATOMIC_ACQUIRE)) {
        hle_event_set(&g_back.kick);    /* the render thread reaps the tests */
    }
    hle_disp_on_complete(completed);
}

int hle_back_start(void)
{
    if (g_back.running) {
        return 0;
    }
    int r = hle_mtl_init();
    if (r) {
        return r;
    }
    const char *what = hle_mtl_arena_init(256u << 20) ? "the upload arena" :
                       hle_mtl_land_init(16u << 20) ? "the readback buffer" :
                       hle_fe_init() ? "the front end" :
                       hle_tl_init(on_complete) ? "the timeline" :
                       hle_mtl_draw_init() ? "the draws" : NULL;
    if (what) {
        hle_log("hakuX-hle-back", "back end init failed: %s", what);
        snprintf(g_hle_unavailable, sizeof(g_hle_unavailable), "%s can't set up %s",
                 g_mtl.dev.name.UTF8String, what);
        return -3;
    }
    hle_event_init(&g_back.kick, false);
    hle_barrier_set_waiter(hle_tl_completed, hle_tl_wait);
    hle_thread_create(&g_back.thread, "hle.render", render_thread, NULL, HLE_THREAD_DETACHED);
    g_back.running = true;
    hle_disp_setup();
    hle_mtl_set_ready();
    hle_log("hakuX-hle-back", "back end started (Metal, zero_copy=%d)", hle_gpu_zero_copy());
    return 0;
}

bool hle_back_running(void)
{
    return g_back.running;
}

void hle_back_kick(void)
{
    if (g_back.running) {
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        if (__atomic_load_n(&g_back.sleeping, __ATOMIC_SEQ_CST)) {
            hle_event_set(&g_back.kick);
        }
    }
}

void hle_back_urgent(void)
{
    if (g_back.running) {
        hle_atomic_set(&g_pend.urgent, 1);
        __asm__ volatile("sev" ::: "memory");
        hle_event_set(&g_back.kick);
    }
}

void hle_back_draw_diag(void)
{
    hle_log("hakuX-hle-back", "mtl: %llu draws, %llu clears, %llu passes, %llu swaps",
            (unsigned long long)g_back.st.draws, (unsigned long long)g_back.st.clears,
            (unsigned long long)g_back.st.passes, (unsigned long long)g_back.st.swaps);
    hle_mtl_draw_diag();
}

uint64_t hle_back_swap_count(void)
{
    return g_back.st.swaps;
}
