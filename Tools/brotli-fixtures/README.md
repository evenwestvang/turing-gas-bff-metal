# brotli-fixtures — authoritative Brotli 1.1.0 quality-2 fixtures

`generate.sh` regenerates
`Tests/BrotliMetricsTests/Fixtures/brotli-1.1.0-q2.json` from an **external**,
never-committed Brotli 1.1.0 checkout.

## Provenance (pinned)

| | |
|---|---|
| Repository | <https://github.com/google/brotli> |
| Tag / commit | `v1.1.0` = `ed738e842d2fbdf2d6459e39267a633c4a9b2f5d` |
| Version gate | `BrotliEncoderVersion() == 0x1001000`; the generator refuses to emit otherwise |
| Compression call | `BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC, n, in, &out, buf)` |
| Parameters | quality **2**, lgwin **24** (`BROTLI_MAX_WINDOW_BITS`), mode **generic**, whole buffer in one shot |
| Output sizing | `BrotliEncoderMaxCompressedSize(n)` |

These are byte-identical to cubff's `brotli_size` measurement
(`common_language.h`, paradigms-of-intelligence/cubff — see
`Docs/CubffGrounding.md`) and feed the paper's high-order complexity
`higher_entropy = H0 − brotli_bpb`.

## What each `compressedByteCount` is

The exact `*encoded_size` Brotli returns for the case's `inputHex` bytes. Inputs
are generated deterministically in-process (constant runs, opcode cycles, an
iota block, and SplitMix64 pseudo-random blocks with recorded seeds) and echoed
as hex, so every case is self-contained and regeneration is bit-stable.

## Version stability note

For the small inputs here, Brotli **1.0.9 and 1.1.0 produce identical q2 byte
counts** (verified). They diverge only at soup scale (~0.005% at 131072
programs, per `Docs/CubffGrounding.md`). So the fixture test passes on a 1.0.9
host too, but the *runtime paper metric* is still pinned to 1.1.0
(`BrotliCompressor.isPaperPinned`) because the at-scale number must match the
paper's encoder exactly.

## Reproducing

```sh
Tools/brotli-fixtures/generate.sh            # re-clones the pinned tag, rebuilds, regenerates
swift test --filter BrotliMetricsTests       # verifies our encoder call reproduces the counts
```

Nothing here is committed except this README, `gen_brotli_fixtures.c`,
`generate.sh`, and the resulting JSON fixture. The Brotli source archive, the
build tree, and any binaries are external and git-ignored by convention (they
live under `/tmp`).
