# DRAFT 2 — Changes from review passes

All seven scope items closed. Per-file summary, then the item-by-item closure map.

## Per-file changes

**00-overview.md**
- Hardware-table row on threadgroup memory no longer asserts "leaving occupancy headroom" as
  fact: now "*targeting* 2 resident threadgroups/core … a target to be verified", pointing at
  02 §6 / 06 M3 — consistent with 02's "#1 thing to measure".

**01-bff-spec.md**
- §3: halt-reason enum block marked **informative copy**; `BFFShared.h` (02 §1) declared the
  single owning definition.
- New **§7 "Validation chain (golden vectors)"**: §7.1 one-time cubff→oracle grounding
  (pinned commit, fixed seed, bit-identical soup + histogram at epochs {128, 1024, 16384},
  `cubffCompat` RNG/pairing mode in the oracle, mismatch-bisection path, interaction-level
  fallback); §7.2 continuous oracle→GPU bit-identical diff; §7.3 the D1 decision procedure
  (both bracket modes in the oracle, remap-event counter, known-replicator ×13 seeds ×4
  generations experiment, explicit decision rule); §7.4 the six cubff-alignment tags pinned in
  a table with assumed answers + where to confirm, flagging loop re-entry (tag 5) as the one
  most entangled with self-modification.
- §6 closing bullet links the parity non-goal to the one place bit-exactness *is* demanded
  (§7.1).

**02-gpu-execution.md**
- §1: `SimParams` gains `float emaAlpha` (metrics EMA now has a defined data path).
- §6: "same kernel body survives into v2 unchanged" claim replaced (only the outer
  pair-acquisition loop changes; interior survives). Threadgroup tape is now a
  **`uint4`-typed** `[[threadgroup(0)]]` argument (guaranteed 16-byte alignment for the
  vectorized stage-in/out); stage-in/out code updated to use the `uint4` view.
- §8: `bff_program_metrics` signature and full body given — `metricEMA` added as
  `buffer(6)` (now agrees with 03 §4); O(64²) entropy loop written out with exact `cᵢ`
  semantics (`cᵢ` = count of bytes equal to `prog[i]`; `H = (1/64)Σ log2(64/cᵢ)`, bits/byte,
  range [0, 6], stored as H/8 so max 0.75); **categorical-mip bug fixed**: channel A is now a
  0/1 budget-halt indicator (mips average it into "fraction at budget" — the phase signal);
  categorical halt reason explicitly excluded from the texture, served per-program via
  `progStats` reads instead. Choice and reason stated.
- §9.1 rewritten: **per-simdgroup batch claiming** — first active lane claims exactly 32
  pairs via one `atomic_fetch_add`, `simd_broadcast_first` of the base, lane i runs base+i,
  all 32 lanes stay on the batch until all halt, then claim together. Explicit statement of
  why per-lane claiming breaks the `simd_all` invariant and how batch claiming preserves it;
  code sketch included; old "survives unchanged" claim explicitly retracted.
- §10 build order: new **v0.5 grounding stage** (cubff golden vectors + six tags); v0 row now
  requires both bracket modes + `cubffCompat`; v1/v1.5/v2 exit criteria wired to 01 §7.

**03-visualization-lod.md**
- §4: channel-A row is now the budget-halt indicator; new bullet "No categorical values in
  the texture" explaining the mip-garbage bug and the chosen resolution; EMA bullet names
  `buffer(6)` and `SimParams.emaAlpha` (α default 0.85, set via `setLive`); colormap prose no
  longer claims "3 categorical colors" — Halt view colormaps the budget fraction; entropy row
  notes the 0.75 ceiling and points at 02 §8 for exact semantics.
- §7: `metricChannel` comment updated (3 = budget-halt fraction).
- §9: acceptance sketch rewritten honestly for well-mixed pairing — copies land at random
  indices, so the signal is exponentially densifying popcorn / field-wide brightening, **not**
  in-place multiplying specks; spatial imagery explicitly reserved for the opt-in 2-D variant.

**04-profiling.md**
- §2: counter-overflow note points at the batcher spec (05 §4.1).
- §3: MSL note on `simd_ballot` returning `simd_vote`; all popcounts now
  `popcount((uint)(ulong)simd_ballot(...))`. `PROF_PAIR_DONE` halt histogram written out in
  full: three ballots (BUDGET / PC_OUT / UNMATCHED), which atomic each feeds,
  `haltCounts[0]` documented as reserved/never written (enum starts at 1). Register-reset
  semantics of `r_*` clarified (works under v2 batch claiming). RMW count corrected 6 → 8.
- §4: bandwidth model rewritten as an explicit per-term table (stats term = `16·P` = 8 B ×
  2 programs/pair; adds the previously missing jt-build soup read and pairs reads) — the
  terms now genuinely total the ≈ 42 MiB/epoch headline, which is unchanged.
- §8: "every variant prebuilt / toggling costs nothing" restricted to profile levels;
  staging/brackets explicitly not live.

