# Metal Soup Slice — deterministic small-soup evolution around the evaluator

This checkpoint adds the epoch loop *around* the already-validated normative dynamic-scan
Metal evaluator (see [GPUFixtureParity.md](GPUFixtureParity.md)). It does **not** touch the
evaluator's semantics or its cubff fixture parity: it packs interactions, dispatches the
existing evaluator, scatters results back, and reduces host-side counters, metrics, and a
sampled CPU-shadow comparison — enough to validate several epochs before any visualization.

Deliberately **not** in this slice (strict exclusions): renderer / MTKView / textures / colors
/ glyphs / metric mipmaps, pan/zoom/HUD, continuous app loop or display link, persistent GPU
queue / scheduler / batching / fences / threadgroup staging / SIMD tricks, jump tables or any
alternate interpreter, 131,072-program tuning, emergence experiments, and cubff whole-soup RNG
parity. The bracket path is still *only* dynamic live scanning on the GPU.

## What it reuses (no new contracts)

Initialization, mutation, and pairing are the existing `counter-pcg-v1` `BFFRandom` routines
verbatim (`BFFOracle`). This slice invents no second RNG / pairing / mutation contract:

| Concern | Source | Domain |
|---|---|---|
| Soup init | `BFFRandom.initialSoup` | stream `soupInit` (epoch 0) |
| Point mutation | `BFFRandom.mutate` (now also returns fired count) | stream `epoch*4 + mutate` |
| Fisher–Yates pairing | `BFFRandom.pairingPermutation` | stream `epoch*4 + pairing` |
| Per-interaction execution | `MetalBFFEvaluator` (GPU) / `BFFInterpreter` (CPU shadow) | — |

Mutation probability is the integer threshold `mutationP32` (mutate iff a `uint32` draw is
`< mutationP32`) — no floating-point probability anywhere. `0` disables mutation.

## Pieces (all in `Sources/BFFMetal`, platform-independent unless noted)

| Piece | File | Runs on |
|---|---|---|
| `SoupConfig` (throwing validation) + `SoupDigest` (FNV-1a) | `SoupConfig.swift` | every platform |
| `EpochPlan` / `SoupPlanner` (mutate→pair→pack, scatter), `EpochCounters`, `ProgramMetric` / `SoupMetrics` | `SoupEpoch.swift` | every platform |
| `ShadowSampler` (deterministic, domain-separated) + `ShadowComparator` | `SoupShadow.swift` | every platform |
| `PairEvaluator`, `CPUPairEvaluator`, `SoupRunner`, `EpochReport` | `SoupRunner.swift` | every platform |
| `MetalBFFEvaluator: PairEvaluator` conformance | `MetalEvaluator.swift` | macOS |
| Headless runner CLI | `Sources/bff-metal-soup/main.swift` | macOS (exits 2 elsewhere) |

`SoupRunner` is generic over `PairEvaluator`, so the *entire* epoch orchestration runs on
non-Metal hosts by injecting `CPUPairEvaluator` — an honest CPU computation, never a faked GPU
run. The GPU is a drop-in evaluator; on macOS the CLI and the `MetalSoupEpochTests` inject it.

## Identity, counters, metrics, shadow — the definitions

- **Identity / scatter.** Pairing shuffles *positions*; pair `p` is
  `(perm[2p], perm[2p+1])` mapped to stable program IDs. After the GPU runs, the two 64-byte
  halves scatter back to exactly those IDs. Pairs are a permutation → disjoint → no aliasing.
- **Counters** (host reduction of the per-interaction result records; **no per-step global
  atomics**). Per epoch: `mutationCount`, `interactions`, raw `steps`, `noopSteps`
  (cubff `nskip`), derived `commandSteps = raw − noop`, `loopOps`, `copyWrites`, and the
  halt-reason histogram `{budget, pcOut, unmatched}` (which sums to `interactions`).
- **Activity** (integer, per program): the interaction's `commandSteps`, attributed
  identically to *both* partners — activity is a pair-level event, mirroring the evaluator
  design's `progStats[ia] = progStats[ib]`.
- **Byte entropy** (per program): order-0 Shannon entropy of the 64 post-epoch bytes, bits/byte
  in `[0, 6]` (64 bytes hold at most 64 distinct values → `log2 64 = 6`). Same definition as
  `ByteHistogram`. Pinned by tests: one repeated byte → 0, 64 distinct bytes → 6.
- **CPU shadow.** A deterministic without-replacement sample of pair indices per epoch, chosen
  from `(seed, epoch)` in a HOST-ONLY RNG domain (`seed ^ 0x5AD05EED`) kept clear of the soup
  streams. Each sampled pair's exact pre-GPU 128-byte input is re-run on `BFFInterpreter`
  (`.dynamicScan`, same variant/budget) and every observable (final tape + all counters + halt)
  is compared. Shadowing is read-only: it never mutates the soup or draws from the soup RNG, so
  it cannot perturb the trajectory. Sample count `0` disables it; `pairCount` shadows every
  pair. Mismatches report `epoch`, `pairIndex`, both program IDs, first differing byte, and one
  line per divergent field.
- **Digest.** FNV-1a over the raw soup bytes — a dependency-free deterministic fingerprint for
  cross-machine replay comparison.

## Running headless

```sh
swift run bff-metal-soup [--seed N] [--programs EVEN] [--epochs N] \
                         [--budget N] [--mutation-p32 N] \
                         [--variant noheads|bff] [--shadow-sample N|all]
```

Output is consistently formatted `key=value` tokens: a config/device header, one line per
epoch (mutation count, pair count, raw/no-op/command steps, loop ops, copy writes, halt
histogram, activity and entropy min/mean/max, shadow checked/mismatch counts, and the
post-epoch digest), and a final line with the terminal digest and total mismatches.

Exit codes: `0` all epochs ran and every shadowed pair matched; `1` a shadow mismatch or
runtime/GPU error; `2` Metal unavailable (nothing ran — the run is honest on Linux); `64`
invalid arguments / configuration (validated before any allocation or dispatch).

## Native validation on bigbook (macOS, actual GPU) — required before claiming GPU epochs

`swift test` covers all platform-independent logic on Linux with the CPU evaluator, but the GPU
epoch path is unvalidated until run on a Metal device. From the repository root:

```sh
# GPU epoch parity vs the CPU oracle (per-pair shadow + end-to-end digest), macOS only:
swift test --filter MetalSoupEpochTests

# Headless full-shadow runs; deterministic — same args reproduce byte-for-byte, incl. digests:
swift run bff-metal-soup --seed 1 --programs 16 --epochs 8 --shadow-sample all
swift run bff-metal-soup --seed 1 --programs 32 --epochs 8 --shadow-sample all

# Bounded shadow (sample a subset per epoch) for a slightly larger soup:
swift run bff-metal-soup --seed 12345 --programs 32 --epochs 16 --shadow-sample 8
```

Replay comparison: run the same command twice (or on two machines) and diff stdout — every
token, including per-epoch and final `digest=0x…`, must be identical. Exit `0` with
`shadowMismatchTotal=0` means the GPU matched the scalar oracle on every sampled pair across
every epoch. The existing `bff-metal-parity` behavior is unchanged.

**Status: GPU epoch execution has NOT been performed in-tree** (no Metal device in the build
environment). The Linux `swift test` run validates planning, scatter, counters, metrics, shadow
selection/comparison, and deterministic replay via `CPUPairEvaluator`; `MetalSoupEpochTests`
and the `bff-metal-soup` GPU path remain unvalidated until the commands above run on bigbook.
