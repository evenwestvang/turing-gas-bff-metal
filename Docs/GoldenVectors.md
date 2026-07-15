# Golden Vectors — fixture format, generation, and import

This document covers the versioned golden-fixture format implemented by the CPU oracle
(`Sources/BFFOracle/GoldenFixture.swift`) and how fixtures are generated, compared, and —
eventually — imported from cubff. It is the practical companion to the validation chain of
[Architecture/01-bff-spec.md](Architecture/01-bff-spec.md) §7.

## Status: no cubff fixture ships yet, and no parity is claimed

**Everything under `Tests/` and everything this repo can currently generate is
oracle-sourced.** The one-time cubff grounding run of 01 §7.1 has **not** been performed:

- No fixture in this repository was produced by cubff.
- The oracle's randomness is the counter-based PCG contract of 02 §4 (`counter-pcg-v1`),
  which is deliberately **not** cubff's RNG. A `cubffCompat` mode (port of cubff's RNG,
  soup init, mutation draw order, and pairing shuffle) does not exist yet.
- The six cubff-alignment tags of 01 §7.4 (opcode byte values, initial pc/heads,
  mutate-vs-run order, step counting, loop re-entry landing, CheckSelfRep accounting) are
  implemented as their *assumed* answers. None has been confirmed against cubff source.
- Consequently, current fixtures ground **oracle self-consistency and the future
  oracle↔GPU diff (01 §7.2)** — they do not ground the oracle against the paper.

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

## Importing cubff vectors (future work, 01 §7.1)

When the grounding run happens, the procedure is:

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
5. Reproduce all three checkpoints bit-identically, once; record each of the six 01 §7.4
   tags as confirmed or corrected in 06 D2. Only after that may any parity claim be made.

Until step 5 completes, treat every fixture here as an internal regression anchor, not
as evidence of alignment with the published experiments.
