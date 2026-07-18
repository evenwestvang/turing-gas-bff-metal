import BFFOracle

/// Platform-independent benchmark harness core: configuration, per-epoch
/// observations, entropy/structure signal measurement, ΔH threshold tracking, and
/// the aggregation into a machine-readable `BenchmarkResult`.
///
/// Everything here is pure and testable on any platform — no Metal, no wall clock,
/// no RNG of its own. The GPU-bound CLI (`bff-metal-bench`) supplies the actual
/// timings and the real evaluator; this file decides what those numbers *mean*. The
/// split is deliberate: timing/attribution math and threshold logic are unit-tested
/// here on synthetic inputs, so the only thing that needs a Metal device is the
/// device itself.

// MARK: - Signals

/// The entropy and structure signals of a soup at one instant. Order-0 entropy is
/// order-blind; the structure metrics are not, so together they separate noise from
/// repeated structure (see `StructureMetrics`). All are computed with the existing
/// `ByteHistogram` / `StructureMetrics` definitions — nothing new is claimed.
public struct SoupSignals: Equatable, Sendable {
    /// Whole-soup order-0 Shannon entropy, bits/byte in `[0, 8]` (`ByteHistogram`).
    /// This is the H whose change (ΔH) the thresholds track.
    public var entropyBitsPerByte: Double
    /// Mean over programs of each 64-byte program's order-0 entropy, bits/byte in
    /// `[0, 6]` — the same per-program metric `SoupMetrics`/`ProgramMetric` report.
    public var meanProgramEntropyBitsPerByte: Double
    /// Adjacent-byte transition rate over the whole soup, `[0, 1]`.
    public var transitionRate: Double
    /// Finite-window LZ77 compression proxy over the whole soup, `(0, 1]`. Optional
    /// and OPT-IN: it is the one O(n·window) signal, so the CLI computes it only when
    /// `--compression` is given, and even then only on sampled epochs and the final
    /// epoch — never every epoch — so its cost stays bounded at 131072 programs.
    /// `nil` means "not computed", not "incompressible".
    public var compressionProxyRatio: Double?
    /// Paper-aligned Brotli 1.1.0 quality-2 compressed **bits per byte** of the
    /// whole soup (cubff's `brotli_bpb`). OPT-IN (`--brotli`) and, like the LZ
    /// proxy, computed only on the sample cadence — never every epoch — and only
    /// when the linked Brotli is exactly 1.1.0 (else `nil`, honest "not computed").
    /// This is the real codec number, distinct from `compressionProxyRatio`.
    public var brotliBitsPerByte: Double?
    /// Paper high-order complexity `H0 − brotli_bpb` (cubff's `higher_entropy`),
    /// `entropyBitsPerByte − brotliBitsPerByte`. `nil` exactly when
    /// `brotliBitsPerByte` is. The paper's regime of interest is `>= 1`.
    public var highOrderComplexity: Double?

    public init(entropyBitsPerByte: Double, meanProgramEntropyBitsPerByte: Double,
                transitionRate: Double, compressionProxyRatio: Double?,
                brotliBitsPerByte: Double? = nil, highOrderComplexity: Double? = nil) {
        self.entropyBitsPerByte = entropyBitsPerByte
        self.meanProgramEntropyBitsPerByte = meanProgramEntropyBitsPerByte
        self.transitionRate = transitionRate
        self.compressionProxyRatio = compressionProxyRatio
        self.brotliBitsPerByte = brotliBitsPerByte
        self.highOrderComplexity = highOrderComplexity
    }

    /// Measure a soup. `includeCompression` gates the expensive O(n·window) proxy so
    /// callers can compute the cheap signals (entropy, transition rate) on their own
    /// cadence and the proxy only when explicitly opted in and only on a sampling
    /// cadence. This whole call is skipped entirely under `--no-samples` — the CLI
    /// never invokes it, so no entropy scan, transition scan, or LZ proxy runs.
    public static func measure(soup: [UInt8], programCount: Int,
                               tapeSize: Int = BFF.tapeSize,
                               includeCompression: Bool) -> SoupSignals {
        let soupH = ByteHistogram(bytes: soup).shannonEntropyBitsPerByte

        var perProgramSum = 0.0
        if programCount > 0 {
            for id in 0..<programCount {
                let start = id * tapeSize
                let end = start + tapeSize
                perProgramSum += ByteHistogram(bytes: soup[start..<end]).shannonEntropyBitsPerByte
            }
        }
        let meanProgramH = programCount > 0 ? perProgramSum / Double(programCount) : 0

        return SoupSignals(
            entropyBitsPerByte: soupH,
            meanProgramEntropyBitsPerByte: meanProgramH,
            transitionRate: StructureMetrics.transitionRate(soup),
            compressionProxyRatio: includeCompression
                ? StructureMetrics.compressionProxyRatio(soup) : nil)
    }
}

// MARK: - Configuration

/// One cell of a benchmark matrix. The benchmark CLI expands comma-separated CLI
/// values into the cartesian product of these; app defaults are never touched.
public struct BenchmarkConfig: Equatable, Sendable, Codable {
    public var seed: UInt32
    public var programCount: Int
    public var stepBudget: Int
    public var mutationP32: UInt32
    public var variant: BFFVariant
    public var initMode: SoupConfig.InitMode
    /// Pairs CPU-shadowed per epoch (correctness spot check). 0 = throughput mode.
    public var shadowSampleCount: Int
    /// Epochs run and discarded before measurement (allocation/first-dispatch warmup).
    public var warmupEpochs: Int
    /// Epochs whose timing/throughput are aggregated.
    public var measuredEpochs: Int
    /// ΔH (whole-soup, from the initial soup) levels to record time/epochs-to-cross.
    public var deltaHThresholds: [Double]
    /// Paper high-order-complexity (`H0 − brotli_bpb`) levels to record the first
    /// epoch/time reaching them. Only meaningful with `--brotli`; the crossing epoch
    /// is resolved to the Brotli **measurement cadence** (see the note on the
    /// aggregator), not necessarily the exact epoch. Empty by default.
    public var highOrderComplexityThresholds: [Double]
    /// Emit a per-epoch kinetics sample (and the expensive compression proxy) every
    /// `sampleInterval` epochs. `>= 1`; large values bound output at large soups.
    public var sampleInterval: Int
    /// Opt-in: run the timed epoch's per-program `ProgramMetric` construction
    /// (`MetricsPolicy.enabled`) so `hostStageAttribution.programMetricsMsPerEpoch`
    /// measures the real per-program metric scan. Default `false` — the benchmark
    /// passes `MetricsPolicy.disabled` so the epoch wall carries no per-program
    /// entropy/activity scan (it never consumes `EpochReport.metrics`; in kinetics
    /// mode per-program entropy is measured externally via `SoupSignals.measure`,
    /// outside the epoch wall). DISTINCT from `--no-samples` (which gates the
    /// external `SoupSignals.measure` analysis) and from `--signal-interval` (which
    /// gates the signal-measurement cadence): this knob gates ONLY the in-epoch
    /// `ProgramMetric` construction. Enabling changes nothing else — the soup, RNG,
    /// digest, counters, shadow, and trajectory are byte-for-byte identical (pinned
    /// by test). Most useful with `--host-stage-timing` so the scan is attributed to
    /// `programMetricsMsPerEpoch`; without it the scan runs but is folded into the
    /// unclassified epoch-wall remainder. New in schema 4.
    public var timedProgramMetrics: Bool

