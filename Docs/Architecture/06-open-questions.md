# 06 — Open Questions, Risks, Device Checklist, v1 Milestone

## 1. Deferred design decisions

| # | Decision | Default shipped | Revisit when |
|---|---|---|---|
| D1 | **Jump-table vs dynamic-scan bracket semantics** under mid-run self-modification (01 §3, 02 §5). Tables freeze matching at interaction start; the normative semantics rematch live. | jumpTable | **Decision procedure is now specified: 01 §7.3** — known-replicator lineages under both modes + remap-event counts, run at v1.5 (02 §10). Random-pair diffs are not sufficient (self-bracket-modification is rare pre-transition). If any lineage diverges, dynamicScan becomes the default (or the rebuild is tightened); record the measured remap rate here. This is the highest-priority validation in the project. |
| D2 | Exact cubff alignment: the six pinned tags of **01 §7.4** (opcode bytes, init pc/heads, mutate order, step counting, loop re-entry landing, `CheckSelfRep` accounting) | assumed answers as tabled in 01 §7.4 | Resolved at stage v0.5 (02 §10): the one-time golden-vector grounding (01 §7.1) forces each tag to be confirmed or corrected against cubff source. Record findings here. Full bit-parity of *our* production RNG trajectories with cubff remains a non-goal. |
| D3 | Spatial pairing: random local perfect matching vs cubff's neighbor list (01 §4) | perfect matching | If spatial-mode results are compared against the paper's spatial runs. Pairing generator is pluggable. |
| D4 | CPU Fisher–Yates ring vs GPU Feistel-permutation pairing (would delete the CPU from the epoch loop entirely) | CPU ring | If profiling shows pairing-ring underrun stalls (04 §7 item 1). A 4-round Feistel over 17-bit indices keyed by epoch is the drop-in. |
| D5 | Compression metric: Compression framework zlib vs vendored Brotli (the paper's metric) | zlib | If absolute compressed-size curves must match the paper. Vendoring google/brotli (C, no deps) is the one sanctioned external dependency. |
| D6 | Hazard-tracked shared queue vs untracked resources + `MTLFence`/events | tracked | If render-stall or compute-bubble evidence appears (04 §7 item 1). The escape-hatch procedure is sketched step-by-step in 05 §4 (untrack only `soup`/`metricTex`; `memoryBarrier` between dispatches; `updateFence` at CB end, `waitForFence(before: .fragment)` in the render encoder). |
| D7 | Hierarchical *region* histograms / per-region CPU Brotli for a truer macro entropy (03 §4) | per-program entropy + mips | If the macro view proves misleading in practice. |
| D8 | Head/pc final-position overlay, single-interaction step-debugger in the Inspector (03 §8) | absent | v1.5 — needs interpreter to export `(pc, h0, h1)`; trivial addition to `ProgStats` (widen to 16 B). |
| D9 | Sorted lens (03 §1) and self-rep checker (01 §5) | absent in v1 | v1.5, after the milestone. |
| D10 | Palette exact values + colorblind validation; LOD thresholds (03 §3, §5) | as specced | Tune by eye on device; treat 03's numbers as starting points. |

## 2. Risks

- **R1 — Semantics (D1) invalidates perf work.** Mitigation: v0 oracle implements *both*
  modes from day one; the 02 §10 diff harness covers both; run the D1 experiment before
  building v2.
- **R2 — Occupancy collapse from threadgroup staging.** 16 KiB/threadgroup may cap residency
  at 2 groups/core and starve latency hiding; the fix (`kStageTapes=false`) is prebuilt. This
  is measurement item M3, not a redesign risk.
- **R3 — Divergence worse than modeled post-transition.** If lane utilization craters once
  replicators dominate (all-BUDGET runs actually *reduce* duration variance, so this is
  expected to improve — but verify), v2 order is already staged (02 §9).
- **R4 — HUD/render starving compute** via hazard serialization (D6). Detectable by 04 §7
  item 1; bounded by design (≤2 CBs, ~10 ms); escape hatch sketched in 05 §4.
- **R5 — The transition simply not appearing** due to an interpreter bug that random-program
  statistics don't catch (e.g. bracket edge case that only matters to replicators). Mitigation:
  the validation chain (01 §7): cubff golden-vector grounding catches semantic drift, and the
  §7.3 replicator experiment exercises exactly the bracket edge cases random statistics miss;
  plus the golden-run test (05 §8.3).
- **R6 — Well-mixed macro view underwhelming** (uniform field by design — copies land at
  random indices, so the signal is field-wide brightening, not in-place growth; 03 §1, §9).
  Mitigation is already in-design: Life composite + popcorn effect + HUD series; spatial
  variant is the demo mode. Set expectations in docs/UI copy.
- **R7 — ProfCounters 32-bit overflow via batcher misprediction at the transition.** The
  overflow cap (05 §4.1) predicts next-batch mean steps from the *last drain*, but the
  transition grows mean steps ~10× (≈130 → >4096), potentially inside one batch. In-design
  mitigations: ×2 safety factor, the transition guard (mean grew >1.5× between drains ⇒
  assume worst-case 8192), the ×4 ramp limit, and worst-case assumption at cold start. The
  residual failure is one corrupted HUD/stats window, self-healing at the next drain and
  incapable of touching simulation state (counters are write-only from kernels, 01 §6). If
  corrupted windows show up in practice: halve the ramp factor, raise the safety factor, or
  count `totalSteps` in units of 32 (simd-sum shifted) to buy 5 bits of headroom.

## 3. Verify-on-device checklist (M-series facts assumed, not proven)

| # | Check | Assumed | How |
|---|---|---|---|
| M1 | `threadExecutionWidth == 32` for all PSOs | yes | assert at PSO build (a divergent-heavy kernel can report 16 on some GPUs) |
| M2 | `maxThreadgroupMemoryLength ≥ 32 KiB`; PSO `maxTotalThreadsPerThreadgroup` for `bff_interpret` (register pressure signal) | 32 KiB / ≥ 512 | log at startup; compiler report in Xcode |
| M3 | Staging vs no-staging (`kStageTapes`) epochs/s, pre- and post-transition | staging wins pre, unclear post | built-in A/B + HUD (04) |
| M4 | Threadgroup size sweep {64, 128, 256} × staging | 128 | headless CLI sweep |
| M5 | `MTLCounterSet` availability: `timestamp` at `.atStageBoundary` on M4 Max | supported | query `device.counterSets` at startup; fall back per 04 §6 |
| M6 | Actual lane-steps/s and achieved bandwidth vs the 42 MiB/epoch model (04 §4) | 5–20 G lane-steps/s | HUD after v1 |
| M7 | Xcode GPU-capture counter names for occupancy/limiter/SIMD-utilization in current Xcode | as listed 04 §7 | one capture session; update 04 |
| M8 | `generateMipmaps` cost on rgba16Float 512×256 per CB | negligible | pass-time split (04 §6) |
| M9 | Atomic drain cost at profile level 1 vs 0 | < 3 % | calibrate action (04 §1) |
| M10 | 120 Hz frame time of the uber-shader at 4K, worst case (blend band + glyphs) | ≪ 8 ms | Metal HUD / os_signpost |

## 4. Recommended v1 milestone

**"See it come alive, and zoom into the organism."** Smallest build that demonstrates the
phase transition with a working zoom:

In scope: CPUOracle + diff harness; kernels `bff_mutate`, `bff_build_jump_tables`,
`bff_interpret` (level-1 profiling, staging on, jumpTable brackets, `noheads`, well-mixed CPU
pairing ring); `bff_program_metrics` + mips; renderer with L0/L2/L3 and crossfades, palette,
glyph atlas, pan/zoom, click-inspect (hex dump only); HUD with epochs/s, mean steps, halt mix,
lane util, zlib curve; Run/Pause/Step/Reset/seed/mutation controls; headless CLI.

Out of scope (v1.5+): v2 scheduling (02 §9), spatial variant, sorted lens, self-rep checker,
snapshots, minimap, charts panel beyond sparklines, Advisor automation (print the numbers;
human applies 04 §7).

**Acceptance:** on the M4 Max at defaults, from launch: random soup renders and zooms
smoothly at 60+ fps at every level; sim sustains > 300 epochs/s pre-transition; within ~10–60
wall-clock minutes the HUD shows the zlib cliff + mean-steps spike + halt-mix flip; the L0
field visibly brightens/shifts; zooming into a bright cell at L3 shows a readable copy loop;
GPU output still diffs clean against the oracle. That single session validates the science
path, the render path, and the profiling path end-to-end.
