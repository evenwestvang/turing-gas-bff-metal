# Benchmarking — measurement-first harness for the small-soup evaluator

This is a **measurement** layer around the already-validated small-soup epoch loop
([MetalSoupSlice.md](MetalSoupSlice.md)). It changes no evaluator semantics, no RNG, no
app default, no kernel, and no pairing/mutation/scatter — it only times the existing run
and reports entropy kinetics. The `bff-metal-bench` CLI is separate from the interactive
`SoupScope` app and from `bff-metal-soup`; running it never alters their behavior.

Everything here uses the full **8192-step** budget by default, exactly as production does.

## What it measures, and how honestly

| Number | Source | Honesty note |
|---|---|---|
| **GPU ms/epoch** | `MTLCommandBuffer.gpuEndTime − gpuStartTime` | *Command-buffer* GPU time, one command buffer per epoch. Not a per-kernel or per-encoder breakdown, not a CPU profile. `nil` (and the run fails, exit 3) if the hardware reports no usable timestamp. |
| **Epoch wall ms/epoch** (`wallMsPerEpoch`) | monotonic clock **strictly enclosing `runEpoch`** | The epoch execution wall, and the sole basis for raw simulation throughput. It encloses mutation, pairing, packing, GPU dispatch + wait + readback, scatter, counter reduction, the post-epoch FNV-1a digest, and the CPU shadow (if on). The benchmark runs `runEpoch` with **per-program metric collection disabled** (`MetricsPolicy.disabled`), so the per-program entropy/activity scan is **not** in this wall — in raw mode it is not computed at all, and in kinetics mode per-program entropy comes from the external `SoupSignals.measure` timed separately (below). The digest is the one unavoidable O(N) pass inside the wall; counters are O(pairs). |
| **Host residual ms/epoch** | `epoch wall − GPU` | *Everything in the epoch wall that is not GPU command-buffer time.* An attribution, **not** a CPU profiler: it is a single lump and does **not** isolate planning, allocation, marshalling, encode, readback, scatter, counter/program-metric reduction, the shadow, or queue latency. |
| **Signal analysis ms (total)** (`signalAnalysisMsTotal`) | monotonic clock around `SoupSignals.measure`, **outside** the epoch wall | Host analysis cost of the sampled entropy/transition/LZ metrics. Whole-run total. **`null` under `--no-samples`** — that mode computes no signals, so there is nothing to time (honest "not computed", never a fabricated 0). |
| epochs/s, pairs/s, raw/command steps/s | measured epochs ÷ measured **epoch** wall | Warmup epochs excluded; signal analysis never mixed in. |
| halt buckets, copy writes | `EpochCounters` reduced from the GPU records | The existing science counters, summed over measured epochs. Reduced inside `runEpoch`, so part of the epoch wall. |
| max RSS (`maxRSSBytes`) | `getrusage(RUSAGE_SELF).ru_maxrss` | Process **peak / high-water** RSS (bytes; normalized from KiB on Linux, native bytes on Darwin). It is cumulative for the whole process/matrix — **not** cell-exclusive and **not** current resident memory. Sampled at three points per cell (pre-cell, post-`SoupRunner` allocation, post-cell) and reduced to the **maximum available** reading (`PeakRSSSampler`); `null` only if every reading was unavailable. One ceiling for the whole run, best-effort. |

Output is one JSON document `{ "schemaVersion": 3, "results": [ … ] }` on stdout; all
diagnostics and warnings go to stderr. One `results[]` entry per matrix cell. Pipe to `jq`.