    public init(seed: UInt32, programCount: Int,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                initMode: SoupConfig.InitMode = .uniform,
                shadowSampleCount: Int = 0,
                warmupEpochs: Int = 1,
                measuredEpochs: Int = 8,
                deltaHThresholds: [Double] = [],
                highOrderComplexityThresholds: [Double] = [],
                sampleInterval: Int = 1,
                timedProgramMetrics: Bool = false) {
        self.seed = seed
        self.programCount = programCount
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.initMode = initMode
        self.shadowSampleCount = shadowSampleCount
        self.warmupEpochs = warmupEpochs
        self.measuredEpochs = measuredEpochs
        self.deltaHThresholds = deltaHThresholds
        self.highOrderComplexityThresholds = highOrderComplexityThresholds
        self.sampleInterval = max(1, sampleInterval)
        self.timedProgramMetrics = timedProgramMetrics
    }

    /// Total epochs the run executes (warmup + measured).
    public var totalEpochs: Int { warmupEpochs + measuredEpochs }

    /// Validated soup configuration for this cell (reuses `SoupConfig`'s bounds).
    public func soupConfig() throws -> SoupConfig {
        try SoupConfig(seed: seed, programCount: programCount, stepBudget: stepBudget,
                       mutationP32: mutationP32, variant: variant,
                       shadowSampleCount: shadowSampleCount, initMode: initMode)
    }

    /// Backward-compatible decode: schema-2 JSON lacks `highOrderComplexityThresholds`
    /// (added in schema 3). Default it to `[]` so a schema-2-shaped config decodes
    /// without changing any existing field's meaning. `deltaHThresholds` is treated
    /// the same way for robustness (it is a schema-2 key but may be absent in
    /// trimmed snapshots). Existing scalar keys are decoded strictly — no silent
    /// remapping of old field meanings. Schema 4 adds `timedProgramMetrics`
    /// (default `false` when absent), so schema-2/3 and either schema-3 branch
    /// decode losslessly with the in-epoch metrics scan staying off (the default).
    enum CodingKeys: String, CodingKey {
        case seed, programCount, stepBudget, mutationP32, variant, initMode,
             shadowSampleCount, warmupEpochs, measuredEpochs, deltaHThresholds,
             highOrderComplexityThresholds, sampleInterval, timedProgramMetrics
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seed = try c.decode(UInt32.self, forKey: .seed)
        programCount = try c.decode(Int.self, forKey: .programCount)
        stepBudget = try c.decode(Int.self, forKey: .stepBudget)
        mutationP32 = try c.decode(UInt32.self, forKey: .mutationP32)
        variant = try c.decode(BFFVariant.self, forKey: .variant)
        initMode = try c.decode(SoupConfig.InitMode.self, forKey: .initMode)
        shadowSampleCount = try c.decode(Int.self, forKey: .shadowSampleCount)
        warmupEpochs = try c.decode(Int.self, forKey: .warmupEpochs)
        measuredEpochs = try c.decode(Int.self, forKey: .measuredEpochs)
        deltaHThresholds = try c.decodeIfPresent([Double].self, forKey: .deltaHThresholds) ?? []
        highOrderComplexityThresholds =
            try c.decodeIfPresent([Double].self, forKey: .highOrderComplexityThresholds) ?? []
        sampleInterval = try c.decodeIfPresent(Int.self, forKey: .sampleInterval) ?? 1
        timedProgramMetrics = try c.decodeIfPresent(Bool.self, forKey: .timedProgramMetrics) ?? false
    }
}

// MARK: - Per-epoch observation

/// Everything measured for one executed epoch.
///
/// - `wallSeconds` is the **epoch execution wall**: the monotonic interval that
///   strictly encloses `runEpoch` (mutation, pairing, packing, GPU dispatch + wait,
///   scatter, counters/program-metrics reduction, and the CPU shadow if enabled) and
///   *nothing else*. Sampled signal analysis is timed separately in `analysisSeconds`.
/// - `gpuSeconds` is `nil` when the hardware reported no usable command-buffer
///   timestamp; the aggregator then marks GPU timing unavailable rather than
///   inventing a number.
/// - `signals` is `nil` when no signal reading was taken for this epoch: either
///   sample-only metric analysis was skipped entirely (`--no-samples`), or a sparse
///   `--signal-interval N` did not place a measurement on this epoch. The aggregator
///   folds only the epochs that *do* carry signals into the kinetics/samples and
///   reports "not computed" (rather than faking a zero) when none were taken.
/// - `analysisSeconds` is the host wall spent computing `signals` for this epoch,
///   measured *outside* `wallSeconds`; `nil` when no analysis ran (skipped or off-cadence),
///   so `signalAnalysisMsTotal` sums only measurements actually performed.
public struct EpochObservation: Sendable {
    public var epoch: Int
    public var isWarmup: Bool
    public var wallSeconds: Double
    public var gpuSeconds: Double?
    public var counters: EpochCounters
    public var shadowChecked: Int
    public var shadowMismatches: Int
    public var signals: SoupSignals?
    /// Host wall spent on sampled signal/metric analysis for this epoch, measured
    /// outside the epoch execution wall. `nil` under `--no-samples` (not computed).
    public var analysisSeconds: Double?
    /// Opt-in host-stage breakdown for this epoch's `runEpoch`, present only when the
    /// run enabled stage instrumentation; `nil` otherwise. Its spans are all measured
    /// *inside* `wallSeconds`, so `wallSeconds − stageBreakdown.classifiedSeconds` is the
    /// per-epoch unclassified remainder the aggregator reconciles.
    public var hostStageSpans: HostStageSpans?

    public init(epoch: Int, isWarmup: Bool, wallSeconds: Double, gpuSeconds: Double?,
                counters: EpochCounters, shadowChecked: Int, shadowMismatches: Int,
                signals: SoupSignals?, analysisSeconds: Double? = nil,
                hostStageSpans: HostStageSpans? = nil) {
        self.epoch = epoch
        self.isWarmup = isWarmup
        self.wallSeconds = wallSeconds
        self.gpuSeconds = gpuSeconds
        self.counters = counters
        self.shadowChecked = shadowChecked
        self.shadowMismatches = shadowMismatches
        self.signals = signals
        self.analysisSeconds = analysisSeconds
        self.hostStageSpans = hostStageSpans
    }
}

// MARK: - Threshold tracking

