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
| **Wall ms/epoch** | monotonic clock around `runEpoch` | End-to-end: host planning + mutate + dispatch + readback + scatter + metrics (+ shadow if on). |
| **Host residual ms/epoch** | `wall − GPU` | *Everything that is not GPU command-buffer time.* This is an attribution, **not** a CPU profiler — it lumps together all host work and any queue latency. |
| epochs/s, pairs/s, raw/command steps/s | measured epochs ÷ measured wall | Warmup epochs are excluded. |
| halt buckets, copy writes | `EpochCounters` reduced from the GPU records | The existing science counters, summed over measured epochs. |
| max RSS | `getrusage(RUSAGE_SELF).ru_maxrss` | Process high-water mark (bytes; normalized from KiB on Linux). One ceiling for the whole run, best-effort. |

Output is one JSON document `{ "schemaVersion": 1, "results": [ … ] }` on stdout; all
diagnostics and warnings go to stderr. One `results[]` entry per matrix cell. Pipe to `jq`.

Exit codes: `0` ok · `1` shadow mismatch or GPU/runtime error · `2` Metal unavailable
(nothing ran) · `3` ran but GPU timestamps were unavailable · `64` bad arguments.

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
  / copied regions appear even while entropy stays high. O(n), computed every epoch.
- **`compressionProxyRatio`** — a finite-window greedy LZ77 **token count ÷ byte count**,
  `(0,1]`; lower ⇒ more repetition. It is a reproducible *proxy* for compressibility, not
  a real codec's ratio and **not Kolmogorov complexity** (which is uncomputable). O(n·window),
  so it is computed only on sampled epochs + the final epoch (see `--sample-interval`).

Read all three as relative, same-alphabet, same-length signals.

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

Low-entropy growth from an executable floor (expect a clear positive ΔH):

```sh
swift run -c release bff-metal-bench \
  --programs 65536 --seed 1 --warmup 2 --epochs 200 \
  --init opcode --delta-h-thresholds 0.25,0.5,1.0 --sample-interval 10 \
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
