// SoupRender.metal — the uber soup visualization shader (03 §7, bounded slice).
//
// One fullscreen-triangle draw call renders the whole soup at every zoom level.
// The fragment shader reads an immutable per-frame snapshot: the soup bytes
// (buffer 1, stable program-ID order) and a small aggregate metric texture
// (texture 0, one texel per program: R = normalized activity, G = normalized
// entropy). There is no glyph atlas, no mipmap, no persistent GPU state — this is
// compiled at runtime via makeLibrary(source:) exactly like BFFEvaluate.metal.
//
// MIRROR CONTRACT: `VizUniforms` below mirrors the Swift `VizUniforms`
// (Sources/SoupScopeApp/VizUniforms.swift). This file is compiled from source at
// runtime and cannot #include a Swift/C header, so agreement is enforced by the
// static_asserts here PLUS the `viz_layout_probe` kernel, which the renderer runs
// at init and checks against the host MemoryLayout before drawing anything
// (REQUIRED: defensive validation for new GPU structures).
//
// The opcode byte→color and byte→glyph tables mirror SoupScopeCore's OpcodeVisual
// (pinned by Swift tests); the ten opcode byte values are the shared 01 §2 ASCII
// constants.

#include <metal_stdlib>
using namespace metal;

struct VizUniforms {
    float viewportPxX;    // 0  drawable width in pixels
    float viewportPxY;    // 4  drawable height in pixels
    float originByteX;    // 8  soup byte coord at the top-left pixel
    float originByteY;    // 12
    float bytePx;         // 16 pixels per byte cell (LOD variable)
    float microBlend;     // 20 smoothstep(0.5,1.5,bytePx)  — host-evaluated (LODModel)
    float glyphBlend;     // 24 smoothstep(12,18,bytePx)     — host-evaluated
    uint  gridWidth;      // 28 program grid columns
    uint  gridHeight;     // 32 program grid rows
    uint  programCount;   // 36 real programs (cells >= this render as background)
    uint  metricChannel;  // 40 resident: 0 composite, 1 R, 2 G, 3 B
    uint  flags;          // 44 reserved
    float programBoundaryBlend; // 48 smoothstep(160,224,8*bytePx) — host-evaluated (LODModel)
    float byteBoundaryBlend;    // 52 smoothstep(24,32,bytePx)   — host-evaluated
};                        // size 56, align 4

static_assert(sizeof(VizUniforms) == 56, "VizUniforms must be 56 bytes");
static_assert(alignof(VizUniforms) == 4, "VizUniforms must be 4-byte aligned");

constant float3 kBackground = float3(0xF4, 0xF0, 0xE8) / 255.0;
constant float3 kProgramBoundaryColor = float3(0x18, 0x16, 0x14) / 255.0;
constant float3 kByteBoundaryColor = float3(0xBD, 0xBA, 0xB4) / 255.0;
constant float3 kGlyphDarkInk = float3(0x17, 0x14, 0x12) / 255.0;
constant float3 kGlyphLightInk = float3(0xFA, 0xF7, 0xEF) / 255.0;
constant float kProgramBoundaryAlpha = 0.80;
constant float kByteBoundaryAlpha = 0.18;

// --- Opcode identity (mirrors OpcodeVisual). -1 = data/no-op byte. ---
static int opcode_index(uchar b) {
    switch (b) {
    case 0x3C: return 0; // '<'
    case 0x3E: return 1; // '>'
    case 0x7B: return 2; // '{'
    case 0x7D: return 3; // '}'
    case 0x2B: return 4; // '+'
    case 0x2D: return 5; // '-'
    case 0x2E: return 6; // '.'
    case 0x2C: return 7; // ','
    case 0x5B: return 8; // '['
    case 0x5D: return 9; // ']'
    default: return -1;
    }
}

// Palette colors, indexed by opcode_index (03 §5; identical literals to
// OpcodeVisual.color).
constant float3 kOpcodeColor[10] = {
    float3(0x4E, 0x92, 0x8C) / 255.0, // '<'
    float3(0x6F, 0xAE, 0xA8) / 255.0, // '>'
    float3(0x5D, 0x78, 0xA0) / 255.0, // '{'
    float3(0x87, 0x9C, 0xBC) / 255.0, // '}'
    float3(0xC9, 0x77, 0x67) / 255.0, // '+'
    float3(0xA9, 0x5C, 0x57) / 255.0, // '-'
    float3(0x6B, 0x9B, 0x7A) / 255.0, // '.'
    float3(0xB4, 0x77, 0x8E) / 255.0, // ','
    float3(0x84, 0x80, 0xAE) / 255.0, // '['
    float3(0x9A, 0x8E, 0x5C) / 255.0, // ']'
};

