/*
 * hakuX HLE GPU — draws on Metal (vk/draw.c, whose comments say why each
 * mapping is what it is): textures from the arena, samplers from the
 * texture-stage state, pipelines of the generators' MSL (shader/msl.h) for
 * fixed function, vertex programs and register combiners, depth-stencil
 * states, and the draws into the open pass. Render thread only.
 *
 * Not yet: shadow-buffer compares (depth surfaces sample lit), the sampler
 * LOD bias (Metal samplers have none), the depth-equal tolerance pass,
 * snapshots of the target for modes other than PROJECT2D / 3D (white).
 */
#include "hw/xbox/hle/mtl/mtl_int.h"

#include <math.h>

#include "hw/xbox/hle/hitch.h"
#include "hw/xbox/hle/hle.h"
#include "hw/xbox/hle/shader/ff.h"
#include "hw/xbox/hle/shader/ffhw.h"
#include "hw/xbox/hle/shader/msl.h"
#include "hw/xbox/hle/shader/psh.h"
#include "hw/xbox/hle/shader/vattr.h"
#include "hw/xbox/hle/shader/vsh.h"
#include "hw/xbox/hle/tex/xdk.h"
#include "hw/xbox/hle/tex/xdk_res.h"

#define HLE_MAX_TEX   2048
#define HLE_MAX_PROGS 1024

/* 5659 render-state indices (D3DRENDERSTATETYPE) */
enum {
    RS_ZFUNC = 57, RS_ALPHAFUNC = 58, RS_ALPHABLENDENABLE = 59, RS_ALPHATESTENABLE = 60,
    RS_ALPHAREF = 61, RS_SRCBLEND = 62, RS_DESTBLEND = 63, RS_ZWRITEENABLE = 64,
    RS_SHADEMODE = 66, RS_COLORWRITEENABLE = 67, RS_STENCILZFAIL = 68,
    RS_STENCILPASS = 69, RS_STENCILFUNC = 70, RS_STENCILREF = 71, RS_STENCILMASK = 72,
    RS_STENCILWRITEMASK = 73, RS_BLENDOP = 74, RS_BLENDCOLOR = 75,
    RS_FOGENABLE = 92, RS_FOGTABLEMODE = 93, RS_FOGSTART = 94, RS_FOGEND = 95,
    RS_FOGDENSITY = 96, RS_RANGEFOGENABLE = 97, RS_LIGHTING = 102, RS_SPECULARENABLE = 103,
    RS_LOCALVIEWER = 104, RS_COLORVERTEX = 105, RS_SPECULARMATERIALSOURCE = 110,
    RS_DIFFUSEMATERIALSOURCE = 111, RS_AMBIENTMATERIALSOURCE = 112,
    RS_EMISSIVEMATERIALSOURCE = 113, RS_POINTSPRITEENABLE = 118, RS_POINTSCALEENABLE = 119,
    RS_VERTEXBLEND = 137,
    RS_NORMALIZENORMALS = 142, RS_FOGCOLOR = 138, RS_ZENABLE = 143, RS_STENCILENABLE = 144,
    RS_STENCILFAIL = 145, RS_FRONTFACE = 146, RS_CULLMODE = 147, RS_TEXTUREFACTOR = 148,
    RS_SHADOWFUNC = 156,
    RS_ZSLOPESCALE = 77, RS_ZOFFSET = 78, RS_SOLIDOFFSETENABLE = 81,
};
/* texture-stage state indices */
enum {
    TSS_ADDRESSU = 0, TSS_ADDRESSV, TSS_ADDRESSW, TSS_MAGFILTER, TSS_MINFILTER,
    TSS_MIPFILTER, TSS_MIPMAPLODBIAS, TSS_MAXMIPLEVEL, TSS_MAXANISOTROPY,
    TSS_COLORKEYOP, TSS_COLORSIGN, TSS_ALPHAKILL, TSS_COLOROP = 12, TSS_COLORARG0, TSS_COLORARG1,
    TSS_COLORARG2, TSS_ALPHAOP, TSS_ALPHAARG0, TSS_ALPHAARG1, TSS_ALPHAARG2, TSS_RESULTARG,
    TSS_TEXTURETRANSFORMFLAGS, TSS_BUMPENVMAT00 = 22, TSS_BUMPENVLSCALE = 26,
    TSS_BUMPENVLOFFSET, TSS_TEXCOORDINDEX = 28, TSS_BORDERCOLOR = 29,
};

typedef struct MtlTex {
    uint32_t id;                /* front-end object id; 0 = free */
    uint32_t xfmt, w, h, d, levels, faces;
    bool vol, linear;
    id<MTLTexture> tex;
    uint64_t k0, k1;            /* tex's descriptor (pool_key) */
} MtlTex;

/* The vertex layout, part of the pipeline (Metal has no dynamic vertex input) */
typedef struct MtlVi {
    uint8_t nattr, nbind;
    uint8_t loc[HLE_DRAW_ATTRS], bind[HLE_DRAW_ATTRS];
    uint16_t off[HLE_DRAW_ATTRS];
    uint16_t fmt[HLE_DRAW_ATTRS];               /* MTLVertexFormat */
    uint32_t stride[HLE_DRAW_MAX_BIND + 1];     /* 0: one value for every vertex */
} MtlVi;

typedef struct PipeKey {
    HleFfVsKey vs;
    HleFfPsKey ps;
    uint32_t blend_en, src, dst, op, wmask;
    uint32_t cfmt, dfmt, stencil, topo_class;
    uint64_t vsh;
    HleVshKey vk;
    uint32_t psh;
    HlePshKey pk;
    MtlVi vi;
} PipeKey;

static struct {
    bool ready, st_valid;
    HleCmdState st;
    MtlTex tex[HLE_MAX_TEX];
    struct { uint64_t hash; uint32_t nslots; uint32_t *tok; } prog[HLE_MAX_PROGS];
    uint32_t nprog;
    NSMutableDictionary<NSNumber *, id> *pipes;     /* key hash -> pipeline, NSNull failed */
    NSMutableDictionary<NSNumber *, id<MTLFunction>> *fns;  /* source hash -> function */
    NSMutableDictionary<NSNumber *, id<MTLDepthStencilState>> *dss;
    NSMutableDictionary<NSNumber *, id<MTLSamplerState>> *smp;
    id<MTLTexture> white2d, whitecube, white3d;
    MTLCompileOptions *copts, *copts_pts;   /* the latter defines HLE_PTS */
    /* the encoder's state (hle_mtl_draw_pass clears it) */
    struct {
        bool valid;
        __unsafe_unretained id pipe, dss;
        HleFfPush pc;
    } rec;
    uint64_t draws, pipes_made, pipe_fail, drops[8];
    /* asynchronous builds (pipeline): building is pipes' entry for one a
     * worker makes, built the finished ones (under its lock) */
    id building;
    NSMutableDictionary<NSNumber *, id> *built;
    dispatch_queue_t workers[3];
    unsigned next_worker, inflight;
    uint64_t async_queued, async_skips;
} g_dr;

enum { DROP_STATE, DROP_DECL, DROP_PIPE, DROP_PRIM, DROP_ALIGN, DROP_N };
static const char *const k_drop[DROP_N] = { "no state", "layout", "pipeline", "primitive",
                                            "alignment" };

static void drop(int why)
{
    if (g_dr.drops[why]++ == 0) {
        hle_log("hakuX-hle-pipe", "mtl: a draw dropped (%s)", k_drop[why]);
    }
}

static uint64_t hash_bytes(const void *p, size_t n)
{
    const uint8_t *b = p;
    uint64_t h = 0xCBF29CE484222325ull;
    for (size_t i = 0; i < n; i++) {
        h = (h ^ b[i]) * 0x100000001B3ull;
    }
    return h;
}

static id<MTLTexture> white_texture(MTLTextureType type)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = type;
    td.pixelFormat = MTLPixelFormatRGBA8Unorm;
    td.width = td.height = 1;
    td.depth = 1;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_mtl.dev newTextureWithDescriptor:td];
    const uint32_t w = 0xFFFFFFFFu;
    for (NSUInteger s = 0; s < (type == MTLTextureTypeCube ? 6u : 1u); s++) {
        [t replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:s withBytes:&w
             bytesPerRow:4 bytesPerImage:4];
    }
    return t;
}

int hle_mtl_draw_init(void)
{
    g_hle_msl = true;
    g_dr.pipes = [NSMutableDictionary new];
    g_dr.fns = [NSMutableDictionary new];
    g_dr.dss = [NSMutableDictionary new];
    g_dr.smp = [NSMutableDictionary new];
    g_dr.building = [NSObject new];
    g_dr.built = [NSMutableDictionary new];
    dispatch_queue_attr_t qa =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    for (unsigned i = 0; i < sizeof(g_dr.workers) / sizeof(g_dr.workers[0]); i++) {
        g_dr.workers[i] = dispatch_queue_create("hakuX.mtl.pipe", qa);
    }
    hle_log("hakuX-hle-pipe", "mtl: pipelines: asynchronous %s", g_mtl_pipe_async ? "on" : "off");
    g_dr.white2d = white_texture(MTLTextureType2D);
    g_dr.whitecube = white_texture(MTLTextureTypeCube);
    g_dr.white3d = white_texture(MTLTextureType3D);
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.preserveInvariance = YES;
    /* NV2A semantics need inf and NaN (RCP(0), mulz, the fog's isnan) */
    if (@available(macOS 15.0, *)) {
        o.mathMode = MTLMathModeSafe;
    } else {
        o.fastMathEnabled = NO;
    }
    g_dr.copts = o;
    g_dr.copts_pts = [o copy];
    g_dr.copts_pts.preprocessorMacros = @{ @"HLE_PTS" : @1 };
    g_hle_glsl_revz = true;             /* before any shader is made */
    g_dr.ready = g_dr.white2d && g_dr.whitecube && g_dr.white3d;
    return g_dr.ready ? 0 : -1;
}

void hle_mtl_draw_pass(void)
{
    g_dr.rec.valid = false;
}

/* ---- state and programs ------------------------------------------------------- */

void hle_mtl_draw_state(const HleCmdState *s)
{
    g_dr.st = *s;
    g_dr.st_valid = true;
}

void hle_mtl_draw_state_part(const HleCmdStatePart *p)
{
    if (g_dr.st_valid && p->off < sizeof(g_dr.st) && p->len <= sizeof(g_dr.st) - p->off) {
        memcpy((uint8_t *)&g_dr.st + p->off, p + 1, p->len);
    }
}

void hle_mtl_draw_vsh(const HleCmdVsh *c)
{
    for (uint32_t i = 0; i < g_dr.nprog; i++) {
        if (g_dr.prog[i].hash == c->hash) {
            return;
        }
    }
    if (g_dr.nprog >= HLE_MAX_PROGS || c->nslots > HLE_VSH_MAX_SLOTS) {
        hle_log("hakuX-hle-pipe", "vertex program %016llx dropped (%u programs, %u slots)",
                (unsigned long long)c->hash, g_dr.nprog, c->nslots);
        return;
    }
    uint32_t *tok = malloc(16 * c->nslots);
    memcpy(tok, c + 1, 16 * c->nslots);
    g_dr.prog[g_dr.nprog].hash = c->hash;
    g_dr.prog[g_dr.nprog].nslots = c->nslots;
    g_dr.prog[g_dr.nprog++].tok = tok;
}

