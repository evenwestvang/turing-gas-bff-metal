import BFFOracle

/// Configuration for one deterministic small-soup GPU evolution run.
///
/// This is the metal-slice analogue of `BFFOracle.SimulationConfig`, but scoped to
/// what the GPU evaluator can actually do: the bracket path is *always* dynamic
/// live scanning (the only GPU bracket implementation — 02 §10 / `BFFEvaluate.metal`),
/// so there is no `bracketMode` knob here, and there is one extra knob — the
/// CPU-shadow sample size — that is meaningless for the pure CPU oracle.
///
/// It reuses the existing `counter-pcg-v1` contract (`BFFRandom`) verbatim for
/// initialization, mutation, and pairing; it does not define any new RNG,
/// pairing, or mutation semantics.
///
/// The initializer is throwing on purpose: every field is validated *before* any
/// buffer is allocated or any dispatch is encoded, so the headless runner can exit
/// nonzero on a bad configuration instead of trapping. All bounds that feed a GPU
/// ABI conversion (`pairCount`, `stepBudget` → `uint32`) are checked here.
public struct SoupConfig: Equatable, Sendable {
    /// Run seed — the sole entropy source together with the fields below.
    public var seed: UInt32
    /// Number of 64-byte programs in the soup. Must be positive and even.
    /// Deliberately modest by default; this checkpoint does not tune for 131,072.
    public var programCount: Int
    /// Gas budget: max executed steps per interaction. Default 8192 (cubff default).
    public var stepBudget: Int
    /// Mutate a byte iff a uniform `UInt32` draw is `< mutationP32` (integer
    /// threshold — no floating-point probability anywhere). 0 disables mutation.
    public var mutationP32: UInt32
    /// Initial pc/head variant (01 §3); the GPU supports both.
    public var variant: BFFVariant
    /// Number of pairs per epoch to re-run on the scalar CPU interpreter and
    /// compare against the GPU. 0 disables shadowing explicitly; `pairCount`
    /// (or more, clamped in validation) shadows every pair.
    public var shadowSampleCount: Int

    /// Interactions per epoch — one paired 128-byte tape per pair.
    public var pairCount: Int { programCount / 2 }

    /// Total soup bytes (`programCount * 64`).
    public var soupByteCount: Int { programCount * BFF.tapeSize }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case programCountNotPositiveEven(Int)
        case programCountOverflow(Int)
        case stepBudgetOutOfRange(Int)
        case shadowSampleOutOfRange(sample: Int, pairCount: Int)

        public var description: String {
            switch self {
            case .programCountNotPositiveEven(let n):
                return "program count \(n) must be positive and even"
            case .programCountOverflow(let n):
                return "program count \(n) is too large: soup bytes or pair count "
                    + "would overflow the addressable / uint32 GPU range"
            case .stepBudgetOutOfRange(let b):
                return "step budget \(b) must be in 1...\(BFFEvalLayout.maxStepBudget) "
                    + "(representable in the shared uint32 field)"
            case .shadowSampleOutOfRange(let sample, let pairCount):
                return "shadow sample count \(sample) must be in 0...\(pairCount) "
                    + "(the number of pairs)"
            }
        }
    }

    /// Validate and construct. Throws `ConfigError` on any invalid field so callers
    /// can report and exit rather than trap.
    public init(
        seed: UInt32,
        programCount: Int = 16,
        stepBudget: Int = BFF.stepBudget,
        mutationP32: UInt32 = BFF.defaultMutationP32,
        variant: BFFVariant = .noheads,
        shadowSampleCount: Int? = nil
    ) throws {
        guard programCount > 0, programCount % 2 == 0 else {
            throw ConfigError.programCountNotPositiveEven(programCount)
        }
        // Overflow guards for the two GPU-ABI conversions and the soup allocation:
        //   - soup byte count (programCount * 64) must fit Int, and
        //   - pairCount (programCount / 2) must fit the dispatch's uint32 pairCount.
        guard programCount <= Int.max / BFF.tapeSize,
              programCount / 2 <= Int(UInt32.max) else {
            throw ConfigError.programCountOverflow(programCount)
        }
        guard stepBudget > 0, stepBudget <= BFFEvalLayout.maxStepBudget else {
            throw ConfigError.stepBudgetOutOfRange(stepBudget)
        }

        let pairs = programCount / 2
        // `nil` means "shadow every pair"; an explicit value is bounds-checked.
        let sample = shadowSampleCount ?? pairs
        guard sample >= 0, sample <= pairs else {
            throw ConfigError.shadowSampleOutOfRange(sample: sample, pairCount: pairs)
        }

        self.seed = seed
        self.programCount = programCount
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.shadowSampleCount = sample
    }
}

/// Deterministic, dependency-free soup fingerprint for replay comparison.
///
/// FNV-1a over the raw soup bytes: a run is a pure function of `(seed, config)`, so
/// two runs with identical inputs must print identical digests, and any trajectory
/// divergence changes the digest. This is a byte fingerprint, not a cryptographic
/// hash — its only job is cheap deterministic equality across machines.
public enum SoupDigest {
    public static func digest(_ soup: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV-1a 64-bit offset basis
        let prime: UInt64 = 0x0000_0100_0000_01B3 // FNV-1a 64-bit prime
        for byte in soup {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return hash
    }

    /// Zero-padded 16-hex-digit rendering of a digest value (lowercase), for
    /// stable, platform-independent CLI/replay output.
    public static func hexString(_ value: UInt64) -> String {
        let raw = String(value, radix: 16)
        return String(repeating: "0", count: 16 - raw.count) + raw
    }

    /// Zero-padded 16-hex-digit rendering of a soup's digest.
    public static func hexString(_ soup: [UInt8]) -> String {
        hexString(digest(soup))
    }
}
