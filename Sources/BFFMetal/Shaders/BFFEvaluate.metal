// BFFEvaluate.metal — the normative dynamic-scan BFF evaluator.
//
// One GPU thread evaluates one interaction: a single unrestricted 128-byte pair
// tape (two 64-byte programs concatenated; no protection boundary between the
// halves). Semantics are the CPU oracle's `.dynamicScan` mode exactly (01 §3,
// grounded against cubff in Docs/CubffGrounding.md): every taken bracket scans
// the LIVE, possibly self-modified tape at the moment it executes. There is no
// jump table, no precomputed bracket map, and no alternate bracket path in this
// file — dynamic scanning is the only implementation. Correctness first: tapes
// live in device memory (no threadgroup staging), no simdgroup tricks.
//
// MIRROR CONTRACT: every #define and struct below mirrors
// Sources/CBFFShared/include/BFFShared.h. This file cannot #include that header
// because it is compiled at runtime via makeLibrary(source:). Drift is caught by
// the static_asserts below (same literals as the header's _Static_asserts) and
// by bff_layout_probe, which MetalBFFEvaluator runs and checks against the
// host's MemoryLayout before dispatching any evaluation.

#include <metal_stdlib>
using namespace metal;

#define BFF_PROG_SIZE 64
#define BFF_PAIR_TAPE_SIZE 128

#define BFF_OP_HEAD0_LEFT 0x3C  /* '<' */
#define BFF_OP_HEAD0_RIGHT 0x3E /* '>' */
#define BFF_OP_HEAD1_LEFT 0x7B  /* '{' */
#define BFF_OP_HEAD1_RIGHT 0x7D /* '}' */
#define BFF_OP_INC 0x2B         /* '+' */
#define BFF_OP_DEC 0x2D         /* '-' */
#define BFF_OP_WRITE 0x2E       /* '.' */
#define BFF_OP_READ 0x2C        /* ',' */
#define BFF_OP_LOOP_OPEN 0x5B   /* '[' */
#define BFF_OP_LOOP_CLOSE 0x5D  /* ']' */

#define BFF_HALT_BUDGET 1
#define BFF_HALT_PC_OUT 2
#define BFF_HALT_UNMATCHED 3

#define BFF_VARIANT_NOHEADS 0
#define BFF_VARIANT_SEEDED_HEADS 1

struct BFFEvalParams {
    uint32_t pairCount;
    uint32_t stepBudget;
    uint32_t variant;
    uint32_t reserved;
};

struct BFFEvalResult {
    uint32_t steps;
    uint32_t noopSteps;
    uint32_t copyWrites;
    uint32_t loopOps;
    uint32_t halt;
};

// Layer-2 layout pins — identical literals to BFFShared.h.
static_assert(sizeof(BFFEvalParams) == 16, "BFFEvalParams must be 16 bytes");
static_assert(alignof(BFFEvalParams) == 4, "BFFEvalParams must be 4-byte aligned");
static_assert(sizeof(BFFEvalResult) == 20, "BFFEvalResult must be 20 bytes");
static_assert(alignof(BFFEvalResult) == 4, "BFFEvalResult must be 4-byte aligned");

/// Normative forward match (01 §3): scan q = p+1 ... 127 over the live tape;
/// '[' deepens, ']' at depth 0 is the match. Returns -1 if unmatched.
static int bff_scan_forward(device const uchar *tape, int p) {
    int depth = 0;
    for (int q = p + 1; q < BFF_PAIR_TAPE_SIZE; q++) {
        uchar c = tape[q];
        if (c == BFF_OP_LOOP_OPEN) {
            depth++;
        } else if (c == BFF_OP_LOOP_CLOSE) {
            if (depth == 0) return q;
            depth--;
        }
    }
    return -1;
}

/// Normative backward match: symmetric, scanning q = p-1 ... 0.
static int bff_scan_backward(device const uchar *tape, int p) {
    int depth = 0;
    for (int q = p - 1; q >= 0; q--) {
        uchar c = tape[q];
        if (c == BFF_OP_LOOP_CLOSE) {
            depth++;
        } else if (c == BFF_OP_LOOP_OPEN) {
            if (depth == 0) return q;
            depth--;
        }
    }
    return -1;
}