/// First-crossing record for one ΔH threshold.
public struct ThresholdCrossing: Equatable, Sendable, Codable {
    /// The threshold in bits/byte of ΔH (whole-soup H minus initial H).
    public var deltaH: Double
    public var crossed: Bool
    /// Epoch index (from the initial soup, warmup included) that first reached it.
    /// This is the deterministic scientific figure.
    public var epoch: Int?
    /// Cumulative wall ms from run start to that epoch (includes warmup timing).
    public var wallMsToCross: Double?
    /// Cumulative GPU command-buffer ms to that epoch, or `nil` if any epoch up to
    /// the crossing lacked a usable GPU timestamp.
    public var gpuMsToCross: Double?
}

/// Records the first epoch at which cumulative ΔH reaches each threshold. Pure and
/// order-following: feed it one `observe(...)` per epoch in epoch order.
public struct ThresholdTracker {
    private let thresholds: [Double]
    private var recorded: [ThresholdCrossing]

    public init(thresholds: [Double]) {
        self.thresholds = thresholds
        self.recorded = thresholds.map {
            ThresholdCrossing(deltaH: $0, crossed: false, epoch: nil,
                              wallMsToCross: nil, gpuMsToCross: nil)
        }
    }

    /// Observe one epoch. `deltaH` is H(epoch) − H(initial); cumulative timings are
    /// from run start. A threshold is crossed the first epoch `deltaH >= threshold`.
    public mutating func observe(epoch: Int, deltaH: Double,
                                 cumulativeWallMs: Double, cumulativeGpuMs: Double?) {
        for i in recorded.indices where !recorded[i].crossed
            && deltaH >= recorded[i].deltaH {
            recorded[i].crossed = true
            recorded[i].epoch = epoch
            recorded[i].wallMsToCross = cumulativeWallMs
            recorded[i].gpuMsToCross = cumulativeGpuMs
        }
    }

    public var crossings: [ThresholdCrossing] { recorded }
}

/// First-crossing record for one paper high-order-complexity (`H0 − brotli_bpb`)
/// threshold. Parallel to `ThresholdCrossing` but tracks the *absolute* complexity,
/// not a delta, and its epoch is resolved only to the Brotli measurement cadence.
///
/// Because Brotli is measured sparsely (on the sample∩signal cadence, plus epoch 0
/// and the final epoch), the true crossing epoch cannot be implied to be exact.
/// Instead the observation interval is encoded explicitly: the true crossing lies
/// in the half-open interval `(previousMeasuredEpoch, observedEpoch]`. At
/// measurement cadence 1 (every epoch measured) this interval is a single epoch
/// and `crossingEpochCensoring` is `"exact"`; at a sparse cadence the interval may
/// span several epochs and `crossingEpochCensoring` is `"interval"`.
public struct HighOrderComplexityCrossing: Equatable, Sendable, Codable {
    /// The threshold in bits/byte of high-order complexity. The paper's regime is `1`.
    public var complexity: Double
    public var crossed: Bool
    /// The first Brotli-measured epoch at which complexity reached the threshold.
    /// `nil` when `crossed` is false. The true crossing epoch lies in the
    /// half-open interval `(previousMeasuredEpoch, observedEpoch]`.
    public var observedEpoch: Int?
    /// The Brotli-measured epoch immediately preceding `observedEpoch`, or `nil`
    /// when the crossing was first observed at the initial (epoch-0) measurement
    /// (the true crossing is then at or before epoch 0). When `crossed` is false
    /// this holds the last Brotli-measured epoch of the run — the right endpoint
    /// of the observation window over which the threshold was not reached. `nil`
    /// when no Brotli measurement was taken at all.
    public var previousMeasuredEpoch: Int?
    /// How the true crossing epoch is bounded — a clear, machine-readable censoring
    /// representation:
    /// - `"exact"`: every epoch in `(previousMeasuredEpoch, observedEpoch]` was
    ///   measured, so `observedEpoch` is the exact crossing epoch. Always the case
    ///   at measurement cadence 1, and when the crossing is first observed at
    ///   epoch 0 (the initial reading).
    /// - `"interval"`: Brotli was measured sparsely; the true crossing is
    ///   somewhere in `(previousMeasuredEpoch, observedEpoch]` but not pinpointed
    ///   to a single epoch.
    /// - `"notCrossed"`: the threshold was not reached by the last Brotli
    ///   measurement (`previousMeasuredEpoch`); `observedEpoch` is `nil`.
    public var crossingEpochCensoring: String
    /// Cumulative wall ms from run start to `observedEpoch` (includes warmup).
    public var wallMsToCross: Double?
    /// Cumulative GPU command-buffer ms to `observedEpoch`, or `nil` if any epoch
    /// up to the crossing lacked a usable GPU timestamp.
    public var gpuMsToCross: Double?

    public init(complexity: Double, crossed: Bool, observedEpoch: Int?,
                previousMeasuredEpoch: Int?, crossingEpochCensoring: String,
                wallMsToCross: Double?, gpuMsToCross: Double?) {
        self.complexity = complexity
        self.crossed = crossed
        self.observedEpoch = observedEpoch
        self.previousMeasuredEpoch = previousMeasuredEpoch
        self.crossingEpochCensoring = crossingEpochCensoring
        self.wallMsToCross = wallMsToCross
        self.gpuMsToCross = gpuMsToCross
    }
}

/// Records the first Brotli-measured epoch at which high-order complexity reaches
/// each threshold. Pure and order-following: feed it one `observe(...)` per
/// Brotli-measured epoch, in epoch order (epoch 0's reference first, if measured).
///
/// **Nil-compression contract (fix: wrong encoder / nil compression).** When
/// `--brotli` is requested but no actual `highOrderComplexity` observation exists
/// (e.g. the injected closure returns `nil` because the linked Brotli is not
/// 1.1.0), `observe(...)` is never called. In that case `crossings` returns an
/// empty array — never a list of false "not crossed" records — so the
/// machine-readable output cannot imply a measurement was taken when it was not.
public struct HighOrderComplexityTracker {
    private let thresholds: [Double]
    private var recorded: [HighOrderComplexityCrossing]
    /// The epoch passed to the previous `observe(...)` call, or `nil` before the
    /// first call. Used to compute `previousMeasuredEpoch` and the censoring kind.
    private var previousEpoch: Int? = nil
    /// Number of `observe(...)` calls. When zero, `crossings` is empty (fix #1).
    private var observationsFed: Int = 0

    public init(thresholds: [Double]) {
        self.thresholds = thresholds
        self.recorded = thresholds.map {
            HighOrderComplexityCrossing(complexity: $0, crossed: false,
                                        observedEpoch: nil, previousMeasuredEpoch: nil,
                                        crossingEpochCensoring: "notCrossed",
                                        wallMsToCross: nil, gpuMsToCross: nil)
        }
    }