**Schema 3** (from 2): paper-aligned high-order-complexity fields (see
"Paper-aligned observability" below). Per sample: `brotliBitsPerByte`,
`highOrderComplexity`. Per result: `initialBrotliBitsPerByte`,
`initialHighOrderComplexity`, `finalBrotliBitsPerByte`, `finalHighOrderComplexity`,
and `highOrderComplexityCrossings` — an array of first-crossing records shaped
`{complexity, crossed, observedEpoch, previousMeasuredEpoch, crossingEpochCensoring,
wallMsToCross, gpuMsToCross}`. The observation interval is encoded explicitly so
machine-readable output cannot imply the true crossing epoch is exact: the true
crossing lies in the half-open interval `(previousMeasuredEpoch, observedEpoch]`,
and `crossingEpochCensoring` is `"exact"` (every epoch in the interval was
measured — always the case at measurement cadence 1, or when the crossing is
first observed at epoch 0), `"interval"` (Brotli was measured sparsely; the true
crossing is somewhere in the interval but not pinpointed), or `"notCrossed"`
(threshold not reached by the last measurement; `observedEpoch` is `null` and
`previousMeasuredEpoch` holds the last measured epoch). When `--brotli` is on but
no `highOrderComplexity` observation exists (e.g. the linked Brotli is not 1.1.0
so the injected closure returns `nil`), `highOrderComplexityCrossings` is `[]` —
never a list of false "not crossed" records. Per config:
`highOrderComplexityThresholds`. **All are `null`/`[]` unless `--brotli` is on
and the linked Brotli is exactly 1.1.0** — the same explicit-null discipline as
schema 2 (keys always present; `null` = "not computed", never a fabricated 0).
Schema 2's key set is otherwise unchanged; `H0` itself is the already-present
whole-soup entropy (`initial/finalEntropyBitsPerByte`, per-sample
`entropyBitsPerByte`). Custom `init(from:)` on `BenchmarkConfig` and
`BenchmarkResult` accepts schema-2-shaped JSON missing every new Brotli/config/
crossing key: optional scalar metrics default to `nil`, arrays/thresholds to `[]`,
and no existing field's meaning is changed.

**Schema 2** (from 1): entropy-kinetics fields (`initialEntropyBitsPerByte`,
`finalEntropyBitsPerByte`, `finalDeltaH`, `finalMeanProgramEntropyBitsPerByte`,
`finalTransitionRate`, `finalCompressionProxyRatio`) are **nullable**. Every documented
optional field is encoded as an **explicit JSON `null`** when unavailable — the keys are
**always present**, never dropped (a stable key set consumers can rely on). Under
`--no-samples` those kinetics fields, `signalAnalysisMsTotal`, `deviceName` (if unknown),
and the GPU-timing fields (`gpuMsPerEpoch`, `hostResidualMsPerEpoch`, `gpuBusyFraction`)
are `null`; `thresholdCrossings` and `samples` are explicit empty arrays `[]`. Added
`signalsAnalyzed` (always present bool — the reliable "were kinetics computed?" flag) and
`signalAnalysisMsTotal` (nullable ms, `null` under `--no-samples`). Nested optionals
follow the same rule: an un-crossed `thresholdCrossings[]` entry still carries
`"epoch": null`, `"wallMsToCross": null`, `"gpuMsToCross": null`.

Exit codes: `0` ok · `1` shadow mismatch or generic GPU/runtime error · `2` Metal
unavailable — **no Metal on the platform *or* no system default device** (nothing ran) ·
`3` ran but GPU timestamps were unavailable · `64` bad arguments (includes any malformed
seed). A missing default device is normalized to `2`; a real compile/layout/allocation
failure stays a distinct `1`.

## Warmup

The **first** dispatch of a size pays one-time costs (buffer allocation, pipeline
residency, first-touch paging). `--warmup N` runs `N` epochs and discards their timing;
timing/throughput aggregate only the following `--epochs` measured epochs. The entropy
trajectory is deterministic regardless, so entropy kinetics and ΔH thresholds span the
whole run (warmup included) — warmup epochs are real evolution, they are only excluded
from *timing*. `--warmup 1` is enough for steady-state throughput at these sizes; use
`--warmup 2` for the largest soups if the first measured epoch still looks like an outlier.

## Initialization modes (`--init`)

