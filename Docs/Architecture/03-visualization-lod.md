# 03 — Visualization: the Zoom / LOD Scheme

One continuous pan/zoom surface over the whole soup. Zoomed out you see a field of
entropy/activity — the phase transition reads as a color shift sweeping the field. Zoomed in
you see individual programs as 8×8 blocks of bytes, each byte color-coded by opcode, with
glyphs appearing at the deepest zoom. No mode switch, no data export: the fragment shader reads
the live `soup` buffer and the GPU-reduced `metricTex` directly (02 §2) and crossfades between
them as a function of zoom. **The entire soup view is one draw call** (a fullscreen triangle)
at every zoom level.

## 1. Spatial mapping: an honest grid

The soup is a *set*, not a surface: with well-mixed pairing (default), program index carries no
neighborhood meaning. We still need a 2-D layout; the design position is:

- **Layout = program index, row-major, and it never changes.** Program `i` sits at grid cell
  `(i mod 512, i div 512)` on a 512×256 program grid (defaults; general: `W = 2^⌈log2(√N)⌉`,
  `H = N/W`). Each program renders as an **8×8 block of byte cells** (byte `j` at in-block
  `(j mod 8, j div 8)`, reading order = tape order), giving a global **byte grid of
  4096×2048**.
- Why fixed: stable identity. You can watch *this* program cell over minutes — see it get
  overwritten, see a replicator's copies appear at scattered fixed cells like popcorn. Any
  re-sorting per epoch would destroy temporal readability (everything would shimmer).
- What the macro view then means: since neighbors are unrelated, spatial averages over regions
  are unbiased random samples of the global distribution. So the zoomed-out view is *honestly
  uniform* pre- and post-transition, and its **global color level is the signal** (plus
  visible salt-and-pepper granularity as replicator clusters of identical low-entropy programs
  appear at random cells). That is genuinely how a well-mixed soup looks; we do not fake
  structure. The dramatic spatial imagery belongs to the spatial variant:
- **Spatial-2D variant** (01 §4): position is intrinsic (local pairing on this same grid, so
  the visualization needs zero changes) — replicator fronts, waves, and takeover domains
  appear as actual spatial structure. This is the demo mode; well-mixed is the science-default
  mode.
- **Sorted lens (optional, v1.5, explicitly labeled):** a toggle that renders through an
  indirection: an index texture `order[N]` recomputed at metrics cadence (CPU sorts program
  indices by a chosen key — steps, entropy — and writes a 512×256 `r32Uint` texture; the
  fragment shader looks up `prog = order[cell]` before fetching bytes). Turns the macro view
  into a live sorted census (replicators pool at one end and the boundary creeps). Off by
  default; the UI badges it "SORTED — position ≠ identity".

## 2. Coordinate systems and the zoom variable

- **Soup byte space**: continuous 2-D, x ∈ [0, 4096), y ∈ [0, 2048); integer lattice = byte
  cells; every 8×8-aligned block = one program.
