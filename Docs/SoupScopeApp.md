# SoupScope — bounded visualization checkpoint

The macOS SwiftUI + Metal app that continuously runs the validated configurable soup and
visualizes it, from an aggregate program-level entropy/activity field down to individual byte
cells and opcodes, with continuous pan/zoom and a minimal live diagnostic HUD.

This checkpoint builds the visualization *around* the already-validated pieces and changes none
of them: the normative dynamic-scan Metal evaluator, the `counter-pcg-v1` RNG contract, stable
program identity, the shared eval ABI, `haltUnknown` accounting, and the deterministic
small-soup epoch loop (`SoupRunner`) are reused verbatim. The headless CLIs
(`bff-metal-soup`, `bff-metal-parity`, `bff-oracle`) and their exact deterministic outputs are
untouched.

## Architecture

```
SoupScopeCore (platform-independent, Linux-tested pure models)
  ProgramGrid            canonical 512×256 row-major layout; padded cells guarded
  Camera / CameraGeometry continuous pan/zoom transform (byte space ↔ pixels)
  LODModel               smoothstep macro↔micro and glyph blends (one source of truth)
  MetricNormalization    fixed, replay-stable activity/entropy → [0,1]
  OpcodeVisual / BFFOpcode ten-opcode classification + stable byte coloring (03 §5)
  AdaptiveBatcher        bounded ~10 ms/frame epoch batching (EMA + ramp + min/max)
  HUDModel               diagnostic counter/halt/shadow propagation
  RenderSnapshot         immutable per-program {64 bytes, activity, entropy}
  AppLaunchOptions       launch-arg parsing incl. --validation-seconds
  VizLayout / VizUniforms host side of the render uniform ABI (CSoupRender header)

SoupScopeApp (macOS only; Linux builds a stub)
  SharedMetalContext     the one owner of device + queue + evaluator + render pipeline
  AppModel               @MainActor driver: runner, batcher, camera, HUD, validation
  Renderer               MTKViewDelegate: bounded batch per frame → upload → draw
  SoupMetalView/SoupMTKView NSViewRepresentable MTKView + pan/zoom/key gestures
  ContentView / HUDView  ZStack shell + monospaced diagnostic overlay
  Shaders/SoupRender.metal fullscreen-triangle uber shader (macro/micro/glyph) + probe

CSoupRender                C header pinning the VizUniforms byte layout (3-layer contract)
```

**One shared GPU context (REQUIRED 1).** `SharedMetalContext` creates a single `MTLDevice` and
one `MTLCommandQueue`. `MetalBFFEvaluator(device:queue:)` (new designated initializer) uses that
exact device and queue; the renderer submits its render command buffers on the same queue. All
command encoding is serial on that one queue — no persistent queue, no scheduler, no indirect
command buffers, no background compute loop, no multi-queue work. Hazard tracking orders the
render pass against compute automatically.

**Bounded frame-driven batching (REQUIRED 2).** `AdaptiveBatcher` targets ~10 ms of simulation
per frame from a smoothed (EMA) ms-per-epoch measurement, clamped to conservative
`[minEpochs, maxEpochs]` bounds with a ramp limit so a slow sample can never schedule a runaway
catch-up. It changes only *how many* `runEpoch` calls happen between frames; the soup trajectory
is a pure function of `(seed, config)` and is identical under any batch partition (pinned by
`testTrajectoryIsIndependentOfBatchPartition`). Epochs advance only from the MTKView's
`draw(in:)`, i.e. only while the view is active. An evaluator error or a CPU-shadow mismatch
stops advancement and is shown in the HUD — never a spin/retry.

**Render data (REQUIRED 3).** Each frame `AppModel` builds an immutable `RenderSnapshot` — one
record per stable program ID with its 64 post-epoch bytes, integer activity (command steps), and
byte entropy. The renderer uploads a fresh soup buffer and a small aggregate texture
(`rgba32Float`, one texel per program: R = normalized activity, G = normalized entropy) each
frame. Because every GPU resource is allocated fresh from the immutable snapshot and retained by
its command buffer, there is no CPU/GPU lifetime race on the evolving soup.

**Normalization / clamping.** Fixed bounds, never auto-scaling (which would make replay look
nondeterministic): activity ÷ `stepBudget` clamped to `[0,1]`; entropy ÷ 6 clamped to `[0,1]`
(6 bits/byte is the hard maximum for a 64-byte window). Boundaries pinned by
`testNormalizationFixedBoundsAndClamping`.

**Pan/zoom and LOD (REQUIRED 4).** Program layout is the architecture's canonical **512×256
program coordinate canvas** (03 §1): stable program ID `i` maps to cell
`(column: i mod 512, row: i div 512)`, a fixed byte grid of 4096×2048 independent of the program
count. Configured modest soups fill the first row-major cells; every remaining cell through
512×256 is padding/background and never indexes the soup or the metric field (the renderer and
shader guard on `programCount`). Program counts above 512×256 (131072) are rejected at launch/
config validation. Camera fit/reset frames the *populated* extent (columns `0..<min(N,512)`,
rows `0..<⌈N/512⌉`) while the coordinates themselves stay canonical. Drag pans; scroll/pinch
zoom is exponential and cursor-anchored. `bytePx` (pixels
per byte cell) is the single LOD variable, clamped to `[minBytePx (fit), 96]`; the origin is
re-clamped so the soup stays within an overscroll margin. Every transform is finite (non-finite
gesture inputs are ignored). LOD is a continuous `smoothstep` crossfade — macro metric field
below `bytePx 1.5`, per-byte opcode color above, opcode glyph marks fading in over `12→18`.
Drawable size and backing scale are accounted for: the shader works in drawable pixels; gestures
convert AppKit points (bottom-left) to drawable pixels (top-left, y-down).

