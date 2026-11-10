/*
 * hakuX HLE GPU — the generators' MSL form (pure). See msl.h.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "hw/xbox/hle/shader/msl.h"

bool g_hle_msl;

/* GLSL's names in MSL; HlePush is ff.h HleFfPush (std430 there, the same
 * offsets here: 256 bytes). */
#define PRELUDE \
    "#include <metal_stdlib>\n" \
    "using namespace metal;\n" \
    "#pragma clang diagnostic ignored \"-Wunused-variable\"\n" \
    "#pragma clang diagnostic ignored \"-Wunused-function\"\n" \
    "#define vec2 float2\n#define vec3 float3\n#define vec4 float4\n" \
    "#define ivec2 int2\n#define ivec3 int3\n#define ivec4 int4\n" \
    "#define uvec2 uint2\n#define uvec3 uint3\n#define uvec4 uint4\n" \
    "#define bvec2 bool2\n#define bvec3 bool3\n#define bvec4 bool4\n" \
    "#define mat2 float2x2\n#define mat4 float4x4\n" \
    "#define precise\n" \
    "#define discard discard_fragment()\n" \
    "#define inversesqrt rsqrt\n#define dFdx dfdx\n#define dFdy dfdy\n" \
    "#define nonuniformEXT(x) (x)\n#define subpassLoad(x) (x)\n" \
    "#define HLE_SL(s) (uint(s) | (uint(s) + 1u) << 16)\n" \
    "inline float3x3 mat3(float3 a, float3 b, float3 c) { return float3x3(a, b, c); }\n" \
    "inline float3x3 mat3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }\n" \
    "inline float uintBitsToFloat(uint x) { return as_type<float>(x); }\n" \
    "inline uint floatBitsToUint(float x) { return as_type<uint>(x); }\n" \
    "inline int bitfieldExtract(int v, int o, int n) { return extract_bits(v, uint(o), uint(n)); }\n" \
    "inline float4 unpackUnorm4x8(uint c) { return unpack_unorm4x8_to_float(c); }\n" \
    "inline float2 unpackHalf2x16(uint c) { return float2(as_type<half2>(c)); }\n" \
    "inline float mod(float a, float b) { return a - b * floor(a / b); }\n" \
    "#define HLE_V(T, B) \\\n" \
    "  inline B lessThan(T a, T b) { return a < b; }\\\n" \
    "  inline B lessThanEqual(T a, T b) { return a <= b; }\\\n" \
    "  inline B greaterThan(T a, T b) { return a > b; }\\\n" \
    "  inline B greaterThanEqual(T a, T b) { return a >= b; }\\\n" \
    "  inline B equal(T a, T b) { return a == b; }\\\n" \
    "  inline B notEqual(T a, T b) { return a != b; }\\\n" \
    "  inline T mix(T a, T b, B c) { return select(a, b, c); }\\\n" \
    "  inline T mix(T a, T b, float t) { return mix(a, b, T(t)); }\\\n" \
    "  inline T clamp(T x, float a, float b) { return clamp(x, T(a), T(b)); }\\\n" \
    "  inline T max(T x, float a) { return max(x, T(a)); }\\\n" \
    "  inline T min(T x, float a) { return min(x, T(a)); }\\\n" \
    "  inline T mod(T a, T b) { return a - b * floor(a / b); }\\\n" \
    "  inline T mod(T a, float b) { return a - b * floor(a / b); }\n" \
    "HLE_V(float2, bool2)\nHLE_V(float3, bool3)\nHLE_V(float4, bool4)\n#undef HLE_V\n" \
    "struct HleTS2 { texture2d<float> t; sampler s; };\n" \
    "struct HleTSC { texturecube<float> t; sampler s; };\n" \
    "struct HleTS3 { texture3d<float> t; sampler s; };\n" \
    "inline HleTS2 sampler2D(texture2d<float> t, sampler s) { return HleTS2{ t, s }; }\n" \
    "inline HleTSC samplerCube(texturecube<float> t, sampler s) { return HleTSC{ t, s }; }\n" \
    "inline HleTS3 sampler3D(texture3d<float> t, sampler s) { return HleTS3{ t, s }; }\n" \
    "inline float4 texture(HleTS2 p, float2 uv) { return p.t.sample(p.s, uv); }\n" \
    "inline float4 texture(HleTSC p, float3 d) { return p.t.sample(p.s, d); }\n" \
    "inline float4 texture(HleTS3 p, float3 uvw) { return p.t.sample(p.s, uvw); }\n" \
    "inline float4 textureGather(HleTS2 p, float2 uv) { return p.t.gather(p.s, uv); }\n" \
    "inline int2 textureSize(HleTS2 p, int l) {\n" \
    "  return int2(p.t.get_width(uint(l)), p.t.get_height(uint(l))); }\n" \
    "struct HlePush {\n" \
    "  float4x4 mvp; float2 vp; uint2 bump3; uint4 tex; uint tfactor; uint bumpl[3];\n" \
    "  float alpha_ref; uint flags; float zscale; uint fog_color; float4 fog; uint psc[20];\n" \
    "  float4 scr; uint4 bump;\n" \
    "};\n"