static const uint32_t *prog_find(uint64_t hash, uint32_t *nslots)
{
    for (uint32_t i = 0; i < g_dr.nprog; i++) {
        if (g_dr.prog[i].hash == hash) {
            *nslots = g_dr.prog[i].nslots;
            return g_dr.prog[i].tok;
        }
    }
    return NULL;
}

/* ---- textures --------------------------------------------------------------------- */

typedef struct TexFmt {
    MTLPixelFormat fmt;
    MTLTextureSwizzleChannels sw;
} TexFmt;

#define SW(r, g, b, a) MTLTextureSwizzleChannelsMake(MTLTextureSwizzle##r, MTLTextureSwizzle##g, \
                                                     MTLTextureSwizzle##b, MTLTextureSwizzle##a)

/* vk/draw.c tex_format */
static bool tex_format(uint32_t x, TexFmt *o)
{
    o->sw = MTLTextureSwizzleChannelsDefault;
    switch (x) {
    case HLE_XFMT_A8R8G8B8: case HLE_XFMT_LIN_A8R8G8B8:
        o->fmt = MTLPixelFormatBGRA8Unorm; return true;
    case HLE_XFMT_X8R8G8B8: case HLE_XFMT_LIN_X8R8G8B8:
        o->fmt = MTLPixelFormatBGRA8Unorm; o->sw = SW(Red, Green, Blue, One); return true;
    case HLE_XFMT_A8B8G8R8: case HLE_XFMT_LIN_A8B8G8R8:
        o->fmt = MTLPixelFormatRGBA8Unorm; return true;
    case HLE_XFMT_B8G8R8A8: case HLE_XFMT_LIN_B8G8R8A8:
        o->fmt = MTLPixelFormatRGBA8Unorm; o->sw = SW(Green, Blue, Alpha, Red); return true;
    case HLE_XFMT_R8G8B8A8: case HLE_XFMT_LIN_R8G8B8A8:
        o->fmt = MTLPixelFormatRGBA8Unorm; o->sw = SW(Alpha, Blue, Green, Red); return true;
    case HLE_XFMT_R5G6B5: case HLE_XFMT_LIN_R5G6B5:
        o->fmt = MTLPixelFormatB5G6R5Unorm; return true;
    case HLE_XFMT_A1R5G5B5: case HLE_XFMT_LIN_A1R5G5B5:
        o->fmt = MTLPixelFormatA1BGR5Unorm; return true;
    case HLE_XFMT_X1R5G5B5: case HLE_XFMT_LIN_X1R5G5B5:
        o->fmt = MTLPixelFormatA1BGR5Unorm; o->sw = SW(Red, Green, Blue, One); return true;
    case HLE_XFMT_L8: case HLE_XFMT_LIN_L8:
        o->fmt = MTLPixelFormatR8Unorm; o->sw = SW(Red, Red, Red, One); return true;
    case HLE_XFMT_AL8: case HLE_XFMT_LIN_AL8:
        o->fmt = MTLPixelFormatR8Unorm; o->sw = SW(Red, Red, Red, Red); return true;
    case HLE_XFMT_A8: case HLE_XFMT_LIN_A8:
        o->fmt = MTLPixelFormatR8Unorm; o->sw = SW(One, One, One, Red); return true;
    case HLE_XFMT_A8L8: case HLE_XFMT_LIN_A8L8:
        o->fmt = MTLPixelFormatRG8Unorm; o->sw = SW(Red, Red, Red, Green); return true;
    case HLE_XFMT_G8B8: case HLE_XFMT_LIN_G8B8:
        o->fmt = MTLPixelFormatRG8Unorm; o->sw = SW(Red, Green, Red, Green); return true;
    case HLE_XFMT_R8B8: case HLE_XFMT_LIN_R8B8:
        o->fmt = MTLPixelFormatRG8Unorm; o->sw = SW(Green, Red, Red, Green); return true;
    case HLE_XFMT_DXT1: o->fmt = MTLPixelFormatBC1_RGBA; return g_mtl.bc;
    case HLE_XFMT_DXT3: o->fmt = MTLPixelFormatBC2_RGBA; return g_mtl.bc;
    case HLE_XFMT_DXT5: o->fmt = MTLPixelFormatBC3_RGBA; return g_mtl.bc;
    default:
        return false;
    }
}

#define TEX_IDS 8193
static uint16_t g_tex_hint[TEX_IDS];

static MtlTex *tex_find(uint32_t id)
{
    if (!id) {
        return NULL;
    }
    if (id < TEX_IDS) {
        unsigned h = g_tex_hint[id];
        if (h && g_dr.tex[h - 1].id == id) {
            return &g_dr.tex[h - 1];
        }
    }
    for (unsigned i = 0; i < HLE_MAX_TEX; i++) {
        if (g_dr.tex[i].id == id) {
            if (id < TEX_IDS) {
                g_tex_hint[id] = i + 1;
            }
            return &g_dr.tex[i];
        }
    }
    return NULL;
}

static uint32_t level_bytes(uint32_t xfmt, uint32_t w, uint32_t h, uint32_t *row)
{
    const HleFmtInfo *fi = hle_fmt_info(xfmt);
    if (fi->flags & HLE_FI_DXT) {
        *row = (w + 3) / 4 * fi->bpp * 2;
        return *row * ((h + 3) / 4);
    }
    *row = w * fi->bpp / 8;
    return *row * h;
}

/* Textures given back, made again for the next upload of their kind: a
 * title that writes hundreds of small textures a frame (Madden's) made as
 * many, a kernel call each, most of the render thread's time. One is taken
 * again once the submission after it was given back completes (the draws
 * sampling it done). A ring: its oldest entry, the head of its bucket's
 * list, goes when the ring comes round to it. */
#define POOL_N 4096u
#define POOL_B 1024u
typedef struct PoolEnt {
    id<MTLTexture> tex;
    uint64_t k0, k1, stamp;     /* stamp 0: not submitted past yet */
    int32_t next;
    uint32_t b;
} PoolEnt;
static struct {
    PoolEnt e[POOL_N];
    int32_t head[POOL_B], tail[POOL_B];
    uint64_t wr, unstamped;
    bool init;
} g_pool;

static void pool_key(const MTLTextureDescriptor *td, uint64_t *k0, uint64_t *k1)
{
    const MTLTextureSwizzleChannels sw = td.swizzle;
    *k0 = (uint64_t)td.textureType | (uint64_t)td.pixelFormat << 8 | (uint64_t)td.width << 24 |
          (uint64_t)td.height << 40;
    *k1 = (uint64_t)td.depth | (uint64_t)td.mipmapLevelCount << 16 | (uint64_t)sw.red << 24 |
          (uint64_t)sw.green << 32 | (uint64_t)sw.blue << 40 | (uint64_t)sw.alpha << 48;
}

static uint32_t pool_bucket(uint64_t k0, uint64_t k1)
{
    return (uint32_t)(((k0 * 0x9e3779b97f4a7c15ull) ^ (k1 * 0xc2b2ae3d27d4eb4full)) >> 54) % POOL_B;
}

static void pool_init(void)
{
    if (!g_pool.init) {
        memset(g_pool.head, 0xff, sizeof(g_pool.head));
        memset(g_pool.tail, 0xff, sizeof(g_pool.tail));
        g_pool.init = true;
    }
}

static void pool_put(id<MTLTexture> tex, uint64_t k0, uint64_t k1)
{
    if (!tex) {
        return;
    }
    pool_init();
    const int32_t slot = (int32_t)(g_pool.wr % POOL_N);
    PoolEnt *e = &g_pool.e[slot];
    if (e->tex) {
        g_pool.head[e->b] = e->next;
        if (e->next < 0) {
            g_pool.tail[e->b] = -1;
        }
        e->tex = nil;
    }
    const uint32_t b = pool_bucket(k0, k1);
    *e = (PoolEnt){ .tex = tex, .k0 = k0, .k1 = k1, .stamp = 0, .next = -1, .b = b };
    if (g_pool.tail[b] >= 0) {
        g_pool.e[g_pool.tail[b]].next = slot;
    } else {
        g_pool.head[b] = slot;
    }
    g_pool.tail[b] = slot;
    g_pool.wr++;
}

static id<MTLTexture> pool_get(uint64_t k0, uint64_t k1)
{
    pool_init();
    const uint32_t b = pool_bucket(k0, k1);
    const uint64_t done = hle_tl_completed();
    int32_t prev = -1;
    for (int32_t i = g_pool.head[b], n = 0; i >= 0 && n < 16; prev = i, i = g_pool.e[i].next, n++) {
        PoolEnt *e = &g_pool.e[i];
        if (e->k0 != k0 || e->k1 != k1) {
            continue;
        }
        if (!e->stamp || e->stamp > done) {
            return nil;                 /* the ones after it newer still */
        }
        if (prev >= 0) {
            g_pool.e[prev].next = e->next;
        } else {
            g_pool.head[b] = e->next;
        }
        if (g_pool.tail[b] == i) {
            g_pool.tail[b] = prev;
        }
        id<MTLTexture> t = e->tex;
        e->tex = nil;
        return t;
    }
    return nil;
}

void hle_mtl_draw_submitted(uint64_t value)
{
    uint64_t s = g_pool.unstamped;
    if (g_pool.wr - s > POOL_N) {
        s = g_pool.wr - POOL_N;
    }
    for (; s < g_pool.wr; s++) {
        PoolEnt *e = &g_pool.e[s % POOL_N];
        if (e->tex && !e->stamp) {
            e->stamp = value;
        }
    }
    g_pool.unstamped = g_pool.wr;
}

void hle_mtl_draw_forget(uint32_t id)
{
    MtlTex *t = tex_find(id);
    if (t) {
        pool_put(t->tex, t->k0, t->k1);
        t->tex = nil;
        t->id = 0;
    }
}

/* Uploads are blits from the arena in a command buffer of their own,
 * committed just before the draws' (hle_mtl_draw_upload_flush): the arena is
 * write-combined, the CPU's reads of it in replaceRegion uncached, and the
 * driver compresses on the CPU there too. The arena's space stays the
 * decoder's to reuse only after the draws' submission completes. */
static struct {
    id<MTLCommandBuffer> cb;
    id<MTLBlitCommandEncoder> enc;
} g_up;

static id<MTLBlitCommandEncoder> upload_enc(void)
{
    if (!g_up.enc) {
        g_up.cb = [g_mtl.queue commandBuffer];
        g_up.enc = [g_up.cb blitCommandEncoder];
    }
    return g_up.enc;
}

void hle_mtl_draw_upload_flush(void)
{
    if (g_up.enc) {
        [g_up.enc endEncoding];
        [g_up.cb commit];
        g_up.enc = nil;
        g_up.cb = nil;
    }
}

