# 01 — BFF Specification

Source of truth: Agüera y Arcas et al., *Computational Life*, arXiv:2406.19108, and the
reference implementation `github.com/paradigms-of-intelligence/cubff` (authoritative where the
paper is vague). This document is written to be sufficient to implement the interpreter without
consulting either. The former "**verify vs cubff**" tags have been resolved: all six
alignment points are confirmed (one corrected) against cubff source at pinned commit
`f212e849027c98fcf4b242eccfb5fed435223e23` — citations, fixtures, and the precise parity
claim live in [../CubffGrounding.md](../CubffGrounding.md).

## 1. Constants

```swift
enum BFF {
    static let tapeSize      = 64          // kSingleTapeSize: bytes per program
    static let pairTapeSize  = 128         // two programs concatenated
    static let stepBudget    = 8192        // 8 * 1024 steps per interaction
    static let defaultSoup   = 131_072     // 128 * 1024 programs
    static let mutationP32   = UInt32(1 << 20)  // per-byte per-epoch: p = 2^20/2^32 = 1/4096
    static let metricsEvery  = 128         // epochs between heavyweight metrics
}
```

## 2. Alphabet and command encoding

The tape alphabet is the full byte range 0–255. Exactly **10 values are commands**; all other
values are inert data (no-op when executed). **Byte 0 is "null"** — it is the value the loop
commands test against (there is no separate "zero flag"); it is also a no-op as an instruction.

| Char | Meaning |
|---|---|
| `<` | `head0 -= 1` |
| `>` | `head0 += 1` |
| `{` | `head1 -= 1` |
| `}` | `head1 += 1` |
| `+` | `tape[head0] += 1` (wrapping mod 256) |
| `-` | `tape[head0] -= 1` (wrapping mod 256) |
| `.` | `tape[head1] = tape[head0]` ("write") |
| `,` | `tape[head0] = tape[head1]` ("read") |
| `[` | if `tape[head0] == 0`: jump forward past matching `]`; else fall through |
| `]` | if `tape[head0] != 0`: jump backward past matching `[`; else fall through |

Note the two-head asymmetry vs standard Brainfuck: `{`/`}` move a *second* head, and `.`/`,`
copy bytes *between the two head positions* instead of doing I/O. `.` and `,` are the copy
primitives replication is built from.

**Byte values of the commands.** The dynamics only require that some fixed 10 of 256 values be
commands and that 0 be null. We adopt the ASCII codes, which is what cubff's textual
CommandRepr `"[]+-.,<>{}"` corresponds to:

```c
// MSL + Swift shared header (BFFShared.h)
#define BFF_OP_H0L  0x3C  // '<'
#define BFF_OP_H0R  0x3E  // '>'
#define BFF_OP_H1L  0x7B  // '{'
#define BFF_OP_H1R  0x7D  // '}'
#define BFF_OP_INC  0x2B  // '+'
#define BFF_OP_DEC  0x2D  // '-'
#define BFF_OP_WR   0x2E  // '.'   tape[head1] = tape[head0]
#define BFF_OP_RD   0x2C  // ','   tape[head0] = tape[head1]
#define BFF_OP_LOOP 0x5B  // '['
#define BFF_OP_END  0x5D  // ']'
```

**Confirmed vs cubff** (`bff.inc.h` `GetOpKind`, pinned in [../CubffGrounding.md](../CubffGrounding.md) §1):
the reference dispatches on exactly these ASCII values; byte 0 is null, all other values are
no-ops. The choice subtly matters (e.g. under ASCII, `+` applied twice turns `[` (0x5B) into
`]` (0x5D)), so exact reproduction of published runs requires the same table. Keep it a single
constant table in the shared header so it is swappable.

## 3. Interaction: two programs, one tape

One "interaction" runs a pair of programs (A, B):

1. Concatenate: `tape[0..63] = A`, `tape[64..127] = B` — a single 128-byte tape.
2. Execute (below) for up to 8,192 steps.
3. Write **both halves back**: `A = tape[0..63]`, `B = tape[64..127]`.

There is **no protection boundary**: heads and pc address the whole 128 bytes, so A can read,
overwrite, and be overwritten by B. Mutual modification *is* the copy/replication mechanism.

### Machine state

- `pc` — program counter, signed conceptually; execution index into the 128-byte tape.
- `head0`, `head1` — data heads, indices into the same 128-byte tape.
- The tape itself (self-modifiable, including bytes currently ahead of pc).