static const char k_vs_begin[] = PRELUDE
    "struct HleVOut {\n"
    "  float4 pos [[position, invariant]];\n"
    "#ifdef HLE_PTS\n"
    "  float psize [[point_size]];\n"
    "#endif\n"
    "  float4 l0 [[user(l0)]]; float4 l1 [[user(l1)]]; float4 l2 [[user(l2)]];\n"
    "  float4 l3 [[user(l3)]]; float4 l4 [[user(l4)]]; float4 l5 [[user(l5)]];\n"
    "  float l6 [[user(l6)]]; float4 l7 [[user(l7)]]; float4 l8 [[user(l8)]];\n"
    "  float l9 [[user(l9)]];\n"
    "};\n"
    "struct HleS {\n"
    "  HlePush pc;\n"
    "  float4 gl_Position = float4(0.0);\n"
    "  float gl_PointSize = 1.0;\n";

static const char k_fs_begin[] = PRELUDE
    "struct HleS {\n"
    "  HlePush pc;\n"
    "  float4 gl_FragCoord = float4(0.0);\n"
    "  float2 gl_PointCoord = float2(0.0);\n"
    "  float gl_FragDepth = 0.0;\n"
    "  float4 uFb = float4(0.0);\n";

const char *hle_msl_begin(bool fs)
{
    return fs ? k_fs_begin : k_vs_begin;
}

static void note(HleMslIo *io, unsigned loc, bool flat, const char *type, const char *name)
{
    io->loc = (uint8_t)loc;
    io->flat = flat;
    snprintf(io->type, sizeof(io->type), "%s", type);
    snprintf(io->name, sizeof(io->name), "%s", name);
}

void hle_msl_io(HleMsl *m, char *line, size_t n, bool in, unsigned loc, bool flat,
                const char *type, const char *name)
{
    if (!m) {
        snprintf(line, n, "layout(location = %u) %s%s %s %s;\n", loc, flat ? "flat " : "",
                 in ? "in" : "out", type, name);
        return;
    }
    if (in && m->nin < sizeof(m->in) / sizeof(m->in[0])) {
        note(&m->in[m->nin++], loc, flat, type, name);
    } else if (!in && m->nout < sizeof(m->out) / sizeof(m->out[0])) {
        note(&m->out[m->nout++], loc, flat, type, name);
    }
    if (in) {
        snprintf(line, n, "  %s %s;\n", type, name);
    } else {
        snprintf(line, n, "  %s %s = %s(0.0);\n", type, name, type);
    }
}

const char *hle_msl_ubo(HleMsl *m, unsigned kind)
{
    m->ubo = (uint8_t)kind;
    return kind == 1 ? "  constant float4 *c;\n  constant float4 *vcur;\n"
                     : "  constant float4 *f;\n";
}

const char *hle_msl_tex(HleMsl *m, unsigned bits)
{
    static const char *const k_tex[8] = {
        "",
        "  texture2d<float> uTex2D[4];\n  sampler uSmp[5];\n",
        "  texturecube<float> uTexCube[4];\n  sampler uSmp[5];\n",
        "  texture2d<float> uTex2D[4];\n  texturecube<float> uTexCube[4];\n  sampler uSmp[5];\n",
        "  texture3d<float> uTex3D[4];\n  sampler uSmp[5];\n",
        "  texture2d<float> uTex2D[4];\n  texture3d<float> uTex3D[4];\n  sampler uSmp[5];\n",
        "  texturecube<float> uTexCube[4];\n  texture3d<float> uTex3D[4];\n  sampler uSmp[5];\n",
        "  texture2d<float> uTex2D[4];\n  texturecube<float> uTexCube[4];\n"
        "  texture3d<float> uTex3D[4];\n  sampler uSmp[5];\n",
    };
    m->tex = (uint8_t)(bits & 7);
    return k_tex[bits & 7];
}

typedef struct Buf {
    char *p;
    size_t cap, len;
    bool overflow;
} Buf;

static void put(Buf *b, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b->p + b->len, b->len < b->cap ? b->cap - b->len : 0, fmt, ap);
    va_end(ap);
    if (n < 0 || b->len + (size_t)n >= b->cap) {
        b->overflow = true;
        b->len = b->cap;
        return;
    }
    b->len += (size_t)n;
}