/* Each upload makes a new texture: the work queued before samples the old
 * one, which its command buffers hold. */
void hle_mtl_draw_tex(const HleCmdTex *c)
{
    TexFmt tf;
    if (!tex_format(c->xfmt, &tf)) {
        static uint64_t s_logged[4];
        if (c->xfmt < 256 && !(s_logged[c->xfmt >> 6] & (1ull << (c->xfmt & 63)))) {
            s_logged[c->xfmt >> 6] |= 1ull << (c->xfmt & 63);
            hle_log("hakuX-hle-back", "texture %u: format 0x%x has no Metal format: not "
                    "drawn (%ux%u)", c->id, c->xfmt, c->w, c->h);
        }
        return;
    }
    if (!g_dr.ready || (c->faces != 1 && c->faces != 6) || !c->w || !c->h) {
        return;
    }
    MtlTex *t = tex_find(c->id);
    if (!t) {
        for (unsigned i = 0; i < HLE_MAX_TEX && !t; i++) {
            if (!g_dr.tex[i].id) {
                t = &g_dr.tex[i];
            }
        }
        if (!t) {
            static unsigned s_full;
            if (s_full++ < 8) {
                hle_log("hakuX-hle-back", "texture %u: the texture table is full (sampled white)",
                        c->id);
            }
            return;
        }
    }
    uint32_t cd = c->faces == 1 && c->d > 1 ? c->d : 1;
    uint32_t maxl = 1;
    while ((MAX(MAX(c->w, c->h), cd) >> maxl) && maxl < 16) {
        maxl++;
    }
    uint32_t levels = MIN(MAX(c->levels, 1u), maxl);
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = c->faces == 6 ? MTLTextureTypeCube : cd > 1 ? MTLTextureType3D
                                                                 : MTLTextureType2D;
    td.pixelFormat = tf.fmt;
    td.width = c->w;
    td.height = c->faces == 6 ? c->w : c->h;
    td.depth = cd;
    td.mipmapLevelCount = levels;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead;
    td.swizzle = tf.sw;
    uint64_t k0, k1;
    pool_key(td, &k0, &k1);
    id<MTLTexture> tex = pool_get(k0, k1);
    if (!tex) {
        tex = [g_mtl.dev newTextureWithDescriptor:td];
    }
    if (!tex) {
        static unsigned s_fail;
        if (s_fail++ < 8) {
            hle_log("hakuX-hle-back", "texture %u (%ux%u fmt 0x%x): not created (sampled white)",
                    c->id, c->w, c->h, c->xfmt);
        }
        t->id = 0;
        t->tex = nil;
        return;
    }
    /* arena: face-major, then levels (front end, HleCmdTex) */
    id<MTLBlitCommandEncoder> up = upload_enc();
    uint32_t pos = c->arena_off, end = c->arena_off + c->arena_len;
    for (uint32_t f = 0; f < c->faces; f++) {
        for (uint32_t l = 0; l < c->levels; l++) {
            uint32_t w = MAX(c->w >> l, 1u), h = MAX(c->h >> l, 1u), row;
            uint32_t dd = MAX(cd >> l, 1u), img = level_bytes(c->xfmt, w, h, &row);
            if (l < levels && pos + img * dd <= end) {
                [up copyFromBuffer:g_mtl.arena sourceOffset:pos sourceBytesPerRow:row
                    sourceBytesPerImage:cd > 1 ? img : 0 sourceSize:MTLSizeMake(w, h, dd)
                             toTexture:tex destinationSlice:f destinationLevel:l
                     destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
            pos += img * dd;
        }
    }
    t->id = c->id;
    t->xfmt = c->xfmt;
    t->w = c->w;
    t->h = c->h;
    t->d = cd;
    t->levels = levels;
    t->faces = c->faces;
    t->vol = cd > 1;
    t->linear = (hle_fmt_info(c->xfmt)->flags & HLE_FI_LIN) != 0;
    if (t->tex) {
        pool_put(t->tex, t->k0, t->k1);
    }
    t->tex = tex;
    t->k0 = k0;
    t->k1 = k1;
    if (c->id < TEX_IDS) {
        g_tex_hint[c->id] = (uint16_t)(t - g_dr.tex + 1);
    }
}

static bool x_alpha(const HleMtlSurf *s)
{
    switch (s->d.xfmt) {
    case HLE_XFMT_X8R8G8B8: case HLE_XFMT_LIN_X8R8G8B8:
    case HLE_XFMT_X1R5G5B5: case HLE_XFMT_LIN_X1R5G5B5:
        return !s->depth;
    default:
        return false;
    }
}

/* A colour target sampled as a texture: its swizzle (vk/surf.c
 * hle_surf_sample_views: L8 / L16 (l, l, l, 1), G8B8 (b, g, b, g), X8R8G8B8
 * and X1R5G5B5 alpha 1); nil when the surface can't be sampled. */
static id<MTLTexture> surf_texture(HleMtlSurf *s)
{
    if (!s->tex || s->depth || s->d.parent || !s->written) {
        return nil;
    }
    if (s->sview) {
        return s->sview;
    }
    MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsDefault;
    bool view = true;
    if (s->fmt == MTLPixelFormatR8Unorm || s->fmt == MTLPixelFormatR16Unorm) {
        sw = SW(Red, Red, Red, One);
    } else if (s->fmt == MTLPixelFormatRG8Unorm) {
        sw = SW(Red, Green, Red, Green);
    } else if (x_alpha(s)) {
        sw = SW(Red, Green, Blue, One);
    } else {
        view = false;
    }
    s->sview = view ? [s->tex newTextureViewWithPixelFormat:s->fmt textureType:s->tex.textureType
                                                     levels:NSMakeRange(0, s->tex.mipmapLevelCount)
                                                     slices:NSMakeRange(0, s->tex.arrayLength *
                                                                        (s->tex.textureType ==
                                                                         MTLTextureTypeCube ? 6 : 1))
                                                    swizzle:sw]
                    : s->tex;
    return s->sview;
}

static HleMtlSurf *tex_surface(uint32_t id, uint32_t rt_id)
{
    if (!id || id == rt_id || tex_find(id)) {
        return NULL;
    }
    return hle_mtl_surf_get(id);
}

/* ---- samplers ------------------------------------------------------------------ */

static MTLSamplerAddressMode addr_mode(uint32_t a)
{
    switch (a) {
    case 2:  return MTLSamplerAddressModeMirrorRepeat;
    case 3:  return MTLSamplerAddressModeClampToEdge;
    case 4:  return MTLSamplerAddressModeClampToBorderColor;
    case 5:  return MTLSamplerAddressModeClampToEdge;
    default: return MTLSamplerAddressModeRepeat;
    }
}

/* vk/draw.c sampler_index; Metal's border colours are three (the nearest is
 * taken, as Vulkan without custom border colours) and its samplers have no
 * LOD bias */
static id<MTLSamplerState> sampler(const uint32_t *tss)
{
    uint32_t base = MIN(tss[TSS_MAXMIPLEVEL], 15u);
    uint32_t bc = tss[TSS_BORDERCOLOR];
    float r = ((bc >> 16) & 0xFF) / 255.0f, g = ((bc >> 8) & 0xFF) / 255.0f,
          b = (bc & 0xFF) / 255.0f, a = (bc >> 24) / 255.0f;
    unsigned border = a < 0.5f ? 0 : r + g + b < 1.5f ? 1 : 2;
    uint64_t key = (uint64_t)(tss[TSS_ADDRESSU] & 7) | (uint64_t)(tss[TSS_ADDRESSV] & 7) << 3 |
                   (uint64_t)(tss[TSS_MAGFILTER] & 7) << 6 |
                   (uint64_t)(tss[TSS_MINFILTER] & 7) << 9 |
                   (uint64_t)(tss[TSS_MIPFILTER] & 7) << 12 |
                   (uint64_t)(tss[TSS_ADDRESSW] & 7) << 15 | (uint64_t)base << 18 |
                   (uint64_t)border << 24;
    NSNumber *k = @(key);
    id<MTLSamplerState> s = g_dr.smp[k];
    if (s) {
        return s;
    }
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    uint32_t mip = tss[TSS_MIPFILTER] & 7;
    d.magFilter = (tss[TSS_MAGFILTER] & 7) >= 2 ? MTLSamplerMinMagFilterLinear
                                                 : MTLSamplerMinMagFilterNearest;
    d.minFilter = (tss[TSS_MINFILTER] & 7) >= 2 ? MTLSamplerMinMagFilterLinear
                                                 : MTLSamplerMinMagFilterNearest;
    d.mipFilter = mip >= 2 ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
    d.sAddressMode = addr_mode(tss[TSS_ADDRESSU]);
    d.tAddressMode = addr_mode(tss[TSS_ADDRESSV]);
    d.rAddressMode = addr_mode(tss[TSS_ADDRESSW]);
    d.borderColor = border == 0 ? MTLSamplerBorderColorTransparentBlack :
                    border == 1 ? MTLSamplerBorderColorOpaqueBlack : MTLSamplerBorderColorOpaqueWhite;
    d.lodMinClamp = (float)base;
    d.lodMaxClamp = mip ? FLT_MAX : base + 0.25f;
    s = [g_mtl.dev newSamplerStateWithDescriptor:d];
    if (s) {
        g_dr.smp[k] = s;
    }
    return s;
}

/* ---- pipelines ------------------------------------------------------------------ */

static MTLBlendFactor blend_factor(uint32_t f)
{
    switch (f) {
    case 0:      return MTLBlendFactorZero;
    case 1:      return MTLBlendFactorOne;
    case 0x300:  return MTLBlendFactorSourceColor;
    case 0x301:  return MTLBlendFactorOneMinusSourceColor;
    case 0x302:  return MTLBlendFactorSourceAlpha;
    case 0x303:  return MTLBlendFactorOneMinusSourceAlpha;
    case 0x304:  return MTLBlendFactorDestinationAlpha;
    case 0x305:  return MTLBlendFactorOneMinusDestinationAlpha;
    case 0x306:  return MTLBlendFactorDestinationColor;
    case 0x307:  return MTLBlendFactorOneMinusDestinationColor;
    case 0x308:  return MTLBlendFactorSourceAlphaSaturated;
    case 0x8001: return MTLBlendFactorBlendColor;
    case 0x8002: return MTLBlendFactorOneMinusBlendColor;
    case 0x8003: return MTLBlendFactorBlendAlpha;
    case 0x8004: return MTLBlendFactorOneMinusBlendAlpha;
    default:     return MTLBlendFactorOne;
    }
}

static MTLBlendOperation blend_op(uint32_t o)
{
    switch (o) {
    case 0x800A: return MTLBlendOperationSubtract;
    case 0x800B: return MTLBlendOperationReverseSubtract;
    case 0x8007: return MTLBlendOperationMin;
    case 0x8008: return MTLBlendOperationMax;
    default:     return MTLBlendOperationAdd;
    }
}

static MTLStencilOperation stencil_op(uint32_t o)
{
    switch (o) {
    case 0:      return MTLStencilOperationZero;
    case 0x1E01: return MTLStencilOperationReplace;
    case 0x1E02: return MTLStencilOperationIncrementClamp;
    case 0x1E03: return MTLStencilOperationDecrementClamp;
    case 0x150A: return MTLStencilOperationInvert;
    case 0x8507: return MTLStencilOperationIncrementWrap;
    case 0x8508: return MTLStencilOperationDecrementWrap;
    default:     return MTLStencilOperationKeep;
    }
}

/* D3DCMP_* - 0x200 is MTLCompareFunction's order */
static MTLCompareFunction cmp_op(uint32_t f)
{
    return (f >= 0x200 && f <= 0x207) ? (MTLCompareFunction)(f - 0x200) : MTLCompareFunctionAlways;
}

/* a depth test on reversed depth (ff.h HLE_ZNORM_REV_GLSL): the order turned */
static MTLCompareFunction zcmp_op(uint32_t f)
{
    switch (cmp_op(f)) {
    case MTLCompareFunctionLess:         return MTLCompareFunctionGreater;
    case MTLCompareFunctionLessEqual:    return MTLCompareFunctionGreaterEqual;
    case MTLCompareFunctionGreater:      return MTLCompareFunctionLess;
    case MTLCompareFunctionGreaterEqual: return MTLCompareFunctionLessEqual;
    default:                             return cmp_op(f);
    }
}

/* pts: a point pipeline; Metal rejects a [[point_size]] output elsewhere */
static id<MTLFunction> shader_fn(const char *src, size_t len, NSString *name, bool pts)
{
    NSNumber *k = @(hash_bytes(src, len) ^ (uint64_t)pts);
    id<MTLFunction> f;
    @synchronized(g_dr.fns) {
        f = g_dr.fns[k];
    }
    if (f) {
        return f;
    }
    NSError *err = nil;
    NSString *s = [[NSString alloc] initWithBytes:src length:len encoding:NSUTF8StringEncoding];
    id<MTLLibrary> lib = [g_mtl.dev newLibraryWithSource:s options:pts ? g_dr.copts_pts : g_dr.copts
                                                    error:&err];
    f = lib ? [lib newFunctionWithName:name] : nil;
    if (!f) {
        static unsigned s_logged;
        if (s_logged++ < 6) {
            hle_log("hakuX-hle-pipe", "mtl: %s did not compile: %s\n%s", name.UTF8String,
                    err.localizedDescription.UTF8String, src);
        }
        return nil;
    }
    @synchronized(g_dr.fns) {
        g_dr.fns[k] = f;
    }
    return f;
}

/* The key's shaders' MSL (render thread: the generators' state is its);
 * false when either translation failed. */
static bool pipeline_src(const PipeKey *k, const uint32_t *tok, uint32_t nslots, char **vs,
                         size_t *vlen, char **fs, size_t *flen)
{
    enum { SRC_MAX = 131072 };
    char *vsrc = malloc(SRC_MAX), *fsrc = malloc(SRC_MAX);
    size_t vn = k->vsh ? (tok ? (hle_ffhw_is(tok, nslots) ? hle_ffhw_glsl(tok, nslots, &k->vk, vsrc,
                                                                          SRC_MAX)
                                                          : hle_vsh_glsl(tok, nslots, &k->vk, vsrc,
                                                                         SRC_MAX))
                              : 0)
                       : hle_ff_vs_glsl(&k->vs, vsrc, SRC_MAX);
    unsigned unsup = 0;
    size_t fn = k->psh ? hle_psh_glsl(&k->pk, fsrc, SRC_MAX, &unsup)
                       : hle_ff_ps_glsl(&k->ps, fsrc, SRC_MAX);
    if (!vn || !fn) {
        hle_log("hakuX-hle-pipe", "mtl: %s shader %016llx: translation failed",
                vn ? "pixel" : "vertex", (unsigned long long)k->vsh);
        free(vsrc);
        free(fsrc);
        return false;
    }
    *vs = vsrc;
    *vlen = vn;
    *fs = fsrc;
    *flen = fn;
    return true;
}

/* The pipeline from its MSL (freed here). Any thread. */
static id<MTLRenderPipelineState> pipeline_compile(const PipeKey *k, char *vsrc, size_t vn,
                                                   char *fsrc, size_t fn, bool async)
{
    id<MTLRenderPipelineState> p = nil;
    int64_t t0 = hle_now_ns();
    id<MTLFunction> vf = shader_fn(vsrc, vn, @"hle_vs", k->topo_class == 0);
    id<MTLFunction> ff = vf ? shader_fn(fsrc, fn, @"hle_fs", false) : nil;
    if (vf && ff) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = vf;
        d.fragmentFunction = ff;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        for (uint32_t i = 0; i < k->vi.nattr; i++) {
            MTLVertexAttributeDescriptor *a = vd.attributes[k->vi.loc[i]];
            a.format = (MTLVertexFormat)k->vi.fmt[i];
            a.offset = k->vi.off[i];
            a.bufferIndex = HLE_MSL_VB_BASE + k->vi.bind[i];
        }
        for (uint32_t b = 0; b < k->vi.nbind; b++) {
            MTLVertexBufferLayoutDescriptor *l = vd.layouts[HLE_MSL_VB_BASE + b];
            if (k->vi.stride[b]) {
                l.stride = k->vi.stride[b];
                l.stepFunction = MTLVertexStepFunctionPerVertex;
                l.stepRate = 1;
            } else {
                l.stride = 16;
                l.stepFunction = MTLVertexStepFunctionConstant;
                l.stepRate = 0;
            }
        }
        d.vertexDescriptor = vd;
        if (k->cfmt) {
            MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0];
            a.pixelFormat = (MTLPixelFormat)k->cfmt;
            a.blendingEnabled = k->blend_en != 0;
            a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor = blend_factor(k->src);
            a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor = blend_factor(k->dst);
            a.rgbBlendOperation = a.alphaBlendOperation = blend_op(k->op);
            a.writeMask = k->wmask;
        }
        if (k->dfmt) {
            d.depthAttachmentPixelFormat = (MTLPixelFormat)k->dfmt;
            if (k->stencil) {
                d.stencilAttachmentPixelFormat = (MTLPixelFormat)k->dfmt;
            }
        }
        static const MTLPrimitiveTopologyClass k_class[3] = {
            MTLPrimitiveTopologyClassPoint, MTLPrimitiveTopologyClassLine,
            MTLPrimitiveTopologyClassTriangle };
        d.inputPrimitiveTopology = k_class[k->topo_class];
        NSError *err = nil;
        p = [g_mtl.dev newRenderPipelineStateWithDescriptor:d error:&err];
        if (!p) {
            static unsigned s_logged;
            if (s_logged++ < 6) {
                hle_log("hakuX-hle-pipe", "mtl: pipeline failed: %s\n--- vertex:\n%s\n--- pixel:\n%s",
                        err.localizedDescription.UTF8String, vsrc, fsrc);
            }
        }
    }
    hle_log("hakuX-hle-pipe", "mtl: pipeline vsh=%016llx fvf=0x%x %s=%u %s in %.1f ms%s",
            (unsigned long long)k->vsh, k->vs.fvf, k->psh ? "combiners" : "stages",
            k->psh ? k->pk.count & 0xFF : k->ps.nstages, p ? "ok" : "FAILED",
            (hle_now_ns() - t0) / 1e6, async ? " (asynchronous)" : "");
    free(vsrc);
    free(fsrc);
    return p;
}

