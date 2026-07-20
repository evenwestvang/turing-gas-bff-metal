# 07 - Ecological Mode (Experimental Spatial BFF Engine)

This document specifies a separate experimental spatial/ecological engine for BFF programs.
It does not replace the paper-grounded well-mixed engine described in
[01-bff-spec.md](01-bff-spec.md), the GPU execution plan in
[02-gpu-execution.md](02-gpu-execution.md), or the resident runner currently used by the app.

The short name is **BFF-Ecology v1**. Its status is **experimental, deterministic, and
not paper-grounded** except for the per-pair BFF evaluator semantics already grounded against
cubff in [../CubffGrounding.md](../CubffGrounding.md). Well-mixed BFF remains the science
default. BFF-Ecology exists to test spatial locality, fronts, domains, and ecological
visualization without changing the contracts of the well-mixed path.

## 1. Scientific status and naming

| Surface | Name | Status | Claim |
|---|---|---|---|
| Well-mixed engine | Paper-grounded BFF / well-mixed BFF | Default scientific path | Per-interaction semantics grounded against cubff; whole-run trajectories use this repo's `counter-pcg-v1` RNG, as documented in [01 §6](01-bff-spec.md#6-determinism-contract). |
| Spatial engine | BFF-Ecology v1 / spatial ecology engine | Experimental opt-in | Uses the same BFF evaluator for one pair, but changes population topology, partner selection, scheduling, and spatial observables. It must never be described as reproducing the paper's well-mixed experiment. |

Required labels:

- App mode label: `Experimental Spatial Ecology`.
- CLI/config label: `engine=ecology-v1`.
- RNG contract label: `ecology-counter-pcg-v1`.
- Scheduler label: `edge-color-sync-v1`.
- Topology label: `torus-512x256-v1`.

