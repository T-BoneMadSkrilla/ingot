/*
 * hakuX HLE GPU — the shader generators' Metal Shading Language form (pure).
 *
 * With g_hle_msl set (the Metal back end, before any shader is made) the
 * generators emit MSL: their GLSL statements unchanged, inside a struct
 * (HleS) whose members are what GLSL has as globals (the push block, the
 * inputs and outputs, the uniform blocks, the textures and samplers, the
 * built-ins) and whose member functions are the GLSL functions, main among
 * them. The prelude maps GLSL's types and functions to MSL's; the entry point
 * (hle_vs / hle_fs) copies the stage's inputs in, calls main and copies the
 * outputs out. GLSL text is unchanged without the flag.
 *
 * Metal bindings (mtl/draw.m):
 * - vertex: attributes by GLSL location ([[attribute(n)]], buffers from
 *   HLE_MSL_VB_BASE); buffer 0 the push block, buffer 1 the uniform block
 *   (vertex programs: c[192] then vcur[16]; fixed function: f[]);
 * - varyings by GLSL location: [[user(lN)]];
 * - fragment: buffer 0 the push block, textures 0-3 2D, 4-7 cube, 8-11 3D
 *   (the stage's: pc.tex is stage | (stage + 1) << 16), samplers 0 the
 *   default, 1-4 the stages'; the colour target's pixel as colour(0).
 */
#ifndef HW_XBOX_HLE_SHADER_MSL_H
#define HW_XBOX_HLE_SHADER_MSL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

extern bool g_hle_msl;

#define HLE_MSL_VB_BASE 8       /* vertex buffer i at buffer(HLE_MSL_VB_BASE + i) */
#define HLE_MSL_TEX_CUBE 4
#define HLE_MSL_TEX_3D 8

typedef struct HleMslIo {
    uint8_t loc, flat;
    char type[8], name[16];
} HleMslIo;

/* What a generator declared, for its entry point. */
typedef struct HleMsl {
    bool fs;
    uint8_t nin, nout;
    HleMslIo in[17], out[11];
    uint8_t ubo;                /* vertex: 1 program constants (c, vcur), 2 FF block (f) */
    uint8_t tex;                /* fragment: bit 0 2D, 1 cube, 2 3D */
    bool fb;                    /* fragment: the target's pixel (uFb) */
    bool ptc;                   /* fragment: gl_PointCoord */
    bool depth;                 /* fragment: writes gl_FragDepth */
} HleMsl;

/* The shader's start: the prelude, then HleS's opening and its built-ins
 * and push block (fs: a fragment shader). */
const char *hle_msl_begin(bool fs);

/* One input or output declaration into line (n bytes): GLSL's
 * "layout(location = loc) [flat ]in|out type name;", or MSL's member, noted
 * in m (NULL: GLSL). */
void hle_msl_io(HleMsl *m, char *line, size_t n, bool in, unsigned loc, bool flat,
                const char *type, const char *name);

/* The uniform block / texture members (MSL), noted in m. */
const char *hle_msl_ubo(HleMsl *m, unsigned kind);
const char *hle_msl_tex(HleMsl *m, unsigned bits);

/* HleS's end and the entry point; its length, 0 if it does not fit. */
size_t hle_msl_entry(const HleMsl *m, char *buf, size_t cap);

#endif
