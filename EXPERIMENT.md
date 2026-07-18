# Experimental GPU-Resident BFF Epoch Slice

This branch adds an opt-in runnable vertical slice:

```sh
swift run -c release bff-resident-epoch --validate smoke --visualize
```

It does not change existing defaults, `bff-metal-soup`, `bff-metal-bench`,
`SoupScope`, the CPU oracle, or the exact Brotli/high-order observability path.

## What Is GPU-Resident

`ResidentMetalEpochRunner` owns reusable Metal buffers for the canonical soup and
epoch working state:

- `resident.soup`: canonical `programCount * 64` byte soup, reused across epochs.
- `resident.permutation`: resident permutation buffer. In the default
  `parallel-swap-or-not-v1` planner it is generated on GPU each epoch; in the
  `cpu-upload-fisher-yates-v1` counterfactual it is filled by a CPU Fisher-Yates
  permutation upload each epoch.
- `resident.pairResults`: 5 `UInt32` words per pair (`steps`, `noopSteps`,
  `copyWrites`, `loopOps`, `halt`).
- `resident.counters`: per-epoch aggregate counters updated with GPU atomics.
- `resident.activity`: one approximate activity value per stable program ID.
- optional `resident.inputCapture` / `resident.finalCapture`: full pre/post 128-byte
  pair tapes for validation and CPU-shadow diagnostics.
- optional RGBA visualization byte buffer plus an `rgba8Unorm` Metal texture with one
  approximate pixel per program.

The epoch command sequence is:

1. `bff_resident_mutate`: deterministic byte mutation in place using the existing
   `counter-pcg-v1` stream contract.
2. Planner:
   - `parallel-swap-or-not-v1` (`--planner keyed`, default): one GPU thread per
     output slot evaluates a keyed swap-or-not bijection over `0..<programCount`.
     This is intentionally NOT Fisher-Yates trajectory compatibility. It is an
     experimental parallel deterministic pairing distribution; acceptance of the
     distribution remains statistical/random-looking only, while exact
     no-duplicate/no-omission coverage is guaranteed by construction for even
     non-power-of-two program counts.
   - `cpu-upload-fisher-yates-v1` (`--planner cpu-upload`): the host generates the
     existing canonical `BFFRandom.pairingPermutation(count:seed:epoch:)`
     Fisher-Yates permutation and copies it into `resident.permutation` before
     eval-scatter. This is a narrow counterfactual for measuring the cost of
     preserving the original Fisher-Yates trajectory.
3. `bff_resident_eval_scatter`: one GPU thread per pair copies the two stable-ID
   programs into a 128-byte local tape, runs the normative dynamic-scan evaluator, writes
   result counters, writes pair activity to both stable IDs, and scatters both 64-byte
   halves back into the canonical soup buffer.
4. `bff_resident_visualize` when enabled: writes approximate activity/opcode/byte-mix
   colors to a reusable buffer and Metal texture.

The evaluator semantics are the normative path: 64-byte programs, 128-byte paired tape,
dynamic live bracket scanning, default 8192 budget, exact opcode bytes, exact head wrap,
and stable-ID scatter.

## Remaining Host Work And Round Trips

Still on the host:

- Initial soup construction and one initial upload into `resident.soup`.
- Per-kernel parameter blocks (`ResidentEpochParams`, 48 bytes per kernel dispatch).
- Command-buffer sequencing and synchronous waits.
- Reading aggregate counters every epoch.
- Optional full-soup checkpoint readback, controlled by `--checkpoint-interval`.
- Optional pair-tape/result readback when capture/shadow validation is enabled.
- CPU-shadow diagnostics when captured tapes are available.
- Digest computation after a checkpoint readback.

No soup upload, mutation table upload, packed pair-tape upload, or post-evaluation
soup scatter happens per epoch in the normal resident path. Per-epoch permutation
upload happens only under `--planner cpu-upload` and is counted in `uploadBytes`.

The buffers use `.storageModeShared` for this first Apple-silicon learning slice. The
canonical state is the Metal buffer; Swift does not mutate it between epochs except for
the initial fill. A later version can move the soup to private storage plus explicit blits
if profiling shows that matters.

## Instrumentation

Each report prints:

- epoch wall time and epochs/sec;
- exact planner identifier;
- planner CPU generation time, permutation upload/copy time and bytes, and planner
  GPU time when a GPU planner actually ran and timestamps are available;
- command-buffer GPU time per resident kernel when Metal timestamps are available;
- host-observed time per kernel command buffer;
- checkpoint time when checkpointing fires;
- upload/readback/parameter bytes;
- persistent buffer sizes and total bytes;
- aggregate counters and halt buckets.
- optional permutation fingerprint and CPU-side pairing distribution diagnostics.

Per-kernel GPU timing is implemented by putting each kernel in its own command buffer.
That is intentionally measurement-friendly rather than throughput-optimal.

`--pairing-diagnostics` enables CPU-side permutation diagnostics for either planner:
fixed-point count, adjacent-ID pair count, mean absolute pair-ID distance, and a coarse
distance histogram. Histogram bins are absolute pair-ID distances:
`0`, `1`, `2...3`, `4...7`, `8...15`, `16...31`, `32...63`, `64...127`,
`128...255`, `256...511`, `512...1023`, and `1024...`. This read/scan is opt-in so
normal throughput epochs do not pay for it.

## Validation Modes

Linux must not attempt Metal execution. The CLI parses arguments and exits 2 there.
Platform-independent tests exercise the resident CPU reference and the resident
permutation contract. `Simulation` remains the Fisher-Yates oracle and is no longer a
trajectory oracle for this resident planner.

Native commands:

```sh
# Focused package tests, including CPU resident parity and macOS Metal smoke if present.
swift test --filter ResidentEpochTests
swift test --filter ResidentMetalEpochTests

# Exhaustive tiny GPU-vs-CPU parity for every even population 2...1024 using the
# selected resident planner.
swift run -c release bff-resident-epoch --validate tiny --epochs 1

# The Fisher-Yates counterfactual: CPU-generate and upload the canonical permutation.
swift run -c release bff-resident-epoch --planner cpu-upload --validate tiny --epochs 1

# Medium 16K stress: several seeds, full checkpoint digest/counters, captured tapes,
# and sampled CPU shadow.
swift run -c release bff-resident-epoch --validate medium --epochs 3 --visualize

# Bounded 131K native smoke. This keeps the large-soup CPU oracle out of the loop but
# checkpoints the soup and shadows a small captured sample by default.
swift run -c release bff-resident-epoch --validate smoke --epochs 1 --visualize
```

Manual run examples:

```sh
swift run -c release bff-resident-epoch \
  --programs 131072 --epochs 8 --checkpoint-interval 4 --shadow-sample 64 --visualize

swift run bff-resident-epoch \
  --programs 32 --epochs 4 --checkpoint-interval 1 --capture-pairs --shadow-sample all

swift run bff-resident-epoch \
  --planner cpu-upload --programs 32 --epochs 4 --checkpoint-interval 1 \
  --capture-pairs --shadow-sample all --pairing-diagnostics
```

## Mismatch Diagnostics

When pair captures are enabled, CPU shadow re-runs the exact captured pre-GPU 128-byte
tape through `BFFInterpreter` and reports:

- epoch and pair index;
- stable program IDs;
- first final-tape byte divergence;
- steps, noop steps, copy writes, loop ops, and halt divergence.

Validation modes compare GPU counters, checkpoint soup bytes, digest, permutation
fingerprint, optional pairing diagnostics, and captured pair records against
`ResidentCPUReferenceRunner`, which implements the selected resident pairing algorithm.

## Known Risks

- `parallel-swap-or-not-v1` is not Fisher-Yates-compatible. It is a fast experimental
  resident planner that is only statistically compatible/random-looking; distribution
  quality must be judged statistically before any scientific claim depends on it.
- Aggregate counters are `UInt32`; the bounded 131K/default-budget smoke fits, but much
  larger populations or budgets need wider reductions.
- Pair capture currently captures all pairs, not only the sampled shadow pairs.
- Per-kernel timing uses one command buffer per kernel, which adds overhead.
- Visualization is approximate and direct; it is not a scientific metric and is separate
  from exact Brotli/high-order measurements.
- No Linux Metal execution is possible or attempted in this branch.