Any plot, screenshot, CSV/JSON field, or benchmark emitted by this engine carries the
`ecology` label. Paper-aligned high-order complexity and Brotli fields keep the definitions
from [../Benchmarking.md](../Benchmarking.md#paper-aligned-observability-brotli-110-high-order-complexity)
and are not silently reused as ecological claims.

## 2. Conservative v1 choices

The v1 design deliberately chooses the most deterministic, GPU-friendly spatial model:

| Concern | v1 choice | Rationale |
|---|---|---|
| Population | Fixed `N = 131072` occupants | Matches the canonical app capacity and avoids partial-grid edge cases. |
| Layout | `512 x 256` row-major torus | Reuses the visual grid in [03 §1](03-visualization-lod.md#1-spatial-mapping-an-honest-grid), but now position is intrinsic. |
| Neighborhood | von Neumann radius 1 | Four direct neighbors only; no diagonals, no random radius, no long-range jumps. |
| Partner selection | Deterministic edge-color perfect matching | Every site has exactly one partner per epoch and no two pairs overlap. |
| Scheduling | Synchronous one-matching epoch | One interaction per occupant per epoch; simple CPU oracle and Metal validation. |
| Movement | Disabled in v1 | Program bytes change in place; no vacancy, swap, migration, or birth/death layer yet. |
| Occupancy | Always full | Every site contains exactly one 64-byte program. There are no empty cells in v1. |
| Reproduction | Only through normal BFF pair writeback | If a program copies itself into its partner half, that spatial neighbor changes. No extra fitness or selection rule is added. |
| Evaluator | Existing per-pair BFF semantics | The 128-byte paired tape, step budget, variant, halt reasons, and dynamic-scan correctness reference come from [01 §3](01-bff-spec.md#3-interaction-two-programs-one-tape). |
| Mutation | Before pairing, per byte, integer threshold | Same timing style as this repo's well-mixed oracle; separate RNG streams. |
| Conflict handling | No conflicts by construction | Perfect matchings make each site the destination of exactly one pair write. |

This is intentionally narrower than a full ecology simulator. It is shippable because every
epoch is a deterministic local perfect matching over disjoint pairs, which preserves the
same order-independence property that makes the well-mixed GPU path validate cleanly.

## 3. Topology, layout, identity

The canonical BFF-Ecology v1 arena is a fixed torus:

```text
width  = 512
height = 256
N      = width * height = 131072
siteID = y * width + x
x      = siteID % width
y      = siteID / width
```

All coordinates wrap:

```text
east(x, y)  = ((x + 1) & 511, y)
south(x, y) = (x, (y + 1) & 255)
```

The stable identity in v1 is **site identity**. A site keeps the same `siteID` and screen
position for the entire run. The occupant is the 64-byte program currently stored at that
site. BFF-Ecology v1 does not assign biological parentage or lineage ownership, because a
BFF interaction can self-modify both halves and can create ambiguous ancestry. Clone/domain
metrics may group byte-identical or near-identical programs, but those are observability
metrics, not identity.

Occupancy is total and invariant:

- Every site has exactly one 64-byte program.
- There are no empty sites.
- Movement is disabled; an occupant does not swap or migrate to a new site.
- Reproduction-like behavior appears only when the BFF evaluator's normal copy operations
  cause a neighboring site's bytes to become a copy or derivative of another program.

Lineage IDs, vacancies, death, explicit movement, and parentage are unresolved choices
listed in [§15](#15-unresolved-choices).

## 4. Deterministic partner selection

An ecological epoch executes one edge-color matching. The matching cycles through the four
local edge colors:

| `epoch & 3` | Matching | Pair owner |
|---|---|---|
| `0` | Horizontal even: `(x, y)` pairs with `(x + 1, y)` for even `x` | West site |
| `1` | Horizontal odd: `(x, y)` pairs with `(x + 1, y)` for odd `x` | West site |
| `2` | Vertical even: `(x, y)` pairs with `(x, y + 1)` for even `y` | North site |
| `3` | Vertical odd: `(x, y)` pairs with `(x, y + 1)` for odd `y` | North site |

Because both dimensions are even, every matching covers all `N` sites exactly once and
contains `P = N / 2` disjoint pairs. Over four epochs, every undirected von Neumann edge is
visited exactly once.

Pair order is canonical:

- Horizontal pairs use `A = west`, `B = east`.
- Vertical pairs use `A = north`, `B = south`.
- The pair index is deterministic row-major over the owner sites in that matching.

There is no random partner draw in v1. If a future stochastic local matching is added, it
must use a new ecology RNG stream and must still produce a perfect matching or a deterministic
conflict-resolution proof.

## 5. Paired tape and evaluator semantics

One ecological pair is evaluated exactly as one BFF interaction:

```text
tape[0..63]    = program at site A
tape[64..127]  = program at site B
run BFF evaluator with configured variant and step budget
write tape[0..63]   back to site A
write tape[64..127] back to site B
```

Evaluator semantics are inherited from [01 §3](01-bff-spec.md#3-interaction-two-programs-one-tape):

- `bff_noheads` is the v1 default variant.
- `stepBudget = 8192` by default.
- Head movement wraps mod 128; `pc` does not wrap.
- Halt reasons are `BUDGET`, `PC_OUT`, and `UNMATCHED`.
- Dynamic live scanning is the CPU oracle's normative reference.

The ecological engine may eventually add a Metal kernel that inlines the evaluator for
throughput, but it must validate against the CPU oracle first. If it offers a jump-table fast
path, the same bracket-mode caveats and decision procedure from
[01 §7.3](01-bff-spec.md#73-link-3--bracket-mode-divergence-on-known-replicators-the-d1-decision-procedure)
apply. The ecological mode cannot make a new bracket semantics claim.

## 6. Mutation and RNG stream separation

Mutation happens once per ecological epoch, before the matching:

```text
for each site, byte:
    draw u32 from ecology mutation stream
    if draw < mutationP32:
        replace byte with low 8 bits from ecology mutation-value stream
```

Defaults:

- `mutationP32 = 1 << 20` (`1/4096` per byte per epoch), same numerical default as
  [01 §4](01-bff-spec.md#4-soup-dynamics).
- `mutationP32 = 0` disables mutation.
- No mutation occurs during evaluator execution.

BFF-Ecology v1 uses the same `rng3` counter-hash family as the repo's existing RNG
([01 §6](01-bff-spec.md#6-determinism-contract), `Sources/BFFOracle/Random.swift`), but under
a separate contract, seed, and a domain-tagged counter layout that is collision-free across
every supported epoch and every named purpose. The Swift implementation must call the same
`rng3` primitive, but only through this ecology wrapper:

```text
contractID = ecology-counter-pcg-v1
ecoSeed    = seed ^ 0xEC0E_C001                  # ecology seed differs from BFFRandom seed

# Logical 64-bit counter C is assembled injectively from (purpose, epoch, element)
# and then split into the (stream, index) pair consumed by rng3:
#
#   bits 63..56 : purpose tag p   (8 bits; p in 0x01..0x06, see table below)
#   bits 55..24 : epoch e          (32 bits; full UInt32 range, 0 ..< 2^32)
#   bits 23..00 : element i        (24 bits; i < 2^24 = 16_777_216)
#
#   stream = UInt32(C >> 32)        = (p << 24) | (e >> 8)
#   index  = UInt32(C & 0xFFFFFFFF) = ((e & 0xFF) << 24) | i
#
#   draw = rng3(seed: ecoSeed, stream: stream, index: index)
```

Supported ranges (exactly these; anything else is a configuration error):

- **Epoch:** any `UInt32`, `0 ... UInt32.max` inclusive. The full 32-bit epoch field is
  carried in `C`, so there is no wrap at epoch 256 or any other boundary.
- **Purpose:** the six named tags `0x01 ... 0x06` below; they fit the 8-bit purpose field
  with room for two more future purposes before the layout is revised.
- **Element:** `0 ... 2^24 - 1` inclusive. For `ecoInit`/`ecoMutateFlag`/`ecoMutateValue`
  the element is `siteID * 64 + byte`, whose maximum is
  `(131072 - 1) * 64 + 63 = 8_388_607 = 0x7F_FFFF < 2^23`, so it fits with one spare high
  bit in the 24-bit element field. For `ecoShadow` the element is `sampleIndex`, bounded by
  the configured shadow sample count, which v1 keeps `<< 2^24`. `ecoFuturePartner` and
  `ecoFutureMovement` are unused in v1 and draw no elements.

Domain-separation guarantee and its limits:

- **Input injectivity (claimed and tested).** Within the supported ranges, distinct
  `(purpose, epoch, element)` triples map to distinct `(stream, index)` pairs, so no two
  logical draws ever alias the same `rng3` invocation. This is a property of the bit layout
  above and is independent of `pcgHash`.
- **No output-uniqueness claim.** `rng3` returns a 32-bit value via `pcgHash`; a 32-bit
  hash cannot be injective over a 2^64 input space, so this contract does **not** claim that
  two distinct draws return distinct values. The contract is domain separation, not output
  uniqueness.
- **Separation from `BFFRandom`.** Well-mixed `BFFRandom` is called with `seed`; ecology is
  called with `ecoSeed = seed ^ 0xEC0E_C001`. The XOR constant `0xEC0E_C001` is nonzero, so at
  least one bit changes and `ecoSeed != seed` for every `UInt32` seed, although `ecoSeed`
  itself may be zero. Even if a `(stream, index)` pair happened to coincide between the two
  engines, the seed inputs differ, so the draws differ.

Named purposes:

| Stream | Purpose tag `p` | Purpose | Element index `i` |
|---|---:|---|---|
| `ecoInit` | `0x01` | Initial 64-byte program bytes (epoch field fixed to `0`) | `siteID * 64 + byte` |
| `ecoMutateFlag` | `0x02` | Per-byte mutation Bernoulli draw | `siteID * 64 + byte` |
| `ecoMutateValue` | `0x03` | Replacement byte when mutation fires | `siteID * 64 + byte` |
| `ecoShadow` | `0x04` | CPU shadow pair sample | `sampleIndex` |
| `ecoFuturePartner` | `0x05` | Reserved for future stochastic local matching | not used in v1 |
| `ecoFutureMovement` | `0x06` | Reserved for future movement/vacancy choices | not used in v1 |

### Mutation flag/value domain separation vs. well-mixed `BFFRandom.mutate`

Ecology deliberately draws the mutation flag and the mutation replacement value from
**separate purpose domains** (`ecoMutateFlag = 0x02` and `ecoMutateValue = 0x03`). This is
unlike the grounded well-mixed path in
[01 §6](01-bff-spec.md#6-determinism-contract) and `BFFRandom.mutate`
(`Sources/BFFOracle/Random.swift:134`), which uses a **single** `.mutate` stream
(`epoch * 4 + 0`) and distinguishes the flag draw from the value draw only by index,
`index ^ 0x8000_0000`. The two designs share **mutation timing** — both mutate before
pairing/evaluation, once per epoch — but they do **not** share draw structure:

- Grounded `BFFRandom.mutate`: one stream; flag at `index`; value at `index ^ 0x8000_0000`.
  Here `^ 0x8000_0000` flips bit 31 of the 32-bit index word, which the well-mixed layout
  treats as a free high bit of the index.
- Ecology: two purpose tags; flag at `(0x02, e, siteID*64+byte)`; value at
  `(0x03, e, siteID*64+byte)`. The `index ^ 0x8000_0000` xor is not used and must not be
  ported. In the ecology layout `index = ((e & 0xFF) << 24) | i`, so bit 31 of the index
  encodes bit 7 of the epoch low byte, not a free bit; flipping it would alias a different
  epoch and corrupt the epoch-low-byte field. This is separate from the spare high bit in
  the 24-bit element domain (bit 23 of the index, see
  [§6](#6-mutation-and-rng-stream-separation)), which the xor does not touch.

Ecology runs must serialize the ecology RNG contract ID in checkpoints and benchmark
output, so a well-mixed fixture cannot be replayed as ecological or vice versa.

## 7. Scheduling modes

### v1: synchronous edge-color epochs

The only shippable v1 scheduler is synchronous:

```text
epoch e:
    mutate all sites using ecology streams for e
    choose matching by e & 3
    evaluate every disjoint pair
    write both final halves back to their two owner sites
    publish counters, snapshots, and visualization metrics
```

All pair inputs come from the post-mutation, pre-evaluation state of that epoch. Since the
matching is disjoint, the Metal implementation may write in place without changing semantics:
no pair can read or write a site owned by another pair in the same epoch.

### Future: asynchronous event schedule

An asynchronous ecology mode is explicitly not v1. If added, it must be deterministic and
specified as an ordered event stream, not as "whatever order the GPU happens to run":

- A total order over events is part of the config.
- Reads and writes for event `k` observe the committed state after event `k - 1`.
- Any parallel batching must prove that events in the batch commute or must use a deterministic
  conflict resolver.
- The CPU oracle owns the semantics before Metal optimization.

Until that exists, all UI and CLI controls must label the v1 scheduler as synchronous.

## 8. Write ownership and conflict resolution

In BFF-Ecology v1, write ownership is static and unambiguous:

- Pair thread `p` owns exactly two destination sites, `A` and `B`.
- It writes exactly `64` bytes to site `A` and `64` bytes to site `B`.
- It writes the pair-level stats for exactly those two sites.
- No other pair in the epoch owns either site.
- No atomics feed back into simulation state.

Therefore there is no undefined overlap, no data race, and no order-dependent conflict.
Profiling counters may use atomics, but counters are observability only.

If a future rule allows multiple sources to target the same destination site, the rule must
define a deterministic winner before implementation. Acceptable forms include a total order
such as `(epoch, phase, targetSiteID, sourceSiteID, pairIndex)` or a commutative reduction
whose exact arithmetic is specified. "Last GPU writer wins" is forbidden.

## 9. Reset, checkpoint, replay

An ecological checkpoint is not a `.bffsoup` well-mixed snapshot. It needs its own magic and
contract fields:

```text
magic                  = "BFFECO1"
schemaVersion          = 1
engineID               = "ecology-v1"
topologyID             = "torus-512x256-v1"
schedulerID            = "edge-color-sync-v1"
rngContractID          = "ecology-counter-pcg-v1"
evaluatorContractID    = BFF evaluator contract / variant / bracket mode
seed
epoch                  = next epoch to execute
mutationP32
stepBudget
variant
raw soup bytes         = N * 64 bytes
optional site stats    = last interaction stats per site
optional spatial stats = visualization/analysis summaries
```

Reset creates the same epoch-0 soup for identical `(seed, config, rngContractID)`. Restore
loads the raw soup bytes and the next epoch number; continuing the run must produce the same
future soup hashes as an uninterrupted run.

Replay definitions of done:

- Same checkpoint restored twice produces identical hashes at epochs `{+1, +4, +128}`.
- Saving at epoch `E`, restoring, and running to `E + K` matches an uninterrupted run to
  `E + K`.
- A checkpoint with `engineID=ecology-v1` is rejected by well-mixed runners, and a well-mixed
  snapshot is rejected by ecological runners.

## 10. CPU oracle to Metal validation

The validation chain is separate from, but modeled on, [01 §7](01-bff-spec.md#7-validation-chain-golden-vectors-resolves-06-d1d2)
and [../MetalSoupSlice.md](../MetalSoupSlice.md):

1. **CPU ecology oracle.** Implements topology, matching, mutation, evaluator calls, counters,
   checkpoint/replay, and deterministic hashes with no Metal.
2. **Pair fixture parity.** Curated ecological pairs validate orientation (`A/B`), edge-color
   partner selection, mutation timing, and writeback.
3. **Full-epoch parity.** Metal runs the same `(seed, config)` and matches CPU soup digests
   at epochs `{1, 2, 3, 4, 128}`.
4. **Shadow validation.** A deterministic `ecoShadow` sample re-runs selected pre-GPU pair
   tapes on the CPU and compares final tape, steps, halt, copy/write counters, and site IDs.
5. **Checkpoint parity.** CPU and Metal restore the same ecological checkpoint and continue
   to the same digest.

Metal validation failure reports must include:

- epoch and matching phase;
- pair index;
- site IDs and coordinates for A/B;
- first differing byte in either half;
- CPU and GPU halt/step/counter fields;
- RNG contract and scheduler ID.

The CPU oracle is the source of truth. Metal performance work starts only after the parity
chain is green.

## 11. Separate implementation surfaces

BFF-Ecology must be a separate engine, not a conditional branch inside the current resident
well-mixed runner.

Required separation:

| Surface | Ecological name | Constraint |
|---|---|---|
| Config | `EcologyConfig` | Separate from `SoupConfig` and `ResidentEpochConfig`; serializes `engineID=ecology-v1`. |
| CPU oracle | `EcologyOracleRunner` | Pure Swift, no Metal dependency, deterministic fixtures. |
| Metal runner | `EcologyMetalEpochRunner` | New type; does not modify `ResidentMetalEpochRunner`. |
| App driver | `EcologySimulationDriver` | New app-side driver parallel to `ResidentSimulationDriver`. |
| Shader | `BFFEcologyEpoch.metal` | New shader source; may share constants/layout headers, but not by editing well-mixed shader behavior. |
| CLI | `bff-ecology-epoch` | New headless product or subcommand; emits `engine=ecology-v1`. |
| App switch | `--engine well-mixed|ecology` or an equivalent explicit UI segmented control | Switching engines resets the run and changes labels. |

`ResidentMetalEpochRunner` is untouched. Existing products (`bff-metal-soup`,
`bff-resident-epoch`, `bff-metal-bench`, and `SoupScope` well-mixed mode) must keep their
current defaults and output contracts unless an ecological engine is explicitly selected.

## 12. Visualization and spatial metrics

Unlike well-mixed mode, the ecological grid is a real spatial field. The renderer can reuse
the canonical row-major coordinates from [03 §1](03-visualization-lod.md#1-spatial-mapping-an-honest-grid),
but the labels and metrics must change.

Required visual labels:

- Mode badge: `Experimental Spatial Ecology`.
- Topology badge: `512x256 torus`.
- Scheduler badge: `sync edge-color phase H0/H1/V0/V1` or equivalent phase label.
- Metric badge: every ecological metric uses an `ecology` prefix in machine-readable output.

Recommended v1 spatial metrics:

| Metric | Definition | Purpose |
|---|---|---|
| `ecologyActivity` | Last pair steps normalized by step budget, attributed to both sites | Local runtime/activity field. |
| `ecologyCopyIntensity` | Cross-half `.`/`,` count normalized, attributed to both sites | Local copying signal. |
| `ecologyBudgetHalt` | `1` if the last pair halted on budget, else `0` | Local phase signal. |
| `ecologyByteEntropy` | Per-site 64-byte order-0 entropy | Local program regularity. |
| `ecologyNeighborSimilarity` | Fraction or hash-distance agreement with four direct neighbors | Domain/front visibility. |
| `ecologyCloneHash` | Stable hash of each 64-byte program, visualized as categorical domains only at labeled zooms | Detects expanding identical-program domains. |

Spatial metrics are visualization-grade unless promoted through a separate analysis spec.
They are not Brotli, not high-order complexity, and not paper `number_selfreps`.

## 13. Separation from Brotli and high-order observability

The Brotli/high-order path remains the paper-aligned observability path documented in
[../Benchmarking.md](../Benchmarking.md#paper-aligned-observability-brotli-110-high-order-complexity)
and [../CubffGrounding.md](../CubffGrounding.md#paper-observability-metrics--exact-source-references).
BFF-Ecology v1 does not link Brotli and does not emit paper high-order fields by default.

If a future benchmark samples whole ecological soups with Brotli, it must:

- run outside the epoch wall;
- preserve byte-for-byte trajectory identity with and without the measurement;
- label fields as ecological, for example `ecologyBrotliBitsPerByte`;
- state that the result is an analysis of this experimental spatial engine, not the paper's
  well-mixed observable;
- keep the existing `BrotliMetrics` dependency isolated from the app and core runners unless
  a new benchmark target explicitly opts in.

Visualization entropy, local clone domains, and neighbor similarity must not be folded into
`highOrderComplexity`. They answer different questions.

## 14. Performance acceptance and bounded native gates

Correctness gates are mandatory before performance claims. Native gates must be bounded so
ecological mode can ship without requiring an open-ended emergence run.

Minimum acceptance for the first Metal ecological slice:

| Gate | Command shape | Pass condition |
|---|---|---|
| CPU unit gate | Swift tests for `EcologyConfig`, matching, mutation, checkpoint, replay | Deterministic hashes and fixtures pass on non-Metal hosts. |
| Tiny Metal parity | `32 x 16` or smaller test topology if implemented as a test-only config | Full CPU/GPU parity for all pairs over at least 8 epochs. |
| Canonical Metal parity | `512 x 256`, shadow sample bounded | Zero shadow mismatches over a fixed short run; digest stable across two runs. |
| App smoke | Launch ecological engine for a bounded validation window | Mode labels visible; frames render; no validation errors; no fallback to well-mixed labels. |
| Throughput smoke | Native M-series, validation off, fixed duration | Reports p50/p95 epoch time and epochs/s; does not regress well-mixed runners because they are separate code paths. |

Initial performance target for v1 is modest: the canonical `512 x 256` engine should sustain
interactive visualization at 60 fps while running ecological epochs in the background, with
bounded command buffers and no unbounded CPU readbacks. If the first native run is slower,
that is a measurement result, not a reason to weaken the deterministic semantics.

No native gate may require Brotli, long-run emergence, or an unbounded wall-clock search.
Long ecological experiments are analysis follow-ups after the deterministic engine exists.

## 15. Unresolved choices

These are deliberately unresolved and must not be smuggled into v1 without a new spec update:

| ID | Choice | v1 answer | What would resolve it |
|---|---|---|---|
| E1 | Biological lineage/parentage | Site identity only | Deterministic parentage rule for self-modifying two-half interactions. |
| E2 | Empty sites, death, birth, carrying capacity | Always full | Occupancy state machine plus deterministic write/conflict rules. |
| E3 | Movement or swapping | Disabled | Explicit movement phase and conflict resolver. |
| E4 | Stochastic local matching | Edge-color cycle only | RNG-separated local perfect-matching generator with CPU oracle fixtures. |
| E5 | Asynchronous scheduling | Synchronous only | Ordered event semantics and proof/implementation of deterministic batching. |
| E6 | Jump-table fast path | Dynamic scan is oracle reference | Same known-replicator decision procedure as [01 §7.3](01-bff-spec.md#73-link-3--bracket-mode-divergence-on-known-replicators-the-d1-decision-procedure), run in ecological domains. |
| E7 | Explicit selection/fitness outside BFF writeback | None | A rule that does not obscure whether BFF itself is doing the copying. |
| E8 | Spatial metrics promoted to science metrics | Visualization-grade only | Separate analysis spec, fixtures, and output schema. |
| E9 | Brotli/high-order for ecological soups | Off by default | New benchmark target and ecological labels. |
| E10 | Non-canonical topologies or sizes | `512 x 256` torus only | Config validation, fixtures, and visualization handling for alternate dimensions. |

## 16. Shippable follow-ups

Each follow-up is independently reviewable and has a concrete definition of done.

### Follow-up A - CPU ecology oracle and fixtures

Scope:

- Add `EcologyConfig`, topology helpers, edge-color matching, ecology RNG streams, mutation,
  CPU epoch runner, counters, and digest.
- Add fixtures for orientation, wraparound, phase cycle, mutation timing, and checkpoint
  rejection across engine IDs.

Definition of done:

- Non-Metal tests pass.
- Same seed/config produces identical hashes across two runs.
- Epoch phases `{0,1,2,3}` cover every local edge exactly once.
- Every site is written exactly once per epoch.
- Named purposes cannot alias over the boundary vectors defined in [§6](#6-mutation-and-rng-stream-separation):
  for every ordered pair of distinct purposes and the boundary epochs
  `{0, 1, 255, 256, UInt32.max - 1, UInt32.max}` (`0xFFFFFFFF`), and index-domain maxima
  `{0, 1, 0x7F_FFFF (siteID*64+byte max), 0xFF_FFFF (element field max)}`, the constructed
  `(stream, index)` pairs are pairwise distinct. The same vectors also assert that
  `ecoSeed = seed ^ 0xEC0E_C001` differs from `seed` for boundary seeds `{0, 1, UInt32.max}`,
  and that the ecology flag/value domains (`0x02`/`0x03`) never share an `(stream, index)`
  slot with each other or with any other purpose at any supported epoch.
- Element indices used by `ecoInit`, `ecoMutateFlag`, and `ecoMutateValue` are asserted to
  stay `< 2^24` for the canonical `512 x 256` topology, so the element field cannot overflow
  into the epoch-low-byte field of the counter layout.
- Same-purpose encoded-input boundary assertions are kept on `(stream, index)` input
  uniqueness, not hash-output uniqueness: at a fixed `(purpose, epoch)`, element `0` and
  element `1` produce the same `stream` and distinct `index` values that differ in bit 0
  (element LSB distinction); at a fixed `(purpose, element)` and `index`, epoch `0` and
  epoch `256` produce the same `index` (their low bytes are both `0x00`) but distinct
  `stream` values (`e >> 8` differs), so the `(stream, index)` pairs remain distinct. These
  confirm input injectivity at same-purpose boundaries without any output-uniqueness claim.
- Well-mixed tests and fixtures are unchanged.

### Follow-up B - Ecological checkpoint/replay CLI

Scope:

- Add `BFFECO1` checkpoint read/write.
- Add a headless `bff-ecology-epoch` runner or equivalent explicit ecological subcommand.
- Emit engine, topology, scheduler, RNG contract, epoch, digest, and bounded counters.

Definition of done:

- Save/restore continuation matches uninterrupted run.
- Ecological checkpoints are rejected by well-mixed runners and vice versa.
- CLI output is deterministic enough to diff between two identical runs.

### Follow-up C - Metal ecological epoch runner and shader

Scope:

- Add `EcologyMetalEpochRunner` and `BFFEcologyEpoch.metal`.
- Implement mutation, edge-color pairing, pair evaluation/writeback, and per-site stats.
- Keep `ResidentMetalEpochRunner` unchanged.

Definition of done:

- CPU/GPU digest parity at epochs `{1,2,3,4,128}` for fixed seeds.
- Shadow validation reports zero mismatches on native Metal.
- Race/conflict audit is documented in code comments or tests: each site has one writer per
  epoch.
- Existing well-mixed CLIs and app resident mode still emit their previous labels/defaults.

### Follow-up D - App switch and ecological visualization labels

Scope:

- Add explicit engine selection.
- Add `EcologySimulationDriver`.
- Render ecological mode with required labels and spatial metrics.

Definition of done:

- Switching engines resets the run and cannot silently preserve incompatible state.
- Ecological mode visibly says `Experimental Spatial Ecology`.
- Well-mixed mode keeps existing labels and visualization behavior.
- Visualization metrics are labeled `ecology*` in machine-readable output.

### Follow-up E - Native bounded validation and performance report

Scope:

- Add a native validation script or documented command set.
- Run tiny parity, canonical shadow, app smoke, and throughput smoke on an M-series Metal
  device.

Definition of done:

- Report includes device name, engine ID, topology ID, scheduler ID, RNG contract, seed,
  epochs, shadow sample count, p50/p95 epoch time, fps, and final digest.
- No gate requires Brotli or long-run emergence.
- Results are stored as ecological validation artifacts, not mixed into paper benchmark
  claims.

### Follow-up F - Optional ecology research extensions

Scope:

- Choose one unresolved item from [§15](#15-unresolved-choices), such as lineage, movement,
  stochastic local matching, asynchronous scheduling, or ecological Brotli analysis.

Definition of done:

- The chosen rule is specified before implementation.
- The CPU oracle implements it first.
- Metal validates against the CPU oracle.
- Labels make the new rule explicit in config, output, and UI.