/* Asynchronous builds: WORKERS serial queues below the render thread's
 * priority; a finished build waits in g_dr.built for the render thread. */
#define WORKERS (sizeof(g_dr.workers) / sizeof(g_dr.workers[0]))
#define INFLIGHT_MAX 256

/* Asynchronous builds skip a draw only on a target drawn in the last
 * SKIP_FRAMES frames: a per-frame pass draws it again soon. On one drawn
 * first, or once (a texture baked at a level's load), a skip would stay:
 * its pipeline is built in place (vk/draw.c's rule). */
#define SKIP_FRAMES 3

static void target_note(HleMtlSurf *s)
{
    uint64_t f = hle_back_swap_count() + 1;
    if (s && s->drawn_cur != f) {
        s->drawn_prev = s->drawn_cur;
        s->drawn_cur = f;
    }
}

static bool target_redrawn(const HleMtlSurf *s)
{
    uint64_t f = hle_back_swap_count() + 1;
    return s && s->drawn_prev && f - s->drawn_prev <= SKIP_FRAMES;
}

static void pipes_collect(void)
{
    if (!g_dr.inflight) {
        return;
    }
    NSDictionary *done;
    @synchronized(g_dr.built) {
        if (!g_dr.built.count) {
            return;
        }
        done = [g_dr.built copy];
        [g_dr.built removeAllObjects];
    }
    [done enumerateKeysAndObjectsUsingBlock:^(NSNumber *h, id p, BOOL *stop) {
        g_dr.pipes[h] = p;
        g_dr.pipes_made += p != [NSNull null];
        g_dr.pipe_fail += p == [NSNull null];
        g_dr.inflight--;
    }];
}

/* The draw's pipeline: made (and remembered, failures included), or nil
 * with *pending while a worker builds it. */
static id<MTLRenderPipelineState> pipeline(const PipeKey *k, HleMtlSurf *target, bool *pending)
{
    *pending = false;
    if (g_mtl_pipe_async) {
        pipes_collect();
        target_note(target);
    }
    NSNumber *h = @(hash_bytes(k, sizeof(*k)));
    id p = g_dr.pipes[h];
    if (p) {
        if (p == g_dr.building) {
            *pending = true;
            return nil;
        }
        return p == [NSNull null] ? nil : p;
    }
    uint32_t nslots = 0;
    const uint32_t *tok = k->vsh ? prog_find(k->vsh, &nslots) : NULL;
    if (k->vsh && !tok) {
        return nil;                     /* the program comes later (HLE_OP_VSH) */
    }
    char *vs, *fs;
    size_t vn, fn;
    if (!pipeline_src(k, tok, nslots, &vs, &vn, &fs, &fn)) {
        g_dr.pipes[h] = [NSNull null];
        g_dr.pipe_fail++;
        return nil;
    }
    if (g_mtl_pipe_async && g_dr.inflight < INFLIGHT_MAX && target_redrawn(target)) {
        const PipeKey key = *k;
        g_dr.pipes[h] = g_dr.building;
        g_dr.inflight++;
        g_dr.async_queued++;
        dispatch_async(g_dr.workers[g_dr.next_worker++ % WORKERS], ^{
            id<MTLRenderPipelineState> q = pipeline_compile(&key, vs, vn, fs, fn, true);
            @synchronized(g_dr.built) {
                g_dr.built[h] = q ? q : [NSNull null];
            }
        });
        *pending = true;
        return nil;
    }
    uint32_t pa = hle_hitch_enter(HLE_ACT_COMPILE);
    p = pipeline_compile(k, vs, vn, fs, fn, false);
    hle_hitch_leave(pa);
    g_dr.pipes[h] = p ? p : [NSNull null];
    g_dr.pipes_made += p != nil;
    g_dr.pipe_fail += p == nil;
    return p;
}

