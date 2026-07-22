// BFFEcologyEpoch.metal — experimental GPU-resident ecology epoch kernels.
//
// Normative source: Sources/BFFOracle/Ecology.swift (CPU oracle).
// This is a separate engine from BFFResidentEpoch.metal; it ports the ecology
// v1 contract (torus-512x256, edge-color-sync scheduler, ecology-counter-pcg
// RNG) to Metal with byte-exact CPU parity.
//
// Kernels:
//   1. bff_ecology_mutate — per-byte mutation from ecology RNG
//   2. bff_ecology_eval_scatter — per-pair BFF interpreter with both bracket modes
//   3. bff_ecology_visualize — app-safe per-site RGB overview from the live soup
//   4. bff_ecology_layout_probe — test-only ABI verification
//   5. bff_ecology_rng_probe — test-only RNG boundary vectors
//   6. bff_ecology_pair_probe — test-only topology pair mapping verification

#include <metal_stdlib>
using namespace metal;

// --- Mirror of BFFEcologyShared.h constants ---
#define BFF_ECO_PROG_SIZE 64
#define BFF_ECO_PAIR_TAPE_SIZE 128
#define BFF_ECO_TOPOLOGY_WIDTH 512
#define BFF_ECO_TOPOLOGY_HEIGHT 256
#define BFF_ECO_SITE_COUNT 131072
#define BFF_ECO_PAIR_COUNT 65536
#define BFF_ECO_SOUP_BYTE_COUNT 8388608
#define BFF_ECO_ELEMENT_LIMIT 16777216u

#define BFF_ECO_RNG_INIT_BYTES 0x01u
#define BFF_ECO_RNG_MUTATE_FLAG 0x02u
#define BFF_ECO_RNG_MUTATE_VALUE 0x03u
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

// --- BFF opcode bytes (match BFFShared.h) ---
#define BFF_ECO_OP_HEAD0_LEFT 0x3Cu
#define BFF_ECO_OP_HEAD0_RIGHT 0x3Eu
#define BFF_ECO_OP_HEAD1_LEFT 0x7Bu
#define BFF_ECO_OP_HEAD1_RIGHT 0x7Du
#define BFF_ECO_OP_INC 0x2Bu
#define BFF_ECO_OP_DEC 0x2Du
#define BFF_ECO_OP_WRITE 0x2Eu
#define BFF_ECO_OP_READ 0x2Cu
#define BFF_ECO_OP_LOOP_OPEN 0x5Bu
#define BFF_ECO_OP_LOOP_CLOSE 0x5Du

// --- Mirror structs (pinned by static_assert against the same literals as the
// C header's _Static_asserts) ---
struct BFFEcologyEpochParams {
    uint32_t seed;
    uint32_t epoch;
    uint32_t stepBudget;
    uint32_t mutationP32;
    uint32_t variant;
    uint32_t bracketMode;
    uint32_t capturePairTapes;
    uint32_t reserved0;
};

struct BFFEcologyPairResult {
    uint32_t steps;
    uint32_t noopSteps;
    uint32_t copyWrites;
    uint32_t loopOps;
    uint32_t remapEvents;
    uint32_t halt;
};

static_assert(sizeof(BFFEcologyEpochParams) == 32, "params size");
static_assert(sizeof(BFFEcologyPairResult) == 24, "pair result size");
static_assert(alignof(BFFEcologyEpochParams) == 4, "params align");
static_assert(alignof(BFFEcologyPairResult) == 4, "pair result align");

// --- PCG hash (identical body to BFFRandom.pcgHash) ---
static uint32_t bff_pcg_hash(uint32_t input) {
    uint32_t x = input * 747796405u + 2891336453u;
    uint32_t w = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    return (w >> 22u) ^ w;
}

