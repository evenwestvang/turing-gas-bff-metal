import BFFOracle

/// Anything that can evaluate a batch of 128-byte interaction tapes under one
/// (variant, budget) and return one `GPUPairOutcome` per input, in order.
///
/// The real implementation is `MetalBFFEvaluator` (macOS, GPU). `CPUPairEvaluator`
/// below is the platform-independent scalar reference — it lets the entire epoch
/// orchestration be exercised deterministically on non-Metal hosts *without
/// pretending a GPU ran*: tests inject the CPU evaluator, and the headless runner
/// injects the Metal one. It is the SAME evaluate signature the Metal host already
/// exposes, so `MetalBFFEvaluator` conforms with an empty extension.
public protocol PairEvaluator {
    func evaluate(pairTapes: [[UInt8]], variant: BFFVariant,
                  stepBudget: Int) throws -> [GPUPairOutcome]
}

/// Scalar CPU evaluator built on the existing `BFFInterpreter`. Used both as the
/// non-Metal orchestration reference and, conceptually, as the same routine the
/// CPU shadow uses — so on a non-Metal host a full "epoch" is honestly a CPU
/// computation, never a faked GPU run.
public struct CPUPairEvaluator: PairEvaluator {
    public init() {}

    public func evaluate(pairTapes: [[UInt8]], variant: BFFVariant,
                         stepBudget: Int) -> [GPUPairOutcome] {
        pairTapes.map { tape in
            let r = BFFInterpreter.run(pairTape: tape, variant: variant,
                                       bracketMode: .dynamicScan, stepBudget: stepBudget)
            return GPUPairOutcome(finalTape: r.tape,
                                  steps: UInt32(r.steps), noopSteps: UInt32(r.noopSteps),
                                  copyWrites: UInt32(r.copyWrites), loopOps: UInt32(r.loopOps),
                                  halt: UInt32(r.halt.rawValue))
        }
    }
}

/// Min / mean / max of a metric across the soup, for concise epoch summaries.
public struct MetricSummary: Equatable, Sendable {
    public var min: Double
    public var mean: Double
    public var max: Double

    public init(values: [Double]) {
        guard !values.isEmpty else {
            self.min = 0; self.mean = 0; self.max = 0
            return
        }
        var lo = values[0], hi = values[0], sum = 0.0
        for v in values {
            if v < lo { lo = v }
            if v > hi { hi = v }
            sum += v
        }
        self.min = lo
        self.max = hi
        self.mean = sum / Double(values.count)
    }
}

/// Policy for the sample-only, per-program work `runEpoch` does *after* the soup is
/// committed. It gates ONLY the derived `ProgramMetric` construction (per-program
/// Shannon entropy + activity); it never touches mutation, pairing, evaluation,
/// scatter, counters, the CPU shadow, or the digest, so the soup trajectory and every
/// evaluator output are byte-for-byte identical whether metrics are collected or not.
public struct MetricsPolicy: Sendable, Equatable {
    /// Whether per-program `ProgramMetric` (order-0 entropy + activity) is built.
    public var collectProgramMetrics: Bool
    public init(collectProgramMetrics: Bool) {
        self.collectProgramMetrics = collectProgramMetrics
    }
    /// Default policy — per-program metrics ON. Every existing app/oracle caller uses
    /// this (via the `runEpoch` default), so their behavior is unchanged.
    public static let enabled = MetricsPolicy(collectProgramMetrics: true)
    /// Raw/throughput policy — skip per-program metric construction entirely. The
    /// benchmark uses this: it never consumes `EpochReport.metrics`, and in kinetics
    /// mode per-program entropy is measured externally (`SoupSignals.measure`) outside
    /// the timed epoch, so the in-epoch scan would only duplicate that work.
    public static let disabled = MetricsPolicy(collectProgramMetrics: false)
}

/// Everything one epoch produced: aggregate counters, per-program metrics, the
/// CPU-shadow outcome, and the post-epoch soup digest.
public struct EpochReport: Sendable {
    public var counters: EpochCounters
    /// One `ProgramMetric` per program in stable-ID order. Non-empty for every default
    /// (`.enabled`) run — the app, oracle, and CLI paths all rely on that. It is empty
    /// ONLY under an explicit `MetricsPolicy.disabled` opt-out (the raw benchmark),
    /// where per-program entropy/activity is deliberately not constructed.
    public var metrics: [ProgramMetric]
    /// Number of pairs actually shadow-checked this epoch.
    public var shadowChecked: Int
    /// Divergences found (empty means the sampled pairs matched the CPU exactly).
    public var shadowMismatches: [ShadowMismatch]
    /// FNV-1a digest of the soup after this epoch's scatter.
    public var digest: UInt64

    public var activitySummary: MetricSummary {
        MetricSummary(values: metrics.map { Double($0.activity) })
    }
    public var entropySummary: MetricSummary {
        MetricSummary(values: metrics.map { $0.entropyBitsPerByte })
    }
}

/// Deterministic small-soup GPU (or CPU-reference) evolution.
///
/// Value semantics like `BFFOracle.Simulation`: copying forks the run; state is
/// fully captured by `(config, soup, epoch)`. The orchestration is
/// platform-independent and generic over `PairEvaluator`; only the concrete
/// evaluator the caller injects decides whether an epoch runs on the GPU.
public struct SoupRunner: Sendable {
    public enum RunError: Error, CustomStringConvertible {
        case evaluatorReturnedWrongCount(expected: Int, got: Int)
        public var description: String {
            switch self {
            case .evaluatorReturnedWrongCount(let expected, let got):
                return "evaluator returned \(got) outcomes, expected \(expected)"
            }
        }
    }

