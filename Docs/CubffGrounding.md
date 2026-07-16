# cubff Grounding — pinned revision, findings, fixtures, and what "parity" means

This document records the one-time source grounding of the Swift CPU oracle
(`Sources/BFFOracle`) against the authoritative public BFF implementation. It replaces the
"assumed, unverified" status of the six alignment tags in
[Architecture/01-bff-spec.md](Architecture/01-bff-spec.md) §7.4.

## Pinned upstream revision

| | |
|---|---|
| Repository | <https://github.com/paradigms-of-intelligence/cubff> |
| Commit | `f212e849027c98fcf4b242eccfb5fed435223e23` ("Fix paper name (#45)", 2025-08-17, upstream `main` at grounding time) |
| Evaluator source | `bff.inc.h` (shared by `bff.cu` = `BFF_HEADS`, and `bff_noheads.cu`) |
| Simulation source | `common_language.h` (`InitPrograms`, `MutateAndRunPrograms`, `CheckSelfRep`, `RunSimulation`), `common.h` (constants, params), `main.cc` (flag defaults) |
| Build used | upstream CPU path (`make CUDA=0` semantics): plain host C++17, g++ 12.2.0, no CUDA. `__device__`/`__host__`/`__global__` are defined away by `common_language.h` when `__CUDACC__` is absent — the evaluator code compiled is byte-for-byte the CUDA code. |

The checkout is external and never vendored; `Tools/cubff-grounding/generate.sh` re-clones and
hard-checks the SHA before generating anything.

**CPU build validated against upstream's own goldens.** `test.sh bff_noheads` and `test.sh bff`
(full 131,072-program, 256-epoch simulations, seed 10248) reproduce upstream's checked-in
`testdata/bff_noheads.txt` and `testdata/bff.txt` **bit-exactly** when linked against brotli
1.1.0. With Debian's brotli 1.0.9 the logged `brotli_size`/`higher_entropy` columns differ by
~0.005% while epoch-1 values still match — the divergence is entirely the compression *stat*,
not the soup: the brotli version affects only the logged compressed size, never the simulation.
This validates that the host build of the pinned evaluator+simulation is faithful to the
implementation that produced upstream's reference outputs.

## The six alignment points, verified from source

Line numbers refer to the pinned commit. Stable URLs:
`https://github.com/paradigms-of-intelligence/cubff/blob/f212e849027c98fcf4b242eccfb5fed435223e23/<file>#L<line>`.

### 1. Opcode byte values and dispatch — CONFIRMED

`bff.inc.h:58-89` (`GetOpKind`): dispatch is a `switch` on the raw byte as a `char` with ASCII
case labels — `'['`/`']'`/`'+'`/`'-'`/`'.'`/`','`/`'<'`/`'>'`/`'{'`/`'}'`; byte `0` is `kNull`,
every other value `kNoop`. `bff.inc.h:91` pins `CommandRepr() = "[]+-.,<>{}"`. Op actions
(`bff.inc.h:289-349`, `EvaluateOne`): `<`/`>` move head0, `{`/`}` move head1, `+`/`-` are
wrapping inc/dec of `tape[head0]`, `.` is `tape[head1] = tape[head0]`, `,` is
`tape[head0] = tape[head1]`. Byte values ≥ 0x80 convert to negative `char` and hit `default:`
(no-op) — no high-byte aliases onto commands. Matches `BFFOp` exactly.

### 2. Initial head0/head1/pc per variant — CONFIRMED

`bff.inc.h:269-283` (`InitialState`):

- `bff_noheads` (no `BFF_HEADS`): `head0 = head1 = 2*kSingleTapeSize` (=128), `pc = 0`.
  Heads are masked `& 127` at the **top** of every `Evaluate` iteration
  (`bff.inc.h:368-369`) before any use, so 128 is observationally head 0. The oracle's
  `pc = 0, h0 = 0, h1 = 0` is byte-equivalent.
- `bff` (`BFF_HEADS`, set by `bff.cu:15`): `head0 = headpos(tape[0])`,
  `head1 = headpos(tape[1])`, `pc = 2`, with `headpos(b) = b % (2*kSingleTapeSize)` = `b % 128`
  (`bff.inc.h:50-52`). Matches `BFFVariant.seededHeads`.

### 3. Mutation placement/order vs pair concatenation — CONFIRMED SEMANTICS, DIFFERENT ORDER

`common_language.h:157-193` (`MutateAndRunPrograms`): per epoch, the host first builds the
pairing permutation (shuffle, `common_language.h:418-424` + `:464-486`), then each worker:
**concatenates** its pair into a 128-byte tape (`:168-171`), **then mutates** all 128 bytes of
the concatenated tape (`:172-180`), **then evaluates** (`:182-187`), then writes both halves
back (`:188-191`). So cubff's order is *pair → mutate → run*; mutation is frozen during
execution (no mid-run mutation), and every program is mutated exactly once per epoch because
the permutation covers each program once.