constant float3 kNullColor = float3(0xEE, 0xE9, 0xDF) / 255.0;
constant float3 kDataRampLow = float3(0xE7, 0xE1, 0xD7) / 255.0;
constant float3 kDataRampHigh = float3(0x8F, 0x9A, 0x9B) / 255.0;

// Compact 5×5 procedural glyph, one 5-bit row mask per row (bit c = column c).
// Not a font atlas — an inline constant, mirrored only for legibility.
constant uint kGlyphRows[10][5] = {
    {4, 2, 1, 2, 4},      // '<'
    {4, 8, 16, 8, 4},     // '>'
    {12, 2, 3, 2, 12},    // '{'
    {6, 8, 24, 8, 6},     // '}'
    {4, 4, 31, 4, 4},     // '+'
    {0, 0, 31, 0, 0},     // '-'
    {0, 0, 0, 4, 0},      // '.'
    {0, 0, 4, 4, 2},      // ','
    {14, 2, 2, 2, 14},    // '['
    {14, 8, 8, 8, 14},    // ']'
};

static float3 palette_color(uchar b) {
    int idx = opcode_index(b);
    if (idx >= 0) return kOpcodeColor[idx];
    if (b == 0) return kNullColor;
    return mix(kDataRampLow, kDataRampHigh, float(b) / 255.0);
}

// Glyph ink coverage in [0,1] for a byte at cell-local uv (0..1, top-left origin).
static float glyph_ink(uchar b, float2 uv) {
    int idx = opcode_index(b);
    if (idx < 0) return 0.0;
    float2 g = (uv - 0.1) / 0.8;             // 10% margin around the 5×5 grid
    if (any(g < 0.0) || any(g >= 1.0)) return 0.0;
    uint col = uint(g.x * 5.0);
    uint row = uint(g.y * 5.0);
    return ((kGlyphRows[idx][row] >> col) & 1u) ? 1.0 : 0.0;
}

static float3 legacy_metric_colormap(float activity, float entropy, uint channel) {
    if (channel == 1) {                       // legacy activity: warm ramp
        return mix(float3(0xF1, 0xED, 0xE4) / 255.0,
                   float3(0xC9, 0x77, 0x67) / 255.0,
                   clamp(activity, 0.0, 1.0));
    } else if (channel == 2) {                // legacy entropy: cool ramp
        return mix(float3(0xF1, 0xED, 0xE4) / 255.0,
                   float3(0x5D, 0x78, 0xA0) / 255.0,
                   clamp(entropy, 0.0, 1.0));
    }
    // Legacy composite for selector 0 and resident-only selector 3: low entropy
    // (replicators) brightens, activity warms. This keeps the CPU snapshot path
    // coherent even though it has no resident B component.
    float life = clamp(1.0 - entropy, 0.0, 1.0);
    float3 base = mix(kBackground, float3(0x4E, 0x8E, 0x86) / 255.0, life * 0.65);
    float3 warm = mix(float3(0.0), float3(0xC9, 0x77, 0x67) / 255.0,
                      clamp(activity, 0.0, 1.0) * 0.35);
    return min(base + warm, float3(1.0));
}

// Shared restrained scalar palette for resident component views (selectors 1...3):
// muted blue -> teal -> muted red. It is intentionally not raw red, green, or
// blue, so single-channel views remain legible and comparable.
static float3 resident_scalar_palette(float value) {
    float t = isfinite(value) ? clamp(value, 0.0, 1.0) : 0.0;
    float3 low = float3(0x32, 0x4E, 0x67) / 255.0;
    float3 mid = float3(0x4E, 0x8E, 0x86) / 255.0;
    float3 high = float3(0xC9, 0x78, 0x67) / 255.0;
    if (t < 0.5) {
        return mix(low, mid, smoothstep(0.0, 1.0, t * 2.0));
    }
    return mix(mid, high, smoothstep(0.0, 1.0, (t - 0.5) * 2.0));
}

static float3 resident_composite_presentation(float3 residentRGB) {
    float3 inverted = 1.0 - clamp(residentRGB, float3(0.0), float3(1.0));
    float3 clamped = clamp(inverted, float3(0.20), float3(0.80));
    float luminance = dot(clamped, float3(0.2126, 0.7152, 0.0722));
    float3 result = mix(float3(luminance), clamped, 0.25);
    return clamp(result, float3(0.20), float3(0.80));
}

// Resident macro helper. Selector 0 presents the producer's RGB composite through
// a bounded low-chroma transform; selectors 1...3 view R/G/B scalar components
// through one shared palette. Out-of-range selectors snap to the composite.
static float3 resident_macro_color(float3 residentRGB, uint channel) {
    if (channel == 1) return resident_scalar_palette(residentRGB.r);
    if (channel == 2) return resident_scalar_palette(residentRGB.g);
    if (channel == 3) return resident_scalar_palette(residentRGB.b);
    return resident_composite_presentation(residentRGB);
}

