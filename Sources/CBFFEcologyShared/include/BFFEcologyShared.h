// BFFEcologyShared.h — the normative byte layout shared between the Swift host
// and the ecology Metal runner.
//
// MIRROR CONTRACT (same three-layer pattern as BFFShared.h)
// ------------------------------------------------------------------
// The Metal runner is compiled at runtime from bundled source
// (Sources/BFFEcologyMetal/Shaders/BFFEcologyEpoch.metal), and a runtime
// `makeLibrary(source:)` compile cannot #include headers across SwiftPM targets.
// The MSL side carries a *mirror* of the structs below. Agreement is enforced
// mechanically, three layers deep:
//
//   1. The _Static_asserts at the bottom of this file pin every size,
//      alignment, and field offset to the documented literals — checked by
//      every C compile, including plain Linux `swift build`.
//   2. `static_assert`s in BFFEcologyEpoch.metal pin the MSL mirror to the
//      SAME literals at Metal compile time.
//   3. The `bff_ecology_layout_probe` kernel reports sizeof/alignof/offsetof
//      as actually compiled by the Metal compiler; EcologyMetalEpochRunner
//      refuses to dispatch any work unless every reported value equals Swift's
//      MemoryLayout of the structs imported from this header.
//
// All fields are uint32_t: one width, alignment 4 everywhere, no implicit
// padding. The ecology contract pins stepBudget to 1...8192; the Metal CLI
// rejects larger values. All counter sums are provably in uint32_t range at
// the grounded contract.

#ifndef BFF_ECOLOGY_SHARED_H
#define BFF_ECOLOGY_SHARED_H

#include <stddef.h>
#include <stdint.h>

#define BFF_ECO_PROG_SIZE 64
#define BFF_ECO_PAIR_TAPE_SIZE 128
#define BFF_ECO_TOPOLOGY_WIDTH 512
#define BFF_ECO_TOPOLOGY_HEIGHT 256
#define BFF_ECO_SITE_COUNT 131072
#define BFF_ECO_PAIR_COUNT 65536
#define BFF_ECO_SOUP_BYTE_COUNT 8388608
#define BFF_ECO_ELEMENT_LIMIT 16777216

#define BFF_ECO_RNG_INIT_BYTES 0x01u
#define BFF_ECO_RNG_MUTATE_FLAG 0x02u
#define BFF_ECO_RNG_MUTATE_VALUE 0x03u
#define BFF_ECO_RNG_SHADOW 0x04u
#define BFF_ECO_RNG_FUTURE_PARTNER 0x05u
#define BFF_ECO_RNG_FUTURE_MOVEMENT 0x06u
#define BFF_ECO_RNG_SEED_XOR 0xEC0EC001u

#define BFF_ECO_PHASE_H0 0u
#define BFF_ECO_PHASE_H1 1u
#define BFF_ECO_PHASE_V0 2u
#define BFF_ECO_PHASE_V1 3u

#define BFF_ECO_VARIANT_NOHEADS 0u
#define BFF_ECO_VARIANT_SEEDED_HEADS 1u

#define BFF_ECO_BRACKET_DYNAMIC_SCAN 0u
#define BFF_ECO_BRACKET_JUMP_TABLE 1u

#define BFF_ECO_HALT_BUDGET 1u
#define BFF_ECO_HALT_PC_OUT 2u
#define BFF_ECO_HALT_UNMATCHED 3u

#define BFF_ECO_COUNTER_MUTATION_COUNT 0
#define BFF_ECO_COUNTER_TOTAL_RAW_STEPS 1
#define BFF_ECO_COUNTER_TOTAL_NOOP_STEPS 2
#define BFF_ECO_COUNTER_TOTAL_LOOP_OPS 3
#define BFF_ECO_COUNTER_TOTAL_COPY_WRITES 4
#define BFF_ECO_COUNTER_TOTAL_REMAP_EVENTS 5
#define BFF_ECO_COUNTER_HALT_BUDGET 6
#define BFF_ECO_COUNTER_HALT_PC_OUT 7
#define BFF_ECO_COUNTER_HALT_UNMATCHED 8
#define BFF_ECO_COUNTER_HALT_UNKNOWN 9
#define BFF_ECO_COUNTER_WORD_COUNT 10

typedef struct {
    uint32_t seed;
    uint32_t epoch;
    uint32_t stepBudget;
    uint32_t mutationP32;
    uint32_t variant;
    uint32_t bracketMode;
    uint32_t capturePairTapes;
    uint32_t reserved0;
} BFFEcologyEpochParams;

typedef struct {
    uint32_t steps;
    uint32_t noopSteps;
    uint32_t copyWrites;
    uint32_t loopOps;
    uint32_t remapEvents;
    uint32_t halt;
} BFFEcologyPairResult;

_Static_assert(sizeof(BFFEcologyEpochParams) == 32,
               "BFFEcologyEpochParams must be 32 bytes");
_Static_assert(_Alignof(BFFEcologyEpochParams) == 4,
               "BFFEcologyEpochParams must be 4-byte aligned");
_Static_assert(offsetof(BFFEcologyEpochParams, seed) == 0, "seed at offset 0");
_Static_assert(offsetof(BFFEcologyEpochParams, epoch) == 4, "epoch at offset 4");
_Static_assert(offsetof(BFFEcologyEpochParams, stepBudget) == 8,
               "stepBudget at offset 8");
_Static_assert(offsetof(BFFEcologyEpochParams, mutationP32) == 12,
               "mutationP32 at offset 12");
_Static_assert(offsetof(BFFEcologyEpochParams, variant) == 16,
               "variant at offset 16");
_Static_assert(offsetof(BFFEcologyEpochParams, bracketMode) == 20,
               "bracketMode at offset 20");
_Static_assert(offsetof(BFFEcologyEpochParams, capturePairTapes) == 24,
               "capturePairTapes at offset 24");
_Static_assert(offsetof(BFFEcologyEpochParams, reserved0) == 28,
               "reserved0 at offset 28");

_Static_assert(sizeof(BFFEcologyPairResult) == 24,
               "BFFEcologyPairResult must be 24 bytes");
_Static_assert(_Alignof(BFFEcologyPairResult) == 4,
               "BFFEcologyPairResult must be 4-byte aligned");
_Static_assert(offsetof(BFFEcologyPairResult, steps) == 0, "steps at offset 0");
_Static_assert(offsetof(BFFEcologyPairResult, noopSteps) == 4,
               "noopSteps at offset 4");
_Static_assert(offsetof(BFFEcologyPairResult, copyWrites) == 8,
               "copyWrites at offset 8");
_Static_assert(offsetof(BFFEcologyPairResult, loopOps) == 12,
               "loopOps at offset 12");
_Static_assert(offsetof(BFFEcologyPairResult, remapEvents) == 16,
               "remapEvents at offset 16");
_Static_assert(offsetof(BFFEcologyPairResult, halt) == 20, "halt at offset 20");

_Static_assert(sizeof(BFFEcologyPairResult) % _Alignof(BFFEcologyPairResult) == 0,
               "BFFEcologyPairResult arrays must be densely packed");

#endif /* BFF_ECOLOGY_SHARED_H */