**05-app-architecture.md**
- §1: **`SharedGPU` is now a concrete Swift struct** (device, queue, soup, metricTex,
  progStats, histogram, `SimParams` value snapshot, generation counter), with what's
  deliberately excluded and why; **reset/restore quiesce handshake shown as code**: async
  `pause()` awaits `inflightCBs == 0`, renderer pauses and awaits its last render CB, then
  the synchronous rebuild/swap runs with provably nothing in flight, then re-adopt + resume;
  `generation` as the stale-handle assert.
- §3: PSO set enumerated exactly — 12 possible interpret combinations; **3 prebuilt**
  (profileLevel {0,1,2} × current staging/brackets — the only live-switchable interpret
  axis); other combos compiled on demand inside `reset()` and cached (≤ 12 ever); fixed PSOs
  listed; one-line reasons given. `reset`/`restore` API made `async` to match the handshake.
- §4: `04 §7.1` dangling citation fixed to "04 §7 item 1"; **untracked-resources + MTLFence
  escape hatch sketched in 4 steps** (untrack only soup/metricTex, memoryBarrier between
  dispatches, updateFence at CB end, waitForFence(before:.fragment) in render; CPU reads
  unchanged) so 06 D6 is actionable. `setBytes` size corrected (~40 B).
- **New §4.1: the adaptive batcher, fully specified** — `AdaptiveBatcher` with
  `record()`/`epochsForTarget(ms:cap:stepCap:)`; EMA of GPU-ms-per-epoch with α = 0.2;
  cold start E = 1 + worst-case predictor; floor 1 / ceiling 1024 / ramp ×4 per CB; the
  explicit overflow invariant **E · predictedMeanSteps · P < 2³¹** with adaptive predictor
  `min(8192, 2 × lastDrainMean)` (safety ×2), a transition guard (mean grew >1.5× between
  drains ⇒ assume 8192 — a static predictor is wrong because post-transition mean is ~10×
  pre-transition), and worked numbers for both regimes. `drain()` now calls
  `batcher.record(...)`; `Config` gains `pairsPerEpoch`.
- §6: zero-cost-switch claims scoped to exactly the prebuilt/uniform axes; reset row notes
  on-demand PSO compiles.
- §8: testing items 1–2 wired to the 01 §7 chain (grounding gate, re-run after every
  optimization).

**06-open-questions.md**
- D1: now points at the concrete decision procedure (01 §7.3) and states random-pair diffs
  are insufficient. D2: reframed around the six pinned tags (01 §7.4), resolved at v0.5.
- D4/D6/R4: dangling "04 §7.1" → "04 §7 item 1"; D6 row references the 05 §4 fence-procedure
  sketch. R5 mitigation wired to 01 §7. R6 notes the random-index/brightening reality.
- **New R7**: ProfCounters 32-bit overflow via batcher misprediction at the transition —
  mitigations (safety factor, transition guard, ramp, cold-start worst case), residual blast
  radius (one HUD window, never simulation state), and escalation options.

## Scope-item closure map

| Item | Closed at |
|---|---|
| 1. Adaptive batcher spec + 2³¹ inequality + adaptive predictor + 06 entry | 05 §4.1 (spec, inequality, predictor, cold start, floor/ceiling/ramp, worked numbers); 04 §2 pointer; 06 R7 |
| 2. v2 "survives unchanged" → per-simdgroup batch claiming | 02 §9.1 (rewritten, code + invariant argument); 02 §6 intro line fixed |
| 3. Validation chain (cubff→oracle→GPU, both bracket modes, replicator experiment, six tags) | 01 §7.1–7.4; 02 §10 (v0.5 stage + wired exit criteria); 05 §8.1–2; 06 D1/D2 |
| 4. Metrics kernel unified (metricEMA in signature), entropy spelled out, categorical-mip fix | 02 §8 (signature + body + A-channel decision); 03 §4 (agreeing prose, buffer(6), no-categoricals bullet), §7 comment |
| 5. SharedGPU concrete struct + quiesce handshake | 05 §1 (struct + handshake code); §3/§5 API harmonized (`reset`/`restore` async, `adopt`) |
| 6. PSO count vs live-switchability | 05 §3 (exact set: 3 prebuilt, 12 max, rule stated); 05 §6 table; 04 §8 |
| 7. Nits: 16·P + 42 MiB reconciled (04 §4 term table); halt histogram written out (04 §3); simd_ballot casts (04 §3); uint4 threadgroup tile (02 §6); halt-enum single owner (01 §3 / 02 §1); "04 §7.1" citations fixed + fence sketch (05 §4, 06 D4/D6/R4); 00 occupancy tone (00 hardware table); 03 §9 well-mixed prose | as listed |

## Consistency check

Final grep confirmed: T = 64 / tape = 128 / N = 131,072 / budget = 8,192 consistent across
files; `bff_program_metrics` signature (with `metricEMA` at `buffer(6)`) agrees between 02 §8
and 03 §4; `SimParams.emaAlpha` referenced consistently (02 §1, 03 §4, 05 §6); `SharedGPU`
members match between 05 §1 and the Renderer API; no remaining "04 §7.1", "~6 combinations",
`halt/3` channel, or bare-uint `simd_ballot` references.

Flagged for on-device / cubff-source verification (unchanged policy, now concentrated):
the six tags of 01 §7.4, cubff's RNG/pairing internals for `cubffCompat` (01 §7.1), and the
06 §3 M-checklist.
