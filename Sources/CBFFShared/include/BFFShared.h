// BFFShared.h — the normative byte layout shared between the Swift host and the
// Metal evaluator (02 §1, reduced to the vertical-slice minimum: no SimParams,
// no ProgStats, no soup/metrics structures yet).
//
// MIRROR CONTRACT
// ---------------
// The Metal evaluator is compiled at runtime from bundled source
// (Sources/BFFMetal/Shaders/BFFEvaluate.metal), and a runtime `makeLibrary(source:)`
// compile cannot #include headers across SwiftPM targets. The MSL side therefore
// carries a *mirror* of the two structs below rather than including this file.
// Agreement is enforced mechanically, three layers deep:
//
//   1. The _Static_asserts at the bottom of this file pin every size, alignment,
//      and field offset to the documented literals — checked by every C compile,
//      including plain Linux `swift build`.
//   2. `static_assert`s in BFFEvaluate.metal pin the MSL mirror to the SAME
//      literals at Metal compile time.
//   3. The `bff_layout_probe` kernel reports sizeof/alignof/offsetof as actually
//      compiled by the Metal compiler; MetalBFFEvaluator refuses to dispatch any
//      work unless every reported value equals Swift's MemoryLayout of the structs
//      imported from this header (see BFFEvalLayout.hostProbeWords()).
//
// Any edit here must be applied to the .metal mirror and to the assert literals
// on both sides; drift fails the build (layers 1–2) or the runner init (layer 3).
//
// All fields are uint32_t on purpose: one width, alignment 4 everywhere, no
// implicit padding, and step budgets up to 2^32-1 are representable without
// truncation (the cubff default is 8192).

#ifndef BFF_SHARED_H
#define BFF_SHARED_H

#include <stddef.h>
#include <stdint.h>

// --- Fixed sizes (01 §1; cubff kSingleTapeSize and the paired tape) ---
#define BFF_PROG_SIZE 64
#define BFF_PAIR_TAPE_SIZE 128

// --- The ten command bytes (ASCII table of 01 §2, cubff CommandRepr "[]+-.,<>{}") ---
#define BFF_OP_HEAD0_LEFT 0x3C  /* '<'  head0 -= 1 (mod 128) */
#define BFF_OP_HEAD0_RIGHT 0x3E /* '>'  head0 += 1 (mod 128) */
#define BFF_OP_HEAD1_LEFT 0x7B  /* '{'  head1 -= 1 (mod 128) */
#define BFF_OP_HEAD1_RIGHT 0x7D /* '}'  head1 += 1 (mod 128) */
#define BFF_OP_INC 0x2B         /* '+'  tape[head0] += 1 (wrapping) */
#define BFF_OP_DEC 0x2D         /* '-'  tape[head0] -= 1 (wrapping) */
#define BFF_OP_WRITE 0x2E       /* '.'  tape[head1] = tape[head0] */
#define BFF_OP_READ 0x2C        /* ','  tape[head0] = tape[head1] */
#define BFF_OP_LOOP_OPEN 0x5B   /* '['  if tape[head0] == 0 jump past match */
#define BFF_OP_LOOP_CLOSE 0x5D  /* ']'  if tape[head0] != 0 jump back past match */

// --- Halt reasons. Raw values match BFFOracle.HaltReason; 0 means "still
// --- running" and is never a final value (the evaluator always halts).
#define BFF_HALT_BUDGET 1    /* step budget exhausted */
#define BFF_HALT_PC_OUT 2    /* pc walked off either tape end (pc does not wrap) */
#define BFF_HALT_UNMATCHED 3 /* a taken bracket had no match on the live tape */

// --- Initial-state variants (01 §3; raw values are this header's contract,
// --- mapped from BFFOracle.BFFVariant by BFFEvalLayout.variantCode) ---
#define BFF_VARIANT_NOHEADS 0      /* cubff bff_noheads: pc=0, head0=0, head1=0 */
#define BFF_VARIANT_SEEDED_HEADS 1 /* cubff bff: head0=tape[0]&127, head1=tape[1]&127, pc=2 */

