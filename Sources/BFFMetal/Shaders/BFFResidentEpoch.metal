// BFFResidentEpoch.metal - experimental GPU-resident soup epoch slice.
//
// Kernels:
//   1. mutate soup in place from counter-pcg-v1
//   2. build the resident parallel-swap-or-not-v1 permutation on GPU
//   3. evaluate each pair with normative dynamic scanning and scatter by stable ID
//   4. optionally write an approximate one-pixel-per-program visualization
//
// This file intentionally mirrors the oracle's byte semantics, not cubff's whole-run
// RNG. It is a runnable learning slice, not a tuned production pipeline.

#include <metal_stdlib>
using namespace metal;

#define BFF_PROG_SIZE 64
#define BFF_PAIR_TAPE_SIZE 128

#define BFF_OP_HEAD0_LEFT 0x3C
#define BFF_OP_HEAD0_RIGHT 0x3E
#define BFF_OP_HEAD1_LEFT 0x7B
#define BFF_OP_HEAD1_RIGHT 0x7D
#define BFF_OP_INC 0x2B
#define BFF_OP_DEC 0x2D
#define BFF_OP_WRITE 0x2E
#define BFF_OP_READ 0x2C
#define BFF_OP_LOOP_OPEN 0x5B
#define BFF_OP_LOOP_CLOSE 0x5D

#define BFF_HALT_BUDGET 1
#define BFF_HALT_PC_OUT 2
#define BFF_HALT_UNMATCHED 3

#define BFF_VARIANT_SEEDED_HEADS 1

#define BFF_COUNTER_MUTATION_COUNT 0
#define BFF_COUNTER_TOTAL_RAW_STEPS 1
#define BFF_COUNTER_TOTAL_NOOP_STEPS 2
#define BFF_COUNTER_TOTAL_LOOP_OPS 3
#define BFF_COUNTER_TOTAL_COPY_WRITES 4
#define BFF_COUNTER_HALT_BUDGET 5
#define BFF_COUNTER_HALT_PC_OUT 6
#define BFF_COUNTER_HALT_UNMATCHED 7
#define BFF_COUNTER_HALT_UNKNOWN 8

#define BFF_RESIDENT_PAIRING_ROUNDS 16u

struct ResidentEpochParams {
    uint32_t seed;
    uint32_t epoch;
    uint32_t programCount;
    uint32_t pairCount;
    uint32_t stepBudget;
    uint32_t mutationP32;
    uint32_t variant;
    uint32_t capturePairTapes;
    uint32_t visualizationWidth;
    uint32_t reserved0;
    uint32_t reserved1;
    uint32_t reserved2;
};

static_assert(sizeof(ResidentEpochParams) == 48, "ResidentEpochParams size drift");
static_assert(alignof(ResidentEpochParams) == 4, "ResidentEpochParams align drift");

static uint32_t bff_pcg_hash(uint32_t input) {
    uint32_t x = input * 747796405u + 2891336453u;
    uint32_t w = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    return (w >> 22u) ^ w;
}

static uint32_t bff_rng3(uint32_t seed, uint32_t stream, uint32_t index) {
    return bff_pcg_hash(bff_pcg_hash(seed ^ (stream * 0x9E3779B9u)) ^ index);
}

static uint32_t bff_stream(uint32_t epoch, uint32_t pass) {
    return epoch * 4u + pass;
}

// Resident experimental pairing mode: parallel-swap-or-not-v1.
//
// This is not Fisher-Yates trajectory compatibility. Each round is a keyed
// involution over the exact programCount domain, so the composition is a true
// permutation for non-powers-of-two without cycle walking. One GPU thread can
// evaluate one output slot independently.
static uint32_t bff_resident_pairing_program_id(uint32_t outputIndex,
                                                uint32_t programCount,
                                                uint32_t seed,
                                                uint32_t epoch) {
    uint32_t stream = bff_stream(epoch, 1u);
    uint32_t x = outputIndex;
    for (uint32_t round = 0u; round < BFF_RESIDENT_PAIRING_ROUNDS; round++) {
        uint32_t pivot = bff_rng3(seed, stream, 0x40000000u | round) % programCount;
        uint32_t flip = pivot >= x ? pivot - x : programCount - (x - pivot);
        uint32_t position = x > flip ? x : flip;
        uint32_t bitIndex = 0x80000000u | (round << 27u) | (position >> 5u);
        uint32_t word = bff_rng3(seed, stream, bitIndex);
        if (((word >> (position & 31u)) & 1u) != 0u) {
            x = flip;
        }
    }
    return x;
}