| Mode | Fill | Order-0 H start | Use |
|---|---|---|---|
| `uniform` *(default)* | `BFFRandom.initialSoup` (unchanged) | ~7.8 bits/byte | Production-representative throughput. |
| `constant` | all-zero, inert | **0** | Entropy floor; growth is driven purely by mutation. |
| `opcode` | small alphabet = the ten BFF opcodes | `≤ log2(10) ≈ 3.32` | Low-entropy **and executable** from epoch 0 — the intended regime for watching entropy *increase*. |

`uniform` is byte-for-byte the existing path; the pinned digests are unaffected by this
work. The low-entropy modes are additive and only chosen when requested.

## Structure metrics (deterministic, cheap — not complexity)

Order-0 Shannon entropy is order-blind. Two structure-sensitive signals accompany it:

- **`transitionRate`** — fraction of adjacent bytes that differ, `[0,1]`. Falls when runs
  / copied regions appear even while entropy stays high. O(n), computed on the
  signal-measurement cadence (every epoch by default; only the `--signal-interval` epochs
  when sparse), never under `--no-samples`.
- **`compressionProxyRatio`** — a finite-window greedy LZ77 **token count ÷ byte count**,
  `(0,1]`; lower ⇒ more repetition. It is a reproducible *proxy* for compressibility, not
  a real codec's ratio and **not Kolmogorov complexity** (which is uncomputable). It is
  O(n·window) — the one expensive signal — so it is **opt-in** (`--compression`) and even
  then computed only on sampled epochs + the final epoch, never every epoch. Off by
  default and never under `--no-samples`. `null` means "not computed", not "incompressible".

Read all three as relative, same-alphabet, same-length signals.

> **The LZ proxy is not the paper's compression metric.** `compressionProxyRatio` is
> a codec-free, unit-cost token *ratio* — deterministic and explainable, but **not**
> Brotli and **not** the paper's number. The paper-aligned metric is a separate,
> opt-in path (`--brotli`) that calls **real Brotli 1.1.0 quality 2**; see
> "Paper-aligned observability" below. Never treat the LZ proxy as paper-equivalent.

### Metric controls and hidden-cost avoidance

- **`--no-samples`** is throughput mode: it skips **all** sample-only metric computation —
  the external whole-soup and per-program entropy scans, the adjacent-transition scan, and
  the LZ proxy (no `SoupSignals.measure` call is made at all) **and** the in-epoch
  per-program `ProgramMetric` construction (`MetricsPolicy.disabled`) — not merely their
  JSON emission. So the epoch wall carries **zero** hidden analysis cost. In this mode the
  kinetics fields and `signalAnalysisMsTotal` are `null`, `thresholdCrossings`/`samples`
  are `[]`, and `signalsAnalyzed` is `false`. **Mandatory metrics that remain** in this
  mode: the per-epoch `EpochCounters` (halt buckets, step/copy counts — reduced inside
  `runEpoch` from the GPU result records the kernel already returns, so no extra soup scan)
  and the final `finalDigest` (FNV-1a over the soup, computed inside `runEpoch`). Both are
  part of the epoch wall by construction and are not sample metrics.
- **In-epoch program metrics.** `SoupRunner.runEpoch(using:metrics:)` gates the derived
  per-program `ProgramMetric` (order-0 entropy + activity) behind an explicit policy that
  **defaults to enabled**, so the interactive app, the oracle, and `bff-metal-soup` are
  unchanged. The benchmark always passes `.disabled` because it never consumes
  `EpochReport.metrics`; `metrics` is therefore empty **only** under that explicit
  opt-out. Disabling changes nothing else — the mutation → pair → evaluate → scatter
  sequence, the counters, the CPU shadow, the committed soup, and the digest are
  byte-for-byte identical (pinned by a metrics-enabled-vs-disabled equivalence test, with
  an invocation counter proving the scan is genuinely skipped).
- **`--compression`** opts the LZ proxy in; bounded to the sample cadence so it stays
  affordable even at 131072 programs. Ignored (with a stderr note) under `--no-samples`.
  Under a sparse `--signal-interval` it stays independent and never broadens: the LZ
  proxy runs only where an emission point (`--sample-interval`) and a measured epoch
  (`--signal-interval`) coincide — i.e. a subset of what a per-epoch run would compute —
  and never on an epoch where signals were not measured at all. The final epoch is always
  both, so `finalCompressionProxyRatio` is still populated when `--compression` is on.