/// Dispatch-wide evaluator parameters, bound as `constant BFFEvalParams&`
/// (buffer index 2). One dispatch runs `pairCount` independent interactions of a
/// single variant under a single step budget; the fixture runner groups mixed
/// fixture files into one dispatch per (variant, budget).
typedef struct {
    uint32_t pairCount;  /* offset 0  — 128-byte pair tapes in buffer 0, one GPU thread each */
    uint32_t stepBudget; /* offset 4  — gas: max executed steps per interaction; must be > 0 */
    uint32_t variant;    /* offset 8  — BFF_VARIANT_* */
    uint32_t reserved;   /* offset 12 — must be 0 */
} BFFEvalParams;         /* size 16, alignment 4 */

/// Per-pair result record (buffer index 1), written exactly once by the owning
/// GPU thread. Operation accounting is kept deliberately split:
///   - `steps` is raw budget/gas accounting: EVERY executed op costs 1, including
///     null/non-command no-ops, non-taken brackets, and the taken-but-unmatched
///     bracket that halts the run. Bracket scanning never counts.
///   - `noopSteps` is cubff's `nskip`: executed null/non-command "comment" bytes.
///   - cubff's observable evaluator op count (the `Evaluate` return pinned by the
///     fixtures' `expectedOps`) is DERIVED as `steps - noopSteps`; it is not
///     stored to keep the record free of redundant fields.
typedef struct {
    uint32_t steps;      /* offset 0  — executed ops incl. no-ops (budget accounting) */
    uint32_t noopSteps;  /* offset 4  — executed null/non-command bytes (cubff nskip) */
    uint32_t copyWrites; /* offset 8  — '.'/',' executions with heads in different 64-byte halves */
    uint32_t loopOps;    /* offset 12 — bracket ops executed, taken or not */
    uint32_t halt;       /* offset 16 — BFF_HALT_* */
} BFFEvalResult;         /* size 20, alignment 4 */

/* Layer-1 layout pins: these literals are the contract the MSL mirror asserts
 * against and the Swift MemoryLayout tests re-check. */
_Static_assert(sizeof(BFFEvalParams) == 16, "BFFEvalParams must be 16 bytes");
_Static_assert(_Alignof(BFFEvalParams) == 4, "BFFEvalParams must be 4-byte aligned");
_Static_assert(offsetof(BFFEvalParams, pairCount) == 0, "pairCount at offset 0");
_Static_assert(offsetof(BFFEvalParams, stepBudget) == 4, "stepBudget at offset 4");
_Static_assert(offsetof(BFFEvalParams, variant) == 8, "variant at offset 8");
_Static_assert(offsetof(BFFEvalParams, reserved) == 12, "reserved at offset 12");

_Static_assert(sizeof(BFFEvalResult) == 20, "BFFEvalResult must be 20 bytes");
_Static_assert(_Alignof(BFFEvalResult) == 4, "BFFEvalResult must be 4-byte aligned");
_Static_assert(offsetof(BFFEvalResult, steps) == 0, "steps at offset 0");
_Static_assert(offsetof(BFFEvalResult, noopSteps) == 4, "noopSteps at offset 4");
_Static_assert(offsetof(BFFEvalResult, copyWrites) == 8, "copyWrites at offset 8");
_Static_assert(offsetof(BFFEvalResult, loopOps) == 12, "loopOps at offset 12");
_Static_assert(offsetof(BFFEvalResult, halt) == 16, "halt at offset 16");

/* size == stride: 4 divides 20, so arrays of BFFEvalResult have no tail padding
 * and `results[i]` on the GPU is byte-offset `i * 20` on the host. */
_Static_assert(sizeof(BFFEvalResult) % _Alignof(BFFEvalResult) == 0,
               "BFFEvalResult arrays must be densely packed");

#endif /* BFF_SHARED_H */
