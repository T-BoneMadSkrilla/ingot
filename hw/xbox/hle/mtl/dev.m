/*
 * hakuX HLE GPU — the Metal device (vk/vkdev.c, vk/guest_ram.c): the GPU,
 * its queue, the upload arena and landing buffer, the back end's own
 * shaders, the device-lost state, and gpu.h.
 */
#include "hw/xbox/hle/mtl/mtl_int.h"

#include "hw/xbox/hle/gpu.h"
#include "hw/xbox/hle/hle.h"
#include "hw/xbox/hle/host.h"
#include "hw/xbox/hle/pb/pbres.h"

HleMtl g_mtl;
bool g_mtl_pipe_async;
static HleArena g_arena_alloc, g_land_alloc;
static bool g_lost, g_ready;

/* The back end's own shaders: a full-target triangle (vertex 0-2) sampling
 * a texture (the swap's scaled copy), and the clear quad (colour, depth
 * and stencil through the pipeline's masks). */
static NSString *const k_msl = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 pos [[position]]; float2 uv; };\n"
    "vertex V hle_tri(uint i [[vertex_id]]) {\n"
    "  float2 p = float2((i << 1) & 2, i & 2);\n"
    "  V o; o.pos = float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0); o.uv = p;\n"
    "  return o;\n"
    "}\n"
    /* k: the part of t shown (its top left), as a fraction of t */
    "fragment float4 hle_copy(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
    "                         sampler s [[sampler(0)]], constant float2 &k [[buffer(0)]]) {\n"
    "  return t.sample(s, in.uv * k);\n"
    "}\n"
    /* r: the source rectangle (origin, size) as fractions of t */
    "fragment float4 hle_copy_rect(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
    "                              sampler s [[sampler(0)]], constant float4 &r [[buffer(0)]]) {\n"
    "  return t.sample(s, r.xy + in.uv * r.zw);\n"
    "}\n"
    "fragment float4 hle_copy_gamma(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
    "                               texture2d<float> ramp [[texture(1)]],\n"
    "                               sampler s [[sampler(0)]], constant float2 &k [[buffer(0)]]) {\n"
    "  float4 c = t.sample(s, in.uv * k);\n"
    "  constexpr sampler n(filter::nearest, coord::pixel);\n"
    "  float3 i = floor(saturate(c.rgb) * 255.0 + 0.5) + 0.5;\n"
    "  return float4(ramp.sample(n, float2(i.r, 0.5)).r, ramp.sample(n, float2(i.g, 0.5)).g,\n"
    "                ramp.sample(n, float2(i.b, 0.5)).b, c.a);\n"
    "}\n"
    "struct ClearOut { float4 c [[color(0)]]; float d [[depth(any)]]; };\n"
    "struct CV { float4 pos [[position]]; };\n"
    "vertex CV hle_clear_tri(uint i [[vertex_id]], constant float4 &c [[buffer(0)]],\n"
    "                        constant float &z [[buffer(1)]]) {\n"
    "  float2 p = float2((i << 1) & 2, i & 2);\n"
    "  CV o; o.pos = float4(p * 2.0 - 1.0, z, 1.0); return o;\n"
    "}\n"
    "fragment ClearOut hle_clear_fs(CV in [[stage_in]], constant float4 &c [[buffer(0)]]) {\n"
    "  ClearOut o; o.c = c; o.d = in.pos.z; return o;\n"
    "}\n"
    /* the presenter: the frame through the display's gamma ramp (a 256 x 1
     * texture of the three channels' ramps) */
    "fragment float4 hle_present(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
    "                            texture2d<float> ramp [[texture(1)]],\n"
    "                            sampler s [[sampler(0)]]) {\n"
    "  float4 c = t.sample(s, in.uv);\n"
    "  constexpr sampler n(filter::nearest, coord::pixel);\n"
    "  float3 i = floor(saturate(c.rgb) * 255.0 + 0.5) + 0.5;\n"
    "  return float4(ramp.sample(n, float2(i.r, 0.5)).r, ramp.sample(n, float2(i.g, 0.5)).g,\n"
    "                ramp.sample(n, float2(i.b, 0.5)).b, 1.0);\n"
    "}\n";

int hle_mtl_init(void)
{
    g_mtl.dev = MTLCreateSystemDefaultDevice();
    if (!g_mtl.dev) {
        snprintf(g_hle_unavailable, sizeof(g_hle_unavailable), "no Metal device");
        return -1;
    }
    g_mtl.queue = [g_mtl.dev newCommandQueueWithMaxCommandBufferCount:64];
    g_mtl.present_queue = [g_mtl.dev newCommandQueue];
    g_mtl.bc = g_mtl.dev.supportsBCTextureCompression;
    NSError *err = nil;
    MTLCompileOptions *co = [MTLCompileOptions new];
    co.mathMode = MTLMathModeSafe;
    g_mtl.lib = [g_mtl.dev newLibraryWithSource:k_msl options:co error:&err];
    if (!g_mtl.lib) {
        hle_log("hakuX-hle-back", "mtl: back end shaders: %s", err.localizedDescription.UTF8String);
        return -1;
    }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_mtl.linear = [g_mtl.dev newSamplerStateWithDescriptor:sd];
    /* Metal draws no triangle fans: fans and polygons become lists (pbres.c) */
    g_hle_no_fans = true;
    hle_log("hakuX-hle-back", "mtl: %s, unified memory %d, BC %d, max buffer %llu MiB",
            g_mtl.dev.name.UTF8String, g_mtl.dev.hasUnifiedMemory, g_mtl.bc,
            (unsigned long long)(g_mtl.dev.maxBufferLength >> 20));
    return 0;
}