// --- Ecology RNG (mirrors EcologyRandom exactly) ---
// ecologySeed = seed ^ 0xEC0EC001
// stream = (purpose << 24) | (epoch >> 8)
// index  = ((epoch & 0xFF) << 24) | element
// draw   = pcg_hash(pcg_hash(ecologySeed ^ (stream * 0x9E3779B9)) ^ index)
static uint32_t bff_ecology_seed(uint32_t seed) {
    return seed ^ BFF_ECO_RNG_SEED_XOR;
}

static uint32_t bff_ecology_rng3(uint32_t seed, uint32_t purpose,
                                  uint32_t epoch, uint32_t element) {
    uint32_t ecoSeed = bff_ecology_seed(seed);
    uint32_t stream = (purpose << 24u) | (epoch >> 8u);
    uint32_t index = ((epoch & 0xFFu) << 24u) | element;
    return bff_pcg_hash(bff_pcg_hash(ecoSeed ^ (stream * 0x9E3779B9u)) ^ index);
}

// --- Edge-color topology pair mapping (mirrors EcologyTopology.pair) ---
static void bff_ecology_pair(uint32_t pairIndex, uint32_t phase,
                              thread uint32_t &a, thread uint32_t &b) {
    if (phase == BFF_ECO_PHASE_H0 || phase == BFF_ECO_PHASE_H1) {
        uint32_t parity = (phase == BFF_ECO_PHASE_H0) ? 0u : 1u;
        uint32_t ownersPerRow = BFF_ECO_TOPOLOGY_WIDTH / 2u;
        uint32_t y = pairIndex / ownersPerRow;
        uint32_t ownerSlot = pairIndex % ownersPerRow;
        uint32_t x = ownerSlot * 2u + parity;
        a = y * BFF_ECO_TOPOLOGY_WIDTH + x;
        b = y * BFF_ECO_TOPOLOGY_WIDTH + ((x + 1u) & (BFF_ECO_TOPOLOGY_WIDTH - 1u));
    } else {
        uint32_t parity = (phase == BFF_ECO_PHASE_V0) ? 0u : 1u;
        uint32_t ownerRow = pairIndex / BFF_ECO_TOPOLOGY_WIDTH;
        uint32_t x = pairIndex % BFF_ECO_TOPOLOGY_WIDTH;
        uint32_t y = ownerRow * 2u + parity;
        a = y * BFF_ECO_TOPOLOGY_WIDTH + x;
        b = ((y + 1u) & (BFF_ECO_TOPOLOGY_HEIGHT - 1u)) * BFF_ECO_TOPOLOGY_WIDTH + x;
    }
}

// --- Bracket scanning on live tape (dynamic mode) ---
static int bff_ecology_scan_forward(thread const uchar *tape, int p) {
    int depth = 0;
    for (int q = p + 1; q < BFF_ECO_PAIR_TAPE_SIZE; q++) {
        uchar c = tape[q];
        if (c == BFF_ECO_OP_LOOP_OPEN) {
            depth++;
        } else if (c == BFF_ECO_OP_LOOP_CLOSE) {
            if (depth == 0) return q;
            depth--;
        }
    }
    return -1;
}

static int bff_ecology_scan_backward(thread const uchar *tape, int p) {
    int depth = 0;
    for (int q = p - 1; q >= 0; q--) {
        uchar c = tape[q];
        if (c == BFF_ECO_OP_LOOP_CLOSE) {
            depth++;
        } else if (c == BFF_ECO_OP_LOOP_OPEN) {
            if (depth == 0) return q;
            depth--;
        }
    }
    return -1;
}

// --- Frozen bracket scan on the immutable interaction-start tape ---
// Equivalent to BFFInterpreter.buildJumpTable: the frozen target at pc is
// determined by the INITIAL byte at pc, NOT the live opcode direction. If the
// initial byte was '[', its frozen target is the forward match; if it was ']',
// the backward match; otherwise -1 (unmatched). This mirrors the CPU's
// direction-agnostic `frozen[pc]` table lookup exactly.
static int bff_ecology_frozen_target(thread const uchar *initialTape, int p) {
    uchar c = initialTape[p];
    if (c == BFF_ECO_OP_LOOP_OPEN) {
        return bff_ecology_scan_forward(initialTape, p);
    } else if (c == BFF_ECO_OP_LOOP_CLOSE) {
        return bff_ecology_scan_backward(initialTape, p);
    }
    return -1;
}

