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
    uint  metricChannel;  // 40 0 activity, 1 entropy, 2 life composite
    uint  flags;          // 44 reserved
};                        // size 48, align 4

static_assert(sizeof(VizUniforms) == 48, "VizUniforms must be 48 bytes");
static_assert(alignof(VizUniforms) == 4, "VizUniforms must be 4-byte aligned");

constant float3 kBackground = float3(0.02, 0.02, 0.03);

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
    float3(0x2F, 0xB8, 0xAC) / 255.0, // '<'
    float3(0x45, 0xE0, 0xD2) / 255.0, // '>'
    float3(0x3D, 0x6F, 0xE0) / 255.0, // '{'
    float3(0x6F, 0xA0, 0xFF) / 255.0, // '}'
    float3(0xE0, 0x8A, 0x3D) / 255.0, // '+'
    float3(0xC2, 0x4B, 0x4B) / 255.0, // '-'
    float3(0x46, 0xE0, 0x52) / 255.0, // '.'
    float3(0xE0, 0x46, 0xC8) / 255.0, // ','
    float3(0xE0, 0xD0, 0x40) / 255.0, // '['
    float3(0xB8, 0xA8, 0x1E) / 255.0, // ']'
};

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
    if (b == 0) return float3(0x10, 0x10, 0x14) / 255.0; // null vacuum
    float lum = 0.13 + 0.17 * (float(b) / 255.0);        // data ramp, slight blue tint
    return min(float3(lum * 0.90, lum * 0.96, lum * 1.12), float3(1.0));
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

static float3 colormap(float activity, float entropy, uint channel) {
    if (channel == 0) {                       // activity: warm ramp
        return mix(float3(0.05, 0.02, 0.10), float3(1.0, 0.75, 0.20),
                   clamp(activity, 0.0, 1.0));
    } else if (channel == 1) {                // entropy: cool ramp
        return mix(float3(0.02, 0.05, 0.12), float3(0.55, 0.85, 1.0),
                   clamp(entropy, 0.0, 1.0));
    }
    // life composite: low entropy (replicators) brightens, activity warms.
    float life = clamp(1.0 - entropy, 0.0, 1.0);
    float3 base = float3(life * 0.6);
    float3 warm = float3(1.0, 0.5, 0.15) * clamp(activity, 0.0, 1.0);
    return min(base + warm, float3(1.0));
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
    float3 macro = colormap(m.r, m.g, u.metricChannel);

    // ---- micro branch: per-byte color by stable (programID, byteIndex).
    uint2 inBlk = cellByte % 8u;
    uint byteIndex = inBlk.y * 8u + inBlk.x;   // reading order = tape order
    uchar bv = soup[prog * 64u + byteIndex];
    float3 micro = palette_color(bv);

    if (u.glyphBlend > 0.0) {
        float2 cellUV = fract(b);
        float ink = glyph_ink(bv, cellUV) * u.glyphBlend;
        float lum = dot(micro, float3(0.299, 0.587, 0.114));
        float3 inkColor = lum > 0.45 ? float3(0.02) : float3(0.95);
        micro = mix(micro, inkColor, ink);
    }

    // Faint program-block outline once byte cells are large, to reveal the 8×8
    // structure without a hard mode switch.
    if (u.bytePx >= 3.0 && (inBlk.x == 0u || inBlk.y == 0u)) {
        float edge = 0.25 * u.microBlend;
        micro = mix(micro, float3(0.0), edge * 0.15);
    }

    float3 c = mix(macro, micro, clamp(u.microBlend, 0.0, 1.0));
    return float4(c, 1.0);
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
}