## Entropy kinetics

Per run the harness reports absolute mean Shannon entropy (whole-soup bits/byte, and the
existing per-program mean), ΔH from the initial soup, and — for each `--delta-h-thresholds`
level — the **epoch** and **wall/GPU ms** at which ΔH first reached it (epoch is the
deterministic figure; the ms includes warmup). `--sample-interval N` emits a per-epoch
kinetics sample every `N` epochs (plus the final), bounding output at large soups.

### Two independent cadences: `--sample-interval` vs `--signal-interval`

These are **distinct** knobs and are not interchangeable:

- **`--sample-interval N`** — *JSON emission* cadence. A per-epoch kinetics `samples[]`
  entry is written every `N` epochs (plus the final epoch), from among the epochs that
  carry a signal measurement. It decides which measured epochs are *reported* — and, when
  `--compression` is on, it is **also the LZ-proxy measurement cadence**: the O(n·window)
  proxy is computed only at epochs that are both an emission point and a measured signal
  epoch, so `--sample-interval` bounds that one expensive signal. It does not change the
  cheap entropy/transition signals (those follow `--signal-interval`). Default `1`.
- **`--signal-interval N`** — *signal-measurement* cadence (cadence-only signal
  analysis). It decides at which epochs the entropy/transition (and, when `--compression`
  is on, LZ) signals are **measured at all**. Default `1` = every epoch, the exact
  per-epoch trajectory. With `N > 1` signals are measured at, and only at:
  1. **epoch 0**, before any mutation/evaluation (the ΔH reference — always measured);
  2. **every `N`th completed epoch**;
  3. **the final completed epoch**, even when the total is not divisible by `N`.

  It is a pure measurement gate: skipping a measurement never touches the evaluator, the
  RNG, the soup, the counters, or the digest — a sparse run's `finalDigest` and all
  counters are byte-for-byte identical to a per-epoch or `--no-samples` run. It is
  ignored under `--no-samples` (nothing is measured then) with a stderr note.

**Interaction.** A `samples[]` entry is emitted for a **completed** epoch only when it is
*both* an emission point (`--sample-interval`) *and* an epoch that carries a measurement
(`--signal-interval`). With a sparse signal interval the reported samples are therefore
the intersection of the two cadences over the completed epochs, **always including the
final completed epoch** (which is both by construction). **Epoch 0 is never a `samples[]`
entry**: it is the pre-mutation reference, measured before the loop and reported through
the `initial*` fields (`initialEntropyBitsPerByte` and the ΔH baseline), not as a
`samples[]` row. The signal cadence is a **CLI-only** control: it changes which epochs
carry samples but adds **no** JSON key (the schema-2 key set, including
`config.sampleInterval`, is unchanged).

**ΔH thresholds require per-epoch signals.** Exact ΔH-threshold epochs can only be
resolved from the full per-epoch trajectory, so `--delta-h-thresholds` is **incompatible
with a sparse `--signal-interval` (`> 1`)** and the combination is rejected as a usage
error (exit `64`) with a message naming both options. Use `--signal-interval 1` (the
default) for ΔH thresholds, or drop `--delta-h-thresholds` for cadence-only analysis.

## Paper-aligned observability (Brotli 1.1.0 high-order complexity)

`--brotli` opts in to the **paper's** high-order-complexity metric — the one the
reference implementation (paradigms-of-intelligence/cubff) logs as `higher_entropy`.
It is measured with **real Brotli 1.1.0 quality 2**, byte-for-byte the cubff call, and
is entirely separate from the deterministic LZ proxy above.

### What it reports

