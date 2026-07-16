// Host-compatibility wrapper: compiles the UNMODIFIED cubff `bff` evaluator
// (bff.inc.h with BFF_HEADS, exactly like upstream bff.cu) and exposes its
// Evaluate entry point to the fixture generator. No semantics live in this
// file.

#define BFF_HEADS
#include "bff.inc.h"

namespace {

// Same definition pattern as upstream bff.cu.
const char *Bff::name() { return "bff"; }

}  // namespace

size_t CubffEvalBffHeads(uint8_t *tape, size_t stepcount) {
  return Bff::Evaluate(tape, stepcount, /*debug=*/false);
}