    /// Observe one Brotli-measured epoch. A threshold is crossed the first epoch
    /// `complexity >= threshold`. The interval `(previousMeasuredEpoch, observedEpoch]`
    /// is encoded explicitly so the true crossing epoch cannot be mistaken for
    /// exact under a sparse measurement cadence.
    public mutating func observe(epoch: Int, complexity: Double,
                                 cumulativeWallMs: Double, cumulativeGpuMs: Double?) {
        observationsFed += 1
        for i in recorded.indices {
            if !recorded[i].crossed && complexity >= recorded[i].complexity {
                recorded[i].crossed = true
                recorded[i].observedEpoch = epoch
                recorded[i].previousMeasuredEpoch = previousEpoch
                recorded[i].crossingEpochCensoring =
                    Self.censoringKind(observed: epoch, previous: previousEpoch)
                recorded[i].wallMsToCross = cumulativeWallMs
                recorded[i].gpuMsToCross = cumulativeGpuMs
            } else if !recorded[i].crossed {
                // Still not crossed: advance the right endpoint of the observation
                // window so the consumer knows up to which epoch it was not reached.
                recorded[i].previousMeasuredEpoch = epoch
            }
        }
        previousEpoch = epoch
    }

    /// The censoring kind for a crossing at `observed` whose preceding measurement
    /// was at `previous`. `nil` previous means epoch-0 (the initial reading) —
    /// exact. A gap of 1 means every epoch in the interval was measured — exact.
    /// A gap > 1 means the true crossing is somewhere in the interval.
    fileprivate static func censoringKind(observed: Int, previous: Int?) -> String {
        guard let previous else { return "exact" }
        return observed - previous == 1 ? "exact" : "interval"
    }

    public var crossings: [HighOrderComplexityCrossing] {
        // Fix #1: when no observation was ever fed (e.g. --brotli on but the
        // closure returned nil for every epoch), return empty — never a list of
        // false "not crossed" records that would imply a measurement was taken.
        guard observationsFed > 0 else { return [] }
        return recorded
    }
}

// MARK: - Result

/// One per-epoch kinetics sample in the machine-readable output.
///
/// Custom `encode(to:)` (below) emits every optional field as an explicit JSON `null`
/// when absent, so a sample's key set is stable regardless of GPU-timing or
/// compression availability.
public struct EpochSample: Equatable, Sendable, Codable {
    public var epoch: Int
    public var phase: String            // "warmup" | "measured"
    public var wallMs: Double
    public var gpuMs: Double?
    public var hostResidualMs: Double?
    public var rawSteps: Int
    public var commandSteps: Int
    public var copyWrites: Int
    public var entropyBitsPerByte: Double
    public var meanProgramEntropyBitsPerByte: Double
    public var deltaHFromInitial: Double
    public var transitionRate: Double
    public var compressionProxyRatio: Double?
    /// Paper Brotli 1.1.0 q2 bits/byte at this epoch; `nil` unless `--brotli` and
    /// this epoch was a Brotli measurement point on a 1.1.0 encoder.
    public var brotliBitsPerByte: Double?
    /// Paper high-order complexity `entropyBitsPerByte − brotliBitsPerByte`; `nil`
    /// exactly when `brotliBitsPerByte` is.
    public var highOrderComplexity: Double?
}

/// The full machine-readable result for one benchmark config. Codable so the CLI can
/// emit it as JSON.
///
/// Timing attribution (see the honesty note on each field):
/// - `wallMsPerEpoch` is the mean **epoch execution wall** — `runEpoch` only — over
///   measured epochs. Raw simulation throughput derives *only* from this.
/// - `gpuMsPerEpoch` is separate command-buffer GPU time.
/// - `hostResidualMsPerEpoch` = epoch wall − GPU. It is a lump; it does NOT isolate
///   planning, allocation, marshalling, encode, readback, scatter, counter/program
///   metric reduction, or the CPU shadow — all of those live inside the epoch wall.
/// - `signalAnalysisMsTotal` is the sampled signal/metric analysis wall, measured
///   *outside* the epoch wall. `nil` under `--no-samples` (not computed).
///
/// Entropy kinetics and threshold crossings span the whole run (warmup included)
/// because the entropy trajectory is deterministic regardless of timing. They are
/// `nil`/empty when signal analysis was skipped (`--no-samples`).
public struct BenchmarkResult: Sendable, Codable {
    public var config: BenchmarkConfig
    public var deviceName: String?
    public var rngContractID: String

    public var warmupEpochs: Int
    public var measuredEpochs: Int

    // Timing (measured epochs)
    public var gpuTimingAvailable: Bool
    public var wallMsPerEpoch: Double
    public var gpuMsPerEpoch: Double?
    public var hostResidualMsPerEpoch: Double?
    public var gpuBusyFraction: Double?
    /// Whole-run sampled signal/metric analysis wall (ms), measured outside epoch
    /// execution. `nil` when signal analysis was skipped (`--no-samples`): honest
    /// "not computed", never a fabricated 0.
    public var signalAnalysisMsTotal: Double?

    // Host-stage timing attribution (opt-in, schema 3)
    /// `true` iff the run enabled host-stage timing (`--host-stage-timing`). Always
    /// present so a consumer can distinguish "instrumentation off" (attribution `null`)
    /// from "instrumentation on but no measured epochs" (also `null`, but this is `true`).
    public var instrumentationEnabled: Bool
    /// Per-stage mean ms/epoch decomposition of the epoch wall plus the explicit
    /// unclassified remainder, over measured epochs. `null` when instrumentation was off
    /// or there were no measured epochs to attribute. On a non-Metal host the evaluator
    /// substage fields inside it are `null` (only the whole-evaluate span is known).
    public var hostStageAttribution: HostStageAttribution?

    // Throughput (measured epochs)
    public var epochsPerSecond: Double
    public var pairsPerSecond: Double
    public var rawStepsPerSecond: Double
    public var commandStepsPerSecond: Double

    // Aggregate counters (measured epochs, summed)
    public var totalPairs: Int
    public var totalRawSteps: Int
    public var totalCommandSteps: Int
    public var totalCopyWrites: Int
    public var haltBudget: Int
    public var haltPCOut: Int
    public var haltUnmatched: Int
    public var haltUnknown: Int

    // Entropy kinetics (whole run). `nil`/empty when `--no-samples` skipped analysis.
    /// `true` iff sample-only signal analysis ran; when `false` every kinetics field
    /// below is `nil` and `thresholdCrossings` is empty (not computed, not zeroed).
    public var signalsAnalyzed: Bool
    public var initialEntropyBitsPerByte: Double?
    public var finalEntropyBitsPerByte: Double?
    public var finalDeltaH: Double?
    public var finalMeanProgramEntropyBitsPerByte: Double?
    public var finalTransitionRate: Double?
    public var finalCompressionProxyRatio: Double?
    public var thresholdCrossings: [ThresholdCrossing]

    // Paper-aligned high-order complexity (whole run). All `nil`/empty unless
    // `--brotli` is on and the linked Brotli is 1.1.0 (else honest "not computed").
    // H0 itself is already reported as `initial/finalEntropyBitsPerByte`.
    /// Brotli 1.1.0 q2 bits/byte of the initial (epoch-0) soup.
    public var initialBrotliBitsPerByte: Double?
    /// High-order complexity `H0 − brotli_bpb` of the initial soup.
    public var initialHighOrderComplexity: Double?
    /// Brotli 1.1.0 q2 bits/byte of the final soup.
    public var finalBrotliBitsPerByte: Double?
    /// High-order complexity `H0 − brotli_bpb` of the final soup.
    public var finalHighOrderComplexity: Double?
    /// First-crossing records for the configured high-order-complexity thresholds
    /// (default paper threshold `>= 1`). Empty unless `--brotli` measured complexity.
    public var highOrderComplexityCrossings: [HighOrderComplexityCrossing]