// ============================================================
// Kernel: bff_ecology_mutate
// ============================================================
kernel void bff_ecology_mutate(device uchar *soup [[buffer(0)]],
                                device atomic_uint *counters [[buffer(1)]],
                                constant BFFEcologyEpochParams &params [[buffer(2)]],
                                uint gid [[thread_position_in_grid]]) {
    if (gid >= BFF_ECO_SOUP_BYTE_COUNT) return;
    if (params.mutationP32 == 0u) return;

    uint32_t element = (uint32_t)gid;
    uint32_t flag = bff_ecology_rng3(params.seed, BFF_ECO_RNG_MUTATE_FLAG,
                                      params.epoch, element);
    if (flag < params.mutationP32) {
        uint32_t value = bff_ecology_rng3(params.seed, BFF_ECO_RNG_MUTATE_VALUE,
                                           params.epoch, element);
        soup[gid] = (uchar)(value & 0xFFu);
        atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_MUTATION_COUNT,
                                  1u, memory_order_relaxed);
    }
}

// ============================================================
// Kernel: bff_ecology_eval_scatter
// ============================================================
kernel void bff_ecology_eval_scatter(
    device uchar *soup [[buffer(0)]],
    device atomic_uint *counters [[buffer(1)]],
    constant BFFEcologyEpochParams &params [[buffer(2)]],
    device BFFEcologyPairResult *pairResults [[buffer(3)]],
    device uchar *inputCapture [[buffer(4)]],
    device uchar *finalCapture [[buffer(5)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= BFF_ECO_PAIR_COUNT) return;

    uint32_t phase = params.epoch & 3u;
    uint32_t a, b;
    bff_ecology_pair((uint32_t)gid, phase, a, b);

    uint32_t aStart = a * BFF_ECO_PROG_SIZE;
    uint32_t bStart = b * BFF_ECO_PROG_SIZE;
    uint32_t pairStart = gid * BFF_ECO_PAIR_TAPE_SIZE;

    // Live tape — read from soup (which was already mutated by bff_ecology_mutate)
    thread uchar tape[BFF_ECO_PAIR_TAPE_SIZE];
    for (uint i = 0u; i < BFF_ECO_PROG_SIZE; i++) {
        tape[i] = soup[aStart + i];
        tape[BFF_ECO_PROG_SIZE + i] = soup[bStart + i];
    }

    // Immutable interaction-start tape — snapshot AFTER mutation, BEFORE first
    // instruction. Used for frozen bracket scans (jump-table mode control flow)
    // and remapEvents counting (both modes).
    thread uchar initialTape[BFF_ECO_PAIR_TAPE_SIZE];
    for (uint i = 0u; i < BFF_ECO_PAIR_TAPE_SIZE; i++) {
        initialTape[i] = tape[i];
    }

    if (params.capturePairTapes != 0u) {
        for (uint i = 0u; i < BFF_ECO_PAIR_TAPE_SIZE; i++) {
            inputCapture[pairStart + i] = tape[i];
        }
    }

    // --- Interpreter (ports BFFInterpreter.run exactly) ---
    int pc;
    uint h0, h1;
    if (params.variant == BFF_ECO_VARIANT_SEEDED_HEADS) {
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
    uint32_t remapEvents = 0u;
    uint32_t halt = 0u;

    while (true) {
        if (steps >= params.stepBudget) {
            halt = BFF_ECO_HALT_BUDGET;
            break;
        }
        if (pc < 0 || pc >= BFF_ECO_PAIR_TAPE_SIZE) {
            halt = BFF_ECO_HALT_PC_OUT;
            break;
        }

        bool unmatchedHalt = false;
        uchar op = tape[pc];
        switch (op) {
        case BFF_ECO_OP_HEAD0_LEFT:
            h0 = (h0 - 1u) & 127u;
            break;
        case BFF_ECO_OP_HEAD0_RIGHT:
            h0 = (h0 + 1u) & 127u;
            break;
        case BFF_ECO_OP_HEAD1_LEFT:
            h1 = (h1 - 1u) & 127u;
            break;
        case BFF_ECO_OP_HEAD1_RIGHT:
            h1 = (h1 + 1u) & 127u;
            break;
        case BFF_ECO_OP_INC:
            tape[h0]++;
            break;
        case BFF_ECO_OP_DEC:
            tape[h0]--;
            break;
        case BFF_ECO_OP_WRITE:
            tape[h1] = tape[h0];
            copyWrites += (uint32_t)((h0 >> 6) != (h1 >> 6));
            break;
        case BFF_ECO_OP_READ:
            tape[h0] = tape[h1];
            copyWrites += (uint32_t)((h0 >> 6) != (h1 >> 6));
            break;
        case BFF_ECO_OP_LOOP_OPEN:
            loopOps++;
            if (tape[h0] == 0u) {
                int liveTarget = bff_ecology_scan_forward(tape, pc);
                int frozenTarget = bff_ecology_frozen_target(initialTape, pc);
                if (liveTarget != frozenTarget) remapEvents++;
                int target = (params.bracketMode == BFF_ECO_BRACKET_DYNAMIC_SCAN)
                    ? liveTarget : frozenTarget;
                if (target < 0) unmatchedHalt = true;
                else pc = target;
            }
            break;
        case BFF_ECO_OP_LOOP_CLOSE:
            loopOps++;
            if (tape[h0] != 0u) {
                int liveTarget = bff_ecology_scan_backward(tape, pc);
                int frozenTarget = bff_ecology_frozen_target(initialTape, pc);
                if (liveTarget != frozenTarget) remapEvents++;
                int target = (params.bracketMode == BFF_ECO_BRACKET_DYNAMIC_SCAN)
                    ? liveTarget : frozenTarget;
                if (target < 0) unmatchedHalt = true;
                else pc = target;
            }
            break;
        default:
            noopSteps++;
            break;
        }

        pc++;
        steps++;
        if (unmatchedHalt) {
            halt = BFF_ECO_HALT_UNMATCHED;
            break;
        }
    }

    // --- Write back final tape ---
    for (uint i = 0u; i < BFF_ECO_PROG_SIZE; i++) {
        soup[aStart + i] = tape[i];
        soup[bStart + i] = tape[BFF_ECO_PROG_SIZE + i];
    }
    if (params.capturePairTapes != 0u) {
        for (uint i = 0u; i < BFF_ECO_PAIR_TAPE_SIZE; i++) {
            finalCapture[pairStart + i] = tape[i];
        }
    }

    // --- Per-pair results (test-only) ---
    if (params.capturePairTapes != 0u) {
        pairResults[gid].steps = steps;
        pairResults[gid].noopSteps = noopSteps;
        pairResults[gid].copyWrites = copyWrites;
        pairResults[gid].loopOps = loopOps;
        pairResults[gid].remapEvents = remapEvents;
        pairResults[gid].halt = halt;
    }

    // --- Atomic per-epoch counters ---
    atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_TOTAL_RAW_STEPS,
                              steps, memory_order_relaxed);
    atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_TOTAL_NOOP_STEPS,
                              noopSteps, memory_order_relaxed);
    atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_TOTAL_LOOP_OPS,
                              loopOps, memory_order_relaxed);
    atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_TOTAL_COPY_WRITES,
                              copyWrites, memory_order_relaxed);
    atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_TOTAL_REMAP_EVENTS,
                              remapEvents, memory_order_relaxed);

    if (halt == BFF_ECO_HALT_BUDGET) {
        atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_HALT_BUDGET,
                                  1u, memory_order_relaxed);
    } else if (halt == BFF_ECO_HALT_PC_OUT) {
        atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_HALT_PC_OUT,
                                  1u, memory_order_relaxed);
    } else if (halt == BFF_ECO_HALT_UNMATCHED) {
        atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_HALT_UNMATCHED,
                                  1u, memory_order_relaxed);
    } else {
        // Unknown halt — defense-in-depth sentinel. Must remain zero; host throws.
        atomic_fetch_add_explicit(counters + BFF_ECO_COUNTER_HALT_UNKNOWN,
                                  1u, memory_order_relaxed);
    }
}

