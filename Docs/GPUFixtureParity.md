# GPU Fixture Parity — the Metal evaluator vertical slice

This checkpoint adds the first GPU code: the **normative dynamic-scan Metal evaluator**
(02 §10 stage v1's semantic core, none of its performance machinery) plus the host plumbing
that holds it to bit-exact parity with the two existing semantic anchors:

1. the committed cubff evaluator fixtures (`Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json`,
   genuine outputs of the pinned upstream evaluator — see [CubffGrounding.md](CubffGrounding.md)), and
2. the CPU oracle's `.dynamicScan` interpreter (`BFFOracle`), which is already proven
   bit-identical to cubff on those fixtures.

Deliberately **not** in this slice: soup/epoch loop, mutation/shuffle, jump tables, threadgroup
tape staging, simdgroup early exit, renderer/metrics/HUD — correctness only, one interaction
per GPU thread, brackets always resolved by scanning the live tape.

## Pieces

| Piece | Where | Runs on |
|---|---|---|
| Shared CPU/MSL layouts (`BFFEvalParams`, `BFFEvalResult`) | `Sources/CBFFShared/include/BFFShared.h` | every platform |
| Dynamic-scan evaluator + layout-probe kernels | `Sources/BFFMetal/Shaders/BFFEvaluate.metal` | macOS GPU |
| Metal host (`MetalBFFEvaluator`) | `Sources/BFFMetal/MetalEvaluator.swift` | macOS |
| Dispatch planner / parity comparator / report (platform-independent) | `Sources/BFFMetal/{FixturePlanner,GPUFixtureComparator,EvalLayout}.swift` | every platform |
| Fixture parity orchestration | `Sources/BFFMetal/GPUFixtureParityRunner.swift` | macOS |
| Command-line parity runner | `Sources/bff-metal-parity/main.swift` | macOS (exits 2 elsewhere) |
| Tests | `Tests/BFFMetalTests/` | layout/planner/comparator everywhere; `MetalFixtureParityTests` macOS |

## The layout contract

`BFFShared.h` is the normative byte layout. The Metal source cannot `#include` it (the shader
is compiled at runtime from a bundled resource), so the MSL side mirrors the two structs, and
agreement is enforced mechanically at three layers:

1. `_Static_assert`s in the header pin size/alignment/every field offset to documented
   literals — checked by plain `swift build` on every platform, including Linux.
2. `static_assert`s in `BFFEvaluate.metal` pin the MSL mirror to the same literals at Metal
   compile time.
3. The `bff_layout_probe` kernel reports `sizeof`/`alignof`/field offsets as compiled by the
   actual Metal compiler; `MetalBFFEvaluator.init` compares every word against Swift's
   `MemoryLayout` of the imported structs and refuses to dispatch on any mismatch.

Operation accounting is split exactly as the oracle/grounding defines it: `steps` is raw gas
(every executed op costs 1, including no-ops and the halting unmatched bracket), `noopSteps`
is cubff's `nskip`, and cubff's observable evaluator op count — the fixtures' `expectedOps` —
is the derived `steps - noopSteps`. The step budget is a per-dispatch `uint32` taken from each
fixture case, not a constant.

## What parity means here

For every fixture case, the GPU run must match:

- the **fixture** on the final 128-byte tape and the cubff op count (the only observables
  cubff produces), and
- the **oracle** on the full shared accounting: `steps`, `noopSteps`, `copyWrites`, `loopOps`,
  and the halt reason.

Any divergence is reported per case with the fixture name, first differing tape byte
(expected vs actual), and the offending counter/halt fields.

## Validation on Linux (job/CI containers)

```sh
swift build           # includes the header's _Static_asserts and all non-GPU code
swift test            # all platform-independent tests, incl. layout/planner/comparator
swift run bff-metal-parity   # honestly refuses: prints Metal-unavailable and exits 2
```

A supplementary Linux-side semantic check (not a substitute for GPU execution): the `.metal`
kernel logic, compiled as plain C++14 with Metal address-space keywords shimmed away, has been
executed against all 59 committed fixture cases and matches cubff bit-exactly. This validates
the shader's *logic*; it says nothing about the Metal compiler or a real GPU.

## Validation on bigbook (macOS, actual GPU) — required before claiming GPU parity

From the repository root:

```sh
swift test --filter BFFMetalTests        # includes MetalFixtureParityTests on the GPU
swift run bff-metal-parity               # full fixture run; exit 0 = exact parity
swift run bff-metal-parity --fixtures Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json
```

`bff-metal-parity` prints the device, dispatch/case counts, one line per divergence, and a
final PASS/FAIL verdict; exit code 0 means every case matched both anchors exactly.

**Status: GPU execution has NOT yet been performed.** Everything GPU-side (runtime shader
compile, layout probe, kernel execution) is unvalidated until the commands above run on
bigbook; no GPU parity is claimed until then.
