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
///   `options.analyzeSignals` is true AND the epoch is on the signal-measurement
///   cadence (`options.signalInterval`). Under `--no-samples` (`analyzeSignals ==
///   false`) it is never called, so no entropy scan, transition scan, or LZ proxy
///   runs and there is no hidden host analysis cost. Under a sparse
///   `signalInterval > 1` it is called only at epoch 0, every `N`th completed epoch,
///   and the final completed epoch — never on the intervening epochs. Tests inject a
///   counting closure to prove exactly that cadence.
public enum BenchmarkRunner {

    /// Controls for sample-only metric analysis. Both flags are off in throughput
    /// mode; `includeCompression` and `signalInterval` are meaningless (and ignored)
    /// when `analyzeSignals == false`.
    public struct Options: Sendable, Equatable {
        /// Master switch for ALL sample-only metric analysis (entropy scans,
        /// adjacent-transition rate, LZ proxy, kinetics). `false` under `--no-samples`.
        public var analyzeSignals: Bool
        /// Opt-in for the O(n·window) LZ compression proxy. Even when true, the proxy
        /// is only computed on sampled epochs + the final epoch (bounded cost).
        public var includeCompression: Bool
        /// Signal-measurement cadence. `1` (the default) measures signals every epoch —
        /// the exact per-epoch entropy trajectory that ΔH thresholds require. `N > 1`
        /// is cadence-only / sparse analysis: signals are measured at epoch 0 (the
        /// pre-run reference, always), at every `N`th completed epoch, and at the final
        /// completed epoch (even when it is not divisible by `N`), and *nowhere else*.
        /// It is a pure measurement gate: skipping a measurement never touches the
        /// evaluator, the RNG, the soup, the counters, or the digest — only whether
        /// that epoch carries a `SoupSignals` reading. Clamped to `>= 1`. Ignored when
        /// `analyzeSignals == false`.
        public var signalInterval: Int

        public init(analyzeSignals: Bool, includeCompression: Bool,
                    signalInterval: Int = 1) {
            self.analyzeSignals = analyzeSignals
            self.includeCompression = includeCompression
            self.signalInterval = Swift.max(1, signalInterval)
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
        readMaxRSSBytes: () -> Int?,
        now: () -> Double,
        gpuSecondsAfterEpoch: () -> Double?,
        measureSignals: (_ soup: [UInt8], _ includeCompression: Bool) -> SoupSignals,
        onEpoch: (EpochReport) -> Void = { _ in }
    ) throws -> BenchmarkResult {
        // Process peak (high-water) RSS is sampled at three points and reduced to the
        // maximum available reading: pre-cell (before any allocation for this cell),
        // post-allocation (right after the SoupRunner is constructed), and post-cell
        // (after the measured epochs). The value is the process high-water mark, so it
        // is cumulative for the whole run/matrix — never cell-exclusive.
        var rss = PeakRSSSampler()
        rss.sample(readMaxRSSBytes())                       // pre-cell

        var runner = SoupRunner(config: soupConfig)
        rss.sample(readMaxRSSBytes())                       // post-allocation

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
            // JSON emission cadence (`--sample-interval`): which measured epochs the
            // aggregator emits as `EpochSample`s, and — for compression — which epochs
            // may carry the O(n·window) LZ proxy. Unchanged by sparse analysis.
            let isSamplePoint = (completed % config.sampleInterval == 0)
                || completed == config.totalEpochs
            // Signal-measurement cadence (`--signal-interval`): whether signals are
            // measured *at all* this epoch. `1` (default) => every epoch. `N > 1` =>
            // only every `N`th completed epoch plus the final epoch (epoch 0's
            // reference is measured before the loop). This gates measurement only; it
            // never affects the epoch execution below.
            let isSignalPoint = (completed % options.signalInterval == 0)
                || completed == config.totalEpochs

            // --- Epoch execution wall: runEpoch only ---
            // Per-program metrics are always disabled here: the benchmark never
            // consumes `EpochReport.metrics`, and in kinetics mode per-program entropy
            // is measured externally (below) *outside* this wall. So the timed epoch
            // carries mutation → pairing → packing → GPU dispatch/wait/readback →
            // scatter → counters → digest → configured shadow, and NOT the per-program
            // entropy/activity scan. (The FNV-1a digest is the one unavoidable O(N)
            // timed pass; the counters are O(pairs).)
            let t0 = now()
            let report = try runner.runEpoch(using: evaluator, metrics: .disabled)
            let wall = now() - t0
            let gpu = gpuSecondsAfterEpoch()

            // --- Sampled signal/metric analysis: outside the epoch wall ---
            // Measured only on the signal cadence. The LZ proxy stays bounded to the
            // *emission* cadence (`isSamplePoint`) exactly as documented, so under a
            // sparse signal interval it runs only where a measurement AND a sample
            // point coincide — never more often than dense analysis would (the final
            // epoch, always both, still carries it when `--compression` is on).
            var signals: SoupSignals? = nil
            var analysisSeconds: Double? = nil
            if options.analyzeSignals && isSignalPoint {
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

        rss.sample(readMaxRSSBytes())                       // post-cell

        return BenchmarkAggregator.aggregate(
            config: config, deviceName: deviceName,
            initialSignals: initialSignals, observations: observations,
            finalDigestHex: SoupDigest.hexString(runner.digest),
            maxRSSBytes: rss.peakBytes,
            initialAnalysisSeconds: initialAnalysisSeconds)
    }
}

/// Accumulates process high-water RSS readings taken at several points during a
/// benchmark cell and reports the maximum *available* one.
///
/// The underlying reading (`getrusage(RUSAGE_SELF).ru_maxrss`, unit-normalized by the
/// caller) is already the process **high-water / peak** RSS — cumulative for the whole
/// process (and therefore the whole matrix as cells run in sequence), NOT a
/// cell-exclusive delta and NOT current resident memory. Because the OS mark is
/// monotonic, sampling it at several points and keeping the maximum is exactly the
/// peak; folding the samples also makes the report robust to any single reading being
/// momentarily unavailable: a `nil` sample is ignored, and `peakBytes` is `nil` only
/// when *every* sample was unavailable.
public struct PeakRSSSampler: Sendable, Equatable {
    /// Maximum available reading in bytes so far, or `nil` if none was available.
    public private(set) var peakBytes: Int?

    public init() { self.peakBytes = nil }
    /// Seed with a known value (used by tests).
    public init(peakBytes: Int?) { self.peakBytes = peakBytes }

    /// Fold one high-water reading (bytes; `nil` = unavailable at this point) into the
    /// running maximum. Unavailable readings never lower the peak.
    public mutating func sample(_ reading: Int?) {
        guard let reading else { return }
        peakBytes = Swift.max(peakBytes ?? reading, reading)
    }
}