static id<MTLDepthStencilState> depth_stencil(bool zt, bool zw, MTLCompareFunction zop, bool stn,
                                              const uint32_t sraw[4], uint32_t rmask,
                                              uint32_t wmask)
{
    uint64_t key = (uint64_t)zt | (uint64_t)zw << 1 | (uint64_t)zop << 2 | (uint64_t)stn << 5;
    if (stn) {
        key |= (uint64_t)stencil_op(sraw[0]) << 6 | (uint64_t)stencil_op(sraw[1]) << 9 |
               (uint64_t)stencil_op(sraw[2]) << 12 | (uint64_t)cmp_op(sraw[3]) << 15 |
               (uint64_t)(rmask & 0xFF) << 18 | (uint64_t)(wmask & 0xFF) << 26;
    }
    NSNumber *k = @(key);
    id<MTLDepthStencilState> s = g_dr.dss[k];
    if (s) {
        return s;
    }
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = zt ? zop : MTLCompareFunctionAlways;
    d.depthWriteEnabled = zt && zw;
    if (stn) {
        MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
        sd.stencilFailureOperation = stencil_op(sraw[0]);
        sd.depthStencilPassOperation = stencil_op(sraw[1]);
        sd.depthFailureOperation = stencil_op(sraw[2]);
        sd.stencilCompareFunction = cmp_op(sraw[3]);
        sd.readMask = rmask & 0xFF;
        sd.writeMask = wmask & 0xFF;
        d.frontFaceStencil = d.backFaceStencil = sd;
    }
    s = [g_mtl.dev newDepthStencilStateWithDescriptor:d];
    if (s) {
        g_dr.dss[k] = s;
    }
    return s;
}

/* ---- vertex layouts ------------------------------------------------------------- */

typedef struct Attr {
    uint8_t loc, bind;
    uint16_t off;
    MTLVertexFormat fmt;
} Attr;

static uint32_t fvf_attrs(uint32_t fvf, Attr *a)
{
    uint32_t n = 0, off = 0, pos = fvf & HLE_FVF_POSITION_MASK;
#define ATTR(l, f, sz) a[n++] = (Attr){ .loc = (l), .bind = 0, .off = (uint16_t)off, .fmt = (f) }; \
        off += (sz)
    if (pos == HLE_FVF_XYZRHW) {
        ATTR(0, MTLVertexFormatFloat4, 16);
    } else if (pos) {
        ATTR(0, MTLVertexFormatFloat3, 12);
        unsigned nw = pos >= 0x006 ? (pos - 0x004) / 2 : 0;
        if (nw) {
            static const MTLVertexFormat k_wf[4] = {
                MTLVertexFormatFloat, MTLVertexFormatFloat2, MTLVertexFormatFloat3,
                MTLVertexFormatFloat4 };
            uint32_t woff = off;
            ATTR(8, k_wf[MIN(nw, 4u) - 1], 0);
            off = woff + nw * 4;
        }
    }
    if (fvf & HLE_FVF_NORMAL) {
        ATTR(1, MTLVertexFormatFloat3, 12);
    }
    if (fvf & HLE_FVF_PSIZE) {
        ATTR(9, MTLVertexFormatFloat, 4);
    }
    if (fvf & HLE_FVF_DIFFUSE) {
        ATTR(2, MTLVertexFormatUChar4Normalized_BGRA, 4);
    }
    if (fvf & HLE_FVF_SPECULAR) {
        ATTR(3, MTLVertexFormatUChar4Normalized_BGRA, 4);
    }
    unsigned ntc = (fvf & HLE_FVF_TEXCOUNT_MASK) >> HLE_FVF_TEXCOUNT_SHIFT;
    static const MTLVertexFormat k_tf[5] = { MTLVertexFormatInvalid, MTLVertexFormatFloat,
                                             MTLVertexFormatFloat2, MTLVertexFormatFloat3,
                                             MTLVertexFormatFloat4 };
    for (unsigned i = 0; i < ntc && i < 4; i++) {
        unsigned sz = hle_fvf_tex_size(fvf, i);
        ATTR(4 + i, k_tf[sz], sz * 4);
    }
#undef ATTR
    return n;
}

static uint32_t imm_attrs(uint32_t fvf, Attr *a)
{
    uint32_t n = 0;
    bool use[8] = { true, (fvf & HLE_FVF_NORMAL) != 0, (fvf & HLE_FVF_DIFFUSE) != 0,
                    (fvf & HLE_FVF_SPECULAR) != 0 };
    unsigned ntc = (fvf & HLE_FVF_TEXCOUNT_MASK) >> HLE_FVF_TEXCOUNT_SHIFT;
    for (unsigned i = 0; i < ntc && i < 4; i++) {
        use[4 + i] = true;
    }
    for (uint32_t l = 0; l < 8; l++) {
        if (use[l]) {
            a[n++] = (Attr){ .loc = (uint8_t)l, .bind = 0, .off = (uint16_t)(16 * l),
                             .fmt = MTLVertexFormatFloat4 };
        }
    }
    return n;
}

/* 16-bit components: Apple GPUs fetch these at 2-byte aligned offsets */
static bool fmt_short(MTLVertexFormat f)
{
    switch (f) {
    case MTLVertexFormatShort: case MTLVertexFormatShort2: case MTLVertexFormatShort3:
    case MTLVertexFormatShort4: case MTLVertexFormatShortNormalized:
    case MTLVertexFormatShort2Normalized: case MTLVertexFormatShort3Normalized:
    case MTLVertexFormatShort4Normalized: case MTLVertexFormatUShort: case MTLVertexFormatUShort2:
        return true;
    default:
        return false;
    }
}

/* vk/draw.c vat_format. Programs fetch S32K as integers (kind 1) and CMP as
 * two 16-bit halves (kind 2); the FF generators take floats. */
static MTLVertexFormat vat_format(uint8_t fmt, bool prog, unsigned *kind)
{
    static const MTLVertexFormat k_f[4] = { MTLVertexFormatFloat, MTLVertexFormatFloat2,
                                            MTLVertexFormatFloat3, MTLVertexFormatFloat4 };
    static const MTLVertexFormat k_ub[4] = {
        MTLVertexFormatUCharNormalized, MTLVertexFormatUChar2Normalized,
        MTLVertexFormatUChar3Normalized, MTLVertexFormatUChar4Normalized };
    static const MTLVertexFormat k_s1[4] = {
        MTLVertexFormatShortNormalized, MTLVertexFormatShort2Normalized,
        MTLVertexFormatShort3Normalized, MTLVertexFormatShort4Normalized };
    static const MTLVertexFormat k_si[4] = { MTLVertexFormatShort, MTLVertexFormatShort2,
                                             MTLVertexFormatShort3, MTLVertexFormatShort4 };
    unsigned n = hle_vat_count(fmt);
    *kind = 0;
    if (!n || n > 4) {
        return MTLVertexFormatInvalid;
    }
    switch (hle_vat_type(fmt)) {
    case HLE_VAT_F:
        return k_f[n - 1];
    case HLE_VAT_UB_D3D:
        if (n == 4) {
            return MTLVertexFormatUChar4Normalized_BGRA;
        }
        /* fallthrough */
    case HLE_VAT_UB_OGL:
        return k_ub[n - 1];
    case HLE_VAT_S1:
        return k_s1[n - 1];
    case HLE_VAT_S32K:
        *kind = prog ? 1 : 0;
        return k_si[n - 1];
    case HLE_VAT_CMP:
        *kind = 2;
        return MTLVertexFormatUShort2;
    default:
        return MTLVertexFormatInvalid;
    }
}

static bool decl_build(const HleCmdDraw *c, bool prog, Attr *a, uint32_t *na, uint32_t *in,
                       uint32_t *ints, uint32_t *cmps)
{
    *na = *in = *ints = *cmps = 0;
    for (uint32_t loc = 0; loc < HLE_DRAW_ATTRS; loc++) {
        uint32_t x = c->attr[loc];
        if (!hle_vat_count(x & 0xFF)) {
            continue;
        }
        unsigned kind;
        MTLVertexFormat f = vat_format(x & 0xFF, prog, &kind);
        if (!prog && kind == 2 && loc != 1) {
            f = MTLVertexFormatInvalid;
        }
        if (f == MTLVertexFormatInvalid || ((x >> 8) & 0xFF) >= c->nbind) {
            if (!prog) {
                return false;
            }
            continue;
        }
        a[(*na)++] = (Attr){ .loc = (uint8_t)loc, .bind = (uint8_t)((x >> 8) & 0xFF),
                             .off = (uint16_t)(x >> 16), .fmt = f };
        *in |= 1u << loc;
        *ints |= (kind == 1 ? 1u : 0) << loc;
        *cmps |= (kind == 2 ? 1u : 0) << loc;
    }
    return true;
}

/* ---- draws ------------------------------------------------------------------------ */

static uint32_t half1(uint32_t f)
{
    uint32_t s = (f >> 16) & 0x8000, e = (f >> 23) & 0xFF, m = f & 0x7FFFFF;
    int32_t he = (int32_t)e - 127 + 15;
    if (e == 0xFF) {
        return s | 0x7C00 | (m ? 0x200 : 0);
    }
    if (he >= 31) {
        return s | 0x7C00;
    }
    if (he <= 0) {
        if (he < -10) {
            return s;
        }
        uint32_t shift = 14 - he;
        m |= 0x800000;
        return s | ((m >> shift) + ((m >> (shift - 1)) & 1));
    }
    return (s | ((uint32_t)he << 10) | (m >> 13)) + ((m >> 12) & 1);
}

static uint32_t half2(uint32_t a, uint32_t b)
{
    return half1(a) | half1(b) << 16;
}

static unsigned shadow_fmt(uint32_t id)
{
    HleMtlSurf *s = id && !tex_find(id) ? hle_mtl_surf_get(id) : NULL;
    if (!s || !s->tex || !s->depth) {
        return 0;
    }
    switch (s->d.xfmt) {
    case HLE_XFMT_D16: case HLE_XFMT_LIN_D16:   return 2;
    case HLE_XFMT_F24S8: case HLE_XFMT_LIN_F24S8:
    case HLE_XFMT_F16: case HLE_XFMT_LIN_F16:   return 3;
    default:                                    return 1;
    }
}

static unsigned signed_blend(const HleCmdState *s)
{
    uint32_t op = s->rs[RS_BLENDOP];
    if (!s->rs[RS_ALPHABLENDENABLE] || (op != 0xF005 && op != 0xF006) ||
        s->rs[RS_SRCBLEND] != 1 || s->rs[RS_DESTBLEND] != 1) {
        return 0;
    }
    return op == 0xF006 ? 1 : 2;
}

