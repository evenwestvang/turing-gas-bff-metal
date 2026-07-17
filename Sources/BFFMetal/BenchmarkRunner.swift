import BFFOracle

/// The single, platform-independent epoch loop the benchmark uses. Both the GPU CLI
/// (`bff-metal-bench`) and the tests drive *this* function, so there is exactly one
/// place that decides when signals are measured, how the epoch execution wall is
/// bounded, and how host analysis cost is attributed.
///
/// The platform-specific pieces are injected as closures:
/// - `now` supplies monotonic seconds (a real clock in the CLI; a deterministic
///   synthetic clock in tests);
/// - `gpuSecondsAfterEpoch` reads the evaluator's last command-buffer GPU time
///   (Metal in the CLI; `nil` for the CPU reference);
/// - `measureSignals` computes soup signals — and is invoked ONLY when
///   `options.analyzeSignals` is true. Under `--no-samples` (`analyzeSignals ==
///   false`) it is never called, so no entropy scan, transition scan, or LZ proxy
///   runs and there is no hidden host analysis cost. Tests inject a counting closure
///   to prove exactly that.
public enum BenchmarkRunner {

    /// Controls for sample-only metric analysis. Both flags are off in throughput
    /// mode; `includeCompression` is meaningless (and ignored) when
    /// `analyzeSignals == false`.
    public struct Options: Sendable, Equatable {
        /// Master switch for ALL sample-only metric analysis (entropy scans,
        /// adjacent-transition rate, LZ proxy, kinetics). `false` under `--no-samples`.
        public var analyzeSignals: Bool
        /// Opt-in for the O(n·window) LZ compression proxy. Even when true, the proxy
        /// is only computed on sampled epochs + the final epoch (bounded cost).
        public var includeCompression: Bool

        public init(analyzeSignals: Bool, includeCompression: Bool) {
            self.analyzeSignals = analyzeSignals
            self.includeCompression = includeCompression
        }

        /// Pure throughput: no signal analysis at all.
        public static let throughputOnly = Options(analyzeSignals: false,
                                                   includeCompression: false)
    }

    /// Run one config end to end over an injected evaluator and aggregate the result.
    ///
    /// The epoch execution wall (`EpochObservation.wallSeconds`) strictly encloses
    /// `runEpoch` and nothing else: the `now()` reads that bound it are taken with no
    /// signal analysis in between. Signal analysis, when it runs, is timed with its
    /// own `now()` pair and recorded as `analysisSeconds`, entirely outside the epoch
    /// wall — so raw simulation throughput derives only from epoch execution time.
    public static func run<E: PairEvaluator>(
        config: BenchmarkConfig,
        soupConfig: SoupConfig,
        evaluator: E,
        deviceName: String?,
        options: Options,
        maxRSSBytes: Int?,
        now: () -> Double,
        gpuSecondsAfterEpoch: () -> Double?,
        measureSignals: (_ soup: [UInt8], _ includeCompression: Bool) -> SoupSignals,
        onEpoch: (EpochReport) -> Void = { _ in }
    ) throws -> BenchmarkResult {
        var runner = SoupRunner(config: soupConfig)

        // Initial (epoch-0) reference signals — only when analyzing. Timed as host
        // analysis cost, never mixed into any epoch wall.
        var initialSignals: SoupSignals? = nil
        var initialAnalysisSeconds: Double? = nil
        if options.analyzeSignals {
            let a0 = now()
            initialSignals = measureSignals(runner.soup, options.includeCompression)
            initialAnalysisSeconds = now() - a0
        }

        var observations: [EpochObservation] = []
        observations.reserveCapacity(config.totalEpochs)

        for e in 0..<config.totalEpochs {
            let isWarmup = e < config.warmupEpochs
            let completed = e + 1
            let isSamplePoint = (completed % config.sampleInterval == 0)
                || completed == config.totalEpochs

            // --- Epoch execution wall: runEpoch only ---
            let t0 = now()
            let report = try runner.runEpoch(using: evaluator)
            let wall = now() - t0
            let gpu = gpuSecondsAfterEpoch()

            // --- Sampled signal/metric analysis: outside the epoch wall ---
            var signals: SoupSignals? = nil
            var analysisSeconds: Double? = nil
            if options.analyzeSignals {
                let a0 = now()
                let includeComp = options.includeCompression && isSamplePoint
                signals = measureSignals(runner.soup, includeComp)
                analysisSeconds = now() - a0
            }

            onEpoch(report)

            observations.append(EpochObservation(
                epoch: completed, isWarmup: isWarmup, wallSeconds: wall, gpuSeconds: gpu,
                counters: report.counters, shadowChecked: report.shadowChecked,
                shadowMismatches: report.shadowMismatches.count,
                signals: signals, analysisSeconds: analysisSeconds))
        }

        return BenchmarkAggregator.aggregate(
            config: config, deviceName: deviceName,
            initialSignals: initialSignals, observations: observations,
            finalDigestHex: SoupDigest.hexString(runner.digest),
            maxRSSBytes: maxRSSBytes,
            initialAnalysisSeconds: initialAnalysisSeconds)
    }
}
