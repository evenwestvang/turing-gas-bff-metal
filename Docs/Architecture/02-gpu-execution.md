# 02 — GPU Execution Design

Implements the epoch loop of [01-bff-spec.md](01-bff-spec.md) as Metal compute. Strategy per
Research 2: **lockstep masked interpretation** (SIMT gives it for free), **no per-step opcode
binning**, jump tables for O(1) brackets, tape staging in threadgroup memory, grid-stride v1,
persistent-threads + work queue + length binning as v2. ALU is not the bottleneck; control
divergence is bounded (10 opcodes); the real enemies are **memory divergence from head wander**
and **duration variance (tail effect)** — the slowest lane in a simdgroup stalls the other 31.

## 1. Shared header (`BFFShared.h`)

One C header included by both MSL and Swift (via bridging header) so layouts are defined once.

```c
// BFFShared.h — included from .metal and Swift bridging header
#pragma once
#include <stdint.h>

#define BFF_TAPE          128       // pair tape bytes
#define BFF_PROG          64        // bytes per program
#define BFF_JT_UNMATCHED  0xFF

// Command byte values: see 01 §2 (ASCII table).

typedef enum : uint8_t {
    BFF_HALT_BUDGET = 1, BFF_HALT_PC_OUT = 2, BFF_HALT_UNMATCHED = 3,
} BFFHaltReason;

typedef struct {
    uint32_t soupProgs;      // N (power of two, ≥ 2 * threadgroup size)
    uint32_t pairCount;      // P = N/2
    uint32_t epoch;          // current epoch (RNG stream component)
    uint32_t seed;           // run seed
    uint32_t stepBudget;     // 8192
    uint32_t mutationP32;    // mutate iff u32 draw < this (default 1<<20)
    uint32_t flags;          // bit0 BFF_FLAG_DYNAMIC_SCAN, bit1 BFF_FLAG_PROFILE_DETAIL
    uint32_t gridWidth;      // viz grid width in programs (512)
    float    emaAlpha;       // metric temporal smoothing, default 0.85 (03 §4; set via setLive)
} SimParams;

typedef struct {            // one per PROGRAM (both pair members get written)
    uint16_t steps;         // steps of last interaction (0..8192)
    uint8_t  halt;          // BFFHaltReason
    uint8_t  flags;         // reserved
    uint16_t copyWrites;    // '.'/',' executions whose h0/h1 are in different halves
    uint16_t loopOps;       // bracket ops executed
} ProgStats;                // 8 bytes; N * 8 = 1 MiB

// ProfCounters: defined in 04 §2 — one global struct of atomics.
```

## 2. Buffer inventory

All created once at reset; `soup` and everything the CPU touches are `.storageModeShared`
(unified memory — zero copy); GPU-only scratch is `.private`. Hazard tracking left ON
(default) for v1 — automatic dependencies between passes and with the render pass. Revisit
only if the profiler shows scheduling bubbles (06).

| Buffer | Type / size (defaults) | Mode | Writers → Readers |
|---|---|---|---|
| `soup` | `uchar[N*64]` = 8 MiB | Shared | mutate, interpret → everything (incl. fragment shader, CPU) |
| `pairs` | ring of **8 slots** × `uint32[N]` = 4 MiB | Shared | CPU shuffle → buildJumpTables, interpret |
| `jumpTables` | `uchar[P*128]` = 8 MiB | Private | buildJumpTables → interpret |
| `progStats` | `ProgStats[N]` = 1 MiB | Shared | interpret → metrics kernel, CPU, inspector |
| `profCounters` | `ProfCounters` (~256 B) | Shared | all kernels (atomics) → CPU HUD |
| `histogram` | `uint32[256]` = 1 KiB | Shared | histogram kernel → CPU |
| `metricTex` | `MTLTexture` rgba16Float 512×256, full mip chain | Private | program-metrics kernel + mip blit → fragment shader |
| `metricEMA` | `float4[N]` = 2 MiB (temporal smoothing, 03 §4) | Private | program-metrics kernel (read-modify-write) |
| `simParams` | `SimParams` per epoch (small ring, or `setBytes`) | — | CPU → all kernels |

Pairing slot `s` holds a full permutation of `0..N-1`; pair `i` of that epoch is
`(pairs[s][2i], pairs[s][2i+1])`. The CPU (05 §4) keeps the ring filled ahead of the GPU;
one command buffer never encodes more epochs than filled slots available.

## 3. Epoch pass structure