/// One interaction per thread, in place: thread `gid` exclusively owns tape
/// bytes [gid*128, gid*128+128) of buffer 0 and record `gid` of buffer 1; the
/// host uploads inputs before commit and reads finals after completion, so no
/// synchronization beyond command-buffer completion is needed.
kernel void bff_evaluate_pairs(device uchar *tapes [[buffer(0)]],
                               device BFFEvalResult *results [[buffer(1)]],
                               constant BFFEvalParams &params [[buffer(2)]],
                               uint gid [[thread_position_in_grid]]) {
    if (gid >= params.pairCount) return;

    device uchar *tape = tapes + (ulong)gid * BFF_PAIR_TAPE_SIZE;

    // Initial state (01 §3). Seeded heads consume the first two bytes as head
    // positions (mod 128) and start execution past them.
    int pc;
    uint h0, h1;
    if (params.variant == BFF_VARIANT_SEEDED_HEADS) {
        h0 = (uint)tape[0] & 127u;
        h1 = (uint)tape[1] & 127u;
        pc = 2;
    } else {
        pc = 0;
        h0 = 0u;
        h1 = 0u;
    }

    uint32_t steps = 0;
    uint32_t noopSteps = 0;
    uint32_t copyWrites = 0;
    uint32_t loopOps = 0;
    uint32_t halt = 0;

    while (true) {
        if (steps >= params.stepBudget) {
            halt = BFF_HALT_BUDGET;
            break;
        }
        if (pc < 0 || pc >= BFF_PAIR_TAPE_SIZE) {
            halt = BFF_HALT_PC_OUT;
            break;
        }

        // The unmatched halt is deferred past the shared advance so the halting
        // bracket consumes exactly one step and one pc increment — canonical
        // timing of 01 §3 / alignment tag 4, matching the CPU oracle.
        bool unmatchedHalt = false;
        uchar op = tape[pc];
        switch (op) {
        case BFF_OP_HEAD0_LEFT:
            h0 = (h0 - 1u) & 127u;
            break;
        case BFF_OP_HEAD0_RIGHT:
            h0 = (h0 + 1u) & 127u;
            break;
        case BFF_OP_HEAD1_LEFT:
            h1 = (h1 - 1u) & 127u;
            break;
        case BFF_OP_HEAD1_RIGHT:
            h1 = (h1 + 1u) & 127u;
            break;
        case BFF_OP_INC:
            tape[h0]++;
            break;
        case BFF_OP_DEC:
            tape[h0]--;
            break;
        case BFF_OP_WRITE:
            tape[h1] = tape[h0];
            copyWrites += (uint32_t)((h0 >> 6) != (h1 >> 6));
            break;
        case BFF_OP_READ:
            tape[h0] = tape[h1];
            copyWrites += (uint32_t)((h0 >> 6) != (h1 >> 6));
            break;
        case BFF_OP_LOOP_OPEN:
            loopOps++;
            if (tape[h0] == 0) {
                int match = bff_scan_forward(tape, pc);
                if (match < 0) unmatchedHalt = true;
                else pc = match;
            }
            break;
        case BFF_OP_LOOP_CLOSE:
            loopOps++;
            if (tape[h0] != 0) {
                int match = bff_scan_backward(tape, pc);
                if (match < 0) unmatchedHalt = true;
                else pc = match;
            }
            break;
        default:
            // Byte 0 and all other data values: no-op. Consumes budget but is
            // excluded from cubff's reported op count (nskip).
            noopSteps++;
            break;
        }
        // LOAD-BEARING shared advance (01 §3, alignment tags 4/5): a taken '['
        // landed ON its ']' and now moves past it; a taken ']' landed ON its '['
        // and now re-enters the body without re-executing the '['; a
        // taken-but-unmatched bracket still pays this step before halting.
        pc++;
        steps++;
        if (unmatchedHalt) {
            halt = BFF_HALT_UNMATCHED;
            break;
        }
    }

    BFFEvalResult out;
    out.steps = steps;
    out.noopSteps = noopSteps;
    out.copyWrites = copyWrites;
    out.loopOps = loopOps;
    out.halt = halt;
    results[gid] = out;
}

/// Layer-3 layout probe: reports sizeof/alignof/field offsets of the mirrored
/// structs as compiled by the ACTUAL Metal compiler. Word order is the contract
/// documented in BFFEvalLayout.hostProbeWords(); MetalBFFEvaluator compares
/// every word against the host layout before running any evaluation.
kernel void bff_layout_probe(device uint32_t *out [[buffer(0)]],
                             uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    BFFEvalParams p = {};
    BFFEvalResult r = {};
    thread char *pBase = (thread char *)&p;
    thread char *rBase = (thread char *)&r;
    out[0] = (uint32_t)sizeof(BFFEvalParams);
    out[1] = (uint32_t)alignof(BFFEvalParams);
    out[2] = (uint32_t)((thread char *)&p.pairCount - pBase);
    out[3] = (uint32_t)((thread char *)&p.stepBudget - pBase);
    out[4] = (uint32_t)((thread char *)&p.variant - pBase);
    out[5] = (uint32_t)((thread char *)&p.reserved - pBase);
    out[6] = (uint32_t)sizeof(BFFEvalResult);
    out[7] = (uint32_t)alignof(BFFEvalResult);
    out[8] = (uint32_t)((thread char *)&r.steps - rBase);
    out[9] = (uint32_t)((thread char *)&r.noopSteps - rBase);
    out[10] = (uint32_t)((thread char *)&r.copyWrites - rBase);
    out[11] = (uint32_t)((thread char *)&r.loopOps - rBase);
    out[12] = (uint32_t)((thread char *)&r.halt - rBase);
}
