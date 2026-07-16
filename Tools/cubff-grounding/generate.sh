#!/usr/bin/env bash
# Regenerate Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json from the
# pinned upstream cubff evaluator source.
#
# The upstream checkout is EXTERNAL (never vendored into this repo). The
# harness compiles cubff's bff.inc.h unmodified in the upstream-supported
# CPU configuration (make CUDA=0 equivalent: plain host C++17, no CUDA),
# links upstream common.cc, and executes curated + pseudo-random tapes.
#
# Prerequisites: g++ (C++17), libbrotli-dev (for upstream common.cc), git.
# Output is deterministic: same pinned commit -> identical JSON bytes.
#
# Usage: Tools/cubff-grounding/generate.sh [output.json]

set -euo pipefail

CUBFF_URL="https://github.com/paradigms-of-intelligence/cubff"
CUBFF_COMMIT="f212e849027c98fcf4b242eccfb5fed435223e23"
CUBFF_DIR="${CUBFF_DIR:-/tmp/cubff-grounding-checkout}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_DIR="$REPO_ROOT/Tools/cubff-grounding"
OUT="${1:-$REPO_ROOT/Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json}"
CXX="${CXX:-g++}"

# 1. Pin the upstream checkout.
if [ ! -d "$CUBFF_DIR/.git" ]; then
  git clone "$CUBFF_URL" "$CUBFF_DIR"
fi
git -C "$CUBFF_DIR" fetch --quiet origin "$CUBFF_COMMIT" 2>/dev/null || true
git -C "$CUBFF_DIR" checkout --quiet "$CUBFF_COMMIT"
ACTUAL_COMMIT="$(git -C "$CUBFF_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$CUBFF_COMMIT" ]; then
  echo "checkout is at $ACTUAL_COMMIT, expected $CUBFF_COMMIT" >&2
  exit 1
fi

# 2. Build the harness against the unmodified upstream sources.
#    Flags mirror upstream `make CUDA=0` (-std=c++17, host compiler, no
#    __CUDACC__); -O2 keeps builds fast, optimization level does not affect
#    the evaluator's defined behavior.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

BROTLI_CFLAGS="$(pkg-config --cflags libbrotlienc libbrotlicommon)"
BROTLI_LIBS="$(pkg-config --libs libbrotlienc libbrotlicommon)"

$CXX -std=c++17 -O2 -Wall $BROTLI_CFLAGS -I"$CUBFF_DIR" \
  -c "$CUBFF_DIR/common.cc" -o "$BUILD_DIR/common.o"
$CXX -std=c++17 -O2 -Wall $BROTLI_CFLAGS -I"$CUBFF_DIR" \
  -c "$HARNESS_DIR/eval_bff_noheads.cc" -o "$BUILD_DIR/eval_bff_noheads.o"
$CXX -std=c++17 -O2 -Wall $BROTLI_CFLAGS -I"$CUBFF_DIR" \
  -c "$HARNESS_DIR/eval_bff_heads.cc" -o "$BUILD_DIR/eval_bff_heads.o"
$CXX -std=c++17 -O2 -Wall \
  -c "$HARNESS_DIR/gen_fixtures.cc" -o "$BUILD_DIR/gen_fixtures.o"
$CXX "$BUILD_DIR/gen_fixtures.o" "$BUILD_DIR/eval_bff_noheads.o" \
  "$BUILD_DIR/eval_bff_heads.o" "$BUILD_DIR/common.o" \
  $BROTLI_LIBS -o "$BUILD_DIR/gen_fixtures"

# 3. Generate.
CXX_VERSION="$("$CXX" --version | head -1)"
BUILD_INFO="$CXX_VERSION; -std=c++17 host build (upstream 'make CUDA=0' CPU path, no CUDA)"
mkdir -p "$(dirname "$OUT")"
"$BUILD_DIR/gen_fixtures" "$CUBFF_COMMIT" "$CUBFF_URL" "$BUILD_INFO" \
  > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT ($(grep -c '"name"' "$OUT") cases) from cubff@$CUBFF_COMMIT"