Mutation draw (`:172-180`): `rng = SplitMix64((num_programs*seed_e + pairIndex)*128 + i)`;
replacement byte = `rng & 0xFF`; mutate iff `(rng >> 8) & (2^30 - 1) < mutation_prob` —
**denominator 2^30**, default `mutation_prob = 1 << 18` (`common.h:61`; `main.cc` flag default
`1.0/(256*16)` = 1/4096).

The oracle's epoch order is *mutate soup → pair → run* (`Simulation.runEpoch`). Because each
program appears in exactly one pair and mutation is frozen during execution in both, the two
orders compose to the same per-epoch map; only the RNG stream indexing differs. This is an
**intentional retained difference**: the oracle keeps its `counter-pcg-v1` contract (2^32
denominator, PCG streams) rather than porting cubff's SplitMix64 indexing. Consequence: no
fixed-seed whole-soup parity — see "What parity means" below.

### 4. Step accounting — CONFIRMED, with one refinement adopted

`bff.inc.h:356-389` (`Evaluate`): the budget loop `for (i = 0; i < stepcount; i++)` ticks once
per executed byte — no-ops, null bytes, and non-taken brackets all consume budget; bracket
*scan* iterations never do. On a halt (pc < 0 or pc ≥ 128 after an op), the loop still runs
`i++` before breaking (`:377-386`), so the halting op — including a **taken-but-unmatched
bracket** (which parks pc at 128/-1, `:326-328`/`:340-342`) — costs exactly one step. This
confirms alignment tag 4 including its extension to the unmatched case, and it matches the
oracle's `steps` exactly.

Refinement: cubff's *reported* op count (the `Evaluate` return, fed to `insn_count`) is
`i - nskip` (`:388`), where `nskip` counts executed "comments" — byte 0 and every non-command
byte (`EvaluateOne` returning `false`, `:345-347`). The oracle now records this as
`InteractionResult.noopSteps` / `commandSteps` (`commandSteps = steps - noopSteps` = cubff's
return value); `steps` (budget accounting) is unchanged.

### 5. Loop scan and re-entry landing — CONFIRMED

`bff.inc.h:317-330` (taken `[` with `tape[head0] == 0`): depth-counting **forward scan of the
live tape** starting at `pc+1`; on success `EvaluateOne` leaves pc *on* the matching `]` and
the shared `pos++` (`:381`) resumes execution one past it. On failure pc is parked at 128 →
halt after the step is charged.

`bff.inc.h:331-344` (taken `]` with `tape[head0] != 0`): backward scan from `pc-1`; on success
pc is left *on* the matching `[` and the shared `pos++` resumes **one past the `[`** — the `[`
is **not** re-executed and its condition is not re-tested on re-entry. On failure pc is parked
at −1 → halt after the step is charged.

Both scans re-read the **current, possibly self-modified tape** on every taken bracket: cubff
has **no jump table**. The oracle's `.dynamicScan` is therefore the cubff-normative mode; its
`.jumpTable` mode is a deliberate GPU-motivated deviation whose divergence on self-modifying
programs is pinned by the `self-modified-bracket-live-scan` fixture plus
`CubffFixtureTests.testKeyCasesPinExpectedSemantics` (which asserts `.jumpTable` *differs* from
cubff on that tape — an expected-difference fixture, kept deliberately).

### 6. CheckSelfRep accounting — CONFIRMED, SPEC ASSUMPTIONS CORRECTED

`common_language.h:203-277` (`CheckSelfRep`), `common.h:56` (`kSelfrepThreshold = 5`),
`main.cc:348` (classification):

- `kNumIters = 13` independent trials per program; per-trial noise
  `noise[j] = SplitMix64(local_seed ^ SplitMix64((iter+1)*64 + j)) % 256` with
  `local_seed = SplitMix64(num_programs*seed + index)` (`:211-218`).
- Each trial: tape = `program ++ noise`, evaluate (budget 8192); then `kNumExtraGens = 4`
  further generations where the **second half feeds forward** — `tape[j] = tape[j+64]`,
  second half refilled with the *same* noise — and the tape is re-evaluated (`:239-257`).
  Total: 5 evaluations per trial, 13 trials.
- Scoring (`:259-276`): for each of the 128 byte positions, the position counts if **some**
  trial value at that position is shared by **more than `kNumIters/4` = 3 trials (i.e. ≥ 4 of
  13, counting itself)** — with first-half positions additionally required to equal the
  original program byte. `res[0]` = qualifying first-half positions, `res[1]` = second-half;
  the program's score is `min(res[0], res[1])`, and it is classified a self-replicator at
  score `>= 5`.
- The per-epoch seed for the selfrep pass is `seed(epoch)` where
  `seed(x) = SplitMix64(SplitMix64(params.seed) ^ SplitMix64(x))` (`common_language.h:367-369`).
