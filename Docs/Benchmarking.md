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
| **Epoch wall ms/epoch** (`wallMsPerEpoch`) | monotonic clock **strictly enclosing `runEpoch`** | The epoch execution wall, and the sole basis for raw simulation throughput. It encloses mutation, pairing, packing, GPU dispatch + wait, scatter, counter/program-metric reduction, and the CPU shadow (if on). It does **not** include sampled signal analysis — that is timed separately (below). |
| **Host residual ms/epoch** | `epoch wall − GPU` | *Everything in the epoch wall that is not GPU command-buffer time.* An attribution, **not** a CPU profiler: it is a single lump and does **not** isolate planning, allocation, marshalling, encode, readback, scatter, counter/program-metric reduction, the shadow, or queue latency. |
| **Signal analysis ms (total)** (`signalAnalysisMsTotal`) | monotonic clock around `SoupSignals.measure`, **outside** the epoch wall | Host analysis cost of the sampled entropy/transition/LZ metrics. Whole-run total. **`null` under `--no-samples`** — that mode computes no signals, so there is nothing to time (honest "not computed", never a fabricated 0). |
| epochs/s, pairs/s, raw/command steps/s | measured epochs ÷ measured **epoch** wall | Warmup epochs excluded; signal analysis never mixed in. |
| halt buckets, copy writes | `EpochCounters` reduced from the GPU records | The existing science counters, summed over measured epochs. Reduced inside `runEpoch`, so part of the epoch wall. |
| max RSS | `getrusage(RUSAGE_SELF).ru_maxrss` | Process high-water mark (bytes; normalized from KiB on Linux). One ceiling for the whole run, best-effort. |

Output is one JSON document `{ "schemaVersion": 2, "results": [ … ] }` on stdout; all
diagnostics and warnings go to stderr. One `results[]` entry per matrix cell. Pipe to `jq`.

**Schema 2** (from 1): entropy-kinetics fields (`initialEntropyBitsPerByte`,
`finalEntropyBitsPerByte`, `finalDeltaH`, `finalMeanProgramEntropyBitsPerByte`,
`finalTransitionRate`, `finalCompressionProxyRatio`) are now **nullable** — under
`--no-samples` they are *omitted* from the JSON (Swift encodes `nil` optionals as absent
keys; treat absent as `null`); `thresholdCrossings` is then `[]` and `samples` is `[]`.
Added `signalsAnalyzed` (always present bool — the reliable "were kinetics computed?"
flag) and `signalAnalysisMsTotal` (nullable ms, omitted under `--no-samples`).

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
  / copied regions appear even while entropy stays high. O(n), computed on the analysis
  cadence (every sampled epoch), never under `--no-samples`.
- **`compressionProxyRatio`** — a finite-window greedy LZ77 **token count ÷ byte count**,
  `(0,1]`; lower ⇒ more repetition. It is a reproducible *proxy* for compressibility, not
  a real codec's ratio and **not Kolmogorov complexity** (which is uncomputable). It is
  O(n·window) — the one expensive signal — so it is **opt-in** (`--compression`) and even
  then computed only on sampled epochs + the final epoch, never every epoch. Off by
  default and never under `--no-samples`. `null` means "not computed", not "incompressible".

Read all three as relative, same-alphabet, same-length signals.

### Metric controls and hidden-cost avoidance

- **`--no-samples`** is throughput mode: it skips **all** sample-only metric computation —
  the whole-soup and per-program entropy scans, the adjacent-transition scan, and the LZ
  proxy — not merely their JSON emission. No `SoupSignals.measure` call is made at all, so
  the epoch wall carries **zero** hidden analysis cost. In this mode the kinetics fields
  and `signalAnalysisMsTotal` are `null`, `thresholdCrossings`/`samples` are `[]`, and
  `signalsAnalyzed` is `false`. **Mandatory metrics that remain** in this mode: the
  per-epoch `EpochCounters` (halt buckets, step/copy counts — reduced inside `runEpoch`
  from the GPU result records the kernel already returns, so no extra soup scan) and the
  final `finalDigest` (FNV-1a over the soup, computed inside `runEpoch`). Both are part of
  the epoch wall by construction and are not sample metrics.
- **`--compression`** opts the LZ proxy in; bounded to the sample cadence so it stays
  affordable even at 131072 programs. Ignored (with a stderr note) under `--no-samples`.

## Entropy kinetics

Per run the harness reports absolute mean Shannon entropy (whole-soup bits/byte, and the
existing per-program mean), ΔH from the initial soup, and — for each `--delta-h-thresholds`
level — the **epoch** and **wall/GPU ms** at which ΔH first reached it (epoch is the
deterministic figure; the ms includes warmup). `--sample-interval N` emits a per-epoch
kinetics sample every `N` epochs (plus the final), bounding output at large soups.

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