    // Correctness spot check (whole run)
    public var shadowCheckedTotal: Int
    public var shadowMismatchTotal: Int

    // Host memory (best effort)
    public var maxRSSBytes: Int?

    // Per-epoch kinetics samples (sampled cadence). Empty under `--no-samples`.
    public var samples: [EpochSample]

    // Final soup fingerprint for cross-machine determinism checks.
    public var finalDigest: String
}

// MARK: - Stable schema-2 JSON encoding

/// Emit an optional as its value when present, or an explicit JSON `null` when absent —
/// so the key is ALWAYS written. `encodeIfPresent` (the synthesized default) would drop
/// the key entirely; a stable machine-readable schema requires every documented field
/// to appear on every run, `null` standing for "unavailable / not computed".
///
/// Internal (not private) so the host-stage attribution encoder in
/// `HostStageTiming.swift` shares exactly this explicit-null convention.
extension KeyedEncodingContainer {
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) }
        else { try encodeNil(forKey: key) }
    }
}

extension ThresholdCrossing {
    enum CodingKeys: String, CodingKey {
        case deltaH, crossed, epoch, wallMsToCross, gpuMsToCross
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deltaH, forKey: .deltaH)
        try c.encode(crossed, forKey: .crossed)
        try c.encodeOrNull(epoch, forKey: .epoch)
        try c.encodeOrNull(wallMsToCross, forKey: .wallMsToCross)
        try c.encodeOrNull(gpuMsToCross, forKey: .gpuMsToCross)
    }
}

extension HighOrderComplexityCrossing {
    enum CodingKeys: String, CodingKey {
        case complexity, crossed, observedEpoch, previousMeasuredEpoch,
             crossingEpochCensoring, wallMsToCross, gpuMsToCross
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(complexity, forKey: .complexity)
        try c.encode(crossed, forKey: .crossed)
        try c.encodeOrNull(observedEpoch, forKey: .observedEpoch)
        try c.encodeOrNull(previousMeasuredEpoch, forKey: .previousMeasuredEpoch)
        try c.encode(crossingEpochCensoring, forKey: .crossingEpochCensoring)
        try c.encodeOrNull(wallMsToCross, forKey: .wallMsToCross)
        try c.encodeOrNull(gpuMsToCross, forKey: .gpuMsToCross)
    }
    /// Backward-compatible decode: `observedEpoch`, `previousMeasuredEpoch`, and
    /// `crossingEpochCensoring` default gracefully when absent (e.g. partial JSON).
    /// A missing `crossingEpochCensoring` is derived conservatively from `crossed`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        complexity = try c.decode(Double.self, forKey: .complexity)
        crossed = try c.decode(Bool.self, forKey: .crossed)
        observedEpoch = try c.decodeIfPresent(Int.self, forKey: .observedEpoch)
        previousMeasuredEpoch = try c.decodeIfPresent(Int.self, forKey: .previousMeasuredEpoch)
        if let kind = try c.decodeIfPresent(String.self, forKey: .crossingEpochCensoring) {
            crossingEpochCensoring = kind
        } else if crossed, let observed = observedEpoch {
            // Derive from the gap when the field is absent.
            crossingEpochCensoring = HighOrderComplexityTracker.censoringKind(
                observed: observed, previous: previousMeasuredEpoch)
        } else {
            crossingEpochCensoring = "notCrossed"
        }
        wallMsToCross = try c.decodeIfPresent(Double.self, forKey: .wallMsToCross)
        gpuMsToCross = try c.decodeIfPresent(Double.self, forKey: .gpuMsToCross)
    }
}

extension EpochSample {
    enum CodingKeys: String, CodingKey {
        case epoch, phase, wallMs, gpuMs, hostResidualMs, rawSteps, commandSteps,
             copyWrites, entropyBitsPerByte, meanProgramEntropyBitsPerByte,
             deltaHFromInitial, transitionRate, compressionProxyRatio,
             brotliBitsPerByte, highOrderComplexity
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(phase, forKey: .phase)
        try c.encode(wallMs, forKey: .wallMs)
        try c.encodeOrNull(gpuMs, forKey: .gpuMs)
        try c.encodeOrNull(hostResidualMs, forKey: .hostResidualMs)
        try c.encode(rawSteps, forKey: .rawSteps)
        try c.encode(commandSteps, forKey: .commandSteps)
        try c.encode(copyWrites, forKey: .copyWrites)
        try c.encode(entropyBitsPerByte, forKey: .entropyBitsPerByte)
        try c.encode(meanProgramEntropyBitsPerByte, forKey: .meanProgramEntropyBitsPerByte)
        try c.encode(deltaHFromInitial, forKey: .deltaHFromInitial)
        try c.encode(transitionRate, forKey: .transitionRate)
        try c.encodeOrNull(compressionProxyRatio, forKey: .compressionProxyRatio)
        try c.encodeOrNull(brotliBitsPerByte, forKey: .brotliBitsPerByte)
        try c.encodeOrNull(highOrderComplexity, forKey: .highOrderComplexity)
    }
}