int hle_mtl_arena_init(uint32_t size)
{
    g_mtl.arena = [g_mtl.dev newBufferWithLength:size
                                         options:MTLResourceStorageModeShared |
                                                 MTLResourceCPUCacheModeWriteCombined];
    if (!g_mtl.arena) {
        return -1;
    }
    hle_arena_init(&g_arena_alloc, size);
    return 0;
}

int hle_mtl_land_init(uint32_t size)
{
    g_mtl.land = [g_mtl.dev newBufferWithLength:size options:MTLResourceStorageModeShared];
    if (g_mtl.land) {
        hle_arena_init(&g_land_alloc, size);
    }
    return 0;
}

static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *g_pipes;

id<MTLRenderPipelineState> hle_mtl_pipe(NSString *vs, NSString *fs, MTLPixelFormat cf,
                                        MTLPixelFormat df, bool stencil, MTLColorWriteMask wm)
{
    NSString *key = [NSString stringWithFormat:@"%@/%@/%lu/%lu/%d/%lu", vs, fs, (unsigned long)cf,
                                               (unsigned long)df, stencil, (unsigned long)wm];
    if (!g_pipes) {
        g_pipes = [NSMutableDictionary new];
    }
    id<MTLRenderPipelineState> p = g_pipes[key];
    if (p) {
        return p;
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [g_mtl.lib newFunctionWithName:vs];
    d.fragmentFunction = [g_mtl.lib newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat = cf;
    d.colorAttachments[0].writeMask = cf == MTLPixelFormatInvalid ? MTLColorWriteMaskNone : wm;
    d.depthAttachmentPixelFormat = df;
    d.stencilAttachmentPixelFormat = stencil ? df : MTLPixelFormatInvalid;
    NSError *err = nil;
    p = [g_mtl.dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) {
        hle_log("hakuX-hle-back", "mtl: pipeline %s: %s", key.UTF8String,
                err.localizedDescription.UTF8String);
        return nil;
    }
    g_pipes[key] = p;
    return p;
}

/* A new texture for each ramp: a command buffer may still sample the last */
id<MTLTexture> hle_mtl_ramp_texture(const uint8_t rgb[3][256])
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_mtl.dev newTextureWithDescriptor:td];
    uint8_t px[256 * 4];
    for (unsigned i = 0; i < 256; i++) {
        px[4 * i] = rgb[0][i];
        px[4 * i + 1] = rgb[1][i];
        px[4 * i + 2] = rgb[2][i];
        px[4 * i + 3] = 255;
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, 256, 1) mipmapLevel:0 withBytes:px bytesPerRow:sizeof(px)];
    return t;
}

void hle_mtl_lose(const char *what)
{
    if (__atomic_exchange_n(&g_lost, true, __ATOMIC_ACQ_REL)) {
        return;
    }
    char why[160];
    snprintf(why, sizeof(why), "stopped responding (%s)", what);
    hle_log("hakuX-hle-back", "FATAL: the GPU %s: nothing more is drawn", why);
    hle_tl_lose();
    hle_host_gpu_lost(why);
}

bool hle_mtl_lost(void)
{
    return __atomic_load_n(&g_lost, __ATOMIC_ACQUIRE);
}

bool hle_mtl_ready(void)
{
    return hle_atomic_load_acquire(&g_ready);
}

void hle_mtl_set_ready(void)
{
    hle_smp_wmb();
    hle_atomic_set(&g_ready, true);
}

/* ---- gpu.h ---------------------------------------------------------------- */

HleArena *hle_gpu_arena(void)
{
    return &g_arena_alloc;
}

uint8_t *hle_gpu_arena_map(void)
{
    return (uint8_t *)g_mtl.arena.contents;
}

HleArena *hle_gpu_land(void)
{
    return g_mtl.land ? &g_land_alloc : NULL;
}

uint8_t *hle_mtl_land_map(void)
{
    return (uint8_t *)g_mtl.land.contents;
}

bool hle_gpu_zero_copy(void)
{
    return false;
}

bool hle_gpu_has_bc(void)
{
    return false;
}

bool hle_gpu_has_4444(void)
{
    return false;
}

bool hle_gpu_vb_align(void)
{
    return true;
}

bool hle_gpu_vb_align_words(void)
{
    return true;
}

/* Asynchronous builds (draw.m pipeline); no prebuild: the system's shader
 * cache keeps the last runs' */
void hle_pipe_set_options(bool async, bool prebuild)
{
    (void)prebuild;
    const char *e = getenv("HAKUX_HLE_ASYNCPIPE");
    g_mtl_pipe_async = e && *e ? atoi(e) != 0 : async;
}

void hle_pipe_progress(uint32_t *done, uint32_t *total)
{
    *done = *total = 0;
}
