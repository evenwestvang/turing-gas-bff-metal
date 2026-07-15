# 04 — Embedded Profiling

Goal: **the running app tells you what is bottlenecking** — without leaving it. Research 2's
bottleneck ranking (1: control divergence — bounded; 2: memory divergence — the likely
dominator; 3: duration variance / tail effect) becomes a set of counters compiled into the
kernels, derived metrics with explicit formulas, a live HUD, and a decision tree that names
the fix (usually a specific 02 §9 item) and the matching Xcode GPU-capture counter to confirm.

## 1. Profile levels

Function constant `kProfileLevel` (02 §6); each level is a separate PSO variant, so level 0 has
**zero** cost (dead-code eliminated):

| Level | Cost target | Adds |
|---|---|---|
| 0 off | 0 % | nothing |
| 1 cheap (default) | < 3 % | lane-activity, steps, halts, pair counts, timings |
| 2 detailed | < 15 % | opcode-class mix, step histogram, per-simdgroup tail stats, memory-pattern counts |

Overhead is itself measured: the HUD shows epochs/s at the current level, and a "calibrate"
action runs 64 epochs at level 0 vs current and reports the delta.

## 2. `ProfCounters` (in `BFFShared.h`)

One global struct of 32-bit atomics in a Shared buffer, **drained and zeroed by the CPU at
every command-buffer completion** (so 32-bit never overflows: a ~10 ms batch is ≤ ~200 M
lane-steps, far under 2³²; enforced by the batcher's overflow cap, specified in 05 §4.1).

```c
typedef struct {
    // ---- level 1
    atomic_uint pairsDone;          // interactions completed
    atomic_uint totalSteps;         // Σ steps over pairs (science + perf)
    atomic_uint haltCounts[4];      // [_, BUDGET, PC_OUT, UNMATCHED]
    atomic_uint copyWritesTotal;    // Σ cross-half copies (science signal)
    atomic_uint sgLoopIters;        // Σ over simdgroups of lockstep-loop iterations
    atomic_uint activeLaneSteps;    // Σ popcount(active ballot) per loop iteration
    // ---- level 2
    atomic_uint opClass[6];         // moves, arith, copy, loopTaken, loopFall, noop
    atomic_uint stepsHist[16];      // log2 buckets of per-pair steps (bucket 15 = budget)
    atomic_uint sgMaxStepsSum;      // Σ over simdgroups of max(steps) in group
    atomic_uint sgCount;            // number of simdgroup-pair-batches
    atomic_uint jtUnmatchedBuilt;   // unmatched brackets seen at table build
    // ---- v2 queue health
    atomic_uint queueClaims;        // batch claims (should be ≈ pairs/32)
    atomic_uint queueTailIdleIters; // loop iterations executed after queue drained
} ProfCounters;
```

## 3. Accumulation: registers → simdgroup reduce → one atomic

Rule: **no per-step atomics, ever.** Each lane accumulates into registers; reduction happens
across the simdgroup with intrinsics; exactly one lane issues `atomic_fetch_add`s, at points
where control flow is uniform.

MSL note: `simd_ballot` returns a `simd_vote` wrapper type, **not** an integer — it must be
explicitly converted before `popcount`. The MSL-correct form is
`popcount((uint)(ulong)simd_ballot(pred))`: `simd_vote` explicitly converts to `ulong`
(64-bit vote mask; on 32-wide Apple hardware the upper 32 bits are zero), which is then
narrowed to `uint` for a 32-bit popcount. Used verbatim below.

```metal
// Inside the lockstep loop (uniform — every lane executes every iteration):
#define PROF_LOOP_TICK(prof, lane, halt, steps)                              \
    if (kProfileLevel >= 1) {                                                \
        uint active = popcount((uint)(ulong)simd_ballot(halt == 0));         \
        if (simd_is_first_active_lane()) { r_iters++; r_activeSum += active; } \
    }

// After the loop (converged, uniform):
#define PROF_PAIR_DONE(prof, lane, steps, halt, copyW)                       \
    if (kProfileLevel >= 1) {                                                \
        uint sSteps  = simd_sum((uint)steps);                                \
        uint sCopy   = simd_sum((uint)copyW);                                \
        /* halt histogram: one ballot per reason. Every lane has halt != 0   \
           here (the loop exited), and the enum starts at 1, so the three    \
           counts partition all 32 lanes; haltCounts[0] is reserved padding  \
           and is never written. */                                          \
        uint hBudget = popcount((uint)(ulong)simd_ballot(halt == BFF_HALT_BUDGET));    \
        uint hPcOut  = popcount((uint)(ulong)simd_ballot(halt == BFF_HALT_PC_OUT));    \
        uint hUnmat  = popcount((uint)(ulong)simd_ballot(halt == BFF_HALT_UNMATCHED)); \
        if (simd_is_first_active_lane()) {                                   \
            atomic_fetch_add_explicit(&prof.pairsDone, 32u, memory_order_relaxed);     \
            atomic_fetch_add_explicit(&prof.totalSteps, sSteps, memory_order_relaxed); \
            atomic_fetch_add_explicit(&prof.copyWritesTotal, sCopy, memory_order_relaxed); \
            atomic_fetch_add_explicit(&prof.haltCounts[BFF_HALT_BUDGET],    hBudget, memory_order_relaxed); \
            atomic_fetch_add_explicit(&prof.haltCounts[BFF_HALT_PC_OUT],    hPcOut,  memory_order_relaxed); \
            atomic_fetch_add_explicit(&prof.haltCounts[BFF_HALT_UNMATCHED], hUnmat,  memory_order_relaxed); \
            atomic_fetch_add_explicit(&prof.activeLaneSteps, r_activeSum, memory_order_relaxed); \
            atomic_fetch_add_explicit(&prof.sgLoopIters, r_iters, memory_order_relaxed); \
            r_iters = 0; r_activeSum = 0;                                    \
        }                                                                    \
    }
```

(`r_*` are per-lane registers declared by a `PROF_DECLS` macro at kernel top and re-zeroed at
each flush, as shown — this keeps the macros correct under v2's batch-claiming loop; level 2 adds
per-lane `opClass` counters bumped inside the switch — register adds, reduced the same way. At
level 2 the simdgroup max for the tail metric is `simd_max(steps)`.)

Atomic traffic at level 1: 8 RMWs per simdgroup-batch ≈ 16 K per epoch — noise. The
`simd_ballot` per iteration is the only hot-loop cost (~1 instruction).

## 4. Derived metrics (computed on CPU at each drain)

| Metric | Formula | Meaning / healthy range |
|---|---|---|
| **Lane utilization** | `activeLaneSteps / (32 · sgLoopIters)` | fraction of SIMD width doing real work. < 0.6 = divergence/tail problem |
| **Tail ratio** (lvl 2) | `(sgMaxStepsSum / sgCount) / (totalSteps / pairsDone)` | mean simdgroup-max vs mean run length. > ~2.5 = duration variance wasting lanes → 02 §9 (1)(2) |
| **Epochs/s, lane-steps/s** | from `totalSteps`, `pairsDone`, wall/GPU time | throughput; the headline number |
| **Mean steps / halt mix / copy rate** | `totalSteps/pairsDone`, `haltCounts/Σ`, `copyWritesTotal/pairsDone` | science signals (01 §5) — double duty |
| **Est. bandwidth** | `bytesPerEpoch · epochs/s`; per-term model below — ≈ 42 MiB/epoch at defaults | compare against ~500 GB/s peak: >50 % = memory-bound regime |
| **Pass time share** | per-encoder GPU timestamps (§6) | mutate/jt/metrics should be ≪ interpret; if not, fuse or re-cadence |
| **Queue health** (v2) | `queueClaims ≈ pairsDone/32`; `queueTailIdleIters / sgLoopIters` | claim inflation = contention; tail-idle = drain imbalance |

Bandwidth model, term by term (defaults N = 131,072, P = 65,536, µ = 1/4096):

| Term | Bytes/epoch | At defaults |
|---|---|---|
| interpret: soup stage-in + stage-out | `N·64·2` | 16 MiB |
| interpret: jump-table read | `P·128` | 8 MiB |
| jt build: soup read | `N·64` | 8 MiB |
| jt build: table write | `P·128` | 8 MiB |
| pairs read (jt build + interpret) | `2·N·4` | 1 MiB |
| stats write | `16·P` (8 B `ProgStats` × 2 programs/pair) | 1 MiB |
| mutate writes | `N·64·µ` | ~2 KiB |
| **Total** | | **≈ 42 MiB/epoch** |

This is a *traffic* model, not a DRAM model — the interpreter's per-step tape accesses hit
threadgroup memory/L1 and are excluded; metricTex/mips are once per CB, amortized to noise.

## 5. HUD (live overlay)

A SwiftUI panel over the Metal view (05 §2), updated from the drain (throttled to 10 Hz), with
~120-sample ring buffers rendered as sparklines:

```
┌─ PERFORMANCE ──────────────────────────────┐  ┌─ SOUP ───────────────────────────────┐
│ epoch 18 432      1 214 ep/s   ▂▃▅▆▅▆▇     │  │ mean steps 6 891 ▁▁▂▇█   copy/pair 41│
│ 22.4 G lane-steps/s   GPU 96 % busy        │  │ halts: BUDGET 81% PC_OUT 17% UNM 2%  │
│ lane util 71 %  ▆▅▅▃▃   tail ×3.1  ⚠       │  │ soup zlib 2.31 MiB ▇▇▆▂▁  H=4.1 bits │
│ interpret 8.9 ms · jt 0.4 · mut 0.1 · met 0.3 │ replicators (est) 62 %               │
│ est BW 51 GB/s (10 % peak)                 │  └──────────────────────────────────────┘
│ ▶ ADVISOR: tail effect — enable length     │
│   binning (02 §9.2). Confirm in Xcode:     │
│   Compute dispatch tail, low SIMD util.    │
└────────────────────────────────────────────┘
```

The **Advisor** line is the decision tree of §7 evaluated on the latest window — one sentence,
one pointer.

## 6. GPU timing sources

- **Per command buffer**: `gpuStartTime`/`gpuEndTime` (free, always on) → GPU-busy %, epochs/s
  denominators.
- **Per pass**: `MTLComputePassDescriptor.sampleBufferAttachments` with a
  `MTLCounterSampleBuffer` from the `timestamp` counter set, sampled at stage boundaries
  (Apple GPUs report `MTLCounterSamplingPoint.atStageBoundary` only — **verify on M4**, 06).
  Gives the interpret/jt/mutate/metrics time split without Xcode attached.
- Fallback if counter sets misbehave: temporarily encode one pass per command buffer and use
  CB timestamps (coarse but dependency-free).

## 7. Bottleneck decision tree (the point of all this)

Evaluated over the last ~2 s window; first match wins:

1. **GPU busy < 80 %** → CPU-side stall: pairing ring underfilled, inflight-CB cap too low, or
   hazard serialization against the render pass. Check sim-thread timing log (05 §7).
   *Xcode: gaps in the GPU timeline.*
2. **Lane util < 60 % and tail ratio > 2.5** → duration variance (tail effect). Fix: run-length
   binning, then persistent-thread queue (02 §9.1–2). *Xcode: Compute pass shows low "SIMD
   group utilization" late in dispatch.*
3. **Lane util < 60 %, tail ratio ≤ 2.5** → intra-run divergence (mixed opcode paths /
   dynamicScan mode on). Fix: confirm jump tables enabled; consider lane compaction (02 §9.3)
   only with evidence. *Xcode: high "divergent branch" / control-flow cost in shader
   profiler.*
4. **Lane util ≥ 85 %, est. BW > ~40 % peak** → memory-bound. Fix: staging A/B
   (`kStageTapes`), jump-table locality, batch size. *Xcode: "Last Level Cache" / "Memory
   Limiter" high, ALU limiter low.*
5. **Lane util ≥ 85 %, BW low, epochs/s still poor** → occupancy ceiling. Fix: reduce
   threadgroup memory (16 KiB → 8 KiB or `kStageTapes=false`), check register spills in the
   pipeline's compiler report (`maxTotalThreadsPerThreadgroup` of the PSO). *Xcode:
   "Occupancy" counter + limiter attribution.*
6. **Everything ≥ healthy** → you are compute-bound on an interpreter — the good ending.
   Scale N up.

Symptoms 2/3 vs 4/5 disambiguate the two plausible dominators (tail vs memory) *from inside
the app*; Xcode GPU capture (Metal System Trace + shader profiler) is the confirming
instrument, and the counter names above are what to look for. Exact label names drift across
Xcode versions — treat them as search terms (06).

## 8. Determinism and hygiene

- Counters are write-only from kernels, relaxed ordering, never read by simulation logic —
  profiling cannot change a run (01 §6).
- The drain writes a `ProfSnapshot` value struct (plain `UInt64`s, accumulated run totals +
  window deltas) that the HUD consumes; nothing in the UI touches the atomic buffer directly.
- Profile-level switches take effect at the next command buffer; all three level PSOs for the
  current (staging, brackets) combination are prebuilt and resident (05 §3), so toggling the
  level — including the calibrate action's 0 ↔ current flip — costs nothing. Staging and
  bracket A/B switches are *not* live: they go through `reset(config:)` (05 §6) and their PSOs
  may compile on first use.