- **View transform** (CPU-owned, `ViewportState` in 05): `originByte` (soup byte coordinate at
  the viewport's top-left) + `bytePx` (screen pixels per byte cell). Screen → soup:
  `b = originByte + pixel / bytePx`.
- **`bytePx` is the single LOD variable.** Range clamped to [`minBytePx`, 96], where
  `minBytePx` fits the whole soup with ~10 % margin (≈ 0.28 for 4096-wide soup in a 1280 px
  view). Program cell size on screen = `8 · bytePx`.
- Floats suffice everywhere: max coordinate 4096 with sub-pixel precision needs ~2⁻¹⁰ around
  2¹² — comfortably inside float32. (At the 16M-program scale the byte grid is 32768 wide —
  still fine. Keep `originByte` as `double` on the CPU, convert per frame.)

## 3. LOD levels (thresholds in `bytePx`)

| LOD | `bytePx` | What renders | Source |
|---|---|---|---|
| **L0 macro** | < 0.5 | per-program metric field, colormapped; mip-filtered when >1 program/px | `metricTex` + mips |
| **L0→L2 blend** | 0.5 – 1.5 | crossfade macro ↔ byte colors (`smoothstep` on `bytePx`) | both |
| **L2 byte colors** | 1.5 – 12 | each byte = flat color from opcode palette; program grid lines fade in from `bytePx ≥ 3` (i.e. program cell ≥ 24 px) | `soup` + palette LUT |
| **L3 glyphs** | ≥ 12 (fully opaque by 18) | opcode glyph / hex overlay composited on the byte color; byte gridlines from `bytePx ≥ 24`; selection & head-position overlays | + glyph atlas |

All thresholds are constants in one Swift/MSL-shared table — expect to tune them by eye on
device. There are no discrete "levels" in the renderer, just these blend functions of
`bytePx`; zooming is perfectly continuous.

## 4. The macro metric: what, and where it's computed

`metricTex` (rgba16Float, 512×256 = one texel per program, full mip chain) is written by
`bff_program_metrics` once per command buffer (02 §8):

| Ch | Metric | Computation | Why |
|---|---|---|---|
| R | **Activity**: `steps/8192` of last interaction | free from `progStats` | ops-per-run is the paper's second emergence signal; post-transition it saturates |
| G | **Copy intensity**: cross-half `.`/`,` executions, normalized | free from `progStats` | replication *is* cross-tape copying; the most specific "life" signal |
| B | **Byte entropy**: order-0 Shannon entropy of the program's 64 bytes, /8 | GPU, O(64²) equal-count trick, exact cᵢ semantics in 02 §8 | Brotli-proxy at program granularity; 64-byte window caps at 6/8 = 0.75: random ≈ 0.75, replicators ≪ |
| A | **Budget-halt indicator**: 1 if last halt == BUDGET, else 0 | free from `progStats` | scalar 0/1 survives mips/EMA as "fraction at budget" — the phase signal; see note below |

Design choices and their reasons:

- **Shannon entropy, not a compression proxy, per program.** Real compression per region on
  GPU is not worth building; order-0 entropy at 64-byte granularity plus the *global* CPU
  Brotli/zlib metric (01 §5, plotted in the HUD) covers both scales. Per-*region*
  Brotli on CPU is a deferred nicety (06).
- **Aggregation = mip box-filter of per-program metrics.** Averaging entropies is not the
  entropy of the union — a region of diverse-but-individually-uniform programs reads "low".
  That is acceptable and even desirable here: "mean within-program entropy" is exactly the
  replicator signal (replicators are internally repetitive), and cross-program diversity is
  already captured by the activity/copy channels and the global histogram. Hierarchical
  region histograms are explicitly deferred (06).
- **No categorical values in the texture.** The texture is linearly mip-filtered (and EMA'd),
  and interpolated halt *codes* {1,2,3} are garbage — the earlier draft's `halt/3` channel
  would have shown exactly that at macro zoom. Resolution (02 §8): channel A carries the 0/1
  budget-halt indicator, whose box-filtered average is the meaningful "fraction of this region
  halting on budget". The exact per-program halt reason is served by the other path that
  already exists — direct `progStats` reads (Shared) in the tooltip/inspector (§8) — so no
  second non-mipped texture is needed.
- **Temporal smoothing:** raw per-epoch metrics flicker (each program interacts with a new
  random partner every epoch). `bff_program_metrics` applies an EMA against a small
  `float4 metricEMA[N]` device buffer — bound as `buffer(6)` in the 02 §8 signature —
  (`out = mix(new, prev, α)`, α = `SimParams.emaAlpha`) before writing the texture. Default
  `α = 0.85` ≈ 1-second memory at 60 updates/s; exposed as a HUD slider via `setLive` (05 §6).
- **Colormapping happens in the fragment shader**, not in the texture: the user switches the
  macro channel (Entropy / Activity / Copy / Halt / **Life composite**) instantly without
  recomputing anything. Life composite (default): luminance from (1 − entropy), warm overlay
  from copy intensity — dead random soup = dim noise, replicators = bright warm blooms.
  Scalar channels use a shader-baked viridis polynomial; the Halt view colormaps channel A
  (budget fraction) with a diverging map — cold "dies fast" ↔ warm "runs to budget".

## 5. The micro palette: 256 byte values → color

Requirements: the 10 commands must be individually identifiable and *pop* against data; the
copy pair `.` `,` must be the loudest (copy loops are what you're hunting for); paired ops read
as pairs; the 246 data values must show structure (gradients, repeats) without competing.

```
byte 0   null        #101014  (near-black, the "vacuum")
'<' 0x3C head0 left  #2FB8AC  teal        '>' 0x3E head0 right #45E0D2  light teal
'{' 0x7B head1 left  #3D6FE0  blue        '}' 0x7D head1 right #6FA0FF  light blue
'+' 0x2B increment   #E08A3D  orange      '-' 0x2D decrement   #C24B4B  red
'.' 0x2E write→h1    #46E052  green       ',' 0x2C read←h1     #E046C8  magenta
'[' 0x5B loop open   #E0D040  yellow      ']' 0x5D loop close  #B8A81E  dark yellow
data (246 values)    grayscale ramp: sRGB luminance 0.13 + 0.17 · (value/255), slight blue tint
```

Encoded as a 256×1 `rgba8Unorm` texture (or a `constant half3[256]` array — texture chosen so
palettes are swappable assets). Rationale: hue = operational family (teal/blue = head motion
per head, warm = arithmetic, green/magenta = the copy pair, yellow = control), lightness =
direction within the pair. Data stays low-chroma, low-lightness so a replicator — dense in
commands — literally glows against the noise floor. Colors are placeholders to validate for
contrast/CVD once rendering exists (06).

## 6. Glyph atlas (L3)

One 512×512 `r8Unorm` texture, 16×16 grid of 32×32 px cells, cell index = byte value.
Generated **once at startup on the CPU** with CoreText/CoreGraphics (SF Mono): commands get
their character (`< > { } + - . , [ ]`) drawn large; byte 0 gets `·`; the other 245 data
values get their two hex digits drawn small. Coverage-only (alpha); the shader composites
white-or-black ink (chosen by byte-color luminance) over the byte color, faded in over
`bytePx` 12→18. Sampled with linear filtering + implicit derivatives; at 32 px/cell source
resolution glyphs stay crisp past `bytePx` = 32; that's plenty (max zoom 96 uses minor
upscaling, acceptable for a monospaced glyph — bump the atlas to 64 px cells if it bothers,
it's still only 2 MiB).

No instanced quads: a glyph is just another texture fetch inside the same fragment shader
(atlas UV = `(byteValue cell origin + fract(b)) / 16`). Instancing would mean rebuilding an
instance buffer every frame from GPU-resident data for zero benefit.

## 7. The uber fragment shader

Vertex stage: a single fullscreen triangle, no vertex buffer. All logic is in the fragment:

```c
typedef struct {                 // BFFShared.h
    simd_float2 viewportPx;      // drawable size
    simd_float2 originByte;      // soup byte coord at top-left pixel
    float  bytePx;               // pixels per byte cell (the LOD variable)
    float  emaAlpha;             // debug/HUD
    uint32_t metricChannel;      // 0 entropy 1 activity 2 copy 3 budget-halt fraction 4 life
    uint32_t gridWidthProgs;     // 512
    uint32_t soupProgs;          // N
    uint32_t selectedProg;       // 0xFFFFFFFF = none
    uint32_t flags;              // bit0 sortedLens, bit1 showHeads, ...
} VizUniforms;
```

```metal
fragment half4 soup_fragment(
    float4 fragPos [[position]],
    constant VizUniforms&  u         [[buffer(0)]],
    device const uchar*    soup      [[buffer(1)]],
    texture2d<half>        metricTex [[texture(0)]],   // + mips
    texture1d<half>        palette   [[texture(1)]],
    texture2d<half>        glyphs    [[texture(2)]],
    texture2d<uint>        order     [[texture(3)]],   // sorted lens; identity when off
    sampler linearMip [[sampler(0)]], sampler nearest [[sampler(1)]])
{
    const float2 b = u.originByte + fragPos.xy / u.bytePx;          // soup byte coords
    const float2 soupSize = float2(u.gridWidthProgs * 8.0,
                                   (u.soupProgs / u.gridWidthProgs) * 8.0);
    if (any(b < 0.0) || any(b >= soupSize)) return BG_COLOR;

    // ---- macro branch (also computed in blend band)
    half3 macro = 0;
    const float progPx = 8.0 * u.bytePx;
    if (u.bytePx < 1.5) {
        float lod = max(0.0, -log2(progPx));                        // ≥1 texel per pixel
        half4 m = metricTex.sample(linearMip, (b / 8.0) / (soupSize / 8.0), level(lod));
        macro = apply_colormap(m, u.metricChannel);
    }

    // ---- micro branch
    half3 micro = 0;
    if (u.bytePx >= 0.5) {
        uint2 cell  = uint2(b) / 8;
        uint  prog  = cell.y * u.gridWidthProgs + cell.x;
        if (u.flags & VIZ_SORTED) prog = order.read(cell).r;
        uint2 inBlk = uint2(b) % 8;
        uchar byte  = soup[(ulong)prog * 64 + inBlk.y * 8 + inBlk.x];
        micro = palette.sample(nearest, (byte + 0.5h) / 256.0h).rgb;

        if (u.bytePx >= 12.0) {                                      // glyph overlay
            float2 cellUV = fract(b);
            float2 atlasUV = (float2(byte % 16, byte / 16) + cellUV) / 16.0;
            half ink = glyphs.sample(linearMip, atlasUV).r
                     * (half)smoothstep(12.0, 18.0, u.bytePx);
            micro = mix(micro, luminance(micro) > 0.45h ? half3(0.02h) : half3(0.95h), ink);
        }
        micro = apply_gridlines(micro, b, u.bytePx);   // program lines ≥3, byte lines ≥24
    }

    half3 c = mix(macro, micro, (half)smoothstep(0.5, 1.5, u.bytePx));
    c = apply_selection(c, u, b);                       // ring around selectedProg
    return half4(c, 1.0h);
}
```

Cost check: worst case per fragment ≈ one buffer byte fetch + 2–3 texture samples + a little
math; at 4K that's ~8 M fragments — trivially fine at 120 Hz, and neighboring fragments hit
the same cache lines (soup reads are 2-D coherent by construction). The blend band pays both
branches; it's narrow.

The same pipeline renders the **minimap** (always-on 192 px inset, own `VizUniforms` with
whole-soup framing + a viewport rectangle overlay drawn by the SwiftUI layer). Two draw calls
total per frame.

## 8. Pan / zoom / inspect interaction

- **Zoom**: pinch (`MagnifyGesture`) and scroll wheel, **anchored at the cursor**:
  `origin' = b_cursor − pixel_cursor / bytePx'`. Exponential response
  (`bytePx *= exp(k·Δ)`), then clamp to [`minBytePx`, 96], with `origin` re-clamped so the
  soup stays on screen (allow ~25 % overscroll margin).
- **Pan**: drag; also two-finger scroll. Inertia via a critically-damped spring on
  `(originByte, log bytePx)` — animate in the render loop on the CPU, ~5 lines, feels native.
- **Double-click**: animate zoom to the clicked *program* framed at `bytePx = 14` (glyph
  level). **Shift-double-click**: back to full soup.
- **Click / hover**: CPU inverts the transform → `(prog, byteOffset)`; hover shows a tooltip
  (program id, byte value, opcode name); click sets `selectedProg` (highlight ring) and fills
  the **Inspector** (05 §6): 64-byte hex+glyph dump read straight from the Shared `soup`
  buffer, `progStats` (steps / halt / copyWrites), and a "Test self-replication" button
  (01 §5). Because `soup` is Shared, inspection is a `memcpy` of 64 bytes — no GPU round-trip.
- **Head/pc overlay (deferred, v1.5+):** showing head positions requires the interpreter to
  dump final `(pc, h0, h1)` per pair into `progStats.flags`-adjacent fields — cheap, but only
  meaningful with a "step one epoch" workflow. Listed in 06.

## 9. What "watching the transition" looks like (acceptance sketch)

Well-mixed, defaults, Life composite at L0: start = dim uniform noise. Around onset, be honest
about what the physics gives you: pairing is a fresh global shuffle every epoch, so a
replicator's copies land at **random indices** — a bright cell does not "grow" or multiply in
place, and there are no spreading specks or fronts. What you actually see is scattered bright
cells whose *count* rises exponentially — statistically uniform popcorn densifying into a
field-wide brightening/warming until the field saturates (the EMA keeps individual cells from
strobing as they're overwritten and re-randomized). The macro story is the **global level and
rate of change**, corroborated by the HUD time-series (compressed size cliff + mean-steps
spike, 04/05). The compelling *spatial* imagery — replicator fronts, waves, takeover domains
expanding in place — belongs exclusively to the opt-in 2-D variant (§1, 01 §4); don't promise
it for the well-mixed default in demos or UI copy (06 R6). Zoom into any bright cell at L3 and
you should literally read a copy loop (`[`,`.`,`>`,`}`-dense block) — that end-to-end moment
is the v1 milestone's definition of done (06).
