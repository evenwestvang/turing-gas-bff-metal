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
    /// because it is the one O(n·window) signal — the harness computes it only on
    /// sampled epochs and the final epoch to bound cost at large soups.
    public var compressionProxyRatio: Double?

    public init(entropyBitsPerByte: Double, meanProgramEntropyBitsPerByte: Double,
                transitionRate: Double, compressionProxyRatio: Double?) {
        self.entropyBitsPerByte = entropyBitsPerByte
        self.meanProgramEntropyBitsPerByte = meanProgramEntropyBitsPerByte
        self.transitionRate = transitionRate
        self.compressionProxyRatio = compressionProxyRatio
    }

    /// Measure a soup. `includeCompression` gates the expensive proxy so callers can
    /// keep the cheap per-epoch signals (entropy, transition rate) always-on and the
    /// proxy on a sampling cadence.
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

/// Everything measured for one executed epoch. `gpuSeconds` is `nil` when the
/// hardware reported no usable command-buffer timestamp; the aggregator then marks
/// GPU timing unavailable rather than inventing a number.
public struct EpochObservation: Sendable {
    public var epoch: Int
    public var isWarmup: Bool
    public var wallSeconds: Double
    public var gpuSeconds: Double?
    public var counters: EpochCounters
    public var shadowChecked: Int
    public var shadowMismatches: Int
    public var signals: SoupSignals

    public init(epoch: Int, isWarmup: Bool, wallSeconds: Double, gpuSeconds: Double?,
                counters: EpochCounters, shadowChecked: Int, shadowMismatches: Int,
                signals: SoupSignals) {
        self.epoch = epoch
        self.isWarmup = isWarmup
        self.wallSeconds = wallSeconds
        self.gpuSeconds = gpuSeconds
        self.counters = counters
        self.shadowChecked = shadowChecked
        self.shadowMismatches = shadowMismatches
        self.signals = signals
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
/// emit it as JSON. Timing/throughput fields cover the MEASURED epochs only; entropy
/// kinetics and threshold crossings span the whole run (warmup included) because the
/// entropy trajectory is deterministic regardless of timing.
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

    // Entropy kinetics (whole run)
    public var initialEntropyBitsPerByte: Double
    public var finalEntropyBitsPerByte: Double
    public var finalDeltaH: Double
    public var finalMeanProgramEntropyBitsPerByte: Double
    public var finalTransitionRate: Double
    public var finalCompressionProxyRatio: Double?
    public var thresholdCrossings: [ThresholdCrossing]

    // Correctness spot check (whole run)
    public var shadowCheckedTotal: Int
    public var shadowMismatchTotal: Int

    // Host memory (best effort)
    public var maxRSSBytes: Int?

    // Per-epoch kinetics samples (sampled cadence)
    public var samples: [EpochSample]

    // Final soup fingerprint for cross-machine determinism checks.
    public var finalDigest: String
}

// MARK: - Aggregation

public enum BenchmarkAggregator {

    /// Fold per-epoch observations into a `BenchmarkResult`.
    ///
    /// - `initialSignals` are the epoch-0 (pre-run) soup signals, so ΔH is measured
    ///   from the true starting state.
    /// - Timing/throughput use measured (non-warmup) epochs only.
    /// - Threshold crossings and kinetics use every epoch in order.
    public static func aggregate(config: BenchmarkConfig,
                                 deviceName: String?,
                                 initialSignals: SoupSignals,
                                 observations: [EpochObservation],
                                 finalDigestHex: String,
                                 maxRSSBytes: Int?) -> BenchmarkResult {
        let initialH = initialSignals.entropyBitsPerByte
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

        // --- Kinetics + thresholds over every epoch, in order ---
        var tracker = ThresholdTracker(thresholds: config.deltaHThresholds)
        var cumWall = 0.0
        var cumGpu: Double? = 0.0
        var samples: [EpochSample] = []
        for o in observations {
            cumWall += o.wallSeconds
            if let g = o.gpuSeconds, cumGpu != nil { cumGpu! += g } else { cumGpu = nil }
            let deltaH = o.signals.entropyBitsPerByte - initialH
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
                    entropyBitsPerByte: o.signals.entropyBitsPerByte,
                    meanProgramEntropyBitsPerByte: o.signals.meanProgramEntropyBitsPerByte,
                    deltaHFromInitial: deltaH,
                    transitionRate: o.signals.transitionRate,
                    compressionProxyRatio: o.signals.compressionProxyRatio))
            }
        }

        let last = observations.last?.signals
        let finalH = last?.entropyBitsPerByte ?? initialH

        let shadowChecked = observations.reduce(0) { $0 + $1.shadowChecked }
        let shadowMismatch = observations.reduce(0) { $0 + $1.shadowMismatches }

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
            epochsPerSecond: epochsPerSecond,
            pairsPerSecond: perSec(totalPairs),
            rawStepsPerSecond: perSec(totalRaw),
            commandStepsPerSecond: perSec(totalCmd),
            totalPairs: totalPairs,
            totalRawSteps: totalRaw,
            totalCommandSteps: totalCmd,
            totalCopyWrites: totalCopy,
            haltBudget: hB, haltPCOut: hP, haltUnmatched: hU, haltUnknown: hUnk,
            initialEntropyBitsPerByte: initialH,
            finalEntropyBitsPerByte: finalH,
            finalDeltaH: finalH - initialH,
            finalMeanProgramEntropyBitsPerByte: last?.meanProgramEntropyBitsPerByte ?? initialSignals.meanProgramEntropyBitsPerByte,
            finalTransitionRate: last?.transitionRate ?? initialSignals.transitionRate,
            finalCompressionProxyRatio: last?.compressionProxyRatio ?? initialSignals.compressionProxyRatio,
            thresholdCrossings: tracker.crossings,
            shadowCheckedTotal: shadowChecked,
            shadowMismatchTotal: shadowMismatch,
            maxRSSBytes: maxRSSBytes,
            samples: samples,
            finalDigest: finalDigestHex)
    }
}