static int bff_scan_forward(thread const uchar *tape, int p) {
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

static int bff_scan_backward(thread const uchar *tape, int p) {
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

static bool bff_is_command(uchar b) {
    return b == BFF_OP_HEAD0_LEFT
        || b == BFF_OP_HEAD0_RIGHT
        || b == BFF_OP_HEAD1_LEFT
        || b == BFF_OP_HEAD1_RIGHT
        || b == BFF_OP_INC
        || b == BFF_OP_DEC
        || b == BFF_OP_WRITE
        || b == BFF_OP_READ
        || b == BFF_OP_LOOP_OPEN
        || b == BFF_OP_LOOP_CLOSE;
}

kernel void bff_resident_mutate(device uchar *soup [[buffer(0)]],
                                device atomic_uint *counters [[buffer(1)]],
                                constant ResidentEpochParams &params [[buffer(2)]],
                                uint gid [[thread_position_in_grid]]) {
    uint byteCount = params.programCount * BFF_PROG_SIZE;
    if (gid >= byteCount) return;
    if (params.mutationP32 == 0u) return;

    uint32_t stream = bff_stream(params.epoch, 0u);
    uint32_t idx = (uint32_t)gid;
    if (bff_rng3(params.seed, stream, idx) < params.mutationP32) {
        soup[gid] = (uchar)(bff_rng3(params.seed, stream, idx ^ 0x80000000u) & 0xFFu);
        atomic_fetch_add_explicit(counters + BFF_COUNTER_MUTATION_COUNT,
                                  1u, memory_order_relaxed);
    }
}

kernel void bff_resident_plan_pairs(device uint32_t *permutation [[buffer(0)]],
                                    constant ResidentEpochParams &params [[buffer(1)]],
                                    uint gid [[thread_position_in_grid]]) {
    if (gid >= params.programCount) return;
    permutation[gid] = bff_resident_pairing_program_id((uint32_t)gid,
                                                       params.programCount,
                                                       params.seed,
                                                       params.epoch);
}

kernel void bff_resident_eval_scatter(device uchar *soup [[buffer(0)]],
                                      device const uint32_t *permutation [[buffer(1)]],
                                      device uint32_t *pairResults [[buffer(2)]],
                                      device atomic_uint *counters [[buffer(3)]],
                                      device uchar *inputCapture [[buffer(4)]],
                                      device uchar *finalCapture [[buffer(5)]],
                                      device uint32_t *programActivity [[buffer(6)]],
                                      constant ResidentEpochParams &params [[buffer(7)]],
                                      uint gid [[thread_position_in_grid]]) {
    if (gid >= params.pairCount) return;

    uint32_t a = permutation[gid * 2u];
    uint32_t b = permutation[gid * 2u + 1u];
    uint32_t aStart = a * BFF_PROG_SIZE;
    uint32_t bStart = b * BFF_PROG_SIZE;
    uint32_t pairStart = gid * BFF_PAIR_TAPE_SIZE;

    thread uchar tape[BFF_PAIR_TAPE_SIZE];
    for (uint i = 0u; i < BFF_PROG_SIZE; i++) {
        tape[i] = soup[aStart + i];
        tape[BFF_PROG_SIZE + i] = soup[bStart + i];
    }
    if (params.capturePairTapes != 0u) {
        for (uint i = 0u; i < BFF_PAIR_TAPE_SIZE; i++) {
            inputCapture[pairStart + i] = tape[i];
        }
    }

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

    uint32_t steps = 0u;
    uint32_t noopSteps = 0u;
    uint32_t copyWrites = 0u;
    uint32_t loopOps = 0u;
    uint32_t halt = 0u;

    while (true) {
        if (steps >= params.stepBudget) {
            halt = BFF_HALT_BUDGET;
            break;
        }
        if (pc < 0 || pc >= BFF_PAIR_TAPE_SIZE) {
            halt = BFF_HALT_PC_OUT;
            break;
        }

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
            noopSteps++;
            break;
        }

        pc++;
        steps++;
        if (unmatchedHalt) {
            halt = BFF_HALT_UNMATCHED;
            break;
        }
    }

    for (uint i = 0u; i < BFF_PROG_SIZE; i++) {
        soup[aStart + i] = tape[i];
        soup[bStart + i] = tape[BFF_PROG_SIZE + i];
    }
    if (params.capturePairTapes != 0u) {
        for (uint i = 0u; i < BFF_PAIR_TAPE_SIZE; i++) {
            finalCapture[pairStart + i] = tape[i];
        }
    }

    uint32_t resultStart = gid * 5u;
    pairResults[resultStart] = steps;
    pairResults[resultStart + 1u] = noopSteps;
    pairResults[resultStart + 2u] = copyWrites;
    pairResults[resultStart + 3u] = loopOps;
    pairResults[resultStart + 4u] = halt;

    uint32_t commandSteps = steps - noopSteps;
    programActivity[a] = commandSteps;
    programActivity[b] = commandSteps;

    atomic_fetch_add_explicit(counters + BFF_COUNTER_TOTAL_RAW_STEPS,
                              steps, memory_order_relaxed);
    atomic_fetch_add_explicit(counters + BFF_COUNTER_TOTAL_NOOP_STEPS,
                              noopSteps, memory_order_relaxed);
    atomic_fetch_add_explicit(counters + BFF_COUNTER_TOTAL_LOOP_OPS,
                              loopOps, memory_order_relaxed);
    atomic_fetch_add_explicit(counters + BFF_COUNTER_TOTAL_COPY_WRITES,
                              copyWrites, memory_order_relaxed);
    if (halt == BFF_HALT_BUDGET) {
        atomic_fetch_add_explicit(counters + BFF_COUNTER_HALT_BUDGET,
                                  1u, memory_order_relaxed);
    } else if (halt == BFF_HALT_PC_OUT) {
        atomic_fetch_add_explicit(counters + BFF_COUNTER_HALT_PC_OUT,
                                  1u, memory_order_relaxed);
    } else if (halt == BFF_HALT_UNMATCHED) {
        atomic_fetch_add_explicit(counters + BFF_COUNTER_HALT_UNMATCHED,
                                  1u, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(counters + BFF_COUNTER_HALT_UNKNOWN,
                                  1u, memory_order_relaxed);
    }
}

kernel void bff_resident_visualize(device const uchar *soup [[buffer(0)]],
                                   device const uint32_t *programActivity [[buffer(1)]],
                                   device uchar *rgba [[buffer(2)]],
                                   constant ResidentEpochParams &params [[buffer(3)]],
                                   texture2d<float, access::write> texture [[texture(0)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid >= params.programCount) return;

    uint32_t start = gid * BFF_PROG_SIZE;
    uint32_t sum = 0u;
    uint32_t commandCount = 0u;
    uint32_t xors = 0u;
    for (uint i = 0u; i < BFF_PROG_SIZE; i++) {
        uchar b = soup[start + i];
        sum += (uint32_t)b;
        xors ^= ((uint32_t)b << (i & 3u));
        commandCount += bff_is_command(b) ? 1u : 0u;
    }

    uint32_t mean = sum >> 6u;
    uint32_t activity = min(programActivity[gid] >> 5u, 255u);
    uint32_t commands = min(commandCount * 24u, 255u);
    uint32_t edge = (mean ^ xors) & 255u;

    uint32_t off = gid * 4u;
    rgba[off] = (uchar)activity;
    rgba[off + 1u] = (uchar)commands;
    rgba[off + 2u] = (uchar)edge;
    rgba[off + 3u] = 255;

    uint32_t width = max(params.visualizationWidth, 1u);
    uint2 coord = uint2(gid % width, gid / width);
    if (coord.x < texture.get_width() && coord.y < texture.get_height()) {
        texture.write(float4((float)activity / 255.0f,
                             (float)commands / 255.0f,
                             (float)edge / 255.0f,
                             1.0f),
                      coord);
    }
}
