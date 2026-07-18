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

    public init(entropyBitsPerByte: Double, meanProgramEntropyBitsPerByte: Double,
                transitionRate: Double, compressionProxyRatio: Double?) {
        self.entropyBitsPerByte = entropyBitsPerByte
        self.meanProgramEntropyBitsPerByte = meanProgramEntropyBitsPerByte
        self.transitionRate = transitionRate
        self.compressionProxyRatio = compressionProxyRatio
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
    /// Emit a per-epoch kinetics sample (and the expensive compression proxy) every
    /// `sampleInterval` epochs. `>= 1`; large values bound output at large soups.
    public var sampleInterval: Int

    public init(seed: UInt32, programCount: Int,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                initMode: SoupConfig.InitMode = .uniform,
                shadowSampleCount: Int = 0,
                warmupEpochs: Int = 1,
                measuredEpochs: Int = 8,
                deltaHThresholds: [Double] = [],
                sampleInterval: Int = 1) {
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
        self.sampleInterval = max(1, sampleInterval)
    }

    /// Total epochs the run executes (warmup + measured).
    public var totalEpochs: Int { warmupEpochs + measuredEpochs }

    /// Validated soup configuration for this cell (reuses `SoupConfig`'s bounds).
    public func soupConfig() throws -> SoupConfig {
        try SoupConfig(seed: seed, programCount: programCount, stepBudget: stepBudget,
                       mutationP32: mutationP32, variant: variant,
                       shadowSampleCount: shadowSampleCount, initMode: initMode)
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

extension EpochSample {
    enum CodingKeys: String, CodingKey {
        case epoch, phase, wallMs, gpuMs, hostResidualMs, rawSteps, commandSteps,
             copyWrites, entropyBitsPerByte, meanProgramEntropyBitsPerByte,
             deltaHFromInitial, transitionRate, compressionProxyRatio
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
        try c.encode(shadowCheckedTotal, forKey: .shadowCheckedTotal)
        try c.encode(shadowMismatchTotal, forKey: .shadowMismatchTotal)
        try c.encodeOrNull(maxRSSBytes, forKey: .maxRSSBytes)
        try c.encode(samples, forKey: .samples)
        try c.encode(finalDigest, forKey: .finalDigest)
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
        var cumWall = 0.0
        var cumGpu: Double? = 0.0
        var samples: [EpochSample] = []
        if signalsAnalyzed, let initialH {
            for o in observations {
                cumWall += o.wallSeconds
                if let g = o.gpuSeconds, cumGpu != nil { cumGpu! += g } else { cumGpu = nil }
                guard let s = o.signals else { continue }
                let deltaH = s.entropyBitsPerByte - initialH
                tracker.observe(epoch: o.epoch, deltaH: deltaH,
                                cumulativeWallMs: cumWall * 1000,
                                cumulativeGpuMs: cumGpu.map { $0 * 1000 })

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
                        compressionProxyRatio: s.compressionProxyRatio))
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

        let shadowChecked = observations.reduce(0) { $0 + $1.shadowChecked }
        let shadowMismatch = observations.reduce(0) { $0 + $1.shadowMismatches }

        // --- Host-stage attribution (opt-in, measured epochs only) ---
        // Built only from measured epochs that carry a stage breakdown. The remainder
        // reconciles against the same measured epoch wall used for throughput, so the
        // attribution and the headline `wallMsPerEpoch` describe the same interval.
        let stageMeasured: [(wallSeconds: Double, spans: HostStageSpans)] =
            measured.compactMap { o in o.hostStageSpans.map { (o.wallSeconds, $0) } }
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
            shadowCheckedTotal: shadowChecked,
            shadowMismatchTotal: shadowMismatch,
            maxRSSBytes: maxRSSBytes,
            samples: samples,
            finalDigest: finalDigestHex)
    }
}