| Field | Definition | cubff name |
|---|---|---|
| **H0** | whole-soup order-0 Shannon entropy, bits/byte | `h0` |
| **Brotli bpb** (`brotliBitsPerByte`) | `brotli_size * 8 / soupBytes` — the whole soup compressed under Brotli 1.1.0 q2, as bits per input byte | `brotli_bpb` |
| **High-order complexity** (`highOrderComplexity`) | `H0 − brotli_bpb` | `higher_entropy` |
| **Threshold crossing** (`highOrderComplexityCrossings`) | first epoch/time high-order complexity reaches each `--high-order-thresholds` level (default **`>= 1`**) | — |

H0 is the already-reported whole-soup entropy (`initial/finalEntropyBitsPerByte`), so
`--brotli` adds only the Brotli reading and the derived complexity + crossings.

### Exact Brotli provenance and parameters (pinned)

| | |
|---|---|
| Encoder | Brotli **1.1.0**, tag `v1.1.0` = `ed738e842d2fbdf2d6459e39267a633c4a9b2f5d` |
| Call | `BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC, n, soup, &size, buf)` |
| Parameters | quality **2**, lgwin **24** (`BROTLI_MAX_WINDOW_BITS`), mode **generic**, whole soup in one shot, output sized by `BrotliEncoderMaxCompressedSize(n)` |
| Provenance gate | `BrotliEncoderVersion() == 0x1001000`; the metric is emitted **only** against 1.1.0 — any other encoder yields `null` (honest "not computed"), never a wrong number |

These match cubff's measurement exactly. The upstream source references
(paradigms-of-intelligence/cubff, pinned commit
`f212e849027c98fcf4b242eccfb5fed435223e23`; see `Docs/CubffGrounding.md`):

| Metric | cubff name | Upstream source |
|---|---|---|
| **H0** (whole-soup order-0 Shannon entropy, bits/byte) | `h0` | `common_language.h` — computed over the whole soup each measured epoch |
| **Brotli bpb** (`brotli_size * 8 / soupBytes`) | `brotli_bpb` | `common_language.h` — `BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC, …)` over the whole soup; `brotli_size` = the returned `*encoded_size` |
| **High-order complexity** (`H0 − brotli_bpb`) | `higher_entropy` | `common_language.h` — arithmetic `h0 - brotli_bpb`, logged per measured epoch |

**Runtime version gating is not cryptographic tag authentication.** The
`BrotliEncoderVersion() == 0x1001000` check detects a library that *reports* 1.1.0
but does not verify the library binary against the pinned tag's hash — a
maliciously patched Brotli that lies about its version would pass the gate. The
fixture generator (`Tools/brotli-fixtures/generate.sh`) remains **tag-pinned**: it
clones `v1.1.0` from `https://github.com/google/brotli`, hard-checks the commit
SHA `ed738e842d2fbdf2d6459e39267a633c4a9b2f5d`, and refuses to emit fixtures from
any other checkout, so the authoritative compressed-byte-count fixtures are
reproducible from source regardless of what the system library reports.

**Fixtures.** `Tests/BrotliMetricsTests/Fixtures/brotli-1.1.0-q2.json` records eight
small literal inputs (empty, constant runs, an opcode cycle, an iota block, SplitMix64
pseudo-random blocks) with their authoritative 1.1.0 q2 compressed byte counts.
Regenerate with `Tools/brotli-fixtures/generate.sh` (clones the pinned tag, rebuilds,
refuses to emit unless it linked 1.1.0). `BrotliMetricsTests` asserts our encoder call
reproduces every count. For these small inputs the counts are byte-identical under
Brotli 1.0.9 and 1.1.0 (verified), so the fixture test passes on either host; the
divergence appears only at soup scale (see `Docs/CubffGrounding.md`), which is exactly
why the *runtime* metric is pinned to 1.1.0.

### Cadence, cost, and the two knobs it shares

Compressing the whole soup is O(soup); `--brotli` therefore runs on **exactly the
LZ-proxy cadence** — only at an epoch that is *both* a signal-measurement point
(`--signal-interval`) and a JSON emission point (`--sample-interval`), plus the epoch-0
reference and the always-both final epoch — and **outside the measured epoch wall**
(timed into `signalAnalysisMsTotal`, like every other sampled signal). It never runs
every epoch and never inside `runEpoch`, so simulation throughput is unaffected. It is
ignored (stderr note) under `--no-samples`.