static float3 blend_macro_micro(float3 macro, float3 micro, float microBlend) {
    float t = clamp(microBlend, 0.0, 1.0);
    if (t >= 1.0) return micro;
    return mix(macro, micro, t);
}

// Mutually exclusive structural edge classification. Program perimeter wins and
// receives only the stronger program alpha; interior byte boundaries receive only
// the weaker byte alpha, so close-grid compositing never double-darkens a pixel.
static uint grid_edge_kind(uint2 inBlk, float2 cellUV, float lineFrac) {
    bool onProgramEdge = (inBlk.x == 0u && cellUV.x < lineFrac)
                       || (inBlk.y == 0u && cellUV.y < lineFrac)
                       || (inBlk.x == 7u && cellUV.x >= 1.0 - lineFrac)
                       || (inBlk.y == 7u && cellUV.y >= 1.0 - lineFrac);
    if (onProgramEdge) return 1u;

    bool onInteriorByteEdge = (inBlk.x > 0u && cellUV.x < lineFrac)
                           || (inBlk.y > 0u && cellUV.y < lineFrac)
                           || (inBlk.x < 7u && cellUV.x >= 1.0 - lineFrac)
                           || (inBlk.y < 7u && cellUV.y >= 1.0 - lineFrac);
    return onInteriorByteEdge ? 2u : 0u;
}

struct VSOut {
    float4 pos [[position]];
};

// Fullscreen triangle, no vertex buffer: vids 0,1,2 → clip coords covering screen.
vertex VSOut soup_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VSOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float3 micro_byte_color(constant VizUniforms &u,
                               device const uchar *soup,
                               uint2 inBlk,
                               uint prog,
                               float2 cellUV) {
    uint byteIndex = inBlk.y * 8u + inBlk.x;   // reading order = tape order
    uchar bv = soup[prog * 64u + byteIndex];   // canonical programID * 64 + byteIndex
    float3 micro = palette_color(bv);

    // Structural boundaries, drawn BENEATH the glyph ink so glyphs stay legible. Both
    // fade factors are host-evaluated (LODModel, pinned by Swift tests); the shader
    // only draws them — it never re-derives the thresholds. A padded/background cell
    // never reaches here (the prog >= programCount guard returned), so a boundary can
    // never bleed onto padding. Line width ≈ 1 device pixel, in cell-fraction units.
    float lineFrac = min(0.5 / max(u.bytePx, 1e-4), 0.5);

    uint edgeKind = grid_edge_kind(inBlk, cellUV, lineFrac);
    if (edgeKind == 1u && u.programBoundaryBlend > 0.0) {
        micro = mix(micro, kProgramBoundaryColor,
                    kProgramBoundaryAlpha * u.programBoundaryBlend);
    } else if (edgeKind == 2u && u.byteBoundaryBlend > 0.0) {
        micro = mix(micro, kByteBoundaryColor, kByteBoundaryAlpha * u.byteBoundaryBlend);
    }

    // Opcode glyph ink on top of the boundaries.
    if (u.glyphBlend > 0.0) {
        float ink = glyph_ink(bv, cellUV) * u.glyphBlend;
        float lum = dot(micro, float3(0.299, 0.587, 0.114));
        float3 inkColor = lum > 0.45 ? kGlyphDarkInk : kGlyphLightInk;
        micro = mix(micro, inkColor, ink);
    }

    return micro;
}

fragment float4 soup_fragment(VSOut in [[stage_in]],
                              constant VizUniforms &u [[buffer(0)]],
                              device const uchar *soup [[buffer(1)]],
                              texture2d<float> metricTex [[texture(0)]]) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);

    // Framebuffer pixels (top-left origin, +y down) → soup byte coordinates.
    float2 frag = in.pos.xy;
    float2 b = float2(u.originByteX, u.originByteY) + frag / max(u.bytePx, 1e-4);

    float soupW = float(u.gridWidth * 8u);
    float soupH = float(u.gridHeight * 8u);
    if (b.x < 0.0 || b.y < 0.0 || b.x >= soupW || b.y >= soupH) {
        return float4(kBackground, 1.0);
    }

    uint2 cellByte = uint2(floor(b));
    uint col = cellByte.x / 8u;
    uint row = cellByte.y / 8u;
    uint prog = row * u.gridWidth + col;
    if (prog >= u.programCount) {              // padded, non-program cell
        return float4(kBackground, 1.0);
    }

    // ---- macro branch: one texel per program.
    float2 texUV = float2((float(col) + 0.5) / float(u.gridWidth),
                          (float(row) + 0.5) / float(u.gridHeight));
    float4 m = metricTex.sample(nearestSampler, texUV);
    float3 macro = legacy_metric_colormap(m.r, m.g, u.metricChannel);

    // ---- micro branch: per-byte color by stable (programID, byteIndex).
    uint2 inBlk = cellByte % 8u;
    float2 cellUV = fract(b);                  // position within this byte cell (0..1)
    float3 micro = micro_byte_color(u, soup, inBlk, prog, cellUV);

    float3 c = blend_macro_micro(macro, micro, u.microBlend);
    return float4(c, 1.0);
}