- Quirk, noted not adopted: the bounds check is `if (index > num_programs) return;`
  (`:211`) — `>` where `>=` is conventional.

Two details of the spec's assumed answer (01 §7.4 tag 6) were **wrong** and are corrected in
the spec: (a) the *offspring* half (`tape[64..127]`) feeds forward, not the candidate's half;
(b) "reliably reproduced" means ≥ 4-of-13 trial agreement per byte (plus first-half equality
with the original), not equality across all 13 trials. The oracle does not implement
CheckSelfRep yet; when it does (01 §7.3 needs it), this section is the normative reference.

## Genuine fixtures: generation procedure

`Tools/cubff-grounding/` builds a minimal harness that **compiles the unmodified pinned
evaluator** and executes it on curated + pseudo-random tapes:

- `eval_bff_noheads.cc` / `eval_bff_heads.cc` — include upstream `bff.inc.h` exactly as
  upstream `bff_noheads.cu` / `bff.cu` do (same `name()` definition pattern, `BFF_HEADS` for
  the heads variant) and expose `Bff::Evaluate` to the generator. Zero reimplemented
  semantics; upstream `common.cc` is linked for the (unused at runtime) language registry.
- `gen_fixtures.cc` — 59 cases: 27 curated (ordinary ops, head wrapping mod 128, cross-half
  copies both directions, balanced loop, taken-`[` skip, `]` re-entry + budget accounting,
  taken unmatched `[` and `]`, non-taken unmatched brackets, live-scan self-modification,
  `+`-created brackets/instructions, comment-vs-command op accounting, noheads and
  seeded-heads initialization incl. mod-128 seed reduction) plus 32 pseudo-random tapes
  (16 uniform, 16 command-rich; both variants; inputs derived from cubff's own SplitMix64
  formula with recorded seeds).
- `generate.sh` — pins the checkout to the SHA above (hard failure on mismatch), compiles
  with the upstream CPU configuration, and writes
  `Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json`. Regeneration is deterministic:
  identical JSON bytes for the same pinned commit and toolchain (the build-info provenance
  string records the actual compiler).

Every case records: upstream commit + URL + source files + build facts, generator command +
version, variant (upstream name), step budget, full 128-byte input tape (hex), full expected
final tape (hex), and expected op count. No RNG contract applies — evaluator fixtures are
fixed-input by construction.

## Observable limitations

cubff's `Evaluate` exposes exactly two observables: the final 128-byte tape and the returned
op count (`i - nskip`). It does **not** expose a halt reason, final pc/head positions, or
per-op counters. Therefore:

- The oracle's `halt` (`budget`/`pcOut`/`unmatched`), `copyWrites`, `loopOps`, and
  `remapEvents` are oracle-only instrumentation and are *not* cubff-verified fields (their
  *step* consequences are — a wrong halt classification would corrupt the verified tape or
  op count).
- cubff halts by parking pc out of range for both "walked off the tape" and "unmatched
  bracket"; the oracle's distinct `UNMATCHED` reason is a refinement of the same event, not
  a divergence.
- `CheckSelfRep` results are not covered by fixtures (the oracle does not implement it).

## What "parity" now means

| Claim | Status |
|---|---|
| **Evaluator parity** (fixed 128-byte tape in → final tape + op count out, both variants, dynamic scan) | **Proven** against the pinned cubff evaluator by 59 fixtures; enforced by `CubffFixtureTests` in `swift test`. |
| Step-budget accounting (8192, incl. no-ops and halting op) | Proven via the budget/spin/unmatched fixtures. |
| `.jumpTable` bracket mode | **Deliberate deviation** from cubff (which always live-scans); divergence pinned by an expected-difference fixture. D1 (06) still decides its fate on the GPU. |
| Simulation-level parity: soup init, mutation stream, pairing shuffle, epoch trajectories | **Not claimed.** The oracle keeps `counter-pcg-v1`; cubff uses SplitMix64 counters with pair-indexed mutation (2^30 denominator) and a biased-modulo Fisher–Yates shuffle. Bit parity here would require a `cubffCompat` RNG port (01 §7.1), which remains optional future work. |
| Fixed-seed whole-soup parity with published runs | **Not claimed**, and must not be until the exact RNG + shuffle contract is reproduced. |

`GoldenFixture` (`counter-pcg-v1`) files remain oracle-internal regression anchors; the
comparator still refuses cross-contract replays.

## Reproducing

```sh
# Regenerate fixtures (external checkout, pinned SHA enforced):
Tools/cubff-grounding/generate.sh

# Verify the oracle against them:
swift test --filter CubffFixtureTests

# Re-validate the CPU build of cubff against upstream's own goldens
# (requires brotli 1.1.0 for the logged compression stats to match):
cd <cubff-checkout> && make CUDA=0 && ./test.sh bff_noheads && ./test.sh bff
```