**Close-up bytes and opcodes (REQUIRED 5).** At close zoom every byte gets its deterministic
color; the ten opcodes are distinct hues (copy pair loudest) plus a compact 5×5 procedural glyph
mark — **not** a glyph/font atlas. Non-opcode bytes use a value-derived grayscale ramp. The
opcode byte values are the shared `BFFOp` constants (pinned by
`testExactlyTenOpcodesClassifyAndMatchSharedBytes`). The close-up path indexes bytes by
`(stable programID, byteIndex)` straight from the snapshot — never by shuffled pair position, so
there is no pair-position leakage.

**HUD (REQUIRED 6).** A monospaced overlay showing current epoch; last batch duration / epochs
per batch / ms-per-epoch; raw, no-op and command steps; halt mix (budget/pc-out/unmatched/
unknown); copy writes; cumulative CPU-shadow checked and mismatch counts; program count and
Metal device; and a visible error state. Diagnostic only — no charts, no profiling UI.

**New GPU ABI discipline.** `VizUniforms` is the only new buffer struct. Its layout is pinned in
`Sources/CSoupRender/include/SoupRenderShared.h` (C `_Static_assert`s), mirrored with
`static_assert`s in `SoupRender.metal`, and validated at runtime by the `viz_layout_probe`
kernel, which `SharedMetalContext.init` runs and compares against `VizLayout.hostProbeWords()`
before drawing anything.

## Build / run / test

```sh
swift build                        # whole package (Linux builds SoupScope as a stub)
swift test                         # all tests; Linux covers every pure model + epoch logic
swift run SoupScope                # macOS: interactive window (modest default soup)
swift run SoupScope --help         # print launch arguments
```

Launch arguments (all optional; defaults are a modest soup for interactive launch on M4 Max):

```
--seed N               run seed (default 45071)
--programs EVEN        soup size, positive & even, ≤ 131072 (default 1024)
--budget N             per-interaction step budget (default 8192)
--mutation-p32 N       mutate iff a uint32 draw < N; 0 disables
--variant noheads|bff  initial-state variant (default noheads)
--shadow-sample N      pairs CPU-shadowed per epoch (default 8; 'all' = every pair; 0 off)
--validation-seconds S render for S seconds, print one diagnostic line, then exit
```

Interactive controls: **drag** = pan · **scroll / pinch** = zoom (cursor-anchored) ·
**space** = pause/resume · **f** = fit whole soup · **m** = cycle metric channel
(life / activity / entropy).

To ship a double-clickable, ad-hoc-signed macOS bundle (conventional layout:
executable in `Contents/MacOS`, shaders flat in `Contents/Resources`), run
`Scripts/package-soupscope-app.sh`. Launch arguments still flow through
`open build/SoupScope.app --args …`. See **Docs/Packaging.md** for the layout,
signing, and how resource lookup stays correct both inside the `.app` (via
`Bundle.main`) and under `swift run`/`swift test` (via `Bundle.module`).

## Native validation (owning persona, on the Metal device)

`swift test` on Linux validates every pure model and the epoch orchestration (with the CPU
evaluator). The GPU render/epoch path is validated natively:

```sh
# macOS/Metal smoke tests (shared device/queue evaluator + GPU epochs; XCTSkip if none):
swift test --filter SharedContextEvaluatorTests
swift test --filter MetalSoupEpochTests
# The render pipeline, the SoupRender.metal shader compile, and the VizUniforms
# viz_layout_probe are compiled by `swift build` and exercised at runtime by the
# bounded validation launch below (SharedMetalContext.init runs the probe).

# Bounded reproducible validation run: renders live for N seconds, prints one diagnostic line,
# exits 0 (clean) / 1 (error, shadow mismatch, or no draw progress) / 2 (no Metal):
swift run SoupScope --validation-seconds 8
swift run SoupScope --programs 4096 --shadow-sample 16 --validation-seconds 8

# Interactive session for pan/zoom + HUD inspection:
swift run SoupScope
```

The `--validation-seconds` run advances/renders many live epochs, then prints e.g.
`validation outcome=ok requestedSeconds=8.0 completedDraws=… epochs=… lastBatchEpochs=… `
`msPerEpoch=… halt[…] copyWrites=… shadowChecked=… shadowMismatch=0 programs=1024 device="…" `
`error=none`. Verify multiple live epochs, growing HUD counters, `completedDraws` ≥ 1,
`shadowMismatch=0`, and no Metal validation/runtime errors.

**Finite even without a drawable.** Validation *requires* a window/drawable to succeed —
`outcome=ok` is reported only after the requested duration has elapsed **and** at least one
render command buffer has actually completed, and it is triggered from that buffer's completion
handler so the process never exits with a submission still in flight. It never hangs when a
drawable is unavailable: a one-shot, display-independent watchdog on the main run loop is the
finite backstop. If no render lands within `requestedSeconds + 2 s` (the grace deadline), the run
prints one deterministic line with `outcome=noDrawProgress` and exits nonzero rather than
blocking on a display callback that never comes. The watchdog is a validation-only timeout — it
advances no epochs and schedules no rendering, and it adds no extra queue, fence, or background
loop. An error or CPU-shadow mismatch fails immediately (`outcome=error` / `outcome=shadowMismatch`,
exit 1); no Metal device yields `outcome=noMetal`, exit 2. Watchdog and frame completion race into
exactly one diagnostic line and one termination path (the run latches its first verdict).

**Status: the GPU render/epoch path has NOT been exercised in-tree** (no Metal device or Swift
toolchain in the build environment). The commands above must be run on the Metal device to
confirm the render path, the HUD counters, and zero shadow mismatches.
