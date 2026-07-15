/// The scalar epoch runner: mutate → pair → run, per 01 §4.

/// Full run configuration. Together with nothing else, this determines every byte of
/// a run (01 §6 determinism contract, under the `counter-pcg-v1` RNG).
public struct SimulationConfig: Codable, Equatable, Sendable {
    public var seed: UInt32
    /// Number of 64-byte programs in the soup. Must be positive and even.
    /// Spec default is 131,072; tests use small values.
    public var populationSize: Int
    public var stepBudget: Int
    /// Mutate a byte iff a uniform `UInt32` draw is `< mutationP32`.
    /// Default `2^20` (= 1/4096 per byte per epoch); 0 disables mutation.
    public var mutationP32: UInt32
    public var variant: BFFVariant
    public var bracketMode: BracketMode

    public init(
        seed: UInt32,
        populationSize: Int = BFF.defaultSoupPrograms,
        stepBudget: Int = BFF.stepBudget,
        mutationP32: UInt32 = BFF.defaultMutationP32,
        variant: BFFVariant = .noheads,
        bracketMode: BracketMode = .dynamicScan
    ) {
        precondition(populationSize > 0 && populationSize % 2 == 0,
                     "population must be positive and even")
        precondition(stepBudget > 0)
        self.seed = seed
        self.populationSize = populationSize
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.bracketMode = bracketMode
    }
}

/// Lightweight per-epoch statistics — the "free byproducts" of 01 §4/§5.
public struct EpochStats: Codable, Equatable, Sendable {
    /// The epoch these stats describe (0-based).
    public var epoch: Int
    /// Number of interactions run (= populationSize / 2).
    public var interactions: Int
    public var totalSteps: Int
    public var meanSteps: Double
    /// Halt-reason mix — the cheap phase-transition detector of 01 §3.
    public var haltBudget: Int
    public var haltPCOut: Int
    public var haltUnmatched: Int
    /// Cross-half `.`/`,` executions summed over all interactions.
    public var totalCopyWrites: Int
    /// Bracket ops executed, summed.
    public var totalLoopOps: Int
    /// Taken brackets whose live match differed from the frozen table (06 D1).
    public var totalRemapEvents: Int
}

/// A deterministic, single-threaded BFF soup simulation.
///
/// Value semantics: copying a `Simulation` forks the run. Epoch `e` consumes RNG
/// streams `e*4 + pass`, so state is fully captured by `(config, soup, epoch)`.
public struct Simulation: Sendable {
    public let config: SimulationConfig
    /// The soup: `populationSize * 64` bytes, program `i` at `i*64 ..< (i+1)*64`.
    public private(set) var soup: [UInt8]
    /// Next epoch to run (also the number of epochs run so far).
    public private(set) var epoch: Int
    /// Stats of the most recently completed epoch, if any.
    public private(set) var lastEpochStats: EpochStats?

    public init(config: SimulationConfig) {
        self.config = config
        self.soup = BFFRandom.initialSoup(programs: config.populationSize, seed: config.seed)
        self.epoch = 0
    }

    /// The 64-byte program at index `i` (a copy).
    public func program(at i: Int) -> [UInt8] {
        precondition(i >= 0 && i < config.populationSize)
        return Array(soup[i * BFF.tapeSize ..< (i + 1) * BFF.tapeSize])
    }

    /// Global 256-bin byte histogram of the current soup.
    public func histogram() -> ByteHistogram {
        ByteHistogram(bytes: soup)
    }

    /// Run one epoch: mutate → pair (Fisher–Yates) → run all pairs (01 §4).
    /// Mutation is frozen during execution; pairs are disjoint, so execution order
    /// cannot affect the result.
    @discardableResult
    public mutating func runEpoch() -> EpochStats {
        let e = UInt32(epoch)
        BFFRandom.mutate(soup: &soup, seed: config.seed, epoch: e,
                         mutationP32: config.mutationP32)
        let perm = BFFRandom.pairingPermutation(
            count: config.populationSize, seed: config.seed, epoch: e)

        var stats = EpochStats(
            epoch: epoch, interactions: config.populationSize / 2,
            totalSteps: 0, meanSteps: 0,
            haltBudget: 0, haltPCOut: 0, haltUnmatched: 0,
            totalCopyWrites: 0, totalLoopOps: 0, totalRemapEvents: 0)

        for p in 0..<(config.populationSize / 2) {
            let ia = Int(perm[2 * p])
            let ib = Int(perm[2 * p + 1])
            let rangeA = ia * BFF.tapeSize ..< (ia + 1) * BFF.tapeSize
            let rangeB = ib * BFF.tapeSize ..< (ib + 1) * BFF.tapeSize

            let result = BFFInterpreter.run(
                pairTape: Array(soup[rangeA]) + Array(soup[rangeB]),
                variant: config.variant,
                bracketMode: config.bracketMode,
                stepBudget: config.stepBudget)

            // Write both halves back (01 §3 step 3).
            soup.replaceSubrange(rangeA, with: result.tape[0..<BFF.tapeSize])
            soup.replaceSubrange(rangeB, with: result.tape[BFF.tapeSize..<BFF.pairTapeSize])

            stats.totalSteps += result.steps
            switch result.halt {
            case .budget: stats.haltBudget += 1
            case .pcOut: stats.haltPCOut += 1
            case .unmatched: stats.haltUnmatched += 1
            }
            stats.totalCopyWrites += result.copyWrites
            stats.totalLoopOps += result.loopOps
            stats.totalRemapEvents += result.remapEvents
        }

        stats.meanSteps = Double(stats.totalSteps) / Double(stats.interactions)
        epoch += 1
        lastEpochStats = stats
        return stats
    }

    /// Run `count` epochs, returning per-epoch stats.
    @discardableResult
    public mutating func run(epochs count: Int) -> [EpochStats] {
        precondition(count >= 0)
        var all: [EpochStats] = []
        all.reserveCapacity(count)
        for _ in 0..<count { all.append(runEpoch()) }
        return all
    }
}