static unsigned fb_stages(const HleCmdDraw *c, const HleMtlSurf *rt)
{
    const HleCmdState *s = &g_dr.st;
    if (!rt || rt->depth) {
        return 0;
    }
    if (signed_blend(s)) {
        return 0x10;
    }
    unsigned m = 0;
    if (!s->psh) {
        unsigned first = s->rs[RS_POINTSPRITEENABLE] ? HLE_FF_SPRITE_STAGE : 0;
        for (unsigned st = first; st < HLE_FF_STAGES && s->tss[st][TSS_COLOROP] > 1; st++) {
            if (c->tex[st] == rt->id) {
                m |= 1u << (st - first);
            }
        }
        return m && !tex_find(rt->id) ? m : 0;
    }
    for (unsigned st = 0; st < HLE_TSS_STAGES; st++) {
        unsigned mode = (s->rs[HLE_PS_TEXMODES] >> (5 * st)) & 0x1F;
        if (c->tex[st] == rt->id && (mode == HLE_PST_PROJECT2D || mode == HLE_PST_PROJECT3D)) {
            m |= 1u << st;
        }
    }
    return m;
}

static uint32_t lin_rect(const HleCmdDraw *c, const HleCmdState *s, unsigned st)
{
    const HleMtlSurf *sf = (c->tex_lin >> st & 1) && c->tex[st] && !tex_find(c->tex[st]) ?
                           hle_mtl_surf_get(c->tex[st]) : NULL;
    const uint32_t r = c->tex_rect[st];
    uint32_t w = (r >> 16) & 0x1FFF, h = r & 0x1FFF;
    if (!sf || !w || !h || !sf->d.w || !sf->d.h || (w >= sf->d.w && h >= sf->d.h)) {
        return 0;
    }
    w = MIN(w, sf->d.w);
    h = MIN(h, sf->d.h);
    if (w > 4096 || h > 4096) {
        return 0;
    }
    static const uint8_t k_class[8] = { 2, 2, 3, 0, 1, 0, 2, 2 };
    return (w - 1) | (h - 1) << 12 | (uint32_t)k_class[s->tss[st][TSS_ADDRESSU] & 7] << 24 |
           (uint32_t)k_class[s->tss[st][TSS_ADDRESSV] & 7] << 26 | (st & 1u) << 28 | 1u << 29 |
           (st >> 1) << 31;
}

/* The draw's textures: key stage ki samples texture stage st through fixed
 * slots (pc.tex[ki] = ki | (ki + 1) << 16: msl.h); *flags gets the linear
 * bits (vk/draw.c stage_slot). */
typedef struct Bind {
    __unsafe_unretained id<MTLTexture> t2[4], tc[4], t3[4];
    __unsafe_unretained id<MTLSamplerState> sm[5];
} Bind;

static void stage_bind(Bind *b, const HleCmdDraw *c, unsigned st, unsigned ki, uint32_t rt_id,
                       uint32_t *flags, HleFfPush *pc)
{
    MtlTex *tx = tex_find(c->tex[st]);
    pc->tex[ki] = ki | (ki + 1) << 16;
    b->sm[ki + 1] = sampler(g_dr.st.tss[st]);
    if (tx && tx->tex) {
        if (tx->faces == 6) {
            b->tc[ki] = tx->tex;
        } else if (tx->vol) {
            b->t3[ki] = tx->tex;
        } else {
            b->t2[ki] = tx->tex;
        }
        *flags |= tx->linear ? 1u << ki : 0;
        return;
    }
    HleMtlSurf *ts = tex_surface(c->tex[st], rt_id);
    id<MTLTexture> t = ts ? surf_texture(ts) : nil;
    if (t) {
        if (t.textureType == MTLTextureTypeCube) {
            b->tc[ki] = t;
        } else {
            b->t2[ki] = t;
        }
        *flags |= (c->tex_lin >> st & 1) ? (1u << ki) | (ts->scale > 1 ? 256u << ki : 0) : 0;
    }
}