Per epoch, three compute dispatches; metrics run at command-buffer granularity:

```text
CommandBuffer (E epochs, E ≤ ring headroom, sized to ~10 ms GPU time):
  repeat E times:
    1. bff_mutate            (skipped when mutationP32 == 0)
    2. bff_build_jump_tables (skipped in dynamicScan mode)
    3. bff_interpret
  then once per CB:
    4. bff_program_metrics   (progStats + soup + metricEMA → metricTex level 0)
    5. blit: generateMipmaps(metricTex)
    6. bff_histogram         (every metricsEvery epochs)
  completion handler: CPU reads profCounters, publishes HUD stats, recycles ring slots.
```

All three per-epoch kernels are grid-sized so **`pairCount % threadgroupSize == 0`**
(guaranteed: N is a power of two ≥ 2·256). This keeps every simdgroup fully populated —
required for the uniform `simd_all` early-exit below, and it means no bounds-check branch in
hot loops.

## 4. RNG (counter-based, stateless)

```metal
inline uint pcg_hash(uint x) {                 // PCG-XSH-RR style mix
    x = x * 747796405u + 2891336453u;
    uint w = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    return (w >> 22u) ^ w;
}
inline uint rng3(uint seed, uint stream, uint idx) {
    return pcg_hash(pcg_hash(seed ^ (stream * 0x9E3779B9u)) ^ idx);
}
```

Streams: `stream = epoch * 4 + passID` (mutate=0, pairing=1, soupInit=2, selfRep=3). The same
functions are mirrored in Swift for the CPU-side Fisher–Yates so a run is a pure function of
`(seed, config)` (01 §6).

## 5. Kernel: `bff_build_jump_tables`

One thread per pair; bracket-match stack in threadgroup memory (depth ≤ 64 on a 128-byte tape,
`uint8` entries). Threadgroup 128 → 8 KiB threadgroup memory.

```metal
kernel void bff_build_jump_tables(
    device const uchar* soup        [[buffer(0)]],
    device const uint*  pairs       [[buffer(1)]],
    device uchar*       jumpTables  [[buffer(2)]],
    constant SimParams& sp          [[buffer(5)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    threadgroup uchar*  stacks      [[threadgroup(0)]])   // TG * 64 bytes
{
    device const uchar* a = soup + (ulong)pairs[2*gid]     * BFF_PROG;
    device const uchar* b = soup + (ulong)pairs[2*gid + 1] * BFF_PROG;
    device uchar* jt = jumpTables + (ulong)gid * BFF_TAPE;
    threadgroup uchar* stk = stacks + tid * 64;

    int sp2 = 0;
    for (int i = 0; i < BFF_TAPE; i++) {
        uchar c = (i < BFF_PROG) ? a[i] : b[i - BFF_PROG];
        if (c == BFF_OP_LOOP) { stk[sp2++] = (uchar)i; }
        else if (c == BFF_OP_END) {
            if (sp2 > 0) { uchar o = stk[--sp2]; jt[o] = (uchar)i; jt[i] = o; }
            else jt[i] = BFF_JT_UNMATCHED;
        }
    }
    while (sp2 > 0) jt[stk[--sp2]] = BFF_JT_UNMATCHED;
}
```

