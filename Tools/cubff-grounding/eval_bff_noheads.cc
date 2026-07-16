// Host-compatibility wrapper: compiles the UNMODIFIED cubff `bff_noheads`
// evaluator (bff.inc.h without BFF_HEADS, exactly like upstream
// bff_noheads.cu) and exposes its Evaluate entry point to the fixture
// generator. No semantics live in this file.
//
// Build: CPU path only (no __CUDACC__), mirroring upstream `make CUDA=0`,
// where common_language.h defines __device__/__host__/__global__ away.

#include "bff.inc.h"

namespace {

// Same definition pattern as upstream bff_noheads.cu.
const char *Bff::name() { return "bff_noheads"; }

}  // namespace

size_t CubffEvalBffNoheads(uint8_t *tape, size_t stepcount) {
  return Bff::Evaluate(tape, stepcount, /*debug=*/false);
}