    public let config: SoupConfig
    /// `programCount * 64` bytes; program `i` at `i*64 ..< (i+1)*64`.
    public private(set) var soup: [UInt8]
    /// Next epoch to run (also the number of epochs completed).
    public private(set) var epoch: Int
    /// Invocation seam: how many epochs actually built per-program metrics. Lets tests
    /// PROVE metric construction is skipped under `MetricsPolicy.disabled` (rather than
    /// merely observe an empty `metrics` array). Purely diagnostic — it never affects
    /// the soup, the RNG, the counters, or the digest.
    public private(set) var programMetricBuildCount: Int = 0

    public init(config: SoupConfig) {
        self.config = config
        // `.uniform` is the existing default path, byte-for-byte; the low-entropy
        // modes are additive and only chosen when explicitly configured.
        switch config.initMode {
        case .uniform:
            self.soup = BFFRandom.initialSoup(programs: config.programCount, seed: config.seed)
        case .constant:
            self.soup = BFFRandom.constantSoup(programs: config.programCount)
        case .opcode:
            self.soup = BFFRandom.opcodeSoup(programs: config.programCount, seed: config.seed)
        }
        self.epoch = 0
    }

    /// The 64-byte program at index `i` (a copy).
    public func program(at i: Int) -> [UInt8] {
        precondition(i >= 0 && i < config.programCount)
        return Array(soup[i * BFF.tapeSize ..< (i + 1) * BFF.tapeSize])
    }

    /// Digest of the current soup.
    public var digest: UInt64 { SoupDigest.digest(soup) }

    /// Run one epoch end-to-end: mutate → pair → pack → evaluate → scatter →
    /// reduce → metrics → shadow. The soup and epoch counter are committed only
    /// after a successful evaluate + scatter, so a thrown evaluator error leaves
    /// the run untouched.
    ///
    /// `metrics` gates ONLY the derived per-program `ProgramMetric` construction. It
    /// defaults to `.enabled` so every existing caller (app, oracle, CLI) is
    /// unchanged. Passing `.disabled` (the raw benchmark) skips the per-program
    /// entropy/activity scan entirely — everything else (mutation, pairing, evaluate,
    /// scatter, counters, the configured CPU shadow, and the post-epoch digest) runs
    /// exactly as before, so the committed soup and every counter/digest are identical.
    @discardableResult
    public mutating func runEpoch<E: PairEvaluator>(
        using evaluator: E,
        metrics policy: MetricsPolicy = .enabled
    ) throws -> EpochReport {
        let (mutated, plan) = SoupPlanner.plan(soup: soup, config: config, epoch: epoch)

        let outcomes = try evaluator.evaluate(pairTapes: plan.inputTapes,
                                              variant: config.variant,
                                              stepBudget: config.stepBudget)
        guard outcomes.count == plan.pairs.count else {
            throw RunError.evaluatorReturnedWrongCount(expected: plan.pairs.count,
                                                       got: outcomes.count)
        }

        var newSoup = mutated
        SoupPlanner.scatter(into: &newSoup, plan: plan,
                            finalTapes: outcomes.map(\.finalTape))

        let counters = EpochCounters.reduce(epoch: epoch,
                                            mutationCount: plan.mutationCount,
                                            outcomes: outcomes)
        // Per-program metrics are the only work gated by policy. Under `.disabled` the
        // scan (and its O(programCount) entropy computation) is not performed at all;
        // the report simply carries no per-program metrics. Nothing below depends on it.
        let metrics: [ProgramMetric]
        if policy.collectProgramMetrics {
            metrics = SoupMetrics.programMetrics(soup: newSoup, plan: plan,
                                                 outcomes: outcomes,
                                                 programCount: config.programCount)
            programMetricBuildCount += 1
        } else {
            metrics = []
        }

        // CPU shadow: read-only, never perturbs the soup or its RNG.
        let sample = ShadowSampler.sampleIndices(pairCount: config.pairCount,
                                                 sampleCount: config.shadowSampleCount,
                                                 seed: config.seed, epoch: epoch)
        var mismatches: [ShadowMismatch] = []
        for idx in sample {
            let pair = plan.pairs[idx]
            if let mm = ShadowComparator.check(epoch: epoch, pairIndex: idx,
                                               programA: pair.a, programB: pair.b,
                                               input: plan.inputTapes[idx],
                                               variant: config.variant,
                                               stepBudget: config.stepBudget,
                                               gpu: outcomes[idx]) {
                mismatches.append(mm)
            }
        }

        // Commit only now.
        soup = newSoup
        epoch += 1

        return EpochReport(counters: counters, metrics: metrics,
                           shadowChecked: sample.count, shadowMismatches: mismatches,
                           digest: SoupDigest.digest(newSoup))
    }

    /// Run `count` epochs, returning each epoch's report in order.
    @discardableResult
    public mutating func run<E: PairEvaluator>(epochs count: Int,
                                               using evaluator: E) throws -> [EpochReport] {
        precondition(count >= 0)
        var reports: [EpochReport] = []
        reports.reserveCapacity(count)
        for _ in 0 ..< count { reports.append(try runEpoch(using: evaluator)) }
        return reports
    }
}