void hle_mtl_draw(const HleCmdDraw *c, id<MTLRenderCommandEncoder> e, HleMtlSurf *rt,
                  HleMtlSurf *ds, const HleCmdViewport *vpc)
{
    if (!g_dr.ready || !g_dr.st_valid || (!rt && !ds)) {
        drop(DROP_STATE);
        return;
    }
    const HleCmdState *s = &g_dr.st;
    const uint32_t rt_id = rt ? rt->id : 0;
    static PipeKey k;                   /* hashed whole: its padding stays 0 */
    memset(&k, 0, sizeof(k));
    k.vs.fvf = c->fvf;
    bool prog = c->vsh != 0;
    Attr ad[HLE_DRAW_ATTRS + 1];
    uint32_t na = 0, in = 0, ints = 0, cmps = 0;
    if (c->nbind && !decl_build(c, prog, ad, &na, &in, &ints, &cmps)) {
        drop(DROP_DECL);
        return;
    }
    k.vs.cmp_normal = !prog && (cmps & 2);
    if (c->imm) {
        k.vs.fvf = (c->fvf & (HLE_FVF_POSITION_MASK | HLE_FVF_NORMAL)) | HLE_FVF_DIFFUSE |
                   HLE_FVF_SPECULAR | (4u << HLE_FVF_TEXCOUNT_SHIFT) | 0xAA0000u;
    }
    k.vs.flat = k.ps.flat = s->rs[RS_SHADEMODE] == 0x1D00;
    HleFfPush pc;
    memset(&pc, 0, sizeof(pc));
    memcpy(pc.mvp, s->mvp, sizeof(pc.mvp));
    pc.fog_color = s->rs[RS_FOGCOLOR];
    memcpy(&pc.fog[0], &s->rs[RS_FOGSTART], 4);
    memcpy(&pc.fog[1], &s->rs[RS_FOGEND], 4);
    memcpy(&pc.fog[2], &s->rs[RS_FOGDENSITY], 4);
    Bind bind;
    for (unsigned i = 0; i < 4; i++) {
        bind.t2[i] = g_dr.white2d;
        bind.tc[i] = g_dr.whitecube;
        bind.t3[i] = g_dr.white3d;
        bind.sm[i + 1] = g_mtl.linear;
    }
    bind.sm[0] = g_mtl.linear;
    uint32_t rect = 0;
    unsigned first = s->rs[RS_POINTSPRITEENABLE] ? HLE_FF_SPRITE_STAGE : 0;
    for (unsigned st = first; st < HLE_FF_STAGES && !s->psh; st++) {
        const uint32_t *t = s->tss[st];
        if (t[TSS_COLOROP] <= 1) {
            break;
        }
        unsigned ki = st - first;
        HleFfStage *fs = &k.ps.st[ki];
        fs->colorop = t[TSS_COLOROP];
        fs->colorarg0 = t[TSS_COLORARG0];
        fs->colorarg1 = t[TSS_COLORARG1];
        fs->colorarg2 = t[TSS_COLORARG2];
        fs->alphaop = t[TSS_ALPHAOP];
        fs->alphaarg0 = t[TSS_ALPHAARG0];
        fs->alphaarg1 = t[TSS_ALPHAARG1];
        fs->alphaarg2 = t[TSS_ALPHAARG2];
        fs->resultarg = t[TSS_RESULTARG];
        if (shadow_fmt(c->tex[st])) {
            pc.tex[ki] = ki | (ki + 1) << 16;
        } else {
            stage_bind(&bind, c, st, ki, rt_id, &pc.flags, &pc);
        }
        fs->texture = c->tex[st] != 0;
        fs->unset = c->tex_unset >> st & 1;
        fs->alpha_kill = fs->texture && t[TSS_ALPHAKILL] != 0;
        k.vs.texcoord[ki] = t[TSS_TEXCOORDINDEX] & 7;
        k.ps.nstages = ki + 1;
        k.vs.ntex = ki + 1;
    }
    if (!s->psh) {
        k.ps.fbfetch = (uint8_t)fb_stages(c, rt);
    } else {
        pc.flags = 0;
        for (unsigned st = 0; st < HLE_FF_STAGES; st++) {
            stage_bind(&bind, c, st, st, rt_id, &pc.flags, &pc);
            k.vs.texcoord[st] = s->tss[st][TSS_TEXCOORDINDEX] & 7;
        }
        k.vs.ntex = HLE_FF_STAGES;
        k.psh = 1;
        hle_psh_key(s->rs, &k.pk);
        k.pk.fbfetch = (uint8_t)fb_stages(c, rt);
        k.pk.alpha_test = s->rs[RS_ALPHATESTENABLE] != 0;
        k.pk.alpha_func = s->rs[RS_ALPHAFUNC] >= 0x200 ? (s->rs[RS_ALPHAFUNC] - 0x200) & 7 : 7;
        k.pk.flat = s->rs[RS_SHADEMODE] == 0x1D00;
        k.pk.fog = s->rs[RS_FOGENABLE] ? (s->rs[RS_FOGTABLEMODE] & 3) + 1 : 0;
        k.pk.fog_abs = (s->rs[RS_FOGTABLEMODE] >> 8) & 1;
        k.pk.specular = s->rs[RS_SPECULARENABLE] != 0;
        k.pk.point_sprite = c->prim == 0 && s->rs[RS_POINTSPRITEENABLE] != 0;
        k.pk.out_bgra = rt && hle_mtl_out_bgra(rt->fmt);
        for (unsigned st = 0; st < 4; st++) {
            k.pk.alpha_kill |= (c->tex[st] && s->tss[st][TSS_ALPHAKILL] != 0) << st;
            unsigned sf = shadow_fmt(c->tex[st]);
            if (sf) {
                k.pk.shadow |= 1u << st;
                k.pk.shadow_fmt |= sf << (2 * st);
            }
        }
        for (unsigned st = 0; st < 4; st++) {
            unsigned m = (k.pk.tex_modes >> (5 * st)) & 0x1F;
            MtlTex *t = c->tex[st] ? tex_find(c->tex[st]) : NULL;
            bool vol = t && t->vol, flat = c->tex[st] && !vol && !(t && t->faces == 6);
            if (vol) {
                k.pk.vol |= 1u << st;
            } else if (m == HLE_PST_PROJECT3D && flat && !((k.pk.shadow >> st) & 1)) {
                k.pk.tex_modes -= (HLE_PST_PROJECT3D - HLE_PST_PROJECT2D) << (5 * st);
            }
        }
        for (unsigned st = 0; st < 4 && !rect; st++) {
            const unsigned m = (k.pk.tex_modes >> (5 * st)) & 0x1F;
            const bool v = (k.pk.vol >> st) & 1;
            const bool samp2d = m == HLE_PST_DOT_ST || m == HLE_PST_BRDF || m == HLE_PST_DOT_ZW ||
                                m > HLE_PST_DOT_RFLCT_SPEC_CONST ||
                                ((m == HLE_PST_PROJECT2D || m == HLE_PST_BUMPENVMAP ||
                                  m == HLE_PST_BUMPENVMAP_LUM) && !v) ||
                                ((m == HLE_PST_DPNDNT_AR || m == HLE_PST_DPNDNT_GB) && !st);
            if (samp2d && !((k.pk.shadow >> st) & 1) && !((k.pk.fbfetch >> st) & 1)) {
                rect = lin_rect(c, s, st);
            }
        }
        if (rect) {
            k.pk.vol |= HLE_PSH_RECT;
        }
        if (k.pk.shadow) {
            k.pk.shadow |= 7 << 4;      /* no depth compares yet: lit */
        }
        for (unsigned i = 0; i < 8; i++) {
            pc.psc[i] = s->rs[HLE_PS_C0 + i];
            pc.psc[8 + i] = s->rs[HLE_PS_C1 + i];
        }
        pc.psc[16] = s->rs[HLE_PS_FINAL_C0];
        pc.psc[17] = s->rs[HLE_PS_FINAL_C1];
        for (unsigned st = 1; st < 4; st++) {
            unsigned m = (k.pk.tex_modes >> (5 * st)) & 0x1F;
            if (m == HLE_PST_BUMPENVMAP || m == HLE_PST_BUMPENVMAP_LUM) {
                const uint32_t *t = s->tss[st];
                uint32_t *mt = st == 3 ? pc.bump3 : &pc.bump[2 * (st - 1)];
                mt[0] = half2(t[TSS_BUMPENVMAT00], t[TSS_BUMPENVMAT00 + 1]);
                mt[1] = half2(t[TSS_BUMPENVMAT00 + 2], t[TSS_BUMPENVMAT00 + 3]);
                pc.bumpl[st - 1] = half2(t[TSS_BUMPENVLSCALE], t[TSS_BUMPENVLSCALE + 1]);
            }
        }
    }
    bool rhw = (k.vs.fvf & HLE_FVF_POSITION_MASK) == HLE_FVF_XYZRHW;
    if (!prog) {
        if (s->rs[RS_FOGENABLE]) {
            k.vs.fog_src = !(s->rs[RS_FOGTABLEMODE] & 3) ? HLE_FOG_SRC_SPEC_ALPHA :
                           s->rs[RS_RANGEFOGENABLE] ? HLE_FOG_SRC_RADIAL : HLE_FOG_SRC_PLANAR;
        }
        if (c->ff_ubo != HLE_DRAW_NO_UBO) {
            if (c->prim == 0) {
                k.vs.points = !rhw && s->rs[RS_POINTSCALEENABLE] ? 2 : 1;
            }
            if (!rhw) {
                /* vk/draw.c ff_vs_key */
                const uint32_t *rs = s->rs;
                bool tg = false;
                unsigned f0 = rs[RS_POINTSPRITEENABLE] && !s->psh ? HLE_FF_SPRITE_STAGE : 0;
                for (unsigned st = 0; st < k.vs.ntex && st + f0 < HLE_FF_STAGES; st++) {
                    uint32_t tci = s->tss[st + f0][TSS_TEXCOORDINDEX] >> 16;
                    uint32_t ttf = s->tss[st + f0][TSS_TEXTURETRANSFORMFLAGS];
                    k.vs.texgen[st] = tci <= HLE_TCI_SPHEREMAP ? tci : 0;
                    k.vs.texxform[st] = (ttf & 7) | (ttf & 0x100 ? 0x10 : 0);
                    tg |= k.vs.texgen[st] != 0;
                }
                if (rs[RS_LIGHTING] && (c->ff_lights & HLE_DRAW_LIT_DATA)) {
                    k.vs.lighting = 1;
                    k.vs.nlights = MIN(c->ff_lights & 0xF, HLE_FF_LIGHTS);
                    for (unsigned i = 0; i < k.vs.nlights; i++) {
                        k.vs.light_type[i] = (c->ff_lights >> (4 + 2 * i)) & 3;
                    }
                    k.vs.specular = rs[RS_SPECULARENABLE] != 0;
                    k.vs.local_viewer = rs[RS_LOCALVIEWER] != 0;
                    k.vs.colorvertex = rs[RS_COLORVERTEX] != 0;
                    k.vs.src[0] = rs[RS_DIFFUSEMATERIALSOURCE] & 3;
                    k.vs.src[1] = rs[RS_AMBIENTMATERIALSOURCE] & 3;
                    k.vs.src[2] = rs[RS_SPECULARMATERIALSOURCE] & 3;
                    k.vs.src[3] = rs[RS_EMISSIVEMATERIALSOURCE] & 3;
                }
                uint32_t vb = rs[RS_VERTEXBLEND], pos = k.vs.fvf & HLE_FVF_POSITION_MASK;
                if (vb >= 1 && vb <= 6 && pos >= 0x006 && pos <= 0x00C) {
                    k.vs.blend = (uint8_t)((vb + 1) / 2 + 1);
                    k.vs.blend_mix = vb & 1;
                }
                if (k.vs.lighting || tg || k.vs.blend) {
                    k.vs.normalize = rs[RS_NORMALIZENORMALS] != 0;
                }
            }
        } else if (!rhw && k.vs.fog_src != HLE_FOG_SRC_SPEC_ALPHA) {
            k.vs.fog_src = HLE_FOG_SRC_OFF;
        }
    }
    bool cur_diffuse = !prog && !c->nbind && !c->imm && c->diffuse_cur &&
                       !(k.vs.fvf & HLE_FVF_DIFFUSE) && !k.vs.lighting;
    if (cur_diffuse) {
        k.vs.fvf |= HLE_FVF_DIFFUSE;
    }
    if (prog) {
        memset(&k.vs, 0, sizeof(k.vs));
        k.vsh = c->vsh;
        k.vk.in_mask = in;
        k.vk.int_mask = (uint16_t)ints;
        k.vk.cmp_mask = (uint16_t)cmps;
        k.vk.flat = s->rs[RS_SHADEMODE] == 0x1D00;
        k.vk.spec_off = !s->spec;
        k.vk.fog_table = s->rs[RS_FOGENABLE] && (s->rs[RS_FOGTABLEMODE] & 3) != 0;
    }
    if (!s->psh) {
        k.ps.alpha_test = s->rs[RS_ALPHATESTENABLE] != 0;
        k.ps.alpha_func = s->rs[RS_ALPHAFUNC] >= 0x200 ? (s->rs[RS_ALPHAFUNC] - 0x200) & 7 : 7;
        k.ps.specular = s->rs[RS_SPECULARENABLE] != 0;
        k.ps.fog = s->rs[RS_FOGENABLE] ? (s->rs[RS_FOGTABLEMODE] & 3) + 1 : 0;
        k.ps.point_sprite = c->prim == 0 && s->rs[RS_POINTSPRITEENABLE] != 0;
        k.ps.out_bgra = rt && hle_mtl_out_bgra(rt->fmt);
    }
    k.blend_en = s->rs[RS_ALPHABLENDENABLE] != 0;
    k.src = s->rs[RS_SRCBLEND];
    k.dst = s->rs[RS_DESTBLEND];
    k.op = s->rs[RS_BLENDOP];
    if (k.blend_en && (k.op == 0xF005 || k.op == 0xF006)) {
        unsigned sb = signed_blend(s);
        if (sb && rt) {
            k.blend_en = 0;
            k.op = 0x8006;
            k.ps.sblend = k.pk.sblend = (uint8_t)sb;
        } else {
            k.op = k.op == 0xF005 ? 0x800B : 0x8006;
        }
    }
    uint32_t cw = s->rs[RS_COLORWRITEENABLE];
    bool bgra = rt && hle_mtl_out_bgra(rt->fmt);
    k.wmask = ((cw >> 16) & 1 ? (bgra ? MTLColorWriteMaskBlue : MTLColorWriteMaskRed) : 0) |
              ((cw >> 8) & 1 ? MTLColorWriteMaskGreen : 0) |
              (cw & 1 ? (bgra ? MTLColorWriteMaskRed : MTLColorWriteMaskBlue) : 0) |
              ((cw >> 24) & 1 ? MTLColorWriteMaskAlpha : 0);
    k.cfmt = rt ? (uint32_t)rt->fmt : 0;
    k.dfmt = ds ? (uint32_t)ds->fmt : 0;
    k.stencil = ds && ds->stencil;
    if (c->prim > 4) {
        drop(DROP_PRIM);
        return;
    }
    k.topo_class = c->prim == 0 ? 0 : c->prim <= 2 ? 1 : 2;
    bool wff = !prog && !rhw && c->wscale > 0.0f;
    bool wbuf = (prog || rhw || wff) && ds && s->rs[RS_ZENABLE] == 2;
    bool zclamp = ds && s->rs[RS_ZENABLE] != 0 && s->zclamp;
    if (prog) {
        k.vk.wbuf = wbuf;
        k.vk.zfree = !ds || s->rs[RS_ZENABLE] == 0;
        k.vk.zclamp = zclamp;
    } else {
        k.vs.wbuf = wbuf;
        k.vs.zclamp = zclamp;
    }
    if (s->psh) {
        k.pk.wbuf = wbuf;
    } else {
        k.ps.wbuf = wbuf;
    }
    bool zt = ds && s->rs[RS_ZENABLE] != 0;
    float zslope, zofs;
    memcpy(&zslope, &s->rs[RS_ZSLOPESCALE], 4);
    memcpy(&zofs, &s->rs[RS_ZOFFSET], 4);
    bool tri = c->prim >= 3;
    bool bias = zt && tri && s->rs[RS_SOLIDOFFSETENABLE] && isfinite(zslope) && isfinite(zofs) &&
                (zslope != 0.0f || zofs != 0.0f);
    if (zt && tri && !s->rs[RS_ZWRITEENABLE] &&
        (s->rs[RS_ZFUNC] == 0x203 || s->rs[RS_ZFUNC] == 0x206)) {
        zslope = bias ? zslope : 0.0f;
        zofs = (bias ? zofs : 0.0f) + (s->rs[RS_ZFUNC] == 0x203 ? -1.0f : 1.0f);
        bias = true;
    }
    zslope *= (float)(rt ? rt->scale : ds->scale);
    if (wbuf && wff) {
        float f = c->zscale / c->wscale;
        zofs *= f;
        zslope *= f;
    }
    if (wbuf) {
        memcpy(&pc.psc[18], bias ? &zofs : &(float){ 0.0f }, 4);
        memcpy(&pc.psc[19], bias ? &zslope : &(float){ 0.0f }, 4);
        bias = false;
    } else {
        /* reversed depth (ff.h HLE_ZNORM_REV_GLSL): the constant part in
         * the vertex shader, the slope's sign turned */
        memcpy(&pc.psc[18], bias ? &zofs : &(float){ 0.0f }, 4);
        zofs = 0.0f;
        zslope = -zslope;
    }
    /* the vertex layout: the declaration's, else the FVF's (the current
     * diffuse on binding 1) */
    uint32_t nb, offs[HLE_DRAW_MAX_BIND + 1];
    if (c->nbind) {
        nb = MIN(c->nbind, (uint32_t)HLE_DRAW_MAX_BIND);
        for (uint32_t i = 0; i < nb; i++) {
            k.vi.stride[i] = c->bind_stride[i];
            offs[i] = c->bind_off[i];
        }
    } else {
        nb = 1;
        k.vi.stride[0] = c->stride;
        offs[0] = c->vb_off;
        na = c->imm ? imm_attrs(k.vs.fvf, ad) : fvf_attrs(c->fvf, ad);
        if (cur_diffuse) {
            ad[na++] = (Attr){ .loc = 2, .bind = 1, .off = 0, .fmt = MTLVertexFormatFloat4 };
            k.vi.stride[1] = 0;
            offs[1] = c->diffuse_cur - 1;
            nb = 2;
        }
    }
    na = MIN(na, (uint32_t)HLE_DRAW_ATTRS);
    k.vi.nattr = (uint8_t)na;
    k.vi.nbind = (uint8_t)nb;
    for (uint32_t i = 0; i < na; i++) {
        k.vi.loc[i] = ad[i].loc;
        k.vi.bind[i] = ad[i].bind;
        k.vi.off[i] = ad[i].off;
        k.vi.fmt[i] = (uint16_t)ad[i].fmt;
        if (ad[i].off & (fmt_short(ad[i].fmt) ? 1 : 3)) {
            static unsigned s_logged;
            if (s_logged++ < 8) {
                hle_log("hakuX-hle-pipe", "mtl: align drop: attr loc %u off %u fmt %u",
                        ad[i].loc, ad[i].off, (unsigned)ad[i].fmt);
            }
            drop(DROP_ALIGN);
            return;
        }
    }
    for (uint32_t i = 0; i < nb; i++) {
        if ((k.vi.stride[i] & 3) || (offs[i] & 3)) {
            static unsigned s_logged;
            if (s_logged++ < 8) {
                hle_log("hakuX-hle-pipe", "mtl: align drop: bind %u/%u stride %u off %u (decl %u fvf %#x imm %d)",
                        i, nb, k.vi.stride[i], offs[i], c->nbind, c->fvf, c->imm);
            }
            drop(DROP_ALIGN);
            return;
        }
    }
    bool pending;
    id<MTLRenderPipelineState> p = pipeline(&k, rt ? rt : ds, &pending);
    if (!p) {
        if (pending) {
            g_dr.async_skips++;
        } else {
            drop(DROP_PIPE);
        }
        return;
    }
    /* raster, depth and stencil */
    uint32_t cull = s->rs[RS_CULLMODE], ff = s->rs[RS_FRONTFACE];
    const bool stn = ds && ds->stencil && s->rs[RS_STENCILENABLE];
    const uint32_t sraw[4] = { s->rs[RS_STENCILFAIL], s->rs[RS_STENCILPASS],
                               s->rs[RS_STENCILZFAIL], s->rs[RS_STENCILFUNC] };
    id<MTLDepthStencilState> dss = depth_stencil(zt, zt && s->rs[RS_ZWRITEENABLE],
                                                 zcmp_op(s->rs[RS_ZFUNC]), stn, sraw,
                                                 s->rs[RS_STENCILMASK], s->rs[RS_STENCILWRITEMASK]);
    if (!g_dr.rec.valid || g_dr.rec.pipe != p) {
        [e setRenderPipelineState:p];
        g_dr.rec.pipe = p;
    }
    if (!g_dr.rec.valid || g_dr.rec.dss != dss) {
        [e setDepthStencilState:dss];
        g_dr.rec.dss = dss;
    }
    [e setStencilReferenceValue:s->rs[RS_STENCILREF] & 0xFF];
    [e setCullMode:cull == 0 ? MTLCullModeNone : cull == ff ? MTLCullModeFront : MTLCullModeBack];
    [e setFrontFacingWinding:ff == 0x901 ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [e setDepthBias:bias ? zofs : 0.0f slopeScale:bias ? zslope : 0.0f clamp:0.0f];
    [e setDepthClipMode:zclamp ? MTLDepthClipModeClamp : MTLDepthClipModeClip];
    /* positions come out mapped to the whole target (vk/draw.c): the Metal
     * viewport's y already points down, as Vulkan's flipped one */
    uint32_t tw = rt ? rt->d.w : ds->d.w, th = rt ? rt->d.h : ds->d.h;
    uint32_t sw = rt ? rt->w : ds->w, sh = rt ? rt->h : ds->h;
    if (rt && ds) {
        sw = MIN(sw, ds->w);
        sh = MIN(sh, ds->h);
    }
    uint32_t rs = rt ? rt->scale : ds->scale;
    bool full = !vpc->w || !vpc->h;
    int64_t sx = 0, sy = 0, sx2 = sw, sy2 = sh;
    if (vpc->clip) {
        int32_t x1 = MAX(vpc->cx1, 0), y1 = MAX(vpc->cy1, 0);
        int32_t x2 = MIN(vpc->cx2, (int32_t)tw), y2 = MIN(vpc->cy2, (int32_t)th);
        sx = (int64_t)x1 * rs;
        sy = (int64_t)y1 * rs;
        sx2 = (int64_t)MAX(x2, x1) * rs;
        sy2 = (int64_t)MAX(y2, y1) * rs;
    } else if (!full) {
        sx = (int64_t)vpc->x * rs;
        sy = (int64_t)vpc->y * rs;
        sx2 = sx + (int64_t)vpc->w * rs;
        sy2 = sy + (int64_t)vpc->h * rs;
    }
    sx = MIN(MAX(sx, 0), (int64_t)sw);
    sy = MIN(MAX(sy, 0), (int64_t)sh);
    sx2 = MIN(MAX(sx2, sx), (int64_t)sw);
    sy2 = MIN(MAX(sy2, sy), (int64_t)sh);
    if (sx2 == sx || sy2 == sy) {
        g_dr.draws++;                   /* nothing inside the clip */
        return;
    }
    [e setScissorRect:(MTLScissorRect){ (NSUInteger)sx, (NSUInteger)sy, (NSUInteger)(sx2 - sx),
                                        (NSUInteger)(sy2 - sy) }];
    float minz = 0.0f, maxz = 1.0f;
    if (!prog && !rhw && !full) {
        minz = vpc->minz;
        maxz = vpc->maxz;
    }
    [e setViewport:(MTLViewport){ 0, 0, sw, sh, minz, maxz }];
    float msx = MAX(s->xs, 1u), msy = MAX(s->ys, 1u);
    float aax = s->aa ? msx : 1.0f, aay = s->aa ? msy : 1.0f;
    pc.vp[0] = 2.0f * aax / (float)tw;
    pc.vp[1] = -2.0f * aay / (float)th;
    if (rhw && !prog) {
        pc.scr[0] = msx / aax;
        pc.scr[1] = msy / aay;
        pc.scr[2] = vpc->offx;
        pc.scr[3] = vpc->offy;
    } else if (!prog) {
        float vx = full ? 0.0f : vpc->x, vy = full ? 0.0f : vpc->y;
        float vw = full ? tw : vpc->w, vh = full ? th : vpc->h;
        pc.scr[0] = vw * 0.5f / aax;
        pc.scr[1] = -vh * 0.5f / aay;
        pc.scr[2] = (vx + vw * 0.5f) / aax + vpc->offx;
        pc.scr[3] = (vy + vh * 0.5f) / aay + vpc->offy;
    }
    pc.zscale = wbuf && wff ? c->wscale : c->zscale;
    pc.tfactor = s->rs[RS_TEXTUREFACTOR];
    pc.alpha_ref = (s->rs[RS_ALPHAREF] & 0xFF) / 255.0f;
    memcpy(&pc.fog[3], &rect, 4);
    pc.flags |= MIN(rs, 255u) << 16 | MIN(g_hle_rscale, 255u) << 24 |
                (aax > 1.0f || aay > 1.0f ? HLE_TEXEL_EDGE_FLAG : 0u);
    if (!g_dr.rec.valid || memcmp(&g_dr.rec.pc, &pc, sizeof(pc))) {
        [e setVertexBytes:&pc length:sizeof(pc) atIndex:0];
        [e setFragmentBytes:&pc length:sizeof(pc) atIndex:0];
        g_dr.rec.pc = pc;
    }
    uint32_t bc = s->rs[RS_BLENDCOLOR];
    if (bgra) {
        bc = (bc & 0xFF00FF00u) | ((bc >> 16) & 0xFF) | ((bc & 0xFF) << 16);
    }
    [e setBlendColorRed:((bc >> 16) & 0xFF) / 255.0f green:((bc >> 8) & 0xFF) / 255.0f
                   blue:(bc & 0xFF) / 255.0f alpha:(bc >> 24) / 255.0f];
    if (prog) {
        [e setVertexBuffer:g_mtl.arena offset:c->consts_off atIndex:1];
    } else if (c->ff_ubo != HLE_DRAW_NO_UBO) {
        [e setVertexBuffer:g_mtl.arena offset:c->ff_ubo atIndex:1];
    }
    for (uint32_t i = 0; i < nb; i++) {
        [e setVertexBuffer:g_mtl.arena offset:offs[i] atIndex:HLE_MSL_VB_BASE + i];
    }
    [e setFragmentTextures:bind.t2 withRange:NSMakeRange(0, 4)];
    [e setFragmentTextures:bind.tc withRange:NSMakeRange(HLE_MSL_TEX_CUBE, 4)];
    [e setFragmentTextures:bind.t3 withRange:NSMakeRange(HLE_MSL_TEX_3D, 4)];
    [e setFragmentSamplerStates:bind.sm withRange:NSMakeRange(0, 5)];
    g_dr.rec.valid = true;
    static const MTLPrimitiveType k_prim[5] = {
        MTLPrimitiveTypePoint, MTLPrimitiveTypeLine, MTLPrimitiveTypeLineStrip,
        MTLPrimitiveTypeTriangle, MTLPrimitiveTypeTriangleStrip };
    if (c->ib_off != UINT32_MAX) {
        [e drawIndexedPrimitives:k_prim[c->prim] indexCount:c->count indexType:MTLIndexTypeUInt16
                     indexBuffer:g_mtl.arena indexBufferOffset:c->ib_off];
    } else {
        [e drawPrimitives:k_prim[c->prim] vertexStart:0 vertexCount:c->count];
    }
    g_dr.draws++;
    if (ds && (zt && s->rs[RS_ZWRITEENABLE])) {
        hle_mtl_surf_written(ds);
    }
}

void hle_mtl_draw_diag(void)
{
    hle_log("hakuX-hle-back", "mtl: draws=%llu pipelines=%llu (%llu failed) drops: state=%llu "
            "layout=%llu pipe=%llu prim=%llu align=%llu; asynchronous %llu built, %llu draws "
            "skipped meanwhile",
            (unsigned long long)g_dr.draws, (unsigned long long)g_dr.pipes_made,
            (unsigned long long)g_dr.pipe_fail, (unsigned long long)g_dr.drops[DROP_STATE],
            (unsigned long long)g_dr.drops[DROP_DECL], (unsigned long long)g_dr.drops[DROP_PIPE],
            (unsigned long long)g_dr.drops[DROP_PRIM], (unsigned long long)g_dr.drops[DROP_ALIGN],
            (unsigned long long)g_dr.async_queued, (unsigned long long)g_dr.async_skips);
}