fragment float4 soup_resident_fragment(VSOut in [[stage_in]],
                                       constant VizUniforms &u [[buffer(0)]],
                                       device const uchar *soup [[buffer(1)]],
                                       texture2d<float> residentTex [[texture(0)]]) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);

    float2 frag = in.pos.xy;
    float2 b = float2(u.originByteX, u.originByteY) + frag / max(u.bytePx, 1e-4);

    float soupW = float(u.gridWidth * 8u);
    float soupH = float(u.gridHeight * 8u);
    if (b.x < 0.0 || b.y < 0.0 || b.x >= soupW || b.y >= soupH) {
        return float4(kBackground, 1.0);
    }

    uint2 cellByte = uint2(floor(b));
    uint col = cellByte.x / 8u;
    uint row = cellByte.y / 8u;
    uint prog = row * u.gridWidth + col;
    if (prog >= u.programCount) {
        return float4(kBackground, 1.0);
    }

    uint texWidth = residentTex.get_width();
    uint2 texel = uint2(prog % texWidth, prog / texWidth);
    float2 texUV = float2((float(texel.x) + 0.5) / float(texWidth),
                          (float(texel.y) + 0.5) / float(residentTex.get_height()));
    float3 macro = resident_macro_color(residentTex.sample(nearestSampler, texUV).rgb,
                                        u.metricChannel);

    uint2 inBlk = cellByte % 8u;
    float2 cellUV = fract(b);
    float3 micro = micro_byte_color(u, soup, inBlk, prog, cellUV);
    return float4(blend_macro_micro(macro, micro, u.microBlend), 1.0);
}

fragment float4 soup_resident_overview_fragment(VSOut in [[stage_in]],
                                                constant VizUniforms &u [[buffer(0)]],
                                                texture2d<float> residentTex [[texture(0)]]) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);

    float2 frag = in.pos.xy;
    float2 b = float2(u.originByteX, u.originByteY) + frag / max(u.bytePx, 1e-4);

    float soupW = float(u.gridWidth * 8u);
    float soupH = float(u.gridHeight * 8u);
    if (b.x < 0.0 || b.y < 0.0 || b.x >= soupW || b.y >= soupH) {
        return float4(kBackground, 1.0);
    }

    uint2 cellByte = uint2(floor(b));
    uint col = cellByte.x / 8u;
    uint row = cellByte.y / 8u;
    uint prog = row * u.gridWidth + col;
    if (prog >= u.programCount) {
        return float4(kBackground, 1.0);
    }

    uint texWidth = residentTex.get_width();
    uint2 texel = uint2(prog % texWidth, prog / texWidth);
    float2 texUV = float2((float(texel.x) + 0.5) / float(texWidth),
                          (float(texel.y) + 0.5) / float(residentTex.get_height()));
    float3 macro = resident_macro_color(residentTex.sample(nearestSampler, texUV).rgb,
                                        u.metricChannel);
    return float4(macro, 1.0);
}

// Layer-3 layout probe: reports sizeof/alignof/field offsets of VizUniforms as the
// Metal compiler actually laid them out. Word order matches VizLayout.hostProbeWords().
kernel void viz_layout_probe(device uint *out [[buffer(0)]],
                             uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    VizUniforms v = {};
    thread char *base = (thread char *)&v;
    out[0] = (uint)sizeof(VizUniforms);
    out[1] = (uint)alignof(VizUniforms);
    out[2] = (uint)((thread char *)&v.viewportPxX - base);
    out[3] = (uint)((thread char *)&v.viewportPxY - base);
    out[4] = (uint)((thread char *)&v.originByteX - base);
    out[5] = (uint)((thread char *)&v.originByteY - base);
    out[6] = (uint)((thread char *)&v.bytePx - base);
    out[7] = (uint)((thread char *)&v.microBlend - base);
    out[8] = (uint)((thread char *)&v.glyphBlend - base);
    out[9] = (uint)((thread char *)&v.gridWidth - base);
    out[10] = (uint)((thread char *)&v.gridHeight - base);
    out[11] = (uint)((thread char *)&v.programCount - base);
    out[12] = (uint)((thread char *)&v.metricChannel - base);
    out[13] = (uint)((thread char *)&v.flags - base);
    out[14] = (uint)((thread char *)&v.programBoundaryBlend - base);
    out[15] = (uint)((thread char *)&v.byteBoundaryBlend - base);
}