`--high-order-thresholds L` records the first-crossing epoch/time for each level
(default `1`). Because Brotli is sparse by construction, the crossing epoch is
resolved **to the Brotli measurement cadence**, not necessarily the exact epoch.
Each crossing record encodes the observation interval explicitly:
`previousMeasuredEpoch` (the preceding Brotli-measured epoch, or `nil` at the
initial epoch-0 reading), `observedEpoch` (the first measured epoch reaching the
threshold), and `crossingEpochCensoring` (`"exact"` when every epoch in the
interval was measured — always at cadence 1; `"interval"` when Brotli was
measured sparsely; `"notCrossed"` when the threshold was never reached). This
ensures machine-readable output cannot imply the true crossing epoch is exact
when it is not. (Contrast `--delta-h-thresholds`, which needs the per-epoch
entropy trajectory and so is rejected under a sparse `--signal-interval`.)

### Determinism and isolation

Enabling `--brotli` changes **nothing** about the simulation: the Brotli reading is a
read-only pass over the committed soup outside the epoch wall, so soup evolution, RNG,
pairing, mutation, scatter, counters, digest, and shadows are byte-for-byte identical
to a run without it (pinned by `PaperComplexityHarnessTests.testBrotliDoesNotAlterTrajectory`).

### Build dependency

`--brotli` requires linking Brotli. The `bff-metal-bench` executable and the
`BrotliMetrics`/`BrotliMetricsTests` targets depend on the `CBrotli` system library
(`pkgConfig: "libbrotlienc"`, providers `apt libbrotli-dev` / `brew brotli`) — the
oracle, the Metal evaluator, and the app do **not**. Install `libbrotli-dev` (Linux)
or `brew install brotli` (macOS). For the *paper* number specifically the linked
Brotli must be **1.1.0**; on any other version the run still completes with the brotli
fields reported as `null`.

### Honest limitations

- **Statistical, not exact-trajectory, parity with cubff.** Our simulator keeps its
  `counter-pcg-v1` RNG; cubff uses SplitMix64 counters with pair-indexed mutation
  (2^30 denominator) and a biased-modulo Fisher–Yates shuffle (`Docs/CubffGrounding.md`).
  So fixed-seed whole-soup trajectories are **not** bit-identical to published cubff
  runs, and neither are the per-epoch H0 / Brotli-bpb / high-order-complexity values.
  Acceptance is **statistical** — the *shapes* (H0 rising, high-order complexity
  crossing 1, replicator onset) should agree in distribution — not exact numeric parity
  at a given epoch. The compression *definition* is exact (same encoder, same
  parameters); only the soup that is fed to it comes from a different RNG.
- **Crossing epoch is cadence-resolved** and the observation interval is encoded
  explicitly in each crossing record (`previousMeasuredEpoch`, `observedEpoch`,
  `crossingEpochCensoring`) — see above.
- **1.0.9 ≠ 1.1.0 at scale**: the metric is pinned to 1.1.0 for this reason.

## Self-replicator counting (`CheckSelfRep`): feasibility report

The paper's fourth observable is `number_selfreps` (`main.cc`), the count of programs
that pass cubff's `CheckSelfRep`. This phase does **not** implement it; this is the
written feasibility assessment the task calls for.

**Semantics are already pinned.** `Docs/CubffGrounding.md` §6 documents `CheckSelfRep`
from the pinned cubff source exactly: `kNumIters = 13` independent trials; per-trial
noise `noise[j] = SplitMix64(local_seed ^ SplitMix64((iter+1)*64 + j)) % 256` with
`local_seed = SplitMix64(num_programs*seed + index)`; `kNumExtraGens = 4` feed-forward
generations (5 evaluations/trial, budget 8192); scoring where a byte position counts
if some trial value is shared by ≥ 4 of 13 trials (first-half positions must also equal
the original program byte); program score `min(res[0], res[1])`; classified a
replicator at score **≥ 5**. The per-epoch seed is `seed(epoch)`. So the evaluator work
is fully specified and reuses the oracle's existing `.dynamicScan` interpreter.