Non-bracket entries are never read, so no table clearing is needed. Tables are rebuilt **every
epoch after mutation** (they'd be stale otherwise) but **not during a run** — see the semantic
caveat in 01 §3 / 06: programs that rewrite their own brackets mid-run see the epoch-start
matching. `dynamicScan` mode (function constant, §6) is the normative-semantics fallback.

Dispatch: `dispatchThreadgroups(P/128, threadsPerThreadgroup: 128)`,
`setThreadgroupMemoryLength(128*64, index: 0)`.

## 6. Kernel: `bff_interpret` (the core)

Design: one **thread = one pair**, lockstep within the simdgroup, halted lanes masked, uniform
`simd_all` early exit, tape staged to threadgroup memory, jump table read from device memory
(brackets are a minority of steps; tape bytes are touched every step — stage the thing that's
hot). Written as a grid-stride loop; in v2 only this outer pair-acquisition loop is replaced by
the per-simdgroup batch-claiming queue of §9.1 — the lockstep interior (stage-in, step loop,
stage-out, profiling) survives unchanged.

Function constants (set at PSO build; each combination gets its own pipeline):

```metal
constant bool kStageTapes   [[function_constant(0)]];  // default true — A/B this (06)
constant bool kDynamicScan  [[function_constant(1)]];  // default false (jump tables)
constant uint kProfileLevel [[function_constant(2)]];  // 0 off, 1 cheap, 2 detailed (04)
```

```metal
kernel void bff_interpret(
    device uchar*        soup        [[buffer(0)]],
    device const uint*   pairs       [[buffer(1)]],
    device const uchar*  jumpTables  [[buffer(2)]],
    device ProgStats*    progStats   [[buffer(3)]],
    device ProfCounters& prof        [[buffer(4)]],
    constant SimParams&  sp          [[buffer(5)]],
    uint gid  [[thread_position_in_grid]],
    uint gsz  [[threads_per_grid]],
    uint tid  [[thread_index_in_threadgroup]],
    uint lane [[thread_index_in_simdgroup]],
    threadgroup uint4* tgTapes [[threadgroup(0)]])      // TG * 8 uint4 = TG * 128 bytes
{
    // uint4-typed threadgroup storage guarantees the 16-byte alignment the vectorized
    // stage-in/out needs; a raw uchar* tile would make the uint4 casts UB. Byte-granular
    // interpreter access goes through the uchar view of the same slice.
    threadgroup uint4* tape4 = tgTapes + (uint)tid * 8;          // 8 × uint4 = 128 B slice
    threadgroup uchar* tape  = (threadgroup uchar*)tape4;        // or thread-local if !kStageTapes

    for (uint pair = gid; pair < sp.pairCount; pair += gsz) {   // uniform trip count (§3)
        const uint  ia = pairs[2*pair], ib = pairs[2*pair + 1];
        device uchar* pa = soup + (ulong)ia * BFF_PROG;
        device uchar* pb = soup + (ulong)ib * BFF_PROG;
        device const uchar* jt = jumpTables + (ulong)pair * BFF_TAPE;

        // ---- stage in: 64 B halves are 16-byte aligned → 4 uint4 loads each
        for (uint k = 0; k < 4; k++) {
            tape4[k]     = ((device const uint4*)pa)[k];
            tape4[k + 4] = ((device const uint4*)pb)[k];
        }

        // ---- machine state (registers)
        short  pc = 0;                    // signed: detects pc < 0 (matters for bff variant)
        ushort h0 = 0, h1 = 0;            // bff_noheads init; bff variant seeds from tape (01)
        ushort steps = 0, copyW = 0, loops = 0;
        uchar  halt = 0;

        // ---- lockstep run
        while (!simd_all(halt != 0)) {
            if (halt == 0) {
                if (steps >= (ushort)sp.stepBudget)     halt = BFF_HALT_BUDGET;
                else if (pc < 0 || pc >= BFF_TAPE)      halt = BFF_HALT_PC_OUT;
                else {
                    uchar op = tape[pc];
                    switch (op) {
                    case BFF_OP_H0L: h0 = (h0 - 1) & 127; break;
                    case BFF_OP_H0R: h0 = (h0 + 1) & 127; break;
                    case BFF_OP_H1L: h1 = (h1 - 1) & 127; break;
                    case BFF_OP_H1R: h1 = (h1 + 1) & 127; break;
                    case BFF_OP_INC: tape[h0]++; break;
                    case BFF_OP_DEC: tape[h0]--; break;
                    case BFF_OP_WR:  tape[h1] = tape[h0];
                                     copyW += (ushort)((h0 >> 6) != (h1 >> 6)); break;
                    case BFF_OP_RD:  tape[h0] = tape[h1];
                                     copyW += (ushort)((h0 >> 6) != (h1 >> 6)); break;
                    case BFF_OP_LOOP:
                        loops++;
                        if (tape[h0] == 0) {
                            uchar j = kDynamicScan ? scan_fwd(tape, pc)  : jt[pc];
                            if (j == BFF_JT_UNMATCHED) halt = BFF_HALT_UNMATCHED;
                            else pc = (short)j;
                        }
                        break;
                    case BFF_OP_END:
                        loops++;
                        if (tape[h0] != 0) {
                            uchar j = kDynamicScan ? scan_back(tape, pc) : jt[pc];
                            if (j == BFF_JT_UNMATCHED) halt = BFF_HALT_UNMATCHED;
                            else pc = (short)j;
                        }
                        break;
                    default: break;                       // 246 data values + null: no-op
                    }
                    pc++; steps++;
                }
            }
            PROF_LOOP_TICK(prof, lane, halt, steps);       // 04 §3 — compiles out at level 0
        }

        // ---- stage out + stats (both halves, both programs)
        for (uint k = 0; k < 4; k++) {
            ((device uint4*)pa)[k] = tape4[k];
            ((device uint4*)pb)[k] = tape4[k + 4];
        }
        ProgStats st = { steps, halt, 0, copyW, loops };
        progStats[ia] = st;
        progStats[ib] = st;
        PROF_PAIR_DONE(prof, lane, steps, halt, copyW);    // 04 §3
    }
}
```

Notes, in decreasing order of importance:

- **Early exit is uniform**: every lane in the simdgroup executes `simd_all` on every
  iteration (halted lanes just carry `halt != 0`), so the intrinsic is valid; the loop exits
  the moment all 32 lanes have halted. This is the entire divergence story for v1 — masked
  lanes cost nothing but the tail wait.
- **`scan_fwd`/`scan_back`** (dynamicScan mode) are ≤127-iteration depth-counting loops over
  *threadgroup* memory returning the match index or `BFF_JT_UNMATCHED`. Correct-by-definition
  (01 §3) but turns every taken `]` of a loop into an O(n) scan; used for validation runs and
  A/B semantics experiments, not the default.
- **No barriers anywhere**: each thread owns its 128 B threadgroup-memory slice exclusively;
  pairs are disjoint by construction (permutation), so no two threads touch the same soup
  bytes.
- **Register budget**: state is ~6 scalars + a few profiling accumulators; the switch is
  flat. Expect no spills; confirm with the Metal compiler report (occupancy in 04 §6).
- The interleaved uint4 stage-in of the two halves also *is* the concatenation — there is
  never a separate "build the 128-byte tape" step or buffer.

### Dispatch and sizing

- `threadsPerThreadgroup = 128` (4 simdgroups) → `setThreadgroupMemoryLength(128 * 128 = 16 KiB)`.
  Rationale: 32 KiB (TG=256) would allow only one threadgroup per core and no headroom;
  16 KiB targets 2 resident threadgroups/core. **The staging-vs-occupancy trade is the #1
  thing to measure on device** (06): `kStageTapes=false` (tape in `thread` address space,
  backed by L1) frees all threadgroup memory and may win on M4's cache hierarchy since each
  thread's working set is only 128 B + 128 B jump table.
- v1 grid: `dispatchThreadgroups(P / 128, threadsPerThreadgroup: 128)` — grid == pairCount,
  the stride loop runs once. Query `threadExecutionWidth` (expect 32) and
  `maxTotalThreadsPerThreadgroup` at startup and assert compatibility rather than assuming.

### Why no opcode binning / sorting by opcode

With 10 opcodes and a flat switch, worst-case control divergence costs ~10 serialized short
paths per step — a bounded constant. Any global "sort lanes by next opcode" scheme moves whole
machine states through memory every step and loses. (Research 2; Langdon & Banzhaf's SIMD GP
interpreter reaches the same conclusion.)

## 7. Kernel: `bff_mutate`

One thread per 4 soup bytes; exact per-byte Bernoulli draws (no aggregate shortcuts, keeps the
determinism contract simple).

```metal
kernel void bff_mutate(
    device uchar*       soup [[buffer(0)]],
    constant SimParams& sp   [[buffer(5)]],
    uint gid [[thread_position_in_grid]])
{
    uint base = gid * 4;                                  // soupBytes % 4 == 0 always
    for (uint k = 0; k < 4; k++) {
        uint r = rng3(sp.seed, sp.epoch * 4 + 0, base + k);
        if (r < sp.mutationP32)
            soup[base + k] = (uchar)(rng3(sp.seed, sp.epoch * 4 + 0,
                                          (base + k) ^ 0x80000000u) & 0xFF);
    }
}
```

8 MiB of hashing per epoch is noise next to the interpreter. Skipped entirely when
`mutationP32 == 0`.

## 8. Metrics kernels (consumed by 03/04)

**`bff_program_metrics`** — one thread per program; reads `soup`/`progStats`, applies the
temporal EMA against `metricEMA` (03 §4), writes `metricTex` level 0 (rgba16Float, 512×256):
R = activity `steps/8192`, G = copy `min(copyWrites/64, 1)`, B = byte entropy / 8,
A = **budget-halt indicator** `halt == BFF_HALT_BUDGET ? 1 : 0`.

A is deliberately a 0/1 scalar, **not** the categorical halt code: the texture is linearly
mipmapped, and a box-filtered average of halt codes {1,2,3} is meaningless — whereas the
average of a 0/1 indicator is "fraction of programs in this region halting on budget", which
is exactly the phase-transition signal (01 §3). The exact per-program halt *reason* is never
in the texture; it lives in `progStats` (Shared) and is read directly by the
inspector/tooltip (03 §8, 05 §7).

Entropy channel, exact semantics: the order-0 (plug-in) Shannon entropy of the program's 64
bytes, computed without histograms via the equal-count identity. For position i, `cᵢ` = the
number of bytes in this 64-byte program equal to `prog[i]` (so `cᵢ ≥ 1` always — the byte
matches itself). Then `H = (1/64) Σᵢ₌₀..₆₃ log2(64 / cᵢ)` — identical to
`−Σᵥ (nᵥ/64) log2(nᵥ/64)` summed over distinct values v, because each distinct value v
contributes nᵥ terms of `log2(64/nᵥ)/64`. Units: bits per byte, range [0, 6] (a 64-byte
window can hold at most 64 distinct values → max log2(64) = 6 bits, **not** 8). The channel
stores `H / 8` (normalizing by the 8-bit alphabet, matching 03 §4), so the achievable range
is [0, 0.75]: uniform-random programs read ≈ 0.71–0.75, replicators far lower. O(64²) = 4 K
compares per program, pure registers/L1; 131 K programs runs in well under a millisecond,
once per command buffer, not per epoch.

```metal
kernel void bff_program_metrics(
    device const uchar*     soup      [[buffer(0)]],
    device const ProgStats* progStats [[buffer(3)]],
    constant SimParams&     sp        [[buffer(5)]],
    device float4*          metricEMA [[buffer(6)]],   // temporal smoothing state (03 §4)
    texture2d<half, access::write> metricTex [[texture(0)]],
    uint gid [[thread_position_in_grid]])
{
    device const uchar* prog = soup + (ulong)gid * BFF_PROG;
    ProgStats st = progStats[gid];

    float H = 0.0f;
    for (uint i = 0; i < BFF_PROG; i++) {
        uchar bi = prog[i];
        uint  ci = 0;                            // count of bytes equal to prog[i]
        for (uint j = 0; j < BFF_PROG; j++) ci += (prog[j] == bi);
        H += log2(64.0f / (float)ci);            // ci >= 1, so finite
    }
    H *= (1.0f / 64.0f);                         // bits/byte, in [0, 6]

    float4 raw = float4((float)st.steps / 8192.0f,
                        min((float)st.copyWrites / 64.0f, 1.0f),
                        H / 8.0f,
                        st.halt == BFF_HALT_BUDGET ? 1.0f : 0.0f);
    float4 ema = mix(raw, metricEMA[gid], sp.emaAlpha);   // out = α·prev + (1−α)·new
    metricEMA[gid] = ema;
    metricTex.write((half4)ema, uint2(gid % sp.gridWidth, gid / sp.gridWidth));
}
```

**`generateMipmaps(metricTex)`** via blit encoder immediately after — gives the renderer a
box-filtered pyramid for the zoomed-out view (03 §4).

**`bff_histogram`** — global 256-bin byte histogram: per-threadgroup `threadgroup atomic_uint
bins[256]` (1 KiB), each thread accumulates a strided range of soup bytes locally, then one
`atomic_fetch_add` per bin into the device `histogram`. CPU converts to global Shannon entropy
+ per-symbol frequencies for the HUD (03 §7). Runs every `metricsEvery` epochs.

**Epoch summaries** (mean steps, halt mix, copy totals) come free out of `ProfCounters`
(04 §2) — no separate reduction kernel in v1; the CPU also has `progStats` mapped Shared for
anything ad hoc (inspector, top-k activity for self-rep checks).

## 9. v2: structural fixes for the tail effect

Ship v1 first; adopt these only when the 04 counters prove the need (tail ratio high, late-
dispatch utilization low):

1. **Persistent threads + per-simdgroup batch claiming** (Aila & Laine / Gupta). Dispatch a
   fixed fill-the-GPU grid (≈ cores × 2 threadgroups × 128; tune on device). What changes vs
   v1 is **only the outer pair-acquisition loop**; the lockstep interior (stage-in, step loop,
   stage-out, profiling macros) is untouched. The grid-stride loop is replaced by:

   ```metal
   // device atomic_uint* nextPair — zeroed at the start of each epoch's interpret pass
   while (true) {
       uint base;
       if (simd_is_first_active_lane())
           base = atomic_fetch_add_explicit(nextPair, 32u, memory_order_relaxed);
       base = simd_broadcast_first(base);
       if (base >= sp.pairCount) break;      // P is a multiple of 32 (N power of two ≥ 512),
       uint pair = base + lane;              // so a batch is fully valid or fully past-end
       // ... stage in, lockstep run, stage out — identical to v1 ...
   }
   ```

   Why batches of **exactly 32, claimed once per simdgroup**: the v1 early-exit invariant —
   `simd_all(halt != 0)` means "all 32 lanes are done with the pairs of *this* iteration" —
   holds only while all 32 lanes of a simdgroup work the same batch. In v1 the grid sizing
   (§3) guarantees that; a naive per-*lane* queue (each lane grabbing its own next pair as it
   halts) breaks it — lanes end up on different pairs, `simd_all` no longer describes any one
   batch, and the profiling ballots (04 §3) would mix batches. Batch claiming preserves the
   invariant by construction: the first active lane claims a 32-pair batch with one
   `atomic_fetch_add`, broadcasts the base, lane i runs `base + i`, and **all 32 lanes stay
   together on that batch until every lane has halted** — only then does the simdgroup claim
   the next batch, together. This is also why the claim granularity is pinned to the SIMD
   width, not the threadgroup: claims and exits must be simdgroup-uniform. A simdgroup that
   drew short runs goes back for more instead of idling until the epoch ends. One atomic RMW
   per 32 interactions → ~2 K/epoch: contention-free by construction; confirm with the queue
   counters (04). (An earlier draft claimed the v1 kernel body "survives unchanged" into v2 —
   wrong: the uniform trip count of the stride loop is precisely what made `simd_all` valid,
   and this batch-claiming structure is what re-establishes it.)
2. **Run-length binning** (duration-coherent simdgroups). Every K epochs (K≈16), bucket pair
   indices by *predicted* duration — predictor: `max(progStats[a].steps, progStats[b].steps)`
   from each program's previous interaction — into 8 power-of-two buckets; CPU counting-sort
   while filling the pairing ring (it already owns that data path). Queue serves longest
   buckets first. Effect: lanes in a simdgroup halt together, early-exit fires early; longest-
   first keeps the true stragglers off the epoch's tail.
3. **Prefix-sum lane compaction** — repack live lanes across a simdgroup mid-run
   (`simd_prefix_exclusive_sum` on the active mask; move ~8 B of state + swap tape slice
   pointers through threadgroup memory). Only worth it if profiling shows long stretches at
   <50 % lane activity *after* (1)+(2); expected unnecessary once binning works. Keep behind
   a function constant.

## 10. Build order (concrete)

| Stage | Contents | Exit criterion |
|---|---|---|
| **v0 (CPU oracle)** | Swift interpreter of 01, scalar, **both bracket modes** + remap-event counter; property tests incl. bracket edge cases; `cubffCompat` RNG/pairing mode | Fixed seeds produce stable golden outputs; property tests pass |
| **v0.5 (grounding)** | One-time cubff golden-vector capture + oracle reproduction (01 §7.1); confirm the six alignment tags (01 §7.4) against cubff source | Oracle reproduces cubff soup + histogram **bit-identically** at epochs {128, 1024, 16384}; all six tags recorded as confirmed/corrected in 06 D2 |
| **v1** | All kernels above: lockstep + masking, jump tables, `simd_all` early exit, tape staging (function-constant A/B), grid-stride, whole soup one Shared buffer, ProfCounters level 1 | GPU output bit-identical to v0 per 01 §7.2 (10⁴ random pairs, both bracket modes + epoch-trajectory hashes); phase transition reproduces at defaults |
| **v1.5** | D1 replicator experiment (01 §7.3), `kStageTapes` A/B decision, mutate-skip, self-rep checker batch | D1 resolved (bracket-mode default decided and recorded in 06); perf numbers recorded in 06 checklist |
| **v2** | Persistent threads + batch-claiming queue (§9.1) → then length binning → then (only if counters demand) lane compaction; spatial pairing variant | Post-transition epochs/s improves ≥1.5× or counters prove tail is not the limiter; 01 §7.2 diff still clean |

Correctness harness (v0↔v1) runs both interpreters on identical `(tape pair, variant)` inputs
and diffs final tapes + steps + halt reason; the full chain (cubff → oracle → GPU) is
specified in 01 §7. The 01 §7.2 diff re-runs after **every** optimization. This is
non-negotiable before any perf work.
