/*
 * hakuX HLE GPU — the window's presenter on Metal (vk/swapchain.c): the
 * front frame drawn into the app's CAMetalLayer (mac/window.m), on the
 * window's thread, through the display's gamma ramp when the consumer
 * applies it. FXAA and SGSR are not done (bilinear).
 */
#include "hw/xbox/hle/mtl/mtl_int.h"

#include <android/native_window.h>
#import <QuartzCore/CAMetalLayer.h>

#include "hw/xbox/hle/vk/display.h"
#include "hw/xbox/hle/vk/swapchain.h"

static struct {
    CAMetalLayer *layer;
    id<CAMetalDrawable> drawable;
    uint32_t w, h;
    bool have;                  /* frame holds a slot */
    int stale;                  /* a slot an in-flight present may still read, or -1 */
    HleDispFrame frame;
    id<MTLTexture> frame_tex;   /* frame.tex, kept alive */
    uint8_t rgb[3][256];
    bool identity;
    uint32_t gamma_gen;
    id<MTLTexture> ramp;
    /* what the last present showed (hle_present_unchanged) */
    uint32_t last_gen, last_swap, last_gamma, last_w, last_h;
    uint64_t last_key;
    bool shown;
} g_pr = { .identity = true, .stale = -1 };

bool hle_present_unchanged(struct ANativeWindow *win, uint64_t key)
{
    uint32_t gen, swap;
    if (!g_pr.shown || !win || !hle_disp_front(&gen, &swap)) {
        return false;
    }
    return gen == g_pr.last_gen && swap == g_pr.last_swap &&
           hle_disp_gamma_seq() == g_pr.last_gamma && key == g_pr.last_key &&
           (uint32_t)win->width == g_pr.last_w && (uint32_t)win->height == g_pr.last_h &&
           (__bridge CAMetalLayer *)win->layer == g_pr.layer;
}

bool hle_present_begin(struct ANativeWindow *win, uint32_t *w, uint32_t *h)
{
    if (!win || !win->layer || !hle_mtl_ready() || hle_mtl_lost() ||
        win->width <= 0 || win->height <= 0) {
        return false;
    }
    CAMetalLayer *layer = (__bridge CAMetalLayer *)win->layer;
    if (layer != g_pr.layer) {
        layer.device = g_mtl.dev;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.opaque = YES;
        g_pr.layer = layer;
        g_pr.shown = false;
    }
    g_pr.drawable = [layer nextDrawable];
    if (!g_pr.drawable) {
        return false;
    }
    g_pr.w = (uint32_t)g_pr.drawable.texture.width;
    g_pr.h = (uint32_t)g_pr.drawable.texture.height;
    *w = g_pr.w;
    *h = g_pr.h;
    return true;
}

bool hle_present_frame(uint32_t *w, uint32_t *h)
{
    HleDispFrame f;
    if (hle_disp_acquire(&f)) {
        if (g_pr.have && g_pr.frame.slot != f.slot) {
            if (g_pr.stale >= 0) {
                hle_disp_release(g_pr.stale);
            }
            g_pr.stale = g_pr.frame.slot;
        }
        g_pr.frame = f;
        g_pr.frame_tex = f.tex;
        g_pr.have = true;
    }
    if (!g_pr.have) {
        return false;
    }
    *w = g_pr.frame.w;
    *h = g_pr.frame.h;
    return true;
}

void hle_present_end(float sx, float sy, bool fxaa, int upscale, bool average, uint64_t key)
{
    (void)fxaa;
    (void)upscale;
    (void)average;
    if (!g_pr.drawable) {
        return;
    }
    if (hle_disp_gamma(g_pr.rgb, &g_pr.identity, &g_pr.gamma_gen)) {
        g_pr.ramp = g_pr.identity ? nil : hle_mtl_ramp_texture(g_pr.rgb);
    }
    bool gamma = hle_disp_gamma_consumer() && !g_pr.identity && g_pr.ramp;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = g_pr.drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    hle_disp_use_begin();
    /* Its own queue, so a present doesn't wait out the game's queued work;
     * the GPU waits for the frame's render instead (it can still be pending
     * when it goes to the front). */
    id<MTLCommandBuffer> cb = [g_mtl.present_queue commandBuffer];
    if (g_pr.have && g_pr.frame.value) {
        [cb encodeWaitForEvent:g_mtl.tl value:g_pr.frame.value];
    }
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    id<MTLRenderPipelineState> p = g_pr.have ?
        hle_mtl_pipe(@"hle_tri", gamma ? @"hle_present" : @"hle_copy", MTLPixelFormatBGRA8Unorm,
                     MTLPixelFormatInvalid, false, MTLColorWriteMaskAll) : nil;
    if (p && g_pr.frame.gen == hle_disp_gen()) {
        /* the frame's place: the window's middle, sx x sy of its half size */
        const double vw = g_pr.w * MIN(MAX(sx, 0.0f), 1.0f), vh = g_pr.h * MIN(MAX(sy, 0.0f), 1.0f);
        [e setViewport:(MTLViewport){ (g_pr.w - vw) / 2, (g_pr.h - vh) / 2, vw, vh, 0, 1 }];
        const float k[2] = { 1, 1 };
        [e setRenderPipelineState:p];
        [e setFragmentTexture:g_pr.frame_tex atIndex:0];
        [e setFragmentTexture:g_pr.ramp atIndex:1];
        [e setFragmentSamplerState:g_mtl.linear atIndex:0];
        [e setFragmentBytes:k length:sizeof(k) atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [e endEncoding];
    [cb presentDrawable:g_pr.drawable];
    /* The replaced frame's slot goes back once the presents before this one,
     * the last to read it, are done (the queue runs in order). */
    if (g_pr.stale >= 0) {
        const int stale = g_pr.stale;
        g_pr.stale = -1;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)done;
            hle_disp_release(stale);
        }];
    }
    [cb commit];
    hle_disp_use_end();
    g_pr.drawable = nil;
    g_pr.last_gen = g_pr.have ? g_pr.frame.gen : 0;
    g_pr.last_swap = g_pr.have ? g_pr.frame.swap_id : 0;
    g_pr.last_gamma = hle_disp_gamma_seq();
    g_pr.last_w = g_pr.w;
    g_pr.last_h = g_pr.h;
    g_pr.last_key = key;
    g_pr.shown = g_pr.have;
}