// ============================================================
// Test-only kernels
// ============================================================

// Layout probe: reports sizeof/alignof/byte-offsets as compiled by Metal.
// Uses pointer arithmetic (not offsetof) to match the proven pattern in
// bff_layout_probe (BFFEvaluate.metal) — offsetof availability in MSL is
// not guaranteed across toolchains.
kernel void bff_ecology_layout_probe(device uint32_t *output [[buffer(0)]],
                                      uint gid [[thread_position_in_grid]]) {
    if (gid != 0) return;
    BFFEcologyEpochParams p = {};
    BFFEcologyPairResult r = {};
    thread char *pBase = (thread char *)&p;
    thread char *rBase = (thread char *)&r;
    uint32_t i = 0;
    output[i++] = (uint32_t)sizeof(BFFEcologyEpochParams);
    output[i++] = (uint32_t)alignof(BFFEcologyEpochParams);
    output[i++] = (uint32_t)((thread char *)&p.seed - pBase);
    output[i++] = (uint32_t)((thread char *)&p.epoch - pBase);
    output[i++] = (uint32_t)((thread char *)&p.stepBudget - pBase);
    output[i++] = (uint32_t)((thread char *)&p.mutationP32 - pBase);
    output[i++] = (uint32_t)((thread char *)&p.variant - pBase);
    output[i++] = (uint32_t)((thread char *)&p.bracketMode - pBase);
    output[i++] = (uint32_t)((thread char *)&p.capturePairTapes - pBase);
    output[i++] = (uint32_t)((thread char *)&p.reserved0 - pBase);
    output[i++] = (uint32_t)sizeof(BFFEcologyPairResult);
    output[i++] = (uint32_t)alignof(BFFEcologyPairResult);
    output[i++] = (uint32_t)((thread char *)&r.steps - rBase);
    output[i++] = (uint32_t)((thread char *)&r.noopSteps - rBase);
    output[i++] = (uint32_t)((thread char *)&r.copyWrites - rBase);
    output[i++] = (uint32_t)((thread char *)&r.loopOps - rBase);
    output[i++] = (uint32_t)((thread char *)&r.remapEvents - rBase);
    output[i++] = (uint32_t)((thread char *)&r.halt - rBase);
}

