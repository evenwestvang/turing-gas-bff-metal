#!/usr/bin/env bash
# Regenerate Tests/BrotliMetricsTests/Fixtures/brotli-1.1.0-q2.json from an
# authoritative Brotli 1.1.0 checkout.
#
# The Brotli checkout is EXTERNAL (never vendored into this repo, never
# committed). The harness compiles the unmodified encoder + common C sources at
# the pinned tag with the host C compiler (no cmake required), links the
# generator, and hard-refuses to emit fixtures unless BrotliEncoderVersion()
# reports exactly 1.1.0 (0x1001000). The compressed byte counts are the encoder's
# deterministic output for the fixed inputs, so regeneration is bit-stable across
# hosts (only the recorded `build` string varies).
#
# The one shared compression call is byte-identical to cubff's higher-order
# metric: BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC, ...). See
# Docs/Benchmarking.md ("Paper-aligned observability") and Docs/CubffGrounding.md.
#
# Prerequisites: a C compiler (cc/gcc/clang), git, libm.
# Usage: Tools/brotli-fixtures/generate.sh [output.json]

set -euo pipefail

BROTLI_URL="https://github.com/google/brotli"
# Brotli 1.1.0 release tag.
BROTLI_COMMIT="ed738e842d2fbdf2d6459e39267a633c4a9b2f5d"
BROTLI_DIR="${BROTLI_DIR:-/tmp/brotli-1.1.0-checkout}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_DIR="$REPO_ROOT/Tools/brotli-fixtures"
OUT="${1:-$REPO_ROOT/Tests/BrotliMetricsTests/Fixtures/brotli-1.1.0-q2.json}"
CC="${CC:-cc}"

# 1. Pin the external Brotli checkout to the 1.1.0 tag (hard failure on mismatch).
if [ ! -d "$BROTLI_DIR/.git" ]; then
  git init -q "$BROTLI_DIR"
  git -C "$BROTLI_DIR" remote add origin "$BROTLI_URL"
fi
git -C "$BROTLI_DIR" fetch -q --depth 1 origin "$BROTLI_COMMIT"
git -C "$BROTLI_DIR" checkout -q "$BROTLI_COMMIT"
ACTUAL_COMMIT="$(git -C "$BROTLI_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$BROTLI_COMMIT" ]; then
  echo "brotli checkout is at $ACTUAL_COMMIT, expected $BROTLI_COMMIT" >&2
  exit 1
fi

# 2. Build the encoder + common sources at the pinned tag, then the generator.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

OBJS=()
while IFS= read -r f; do
  o="$BUILD_DIR/$(echo "$f" | tr '/.' '__').o"
  $CC -O2 -I "$BROTLI_DIR/c/include" -c "$f" -o "$o"
  OBJS+=("$o")
done < <(find "$BROTLI_DIR/c/enc" "$BROTLI_DIR/c/common" -name '*.c' | sort)

$CC -O2 -I "$BROTLI_DIR/c/include" \
  "$HARNESS_DIR/gen_brotli_fixtures.c" "${OBJS[@]}" -lm \
  -o "$BUILD_DIR/gen_brotli_fixtures"

# 3. Generate (the tool refuses to run unless it linked Brotli 1.1.0).
CC_VERSION="$("$CC" --version | head -1)"
BUILD_INFO="$CC_VERSION; -O2 host build of c/enc+c/common from the pinned tag"
mkdir -p "$(dirname "$OUT")"
"$BUILD_DIR/gen_brotli_fixtures" "$BROTLI_COMMIT" "$BROTLI_URL" "$BUILD_INFO" \
  > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT ($(grep -c '"name"' "$OUT") cases) from brotli@$BROTLI_COMMIT"