Head moves **wrap mod 128** (`head &= 127`). The pc does *not* wrap — see halting.

### Initial state (variants)

| Variant | Initial state |
|---|---|
| **bff_noheads** (cubff repo default; **our default**) | `pc = 0`, `head0 = 0`, `head1 = 0` |
| bff (paper's original) | `head0 = headpos(tape[0])`, `head1 = headpos(tape[1])`, `pc = 2` — the first two tape bytes seed the head positions (`headpos(b) = b % 128`; **confirmed vs cubff** `bff.inc.h` `InitialState`/`headpos`, [../CubffGrounding.md](../CubffGrounding.md) §2) |

Implement `bff_noheads` first; the variant is a per-run config enum. All downstream design
(02–05) is variant-agnostic.

### Step semantics (normative pseudocode)

```text
steps = 0
loop:
    if steps == 8192:        halt(BUDGET)
    if pc < 0 or pc >= 128:  halt(PC_OUT)          # pc does not wrap
    op = tape[pc]
    switch op:
        '<': head0 = (head0 - 1) & 127
        '>': head0 = (head0 + 1) & 127
        '{': head1 = (head1 - 1) & 127
        '}': head1 = (head1 + 1) & 127
        '+': tape[head0] += 1        (mod 256)
        '-': tape[head0] -= 1        (mod 256)
        '.': tape[head1] = tape[head0]
        ',': tape[head0] = tape[head1]
        '[': if tape[head0] == 0:
                 pc = match_forward(pc)    # matching ']' index; no match ⇒ flag UNMATCHED
        ']': if tape[head0] != 0:
                 pc = match_backward(pc)   # matching '[' index; no match ⇒ flag UNMATCHED
        default: no-op                     # includes byte 0 and all 246 data values
    pc += 1
    steps += 1
    if UNMATCHED flagged: halt(UNMATCHED)  # checked AFTER pc/steps — see bullet below
```

Conventions locked down here (all consistent with "scan to the match, then the shared `pc += 1`
moves past/into it"):

- A **taken `[`** lands on the matching `]`; the `pc += 1` then continues *after* the loop.
- A **taken `]`** lands on the matching `[`; the `pc += 1` then re-enters the loop body.
  (The `[` itself is not re-executed — its condition was logically just tested by `]`.)
- **Every executed op costs exactly 1 step**, including no-ops and non-taken brackets.
  Bracket *scanning* cost is an implementation detail (jump table vs dynamic scan, see 02);
  the step count is defined as op executions. **Confirmed vs cubff** (`bff.inc.h` `Evaluate`
  budget loop; [../CubffGrounding.md](../CubffGrounding.md) §4): the reference never counts
  scan iterations. Refinement adopted: cubff's *reported* op count subtracts executed
  null/non-command "comment" bytes (`i - nskip`); the oracle exposes that as
  `InteractionResult.commandSteps` while `steps` keeps the budget-accounting meaning.
- **Unmatched bracket** on a *taken* branch = hard halt: cubff implements this by setting pc
  out of range; we record it as a distinct halt reason `UNMATCHED` (it is the same event).
  **Canonical timing**: the halting bracket is still a fully executed op — it consumes
  **exactly one step** and the shared `pc += 1` runs **once** before the halt is recorded
  (in the pseudocode above, the UNMATCHED flag is checked *after* `pc += 1; steps += 1`).
  **Confirmed vs cubff** ([../CubffGrounding.md](../CubffGrounding.md) §4/§5, plus the
  `unmatched-*` golden fixtures): the failed scan parks pc at 128/−1 and the loop still
  charges the step before breaking.
  A non-taken unmatched bracket is harmless (falls through as no-op + condition test).

### Bracket matching (normative)

`match_forward(p)`: scan `q = p+1 .. 127`, tracking depth: `[` increments, `]` decrements;
return the `q` where depth returns to zero. `match_backward(p)` is symmetric, scanning
`q = p-1 .. 0`. Matching is over the **current** tape contents at the moment the bracket
executes — self-modification can change the match. Because our fast path precomputes matches
once per interaction (jump tables, 02 §5), programs that rewrite their own brackets mid-run
behave differently under the fast path; a `dynamicScan` mode preserves the normative semantics
for validation. This is the biggest deliberate semantic risk in the design — see 06.

### Halt reasons (recorded per interaction)

```c
// INFORMATIVE COPY — the owning definition of BFFHaltReason lives in BFFShared.h (02 §1).
// It is reproduced here for readability only; do not declare it twice in code, and if the
// two docs ever disagree, 02 §1 wins.
typedef enum : uint8_t {
    BFF_HALT_BUDGET    = 1,  // 8192 steps exhausted
    BFF_HALT_PC_OUT    = 2,  // pc walked off either end of the tape
    BFF_HALT_UNMATCHED = 3,  // taken bracket with no match
} BFFHaltReason;
```

Every interaction halts: the budget guarantees termination. Pre-transition, `PC_OUT` after
~O(128) steps dominates (random bytes are mostly no-ops and the pc marches off the end);
post-transition, `BUDGET` dominates (replicator copy loops). The halt-reason mix is therefore a
cheap phase-transition detector — we surface it in the HUD (04).

## 4. Soup dynamics (epoch loop)

```text
soup = N × 64 random bytes (seeded PRNG)
for epoch = 0, 1, 2, ...:
    1. MUTATE:  each byte of the soup is independently replaced by a uniform random
                byte (0–255, may be 0 or a command) with probability 2^20/2^32 ≈ 1/4096.
                Mutation rate 0 is a supported and interesting mode (self-modification
                alone supplies variation). No mutation occurs during execution.
    2. PAIR:    well-mixed default — Fisher–Yates shuffle of the N program indices;
                consecutive entries (2i, 2i+1) form pair i. Every program is in exactly
                one pair per epoch.
    3. RUN:     all P pairs execute the interaction of §3 independently (order-free,
                embarrassingly parallel — this is the GPU kernel).
    4. METRICS: lightweight stats every epoch (steps, halt reasons — free byproducts);
                heavyweight metrics every 128 epochs (compression proxy, histograms,
                self-replicator checks).
```

Ordering note: mutate-then-run within an epoch. Mutation is frozen during step 3 (a GPU-pass
boundary makes this natural). **Confirmed vs cubff, with a retained order difference**
([../CubffGrounding.md](../CubffGrounding.md) §3): the reference shuffles first and mutates the
*concatenated pair tape* just before evaluating it (pair → mutate → run). Because every program
is in exactly one pair and mutation never happens mid-run in either scheme, the per-epoch
composition is identical; only the RNG stream indexing differs, which is subsumed by the
deliberate RNG-contract difference (`counter-pcg-v1` vs cubff's SplitMix64 counters).

### Spatial 2-D variant (opt-in)

Instead of a global shuffle, programs sit on a fixed 2-D grid and pair only with nearby
programs. To keep "every program in exactly one pair" (required for race-free parallel
execution), we implement locality as a **random local perfect matching**: each epoch pick a
random axis (H or V), a random parity offset (0/1), and optionally a random stride
r ∈ {1, 2, 4}, then pair cell (x, y) with its neighbor along that axis at distance r,
checkerboard-style, with toroidal wrap. Over epochs this approximates cubff's neighbor
sampling while guaranteeing disjoint pairs. **Deliberate deviation from cubff's neighbor-list
scheme** — flagged in 06; the pairing generator is pluggable so the exact cubff scheme can be
added later. In this variant grid position is *intrinsic* and the visualization (03) becomes a
true spatial map (replicator fronts, waves).

## 5. Metrics and emergence detection

- **Compression proxy for Kolmogorov complexity** (the paper's headline metric): compress the
  entire 8 MiB soup with Brotli and record the compressed size. Random soup ≈ incompressible;
  the phase transition appears as a sharp *drop* in compressed size. We compute this on the
  CPU every 128 epochs from the shared soup buffer (background thread). Default build uses
  Apple Compression (zlib level; adequate to show the transition); vendored Brotli is the
  parity option (06).
- **Ops per interaction**: mean/percentiles of `steps` across pairs. Spikes at the transition.
  Free — the interpreter already counts steps per pair.
- **Halt-reason mix**: fraction BUDGET vs PC_OUT vs UNMATCHED per epoch. Free.
- **Byte histogram / Shannon entropy** of the whole soup, and per-region for the
  visualization (03 defines where each is computed).
- **Self-replicator check** (cubff `CheckSelfRep`, run on demand / every 128 epochs on the
  top-k most active programs): pair the candidate with a fresh 64-byte noise program, run the
  interaction, then feed the **offspring half** (`tape[64..127]`) forward as the next
  candidate with the *same* noise refilled behind it, for 4 extra generations; do this for
  13 independent noise trials. Score: a byte position qualifies if some trial value at that
  position is shared by ≥ 4 of the 13 trials (first-half positions must also equal the
  original program byte); the score is min(first-half count, second-half count), and the
  program classifies as a self-replicator at score ≥ 5.
  **Confirmed vs cubff** (`common_language.h` `CheckSelfRep`;
  [../CubffGrounding.md](../CubffGrounding.md) §6 — which also corrects this spec's two
  earlier wrong assumptions: the offspring half feeds forward, and agreement is ≥ 4-of-13,
  not all-13). Implemented as a small GPU batch (13 × 5 evaluations is nothing); v1.5
  feature, not needed to observe the transition.

Expected timeline (well-mixed, defaults): transition onset around ~10³ epochs; readable as (a)
compressed-size cliff, (b) mean-steps spike toward budget, (c) halt-mix flip to BUDGET, (d) the
zoomed-out entropy view (03) visibly shifting as replicator bytes take over the soup.

## 6. Determinism contract

Given (seed, config), a run is bit-reproducible:

- All randomness (soup init, mutation, pairing shuffle, self-rep noise) derives from counter-
  based hashes of `(seed, streamID, epoch, index)` — no stateful RNG shared across threads.
  PCG-hash (02 §7) on GPU; the same function in Swift for CPU-side shuffles.
- Pair execution is order-independent (disjoint tape ranges), so GPU scheduling cannot change
  results. Profiling counters use atomics but never feed back into simulation state.
- Reproducibility does **not** extend to fixed-seed *trajectory* parity with cubff: the RNG
  contracts deliberately differ, and that parity is an explicit non-goal for v1 (the goal is
  reproducing the *phenomenon*, same statistics — not the same trajectory). What *is*
  bit-exact against cubff is per-interaction evaluator behavior, proven by the §7.1 grounding
  fixtures ([../CubffGrounding.md](../CubffGrounding.md)).

## 7. Validation chain (golden vectors; resolves 06 D1/D2)

Three links. Link 1 runs **once** (grounding — performed, see §7.1 status); links 2–3 run
**continuously** (CI, and after every kernel optimization). This section is the concrete plan
behind the §7.4 alignment tags, and it is the decision procedure for 06 D1 (jump table vs
dynamic scan).

### 7.1 Link 1 — cubff → CPU oracle (one-time grounding)

> **Status (2026-07): grounding performed at the evaluator level.** The six §7.4 tags are
> confirmed (tag 6 corrected) directly from cubff source at pinned commit
> `f212e849027c98fcf4b242eccfb5fed435223e23`, and 59 genuine fixtures generated by executing
> the unmodified pinned evaluator pin the oracle's interaction semantics exactly —
> see [../CubffGrounding.md](../CubffGrounding.md). The whole-soup `cubffCompat` replay
> described below remains optional future work; it is the only part of link 1 still open,
> and it gates nothing (evaluator semantics, where five of the six tags live, are grounded).

Build cubff at a pinned commit; run the `bff_noheads` variant at default parameters
(N = 131,072, T = 64, budget 8,192, mutation 1/4096) with a fixed, recorded seed. Dump at
checkpoint epochs **{128, 1024, 16384}** (two pre-transition, one comfortably past typical
onset): the **exact full soup bytes** and the **global 256-bin byte histogram**. Check these
into the repo as golden vectors
(`Tests/Golden/cubff-<commit>-seed<S>-epoch<E>.soup` / `.hist`), together with the exact
command line.

The CPU oracle must reproduce all three checkpoints **bit-identically, one time**. Because a
full trajectory depends on every random draw, the oracle gets a **`cubffCompat` mode**: a port
of cubff's RNG, soup initialization, mutation draw order, and pairing shuffle, taken from the
cubff source (they are *not* our counter-based PCG of §6). This mode exists only in the oracle
and only for grounding; production randomness stays §6. This is deliberate: matching the
trajectory once grounds the oracle against the paper's *actual* semantics — every subsequent
GPU validation (link 2) then inherits that grounding transitively.

Diagnosis path on mismatch: find the first checkpoint whose *histogram* diverges, bisect to
the first divergent epoch, then dump per-interaction records `(pre-pair-tape, post-tape,
steps, halt)` from both sides at that epoch and diff. The six tags of §7.4 are the likely
culprits, roughly in the order listed.

Fallback (only if cubff's RNG proves impractical to mirror): instrument cubff to log ~10⁵
interaction triples `(pre-tape pair → post-tape, steps)` and diff at interaction granularity.
Weaker — it does not ground the mutate/pair ordering (tag 3), which must then be confirmed by
source reading alone — but it still grounds the interpreter semantics, where five of the six
tags live.

### 7.2 Link 2 — CPU oracle → GPU (continuous)

Bit-identical diff on identical `(seed, config)`, both bracket modes, both variants:
(a) 10⁴ random pairs (02 §10 harness) diffing final tapes + steps + halt reason, and
(b) full-epoch trajectories asserting identical soup hash at epochs {1, 128, 1024}.
Runs in CI via the headless CLI and is re-run after **every** kernel optimization — the
determinism contract (§6) makes "bit-identical" a meaningful, cheap assertion.

### 7.3 Link 3 — bracket-mode divergence on known replicators (the D1 decision procedure)

The oracle implements **both** bracket modes from day one: true dynamic scan (normative, §3)
and the jump-table fast path (matches frozen at interaction start, 02 §5). It also counts
**remap events**: a taken bracket whose live-scan match differs from the epoch-start table
entry — i.e. exactly the moments the fast path is wrong.

Random pre-transition pairs almost never rewrite their own brackets mid-run, so the 10⁴-random-
pairs diff is necessary but **not sufficient** for D1. The concrete experiment:

1. Run to post-transition (either mode) and extract the top-16 programs by `copyWrites`
   (known replicators).
2. For each candidate: 13 independent noise seeds × 4 generations of the CheckSelfRep protocol
   (§5) — i.e. replicator vs fresh 64-byte noise — executed under **both** bracket modes.
3. Diff final tapes per generation, the replicator classification, and the remap-event counts.

Decision rule: if any replicator lineage changes classification or produces different
offspring bytes, the jump table is semantically unsafe where it matters and **dynamicScan
becomes the default** (jumpTable demoted to an opt-in speed mode, or the per-interaction
rebuild is tightened to re-scan only on writes to bracket bytes). If remap events occur but
never change outcomes, jumpTable stays the default and the measured remap rate is recorded in
06 D1.

### 7.4 The six cubff-alignment tags — CONFIRMED

All six tags were verified directly against cubff source at pinned commit
`f212e849027c98fcf4b242eccfb5fed435223e23`; exact file/line citations and the golden fixtures
that pin each behavior live in [../CubffGrounding.md](../CubffGrounding.md).

| # | Tag | Verified answer | Status |
|---|---|---|---|
| 1 | Opcode byte values | ASCII table of §2 (`"[]+-.,<>{}"`); byte 0 null, all else no-op | **Confirmed** (`bff.inc.h` `GetOpKind`/`CommandRepr`) |
| 2 | Initial pc/heads | `noheads`: pc = h0 = h1 = 0 (cubff writes 128, masked to 0 before first use). `bff`: h0 = tape[0] % 128, h1 = tape[1] % 128, pc = 2 | **Confirmed** (`bff.inc.h` `InitialState`/`headpos`) |
| 3 | Mutate-vs-run order | cubff: pair → mutate concatenated tape → run; no mutation mid-run. Oracle keeps mutate → pair → run — identical per-epoch composition, different RNG indexing (subsumed by the RNG-contract difference) | **Confirmed, order difference retained** (`common_language.h` `MutateAndRunPrograms`) |
| 4 | Step counting | every executed op = 1 step incl. no-ops, non-taken brackets, and the halting taken-unmatched bracket; scan iterations never count. cubff's *reported* ops = steps − comment steps (oracle: `commandSteps`) | **Confirmed + refinement adopted** (`bff.inc.h` `Evaluate`) |
| 5 | Loop re-entry landing | taken `]` lands **on** the matching `[`; the shared `pc += 1` re-enters the body; the `[` is **not** re-executed. Scans always read the live tape (cubff has no jump table) | **Confirmed** (`bff.inc.h` `EvaluateOne`) |
| 6 | CheckSelfRep accounting | the **offspring** half (`tape[64..127]`) feeds forward with the same noise refilled; byte qualifies at ≥ 4-of-13 trial agreement (first half must also equal the original); score = min(halves); classify at ≥ 5 | **Confirmed — two spec assumptions corrected** (`common_language.h` `CheckSelfRep`) |

Tag 5 is the one most entangled with self-modification: whether the `[` is re-executed
determines whether a `[` byte rewritten mid-loop gets re-tested on re-entry — it changes
replicator behavior directly, so it had to be settled **before** the §7.3 experiment is
meaningful. It now is: cubff does not re-execute the `[`, and every taken bracket re-scans
the live tape.