**What makes it bounded and source-compatible.** The trial evaluation is exactly the
interpreter we already ground against cubff (fixed 128-byte tape → final tape), so no
new evaluator semantics are needed. The 13/4/≥5 constants and the scoring are small,
pinned, and testable against curated tapes.

**What blocks a faithful drop-in now — two real costs:**

1. **RNG.** The noise stream and per-epoch seed are cubff **SplitMix64**, not our
   `counter-pcg-v1`. To reproduce cubff's *exact* replicator counts we would need a
   `cubffCompat` SplitMix64 noise source (a new RNG surface, explicitly out of scope for
   this observability phase — 01 §7.1). Without it, `CheckSelfRep` is still well-defined,
   but its counts are **statistical, not exact** — the same honesty caveat as the Brotli
   metric, for the same RNG reason.
2. **Compute.** `CheckSelfRep` is 13 × 5 = 65 evaluations *per program*. At 131072
   programs that is ~8.5M budgeted 128-byte runs **per measured epoch** — many times the
   cost of one simulation epoch. On the CPU oracle it is affordable only at small `N` or
   over a sampled subset; a full-soup pass wants a GPU kernel.

**Recommendation: defer to a dedicated follow-up, do not fold into this phase.** When
implemented it should (a) preserve **13 trials, 4 extra generations, and threshold 5**
exactly per §6; (b) run only at the reviewed **sparse cadence**, outside the epoch wall,
behind its own `--self-rep` flag (never on by default); (c) be labeled **statistical,
not exact-trajectory** parity unless/until a `cubffCompat` SplitMix64 noise stream is
added; and (d) ship with curated fixtures pinning the scoring on known
self-replicating / non-replicating tapes. Implementing it here would exceed a bounded
observability change and would ship an exact-count claim the RNG cannot yet support.

## Native commands (Apple M4 Max)

Build once in release; `-c release` matters for host-side throughput numbers.

```sh
swift build -c release
```

### Shadow-off throughput across sizes

Pure throughput (no CPU shadow). Run each size on its own so RSS is that size's ceiling:

```sh
for N in 1024 4096 16384 65536 131072; do
  swift run -c release bff-metal-bench \
    --programs $N --seed 1 --warmup 2 --epochs 20 \
    --shadow-sample 0 --no-samples \
    > bench-uniform-$N.json
done
```

Or the whole matrix in one document (samples off keeps it compact):

```sh
swift run -c release bff-metal-bench \
  --programs 1024,4096,16384,65536,131072 --seeds 1,2,3 \
  --warmup 2 --epochs 20 --shadow-sample 0 --no-samples \
  > bench-matrix.json
jq -r '.results[] | [.config.programCount, .config.seed, .epochsPerSecond, .gpuMsPerEpoch, .hostResidualMsPerEpoch, .pairsPerSecond] | @tsv' bench-matrix.json
```

### Random vs low-entropy kinetics

Uniform (production-representative) kinetics with ΔH timing:

```sh
swift run -c release bff-metal-bench \
  --programs 65536 --seed 1 --warmup 2 --epochs 200 \
  --init uniform --delta-h-thresholds 0.05,0.1,0.25 --sample-interval 10 \
  > kinetics-uniform.json
```

Low-entropy growth from an executable floor (expect a clear positive ΔH). Add
`--compression` to also record the LZ proxy on the sampled epochs (off by default):

```sh
swift run -c release bff-metal-bench \
  --programs 65536 --seed 1 --warmup 2 --epochs 200 \
  --init opcode --delta-h-thresholds 0.25,0.5,1.0 --sample-interval 10 --compression \
  > kinetics-opcode.json

swift run -c release bff-metal-bench \
  --programs 65536 --seed 1 --warmup 2 --epochs 200 \
  --init constant --delta-h-thresholds 0.25,0.5,1.0 --sample-interval 10 \
  > kinetics-constant.json
```

