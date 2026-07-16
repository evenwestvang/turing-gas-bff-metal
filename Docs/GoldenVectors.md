# Golden Vectors — fixture format, generation, and import

This document covers the versioned golden-fixture format implemented by the CPU oracle
(`Sources/BFFOracle/GoldenFixture.swift`) and how fixtures are generated, compared, and —
eventually — imported from cubff. It is the practical companion to the validation chain of
[Architecture/01-bff-spec.md](Architecture/01-bff-spec.md) §7.

## Status: evaluator-level cubff grounding done; simulation fixtures stay oracle-sourced

Two fixture families now exist, with different provenance and different claims:

- **Genuine cubff evaluator fixtures**
  (`Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json`, format documented in
  [CubffGrounding.md](CubffGrounding.md)): produced by *executing the unmodified cubff
  evaluator* at pinned commit `f212e849027c98fcf4b242eccfb5fed435223e23` via
  `Tools/cubff-grounding/generate.sh`. They pin per-interaction semantics — final tape and
  op count for fixed 128-byte inputs, both variants — and `CubffFixtureTests` proves the
  oracle matches every observable exactly. The six alignment tags of 01 §7.4 are confirmed.
- **`GoldenFixture` simulation fixtures** (this document's format): still entirely
  oracle-sourced under the counter-based PCG contract of 02 §4 (`counter-pcg-v1`), which is
  deliberately **not** cubff's RNG. A `cubffCompat` mode (port of cubff's SplitMix64 counter
  RNG, soup init, pair-indexed mutation draws, and shuffle) does not exist; therefore **no
  fixed-seed whole-soup cubff parity is claimed**, and these fixtures ground oracle
  self-consistency and the future oracle↔GPU diff (01 §7.2) only.

## Fixture format (`formatVersion` 1)

A fixture is a single JSON file (`GoldenFixture`, Codable, sorted keys):

| Field | Meaning |
|---|---|
| `formatVersion` | Integer format version. Readers reject unknown versions. |
| `source` | Provenance: `"oracle"`, or `"cubff@<commit>"` for imported vectors. |
| `commandLine` | Exact command that produced the file, for replay. |
| `rngContract` | Randomness contract of the run. Currently always `"counter-pcg-v1"`. Comparison across contracts is refused, not attempted. |
| `config` | Full `SimulationConfig`: `seed`, `populationSize`, `stepBudget`, `mutationP32`, `variant` (`noheads` \| `bff`), `bracketMode` (`dynamicScan` \| `jumpTable`). |
| `checkpointEpoch` | Epochs run before capture; the soup is the state *after* this many epochs. |
| `soupBase64` | The exact soup bytes (`populationSize × 64`), base64. |
| `histogram` | Global 256-bin byte histogram of that soup. |
| `expectedStats` | Optional `EpochStats` of the checkpoint (last) epoch: mean steps, halt mix, copy/loop/remap totals. |

The bracket semantics (`bracketMode`) and variant are part of `config` and therefore part
of the fixture identity: a `dynamicScan` fixture must never be compared against a
`jumpTable` replay, and the comparison harness treats them as different configurations.

## Generating and comparing fixtures

The `bff-oracle` CLI wraps the library:

```sh
# Run 128 epochs of a 1024-program soup and capture a fixture:
swift run bff-oracle generate --seed 1 --population 1024 --epochs 128 \
    --output Tests/Golden/oracle-seed1-epoch128.json

# Replay its config from epoch 0 and diff soup, histogram, and stats
# (exit 0 = bit-identical, exit 2 = mismatch, with located divergences):
swift run bff-oracle compare Tests/Golden/oracle-seed1-epoch128.json
```

Programmatic equivalents: `GoldenFixture(capturing:source:commandLine:)`,
`FixtureComparator.replayAndCompare(fixture:)`, and — for diffing against a soup produced
by some *other* engine (the GPU port) — `FixtureComparator.compare(fixture:soup:histogram:stats:)`.

Comparison reports are exact and located: differing byte count, first divergent soup
index with both values, the set of divergent histogram bins, and stats deltas. This is
the diagnosis path of 01 §7.1 ("find the first checkpoint whose histogram diverges…").

## Importing cubff simulation vectors (optional future work, 01 §7.1)

Evaluator-level cubff fixtures are already imported and enforced (see
[CubffGrounding.md](CubffGrounding.md) — that path needs no RNG port because inputs are
fixed). What remains optional is whole-soup *simulation* import; if it ever happens, the
procedure is:

1. Build cubff at a pinned commit; run `bff_noheads` at defaults
   (N = 131,072, T = 64, budget 8,192, mutation 1/4096) with a fixed, recorded seed.
2. Dump the exact full soup bytes and 256-bin histogram at checkpoint epochs
   {128, 1024, 16384}, plus the exact command line.
3. Wrap each dump in this JSON format with `source: "cubff@<commit>"` and an
   `rngContract` naming the cubff RNG port (e.g. `"cubff-compat-<commit>"`) — **not**
   `counter-pcg-v1`.
4. Implement the oracle's `cubffCompat` mode (cubff's RNG, soup init, mutation draw
   order, pairing shuffle) so the oracle can replay those fixtures bit-identically.
   The comparison harness already refuses to replay a fixture whose `rngContract` the
   oracle does not implement, so checked-in cubff fixtures are inert until that mode
   lands rather than silently mis-comparing.
5. Reproduce all three checkpoints bit-identically, once. Only after that may any
   *simulation-level* parity claim be made.

Until step 5 completes, treat every fixture in THIS format as an internal regression
anchor. Evaluator-level alignment with cubff is already established separately
([CubffGrounding.md](CubffGrounding.md)); the six 01 §7.4 tags are confirmed from source
and enforced by `CubffFixtureTests`.