extension BenchmarkResult {
    enum CodingKeys: String, CodingKey {
        case config, deviceName, rngContractID, warmupEpochs, measuredEpochs,
             gpuTimingAvailable, wallMsPerEpoch, gpuMsPerEpoch, hostResidualMsPerEpoch,
             gpuBusyFraction, signalAnalysisMsTotal,
             instrumentationEnabled, hostStageAttribution, epochsPerSecond, pairsPerSecond,
             rawStepsPerSecond, commandStepsPerSecond, totalPairs, totalRawSteps,
             totalCommandSteps, totalCopyWrites, haltBudget, haltPCOut, haltUnmatched,
             haltUnknown, signalsAnalyzed, initialEntropyBitsPerByte,
             finalEntropyBitsPerByte, finalDeltaH, finalMeanProgramEntropyBitsPerByte,
             finalTransitionRate, finalCompressionProxyRatio, thresholdCrossings,
             initialBrotliBitsPerByte, initialHighOrderComplexity,
             finalBrotliBitsPerByte, finalHighOrderComplexity,
             highOrderComplexityCrossings,
             shadowCheckedTotal, shadowMismatchTotal, maxRSSBytes, samples, finalDigest
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(config, forKey: .config)
        try c.encodeOrNull(deviceName, forKey: .deviceName)
        try c.encode(rngContractID, forKey: .rngContractID)
        try c.encode(warmupEpochs, forKey: .warmupEpochs)
        try c.encode(measuredEpochs, forKey: .measuredEpochs)
        try c.encode(gpuTimingAvailable, forKey: .gpuTimingAvailable)
        try c.encode(wallMsPerEpoch, forKey: .wallMsPerEpoch)
        try c.encodeOrNull(gpuMsPerEpoch, forKey: .gpuMsPerEpoch)
        try c.encodeOrNull(hostResidualMsPerEpoch, forKey: .hostResidualMsPerEpoch)
        try c.encodeOrNull(gpuBusyFraction, forKey: .gpuBusyFraction)
        try c.encodeOrNull(signalAnalysisMsTotal, forKey: .signalAnalysisMsTotal)
        try c.encode(instrumentationEnabled, forKey: .instrumentationEnabled)
        try c.encodeOrNull(hostStageAttribution, forKey: .hostStageAttribution)
        try c.encode(epochsPerSecond, forKey: .epochsPerSecond)
        try c.encode(pairsPerSecond, forKey: .pairsPerSecond)
        try c.encode(rawStepsPerSecond, forKey: .rawStepsPerSecond)
        try c.encode(commandStepsPerSecond, forKey: .commandStepsPerSecond)
        try c.encode(totalPairs, forKey: .totalPairs)
        try c.encode(totalRawSteps, forKey: .totalRawSteps)
        try c.encode(totalCommandSteps, forKey: .totalCommandSteps)
        try c.encode(totalCopyWrites, forKey: .totalCopyWrites)
        try c.encode(haltBudget, forKey: .haltBudget)
        try c.encode(haltPCOut, forKey: .haltPCOut)
        try c.encode(haltUnmatched, forKey: .haltUnmatched)
        try c.encode(haltUnknown, forKey: .haltUnknown)
        try c.encode(signalsAnalyzed, forKey: .signalsAnalyzed)
        try c.encodeOrNull(initialEntropyBitsPerByte, forKey: .initialEntropyBitsPerByte)
        try c.encodeOrNull(finalEntropyBitsPerByte, forKey: .finalEntropyBitsPerByte)
        try c.encodeOrNull(finalDeltaH, forKey: .finalDeltaH)
        try c.encodeOrNull(finalMeanProgramEntropyBitsPerByte,
                           forKey: .finalMeanProgramEntropyBitsPerByte)
        try c.encodeOrNull(finalTransitionRate, forKey: .finalTransitionRate)
        try c.encodeOrNull(finalCompressionProxyRatio, forKey: .finalCompressionProxyRatio)
        try c.encode(thresholdCrossings, forKey: .thresholdCrossings)
        try c.encodeOrNull(initialBrotliBitsPerByte, forKey: .initialBrotliBitsPerByte)
        try c.encodeOrNull(initialHighOrderComplexity, forKey: .initialHighOrderComplexity)
        try c.encodeOrNull(finalBrotliBitsPerByte, forKey: .finalBrotliBitsPerByte)
        try c.encodeOrNull(finalHighOrderComplexity, forKey: .finalHighOrderComplexity)
        try c.encode(highOrderComplexityCrossings, forKey: .highOrderComplexityCrossings)
        try c.encode(shadowCheckedTotal, forKey: .shadowCheckedTotal)
        try c.encode(shadowMismatchTotal, forKey: .shadowMismatchTotal)
        try c.encodeOrNull(maxRSSBytes, forKey: .maxRSSBytes)
        try c.encode(samples, forKey: .samples)
        try c.encode(finalDigest, forKey: .finalDigest)
    }

    /// Backward-compatible decode: schema-2 JSON lacks every Brotli/high-order key
    /// added in schema 3 (`initialBrotliBitsPerByte`, `initialHighOrderComplexity`,
    /// `finalBrotliBitsPerByte`, `finalHighOrderComplexity`, and
    /// `highOrderComplexityCrossings`). Optional scalar metrics default to `nil`
    /// and the crossings array defaults to `[]`, so a schema-2-shaped result decodes
    /// without altering any existing field's meaning. Existing schema-2 keys are
    /// decoded strictly; `thresholdCrossings`/`samples` tolerate absence (default
    /// `[]`) for trimmed snapshots but their element semantics are unchanged.
    ///
    /// Schema 4 composes the two predecessor schema-3 shapes (host-attribution and
    /// paper). This decoder also accepts *either* predecessor schema-3 shape:
    /// `instrumentationEnabled` defaults to `false` when absent (paper schema-3 and
    /// schema-2 JSON never carried it), and `hostStageAttribution` defaults to `nil`
    /// (it is an explicit null only under `--host-stage-timing`). The Brotli keys
    /// above default the same way for host-attribution schema-3 and schema-2 JSON.
    /// So a document from either predecessor decodes losslessly into a schema-4
    /// `BenchmarkResult`, the absent side surfaced as "off / not computed".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decode(BenchmarkConfig.self, forKey: .config)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        rngContractID = try c.decode(String.self, forKey: .rngContractID)
        warmupEpochs = try c.decode(Int.self, forKey: .warmupEpochs)
        measuredEpochs = try c.decode(Int.self, forKey: .measuredEpochs)
        gpuTimingAvailable = try c.decode(Bool.self, forKey: .gpuTimingAvailable)
        wallMsPerEpoch = try c.decode(Double.self, forKey: .wallMsPerEpoch)
        gpuMsPerEpoch = try c.decodeIfPresent(Double.self, forKey: .gpuMsPerEpoch)
        hostResidualMsPerEpoch = try c.decodeIfPresent(Double.self, forKey: .hostResidualMsPerEpoch)
        gpuBusyFraction = try c.decodeIfPresent(Double.self, forKey: .gpuBusyFraction)
        signalAnalysisMsTotal = try c.decodeIfPresent(Double.self, forKey: .signalAnalysisMsTotal)
        // Host-attribution keys (schema 3 host / schema 4). Absent in schema 2 and
        // the paper schema-3 shape — default to "off" / nil so those decode too.
        instrumentationEnabled = try c.decodeIfPresent(Bool.self, forKey: .instrumentationEnabled) ?? false
        hostStageAttribution = try c.decodeIfPresent(HostStageAttribution.self, forKey: .hostStageAttribution)
        epochsPerSecond = try c.decode(Double.self, forKey: .epochsPerSecond)
        pairsPerSecond = try c.decode(Double.self, forKey: .pairsPerSecond)
        rawStepsPerSecond = try c.decode(Double.self, forKey: .rawStepsPerSecond)
        commandStepsPerSecond = try c.decode(Double.self, forKey: .commandStepsPerSecond)
        totalPairs = try c.decode(Int.self, forKey: .totalPairs)
        totalRawSteps = try c.decode(Int.self, forKey: .totalRawSteps)
        totalCommandSteps = try c.decode(Int.self, forKey: .totalCommandSteps)
        totalCopyWrites = try c.decode(Int.self, forKey: .totalCopyWrites)
        haltBudget = try c.decode(Int.self, forKey: .haltBudget)
        haltPCOut = try c.decode(Int.self, forKey: .haltPCOut)
        haltUnmatched = try c.decode(Int.self, forKey: .haltUnmatched)
        haltUnknown = try c.decode(Int.self, forKey: .haltUnknown)
        signalsAnalyzed = try c.decode(Bool.self, forKey: .signalsAnalyzed)
        initialEntropyBitsPerByte = try c.decodeIfPresent(Double.self, forKey: .initialEntropyBitsPerByte)
        finalEntropyBitsPerByte = try c.decodeIfPresent(Double.self, forKey: .finalEntropyBitsPerByte)
        finalDeltaH = try c.decodeIfPresent(Double.self, forKey: .finalDeltaH)
        finalMeanProgramEntropyBitsPerByte = try c.decodeIfPresent(Double.self, forKey: .finalMeanProgramEntropyBitsPerByte)
        finalTransitionRate = try c.decodeIfPresent(Double.self, forKey: .finalTransitionRate)
        finalCompressionProxyRatio = try c.decodeIfPresent(Double.self, forKey: .finalCompressionProxyRatio)
        thresholdCrossings = try c.decodeIfPresent([ThresholdCrossing].self, forKey: .thresholdCrossings) ?? []
        initialBrotliBitsPerByte = try c.decodeIfPresent(Double.self, forKey: .initialBrotliBitsPerByte)
        initialHighOrderComplexity = try c.decodeIfPresent(Double.self, forKey: .initialHighOrderComplexity)
        finalBrotliBitsPerByte = try c.decodeIfPresent(Double.self, forKey: .finalBrotliBitsPerByte)
        finalHighOrderComplexity = try c.decodeIfPresent(Double.self, forKey: .finalHighOrderComplexity)
        highOrderComplexityCrossings = try c.decodeIfPresent([HighOrderComplexityCrossing].self, forKey: .highOrderComplexityCrossings) ?? []
        shadowCheckedTotal = try c.decode(Int.self, forKey: .shadowCheckedTotal)
        shadowMismatchTotal = try c.decode(Int.self, forKey: .shadowMismatchTotal)
        maxRSSBytes = try c.decodeIfPresent(Int.self, forKey: .maxRSSBytes)
        samples = try c.decodeIfPresent([EpochSample].self, forKey: .samples) ?? []
        finalDigest = try c.decode(String.self, forKey: .finalDigest)
    }
}