static void vs_entry(Buf *b, const HleMsl *m)
{
    put(b, "struct HleVIn {\n");
    for (unsigned i = 0; i < m->nin; i++) {
        put(b, "  %s %s [[attribute(%u)]];\n", m->in[i].type, m->in[i].name, m->in[i].loc);
    }
    put(b, "};\n"
           "vertex HleVOut hle_vs(%sconstant HlePush &pc_ [[buffer(0)]]%s) {\n"
           "  HleS s;\n  s.pc = pc_;\n",
        m->nin ? "HleVIn i_ [[stage_in]], " : "",
        m->ubo ? ", constant float4 *u_ [[buffer(1)]]" : "");
    if (m->ubo == 1) {
        put(b, "  s.c = u_;\n  s.vcur = u_ + 192;\n");
    } else if (m->ubo == 2) {
        put(b, "  s.f = u_;\n");
    }
    for (unsigned i = 0; i < m->nin; i++) {
        put(b, "  s.%s = i_.%s;\n", m->in[i].name, m->in[i].name);
    }
    put(b, "  s.main();\n"
           "  HleVOut o;\n"
           "  o.pos = s.gl_Position;\n"
           "#ifdef HLE_PTS\n  o.psize = s.gl_PointSize;\n#endif\n"
           "  o.l0 = o.l1 = o.l2 = o.l3 = o.l4 = o.l5 = o.l7 = o.l8 = float4(0.0);\n"
           "  o.l6 = o.l9 = 0.0;\n");
    for (unsigned i = 0; i < m->nout; i++) {
        put(b, "  o.l%u = s.%s;\n", m->out[i].loc, m->out[i].name);
    }
    put(b, "  return o;\n}\n");
}

static void fs_entry(Buf *b, const HleMsl *m)
{
    put(b, "struct HleFIn {\n  float4 pos_ [[position]];\n");
    for (unsigned i = 0; i < m->nin; i++) {
        put(b, "  %s %s [[user(l%u)%s]];\n", m->in[i].type, m->in[i].name, m->in[i].loc,
            m->in[i].flat ? ", flat" : "");
    }
    put(b, "};\n"
           "struct HleFOut {\n  float4 c0 [[color(0)]];\n%s};\n"
           "fragment HleFOut hle_fs(HleFIn i_ [[stage_in]], constant HlePush &pc_ [[buffer(0)]]",
        m->depth ? "  float d [[depth(any)]];\n" : "");
    if (m->tex & 1) {
        put(b, ",\n    array<texture2d<float>, 4> t2_ [[texture(0)]]");
    }
    if (m->tex & 2) {
        put(b, ",\n    array<texturecube<float>, 4> tc_ [[texture(%u)]]", HLE_MSL_TEX_CUBE);
    }
    if (m->tex & 4) {
        put(b, ",\n    array<texture3d<float>, 4> t3_ [[texture(%u)]]", HLE_MSL_TEX_3D);
    }
    if (m->tex) {
        put(b, ",\n    array<sampler, 5> sm_ [[sampler(0)]]");
    }
    if (m->fb) {
        put(b, ",\n    float4 fb_ [[color(0)]]");
    }
    if (m->ptc) {
        put(b, ",\n    float2 pt_ [[point_coord]]");
    }
    put(b, ") {\n  HleS s;\n  s.pc = pc_;\n  s.gl_FragCoord = i_.pos_;\n");
    if (m->tex) {
        put(b, "  for (int j = 0; j < 4; j++) {\n%s%s%s  }\n"
               "  for (int j = 0; j < 5; j++) s.uSmp[j] = sm_[j];\n",
            m->tex & 1 ? "    s.uTex2D[j] = t2_[j];\n" : "",
            m->tex & 2 ? "    s.uTexCube[j] = tc_[j];\n" : "",
            m->tex & 4 ? "    s.uTex3D[j] = t3_[j];\n" : "");
    }
    if (m->fb) {
        put(b, "  s.uFb = fb_;\n");
    }
    if (m->ptc) {
        put(b, "  s.gl_PointCoord = pt_;\n");
    }
    for (unsigned i = 0; i < m->nin; i++) {
        put(b, "  s.%s = i_.%s;\n", m->in[i].name, m->in[i].name);
    }
    put(b, "  s.main();\n  HleFOut o;\n");
    for (unsigned i = 0; i < m->nout; i++) {
        put(b, "  o.c0 = s.%s;\n", m->out[i].name);
    }
    put(b, "%s  return o;\n}\n", m->depth ? "  o.d = s.gl_FragDepth;\n" : "");
}

size_t hle_msl_entry(const HleMsl *m, char *buf, size_t cap)
{
    Buf b = { buf, cap, 0, false };
    put(&b, "};\n");
    if (m->fs) {
        fs_entry(&b, m);
    } else {
        vs_entry(&b, m);
    }
    return b.overflow ? 0 : b.len;
}

void hle_msl_fold_slots(char *src, size_t len)
{
    static const char k_from[] = "pc.tex[", k_to[] = "HLE_SL(";
    const size_t n = sizeof(k_from) - 1;
    for (size_t i = 0; i + n <= len; i++) {
        if (memcmp(src + i, k_from, n)) {
            continue;
        }
        char *close = memchr(src + i + n, ']', len - i - n);
        if (!close) {
            break;
        }
        memcpy(src + i, k_to, n);
        *close = ')';
    }
}
