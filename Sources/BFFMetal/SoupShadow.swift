import BFFOracle

/// Deterministic selection of which pairs to CPU-shadow-check each epoch.
///
/// The sample is chosen without replacement from `0..<pairCount` as a pure
/// function of `(seed, epoch)`, so a replay picks the identical pairs. It draws
/// from a HOST-ONLY RNG domain deliberately separated from the `counter-pcg-v1`
/// soup streams (mutate/pairing/soupInit/selfRep, `stream = epoch*4+pass`): the
/// seed is XORed with `domainTag` before hashing, so no shadow draw can ever
/// coincide with — let alone perturb — a soup draw. (Shadow selection only reads
/// the already-computed plan and outcomes, so it cannot alter the trajectory
/// regardless; the domain separation keeps that guarantee obvious.)
public enum ShadowSampler {

    /// XORed into the seed to place shadow selection in its own RNG domain.
    public static let domainTag: UInt32 = 0x5AD0_5EED

    /// Return `sampleCount` distinct pair indices in `0..<pairCount`, sorted
    /// ascending for stable diagnostics. `0` returns empty (shadowing disabled);
    /// `pairCount` returns every index (full shadow). Uses a partial Fisher–Yates
    /// so the result is a genuine without-replacement sample with no duplicates.
    public static func sampleIndices(pairCount: Int, sampleCount: Int,
                                     seed: UInt32, epoch: Int) -> [Int] {
        precondition(sampleCount >= 0 && sampleCount <= pairCount,
                     "sample count \(sampleCount) out of 0...\(pairCount)")
        guard sampleCount > 0 else { return [] }
        if sampleCount == pairCount { return Array(0 ..< pairCount) }

        let shadowSeed = seed ^ domainTag
        let stream = UInt32(truncatingIfNeeded: epoch)
        var pool = Array(0 ..< pairCount)
        for i in 0 ..< sampleCount {
            let span = UInt32(pairCount - i)
            let r = BFFRandom.rng3(seed: shadowSeed, stream: stream, index: UInt32(i))
            let j = i + Int(r % span)
            pool.swapAt(i, j)
        }
        return Array(pool[0 ..< sampleCount]).sorted()
    }
}

/// One actionable CPU-shadow divergence: enough stable identity to locate it and
/// enough detail to act on it.
public struct ShadowMismatch: Equatable, Sendable {
    public var epoch: Int
    public var pairIndex: Int
    /// The two stable program IDs of this pair (identity is never redefined by
    /// pairing, so these locate the divergence in the soup).
    public var programA: UInt32
    public var programB: UInt32
    /// First differing final-tape byte index, or `nil` if tapes matched.
    public var firstTapeDivergence: Int?
    /// Human-readable, one finding per line (tape byte / each counter / halt).
    public var lines: [String]

    public init(epoch: Int, pairIndex: Int, programA: UInt32, programB: UInt32,
                firstTapeDivergence: Int?, lines: [String]) {
        self.epoch = epoch
        self.pairIndex = pairIndex
        self.programA = programA
        self.programB = programB
        self.firstTapeDivergence = firstTapeDivergence
        self.lines = lines
    }

    /// A single flat diagnostic string prefixed with the stable identity.
    public var summary: String {
        let head = "epoch \(epoch) pair \(pairIndex) (programs \(programA),\(programB))"
        return ([head] + lines).joined(separator: "\n    ")
    }
}

/// Re-runs the scalar CPU BFF interpreter on a sampled pair's exact pre-GPU input
/// and compares every observable against the GPU outcome. Platform-independent and
/// side-effect-free: it never mutates the soup or draws from the soup RNG, so
/// shadowing cannot perturb the trajectory. Unit-testable with synthesized GPU
/// outcomes exactly like `GPUFixtureComparator`.
public enum ShadowComparator {

    /// Compare one pair. Returns `nil` on exact parity, else a mismatch carrying
    /// the epoch, pair index, both program IDs, first differing tape byte, and one
    /// line per divergent field. The reference always uses `.dynamicScan` — the
    /// only semantics the GPU implements.
    public static func check(epoch: Int, pairIndex: Int,
                             programA: UInt32, programB: UInt32,
                             input: [UInt8], variant: BFFVariant, stepBudget: Int,
                             gpu: GPUPairOutcome) -> ShadowMismatch? {
        let oracle = BFFInterpreter.run(pairTape: input, variant: variant,
                                        bracketMode: .dynamicScan,
                                        stepBudget: stepBudget)

        var lines: [String] = []
        var firstTapeDivergence: Int?

        if gpu.finalTape != oracle.tape {
            let first = (0 ..< min(gpu.finalTape.count, oracle.tape.count))
                .first { gpu.finalTape[$0] != oracle.tape[$0] }
            firstTapeDivergence = first
            if let first {
                lines.append("final tape diverges at byte \(first): "
                             + "gpu 0x\(hex(gpu.finalTape[first])) "
                             + "vs cpu 0x\(hex(oracle.tape[first]))")
            } else {
                lines.append("final tape length diverges: gpu \(gpu.finalTape.count) "
                             + "vs cpu \(oracle.tape.count) bytes")
            }
        }
        if Int(gpu.steps) != oracle.steps {
            lines.append("steps diverge: gpu \(gpu.steps) vs cpu \(oracle.steps)")
        }
        if Int(gpu.noopSteps) != oracle.noopSteps {
            lines.append("noopSteps diverge: gpu \(gpu.noopSteps) vs cpu \(oracle.noopSteps)")
        }
        if Int(gpu.copyWrites) != oracle.copyWrites {
            lines.append("copyWrites diverge: gpu \(gpu.copyWrites) vs cpu \(oracle.copyWrites)")
        }
        if Int(gpu.loopOps) != oracle.loopOps {
            lines.append("loopOps diverge: gpu \(gpu.loopOps) vs cpu \(oracle.loopOps)")
        }
        if gpu.halt != UInt32(oracle.halt.rawValue) {
            lines.append("halt reason diverges: gpu \(gpu.halt) "
                         + "vs cpu \(oracle.halt.rawValue) (\(oracle.halt))")
        }

        guard !lines.isEmpty else { return nil }
        return ShadowMismatch(epoch: epoch, pairIndex: pairIndex,
                              programA: programA, programB: programB,
                              firstTapeDivergence: firstTapeDivergence, lines: lines)
    }

    static func hex(_ byte: UInt8) -> String {
        let raw = String(byte, radix: 16)
        return raw.count == 1 ? "0" + raw : raw
    }
}