Cadence-only signal analysis at a very large soup: measure entropy only every 25 epochs
(plus epoch 0 and the final epoch) to bound host analysis cost, with no ΔH thresholds
(they need per-epoch signals and are rejected under a sparse `--signal-interval`):

```sh
swift run -c release bff-metal-bench \
  --programs 131072 --seed 1 --warmup 2 --epochs 200 \
  --init opcode --signal-interval 25 \
  > kinetics-sparse.json
```

### Paper high-order complexity (Brotli 1.1.0) — native, requires brotli 1.1.0

Both commands need the linked Brotli to be **1.1.0** (`brew install brotli`; verify
with `bff-metal-bench --brotli … 2>&1 | grep -i brotli` — a version warning means the
paper fields will be `null`). Brotli runs on the sample cadence only, outside the epoch
wall. **Not executed in this repo** — they are native Apple-silicon runs.

Bounded 131K single-cell probe (one soup size, sparse cadence so Brotli stays cheap):

```sh
swift run -c release bff-metal-bench \
  --programs 131072 --seed 1 --warmup 2 --epochs 200 \
  --init uniform --brotli --signal-interval 25 --sample-interval 25 \
  --high-order-thresholds 1 \
  > paper-probe-131k.json
jq '.results[] | {h0:.finalEntropyBitsPerByte, brotliBpb:.finalBrotliBitsPerByte,
  highOrder:.finalHighOrderComplexity, cross:.highOrderComplexityCrossings}' paper-probe-131k.json
```

Full 16,384-epoch study (the paper's horizon). Keep the two cadences aligned and sparse
so Brotli is measured a bounded number of times over the run:

```sh
swift run -c release bff-metal-bench \
  --programs 131072 --seeds 1,2,3 --warmup 2 --epochs 16384 \
  --init uniform --brotli --signal-interval 64 --sample-interval 64 \
  --high-order-thresholds 0.5,1,2 \
  > paper-study-16384.json
```

`--delta-h-thresholds` is deliberately absent from both: it needs the per-epoch entropy
trajectory and is rejected under a sparse `--signal-interval`. High-order-complexity
crossings are resolved to the Brotli cadence (documented above). Interpret against the
honest limitations: parity with cubff is **statistical**, not exact-trajectory, because
of the `counter-pcg-v1` vs SplitMix64 RNG difference.

### Shadow-on correctness spot checks

Correctness, not speed: re-run a sample of pairs on the CPU oracle each epoch. Any
divergence prints to stderr and exits `1`. Keep the sample small and sizes modest — this
is a spot check, not a throughput run.

```sh
swift run -c release bff-metal-bench \
  --programs 4096 --seeds 1,2,3 --warmup 1 --epochs 10 \
  --shadow-sample 64 --no-samples \
  > spotcheck.json
# 'all' shadows every pair (heaviest, small sizes only):
swift run -c release bff-metal-bench \
  --programs 1024 --seed 7 --warmup 1 --epochs 8 --shadow-sample all
jq '.results[] | {n:.config.programCount, checked:.shadowCheckedTotal, mismatch:.shadowMismatchTotal}' spotcheck.json
```

## Recommended baseline

One reproducible headline number plus a correctness gate:

```sh
swift build -c release
# throughput baseline (shadow off)
swift run -c release bff-metal-bench \
  --programs 1024,4096,16384,65536,131072 --seed 1 \
  --warmup 2 --epochs 20 --shadow-sample 0 --no-samples > baseline.json
# correctness gate (must exit 0)
swift run -c release bff-metal-bench \
  --programs 4096 --seed 1 --warmup 1 --epochs 10 --shadow-sample 64 --no-samples
```

Determinism check: `finalDigest` for a given `(size, seed, init, budget, mutation, variant)`
is machine-independent — the same tuple must print the same digest on any host.

If `bff-metal-bench` exits `3`, the GPU did not report command-buffer timestamps on that
host; wall timing is still valid but GPU/host attribution is not. Investigate before
trusting GPU numbers; `--allow-missing-gpu-timing` accepts wall-only results deliberately.