// MARK: - Aggregation

public enum BenchmarkAggregator {

    /// Fold per-epoch observations into a `BenchmarkResult`.
    ///
    /// - `initialSignals` are the epoch-0 (pre-run) soup signals, so ΔH is measured
    ///   from the true starting state. `nil` when signal analysis was skipped
    ///   (`--no-samples`): every kinetics field is then reported as not computed.
    /// - `initialAnalysisSeconds` is the host wall spent measuring `initialSignals`,
    ///   folded into `signalAnalysisMsTotal` alongside the per-epoch analysis time.
    /// - Timing/throughput use measured (non-warmup) epochs only, and derive solely
    ///   from the epoch execution wall — signal analysis is never mixed in.
    /// - Threshold crossings and kinetics fold every epoch that carries signals, in
    ///   order; epochs without a reading (off a sparse `--signal-interval` cadence)
    ///   are skipped. ΔH thresholds are only ever requested with per-epoch signals
    ///   (the CLI rejects thresholds under a sparse interval), so their epochs stay
    ///   exact.
    public static func aggregate(config: BenchmarkConfig,
                                 deviceName: String?,
                                 initialSignals: SoupSignals?,
                                 observations: [EpochObservation],
                                 finalDigestHex: String,
                                 maxRSSBytes: Int?,
                                 initialAnalysisSeconds: Double? = nil,
                                 instrumentationEnabled: Bool = false) -> BenchmarkResult {
        // Signal analysis is "available" (kinetics were computed) when we have the
        // epoch-0 reference and at least one epoch carries signals — i.e. it was not
        // skipped by `--no-samples`. The dense default (`--signal-interval 1`) measures
        // every epoch, so `contains` and the former `allSatisfy` agree there and the
        // default result is unchanged. Under a sparse `--signal-interval N` only the
        // cadence epochs (plus epoch 0 and the final epoch) carry signals, so requiring
        // *some* — not every — observation to have them is what admits cadence-only
        // kinetics while still reporting `false` under `--no-samples`.
        let signalsAnalyzed = initialSignals != nil
            && !observations.isEmpty
            && observations.contains { $0.signals != nil }
        let initialH = initialSignals?.entropyBitsPerByte
        let measured = observations.filter { !$0.isWarmup }

        // --- Timing over measured epochs ---
        let measuredWall = measured.reduce(0.0) { $0 + $1.wallSeconds }
        let gpuAvailable = !measured.isEmpty && measured.allSatisfy { $0.gpuSeconds != nil }
        let measuredGpu = gpuAvailable ? measured.reduce(0.0) { $0 + ($1.gpuSeconds ?? 0) } : nil

        let n = Double(measured.count)
        let wallMsPerEpoch = measured.isEmpty ? 0 : measuredWall / n * 1000
        let gpuMsPerEpoch = measuredGpu.map { $0 / n * 1000 }
        let hostResidualMsPerEpoch = measuredGpu.map { (measuredWall - $0) / n * 1000 }
        let gpuBusyFraction = (measuredGpu != nil && measuredWall > 0)
            ? measuredGpu! / measuredWall : nil

        // --- Counters over measured epochs ---
        var totalPairs = 0, totalRaw = 0, totalCmd = 0, totalCopy = 0
        var hB = 0, hP = 0, hU = 0, hUnk = 0
        for o in measured {
            let c = o.counters
            totalPairs += c.interactions
            totalRaw += c.totalRawSteps
            totalCmd += c.totalCommandSteps
            totalCopy += c.totalCopyWrites
            hB += c.haltBudget; hP += c.haltPCOut; hU += c.haltUnmatched; hUnk += c.haltUnknown
        }

        // --- Throughput (guard divide-by-zero for synthetic/zero-time inputs) ---
        let perSec: (Int) -> Double = { measuredWall > 0 ? Double($0) / measuredWall : 0 }
        let epochsPerSecond = measuredWall > 0 ? n / measuredWall : 0

        // --- Kinetics + thresholds over every epoch, in order (only when analyzed) ---
        // When `--no-samples` skipped analysis, every observation's `signals` is nil;
        // we emit no thresholds, no samples, and nil kinetics rather than fabricating
        // a flat ΔH == 0 trajectory.
        var tracker = ThresholdTracker(thresholds: signalsAnalyzed ? config.deltaHThresholds : [])
        // Paper high-order-complexity crossings run over the Brotli-measured epochs
        // only (Brotli is sparse by construction), so — unlike ΔH — this tracker is
        // fed just the epochs that carry a `highOrderComplexity`, and its crossing
        // epoch is resolved to that measurement cadence (documented on the struct).
        var highOrderTracker = HighOrderComplexityTracker(
            thresholds: signalsAnalyzed ? config.highOrderComplexityThresholds : [])
        var cumWall = 0.0
        var cumGpu: Double? = 0.0
        var samples: [EpochSample] = []
        if signalsAnalyzed, let initialH {
            // Epoch-0 reference: if the initial soup was Brotli-measured, an already
            // high-order-complex starting soup registers a crossing at epoch 0
            // (cumulative wall/GPU = 0, nothing has run yet).
            if let initialC = initialSignals?.highOrderComplexity {
                highOrderTracker.observe(epoch: 0, complexity: initialC,
                                         cumulativeWallMs: 0, cumulativeGpuMs: 0)
            }
            for o in observations {
                cumWall += o.wallSeconds
                if let g = o.gpuSeconds, cumGpu != nil { cumGpu! += g } else { cumGpu = nil }
                guard let s = o.signals else { continue }
                let deltaH = s.entropyBitsPerByte - initialH
                tracker.observe(epoch: o.epoch, deltaH: deltaH,
                                cumulativeWallMs: cumWall * 1000,
                                cumulativeGpuMs: cumGpu.map { $0 * 1000 })
                if let c = s.highOrderComplexity {
                    highOrderTracker.observe(epoch: o.epoch, complexity: c,
                                             cumulativeWallMs: cumWall * 1000,
                                             cumulativeGpuMs: cumGpu.map { $0 * 1000 })
                }

                let isSamplePoint = (o.epoch % config.sampleInterval == 0)
                    || o.epoch == observations.last?.epoch
                if isSamplePoint {
                    let gpuMs = o.gpuSeconds.map { $0 * 1000 }
                    samples.append(EpochSample(
                        epoch: o.epoch,
                        phase: o.isWarmup ? "warmup" : "measured",
                        wallMs: o.wallSeconds * 1000,
                        gpuMs: gpuMs,
                        hostResidualMs: gpuMs.map { o.wallSeconds * 1000 - $0 },
                        rawSteps: o.counters.totalRawSteps,
                        commandSteps: o.counters.totalCommandSteps,
                        copyWrites: o.counters.totalCopyWrites,
                        entropyBitsPerByte: s.entropyBitsPerByte,
                        meanProgramEntropyBitsPerByte: s.meanProgramEntropyBitsPerByte,
                        deltaHFromInitial: deltaH,
                        transitionRate: s.transitionRate,
                        compressionProxyRatio: s.compressionProxyRatio,
                        brotliBitsPerByte: s.brotliBitsPerByte,
                        highOrderComplexity: s.highOrderComplexity))
                }
            }
        }

        // --- Host analysis cost (outside epoch wall); nil when not computed ---
        let signalAnalysisMsTotal: Double? = signalsAnalyzed
            ? (observations.compactMap { $0.analysisSeconds }.reduce(0, +)
               + (initialAnalysisSeconds ?? 0)) * 1000
            : nil

        // --- Kinetics fields (nil when analysis was skipped) ---
        let last = observations.last?.signals
        let finalH: Double? = signalsAnalyzed ? (last?.entropyBitsPerByte ?? initialH) : nil
        let finalDeltaH: Double? = (signalsAnalyzed && initialH != nil && finalH != nil)
            ? finalH! - initialH! : nil
        let finalMeanH: Double? = signalsAnalyzed
            ? (last?.meanProgramEntropyBitsPerByte ?? initialSignals?.meanProgramEntropyBitsPerByte)
            : nil
        let finalTransition: Double? = signalsAnalyzed
            ? (last?.transitionRate ?? initialSignals?.transitionRate) : nil
        let finalCompression: Double? = signalsAnalyzed
            ? (last?.compressionProxyRatio ?? initialSignals?.compressionProxyRatio) : nil
        // Paper high-order complexity: the final soup's Brotli reading falls back to
        // the initial one only if the final epoch carried no Brotli measurement (it
        // always does when `--brotli` is on, since the final epoch is a sample point).
        let initialBrotli: Double? = signalsAnalyzed ? initialSignals?.brotliBitsPerByte : nil
        let initialHighOrder: Double? = signalsAnalyzed ? initialSignals?.highOrderComplexity : nil
        let finalBrotli: Double? = signalsAnalyzed
            ? (last?.brotliBitsPerByte ?? initialSignals?.brotliBitsPerByte) : nil
        let finalHighOrder: Double? = signalsAnalyzed
            ? (last?.highOrderComplexity ?? initialSignals?.highOrderComplexity) : nil

        let shadowChecked = observations.reduce(0) { $0 + $1.shadowChecked }
        let shadowMismatch = observations.reduce(0) { $0 + $1.shadowMismatches }

        // --- Host-stage attribution (opt-in, measured epochs only) ---
        // Built from every measured epoch when instrumentation is enabled. Missing spans
        // produce a stable incomplete attribution object rather than compacting a subset
        // and reconciling it against the all-epoch wall.
        let stageMeasured: [(wallSeconds: Double, spans: HostStageSpans?)] =
            instrumentationEnabled ? measured.map { ($0.wallSeconds, $0.hostStageSpans) } : []
        let hostStageAttribution = HostStageAttribution.aggregate(measured: stageMeasured)

        return BenchmarkResult(
            config: config,
            deviceName: deviceName,
            rngContractID: BFFRandom.contractID,
            warmupEpochs: observations.filter { $0.isWarmup }.count,
            measuredEpochs: measured.count,
            gpuTimingAvailable: gpuAvailable,
            wallMsPerEpoch: wallMsPerEpoch,
            gpuMsPerEpoch: gpuMsPerEpoch,
            hostResidualMsPerEpoch: hostResidualMsPerEpoch,
            gpuBusyFraction: gpuBusyFraction,
            signalAnalysisMsTotal: signalAnalysisMsTotal,
            instrumentationEnabled: instrumentationEnabled,
            hostStageAttribution: hostStageAttribution,
            epochsPerSecond: epochsPerSecond,
            pairsPerSecond: perSec(totalPairs),
            rawStepsPerSecond: perSec(totalRaw),
            commandStepsPerSecond: perSec(totalCmd),
            totalPairs: totalPairs,
            totalRawSteps: totalRaw,
            totalCommandSteps: totalCmd,
            totalCopyWrites: totalCopy,
            haltBudget: hB, haltPCOut: hP, haltUnmatched: hU, haltUnknown: hUnk,
            signalsAnalyzed: signalsAnalyzed,
            initialEntropyBitsPerByte: signalsAnalyzed ? initialH : nil,
            finalEntropyBitsPerByte: finalH,
            finalDeltaH: finalDeltaH,
            finalMeanProgramEntropyBitsPerByte: finalMeanH,
            finalTransitionRate: finalTransition,
            finalCompressionProxyRatio: finalCompression,
            thresholdCrossings: tracker.crossings,
            initialBrotliBitsPerByte: initialBrotli,
            initialHighOrderComplexity: initialHighOrder,
            finalBrotliBitsPerByte: finalBrotli,
            finalHighOrderComplexity: finalHighOrder,
            highOrderComplexityCrossings: highOrderTracker.crossings,
            shadowCheckedTotal: shadowChecked,
            shadowMismatchTotal: shadowMismatch,
            maxRSSBytes: maxRSSBytes,
            samples: samples,
            finalDigest: finalDigestHex)
    }
}