// RNG probe: writes specific draws at boundary cases for pinned-vector comparison.
// Test dispatches with a buffer of (seed, purpose, epoch, element) quadruples
// and reads back the draw results.
kernel void bff_ecology_rng_probe(device const uint32_t *inputs [[buffer(0)]],
                                   device uint32_t *outputs [[buffer(1)]],
                                   constant uint32_t &count [[buffer(2)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    uint32_t seed = inputs[gid * 4u];
    uint32_t purpose = inputs[gid * 4u + 1u];
    uint32_t epoch = inputs[gid * 4u + 2u];
    uint32_t element = inputs[gid * 4u + 3u];
    outputs[gid] = bff_ecology_rng3(seed, purpose, epoch, element);
}

// Pair probe: writes (a, b) site IDs for a given (pairIndex, phase).
kernel void bff_ecology_pair_probe(device uint32_t *pairAB [[buffer(0)]],
                                   constant BFFEcologyEpochParams &params [[buffer(1)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (gid >= BFF_ECO_PAIR_COUNT) return;
    uint32_t a, b;
    bff_ecology_pair((uint32_t)gid, params.epoch & 3u, a, b);
    pairAB[gid * 2u] = a;
    pairAB[gid * 2u + 1u] = b;
}

// ============================================================
// Kernel: bff_ecology_visualize
// ============================================================
// App-safe per-site RGB overview of the live ecology soup. One GPU thread per
// ecology site (512 × 256 = 131,072). Each texel is a deterministic function
// of THAT site's 64 program bytes only — soup-derived scalar summaries, not
// energy/death/movement/predation/fitness/reproduction/paper metrics:
//   R = opcode-byte density (count of the ten BFF command bytes), scaled.
//   G = per-site byte mean (Σ bytes >> 6), scaled.
//   B = structural positional-XOR fingerprint (Σ (b << (i & 3))) ^ mean.
//
// Writes ONLY the 512×256 rgba8Unorm texture. Unlike `bff_resident_visualize`
// (which also writes a host-readable byte buffer the resident CPU-snapshot
// path consumes), the ecology app-safe path has no host reader for an
// overview byte buffer — the renderer leases the immutable snapshot's TEXTURE
// (blitted from this live texture into a ring slot), and the producer never
// reads the overview back to the CPU. Allocating and writing a 512 KiB byte
// buffer that is never read would be wasted work, so this kernel does not
// take one. The producer runs this AFTER mutate+eval and BEFORE scheduling
// the immutable snapshot publication (a blit of soup + this overview texture
// into a ring slot). The renderer never binds the live soup or the live
// overview texture; it leases the immutable slot. This kernel is NOT called
// by the accepted CLI `EcologyMetalEpochRunner.runEpoch()`, which keeps its
// exact readback+digest semantics; it is the app-safe execution path only.
kernel void bff_ecology_visualize(device const uchar *soup [[buffer(0)]],
                                  texture2d<float, access::write> texture [[texture(0)]],
                                  uint gid [[thread_position_in_grid]]) {
    if (gid >= BFF_ECO_SITE_COUNT) return;

    uint32_t start = gid * BFF_ECO_PROG_SIZE;
    uint32_t sum = 0u;
    uint32_t commandCount = 0u;
    uint32_t xors = 0u;
    for (uint i = 0u; i < BFF_ECO_PROG_SIZE; i++) {
        uchar b = soup[start + i];
        sum += (uint32_t)b;
        xors ^= ((uint32_t)b << (i & 3u));
        switch (b) {
        case BFF_ECO_OP_HEAD0_LEFT:
        case BFF_ECO_OP_HEAD0_RIGHT:
        case BFF_ECO_OP_HEAD1_LEFT:
        case BFF_ECO_OP_HEAD1_RIGHT:
        case BFF_ECO_OP_INC:
        case BFF_ECO_OP_DEC:
        case BFF_ECO_OP_WRITE:
        case BFF_ECO_OP_READ:
        case BFF_ECO_OP_LOOP_OPEN:
        case BFF_ECO_OP_LOOP_CLOSE:
            commandCount++;
            break;
        default:
            break;
        }
    }

    uint32_t mean = sum >> 6u;
    uint32_t commands = min(commandCount * 24u, 255u);
    uint32_t edge = (mean ^ xors) & 255u;

    uint2 coord = uint2(gid % BFF_ECO_TOPOLOGY_WIDTH, gid / BFF_ECO_TOPOLOGY_WIDTH);
    if (coord.x < texture.get_width() && coord.y < texture.get_height()) {
        texture.write(float4((float)commands / 255.0f,
                              (float)mean / 255.0f,
                              (float)edge / 255.0f,
                              1.0f),
                      coord);
    }
}
