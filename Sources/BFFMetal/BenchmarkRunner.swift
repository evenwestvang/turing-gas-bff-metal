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
/// - `measureBrotliBitsPerByte` (optional) supplies the paper-aligned Brotli 1.1.0
///   q2 bits/byte for a soup. Injected only by `bff-metal-bench` (wired to
///   `BrotliMetrics`), so BFFMetal itself never links Brotli; the CPU reference and
///   the tests pass `nil` or a synthetic closure. It is invoked ONLY when
///   `options.includeBrotli` is set and the epoch is on the LZ-proxy cadence
///   (sample ∩ signal point), always outside the epoch execution wall.
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
        /// Opt-in for the paper-aligned Brotli 1.1.0 q2 measurement (`--brotli`).
        /// DISTINCT from `includeCompression` (the LZ proxy). When true, the injected
        /// `measureBrotliBitsPerByte` closure is called on exactly the same bounded
        /// cadence as the LZ proxy — sampled epochs + the final epoch, and only when
        /// the epoch also carries a signal measurement — so the real codec runs only
        /// at the reviewed sparse cadence, never every epoch and never inside the
        /// epoch execution wall. `nil` from the closure (e.g. non-1.1.0 encoder) is
        /// carried through as "not computed".
        public var includeBrotli: Bool
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
        /// Opt-in host-stage timing attribution. When `true`, each epoch's `runEpoch` is
        /// timed with the same monotonic clock at stage boundaries, producing a
        /// `HostStageAttribution` in the result. Off by default and fully orthogonal to
        /// signal analysis: it never changes the soup, RNG, counters, digest, shadow, or
        /// the reported throughput/kinetics. The extra work is a handful of clock reads
        /// per epoch (bounded and cheap). When `false` the runner passes no stage clock,
        /// so `runEpoch` runs exactly as it does for the app/oracle and
        /// `hostStageAttribution` is `null`.
        public var instrumentStages: Bool

        public init(analyzeSignals: Bool, includeCompression: Bool,
                    signalInterval: Int = 1, includeBrotli: Bool = false,
                    instrumentStages: Bool = false) {
            self.analyzeSignals = analyzeSignals
            self.includeCompression = includeCompression
            self.signalInterval = Swift.max(1, signalInterval)
            self.includeBrotli = includeBrotli
            self.instrumentStages = instrumentStages
        }

        /// Pure throughput: no signal analysis at all (and no stage instrumentation).
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
        // `@escaping` because, under `--host-stage-timing`, the same clock is handed to
        // `runEpoch` as the (escaping, optional) stage clock. It is still invoked
        // synchronously within `run`; nothing retains it past this call.
        now: @escaping () -> Double,
        gpuSecondsAfterEpoch: () -> Double?,
        measureSignals: (_ soup: [UInt8], _ includeCompression: Bool) -> SoupSignals,
        measureBrotliBitsPerByte: ((_ soup: [UInt8]) -> Double?)? = nil,
        onEpoch: (EpochReport) -> Void = { _ in }
    ) throws -> BenchmarkResult {
        // Enforce the signal-cadence contract at the very top — before any RSS reading,
        // `SoupRunner` allocation, epoch execution, or signal measurement — so a sparse
        // `--signal-interval` combined with ΔH thresholds can never even begin a run that
        // would report threshold epochs off a trajectory it never measured. The CLI also
        // validates this, but the guard lives here too so any caller of the public runner
        // (not just `bff-metal-bench`) is held to the same contract. Skipped when
        // `analyzeSignals == false` (`--no-samples`): no trajectory is measured then, so
        // the signal knobs are inert and thresholds are simply ignored, exactly as under
        // the throughput-only path.
        if options.analyzeSignals {
            try validateSignalCadence(signalInterval: options.signalInterval,
                                      deltaHThresholdCount: config.deltaHThresholds.count)
        }

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
        // Fold a Brotli bits/byte reading into an already-measured `SoupSignals`
        // (epoch is a sample point). Both the entropy scan (`measureSignals`) and this
        // are timed inside the same analysis window, entirely outside the epoch wall.
        func withBrotli(_ signals: SoupSignals, soup: [UInt8]) -> SoupSignals {
            guard options.includeBrotli, let bpb = measureBrotliBitsPerByte?(soup) else {
                return signals
            }
            var s = signals
            s.brotliBitsPerByte = bpb
            s.highOrderComplexity = s.entropyBitsPerByte - bpb
            return s
        }

        var initialSignals: SoupSignals? = nil
        var initialAnalysisSeconds: Double? = nil
        if options.analyzeSignals {
            let a0 = now()
            initialSignals = withBrotli(measureSignals(runner.soup, options.includeCompression),
                                        soup: runner.soup)
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
            // Per-program metrics default to disabled here: the benchmark never
            // consumes `EpochReport.metrics`, and in kinetics mode per-program entropy
            // is measured externally (below) *outside* this wall. So by default the timed
            // epoch carries mutation → pairing → packing → GPU dispatch/wait/readback →
            // scatter → counters → digest → configured shadow, and NOT the per-program
            // entropy/activity scan. (The FNV-1a digest is the one unavoidable O(N)
            // timed pass; the counters are O(pairs).)
            //
            // `config.timedProgramMetrics` is the explicit opt-in that flips the in-epoch
            // metrics policy to `.enabled` so the per-program `ProgramMetric` scan runs
            // *inside* this wall — making `hostStageAttribution.programMetricsMsPerEpoch`
            // (under `--host-stage-timing`) measure the real per-program metric scan
            // instead of the ~0 it sees under the default `.disabled`. It is DISTINCT
            // from `--no-samples` (external `SoupSignals.measure`) and from
            // `--signal-interval` (the signal-measurement cadence): it gates ONLY the
            // in-epoch `ProgramMetric` construction, which is a pure side computation —
            // the soup, RNG, counters, shadow, digest, and trajectory are byte-for-byte
            // identical whether it runs or not (pinned by test).
            // Pass the SAME monotonic clock as the stage clock when instrumentation is
            // on, so the stage-boundary reads and the enclosing wall come from one clock
            // and reconcile exactly. When off, no stage clock is passed and `runEpoch`
            // is byte-for-byte the uninstrumented call — proven equivalent by test.
            let stageClock: (() -> Double)? = options.instrumentStages ? now : nil
            let metricsPolicy: MetricsPolicy = config.timedProgramMetrics ? .enabled : .disabled
            let t0 = now()
            let report = try runner.runEpoch(using: evaluator, metrics: metricsPolicy,
                                             stageClock: stageClock)
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
                var s = measureSignals(runner.soup, includeComp)
                // The paper Brotli metric follows the LZ proxy's cadence exactly:
                // only where a measured signal epoch and an emission point coincide,
                // so it never runs more often than the LZ proxy would.
                if isSamplePoint { s = withBrotli(s, soup: runner.soup) }
                signals = s
                analysisSeconds = now() - a0
            }

            onEpoch(report)

            observations.append(EpochObservation(
                epoch: completed, isWarmup: isWarmup, wallSeconds: wall, gpuSeconds: gpu,
                counters: report.counters, shadowChecked: report.shadowChecked,
                shadowMismatches: report.shadowMismatches.count,
                signals: signals, analysisSeconds: analysisSeconds,
                hostStageSpans: report.stageBreakdown))
        }

        rss.sample(readMaxRSSBytes())                       // post-cell

        return BenchmarkAggregator.aggregate(
            config: config, deviceName: deviceName,
            initialSignals: initialSignals, observations: observations,
            finalDigestHex: SoupDigest.hexString(runner.digest),
            maxRSSBytes: rss.peakBytes,
            initialAnalysisSeconds: initialAnalysisSeconds,
            instrumentationEnabled: options.instrumentStages)
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
