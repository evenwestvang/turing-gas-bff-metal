import Foundation
import BFFOracle

/// Opt-in, bounded host-stage timing attribution for the small-soup epoch loop.
///
/// The benchmark's `hostResidualMsPerEpoch` (epoch wall − GPU) is a single lump: it is
/// honest but coarse. This file adds an *opt-in* decomposition of the epoch wall into
/// named, mutually-exclusive host stages, plus a clearly-named unclassified remainder,
/// so a native run can answer "where does the host time go?" without ever changing the
/// simulation.
///
/// ## Timing model (read this before trusting a number)
///
/// Two levels, kept deliberately separate so no span is double-counted:
///
/// 1. **Top-level epoch stages** (`HostStageSpans`) — measured by `SoupRunner.runEpoch`
///    from monotonic-clock boundaries taken *between* stages. They are mutually
///    exclusive. The gap (wall − Σ stages) is the explicit signed
///    `unclassifiedMsPerEpoch` remainder. A negative remainder means the measured stage
///    sum exceeded the enclosing epoch wall; the stable `reconciliationValid` /
///    `reconciliationError` fields surface that invalid timing instead of masking it.
///    A positive remainder absorbs the tiny per-boundary clock reads, the soup commit,
///    and `EpochReport` construction. Stages:
///    mutation+pairing, pair packing, evaluate (whole), scatter, counter reduction,
///    per-program metrics, CPU shadow, full-soup digest.
///
/// 2. **Evaluator substages** (`EvaluatorStageProfile`) — a *sub*-decomposition of the
///    single `evaluate` span, reported by an evaluator that conforms to
///    `StageProfilingEvaluator` (the Metal host). They decompose the evaluate span only;
///    they are NOT added to the top-level sum, so there is no overlapping
///    inclusive/exclusive accounting. On a non-Metal host the CPU reference evaluator
///    does not profile, so the profile is `nil` and only the whole `evaluate` span is
///    known — never a fabricated substage breakdown.
///
/// The GPU command-buffer time is *retained separately* (the benchmark's existing
/// `gpuMsPerEpoch`, and `EvaluatorStageProfile.gpuCommandBufferSeconds`). It is NEVER
/// subtracted from the submit+wait span to synthesize "precise CPU work": submit+wait is
/// the CPU-observed wall of commit + `waitUntilCompleted`, reported as measured.

// MARK: - Evaluator substage profile

/// Host-side substage timings for ONE evaluator `evaluate` call, in seconds. Every field
/// is optional: `nil` means "not measured" (e.g. the CPU reference evaluator, or a Metal
/// host that could not read command-buffer timestamps), never a fabricated 0.
///
/// These substages decompose the evaluate span only. `gpuCommandBufferSeconds` is the
/// GPU's own execution time, retained here *alongside* the CPU spans — it is not one of
/// them and is never mixed into `classifiedSeconds`.
public struct EvaluatorStageProfile: Sendable, Equatable {
    /// `MTLBuffer` allocation for the tape + result buffers.
    public var bufferAllocSeconds: Double?
    /// Marshalling the input tapes into the shared tape buffer (+ zeroing results).
    public var uploadSeconds: Double?
    /// Command-buffer + compute-encoder construction and dispatch encoding.
    public var encodeSeconds: Double?
    /// `commit()` + `waitUntilCompleted()` — the CPU-observed submit+wait wall. This
    /// span *contains* the GPU execution time; the two are reported separately and the
    /// GPU time is never subtracted out to derive a CPU figure.
    public var submitWaitSeconds: Double?
    /// Reading the result records + materializing the final tapes back into host arrays.
    public var readbackSeconds: Double?
    /// GPU command-buffer execution time (`gpuEndTime − gpuStartTime`), retained
    /// separately from every CPU span above. `nil` when the hardware reported no usable
    /// timestamp.
    public var gpuCommandBufferSeconds: Double?

    public init(bufferAllocSeconds: Double? = nil, uploadSeconds: Double? = nil,
                encodeSeconds: Double? = nil, submitWaitSeconds: Double? = nil,
                readbackSeconds: Double? = nil, gpuCommandBufferSeconds: Double? = nil) {
        self.bufferAllocSeconds = bufferAllocSeconds
        self.uploadSeconds = uploadSeconds
        self.encodeSeconds = encodeSeconds
        self.submitWaitSeconds = submitWaitSeconds
        self.readbackSeconds = readbackSeconds
        self.gpuCommandBufferSeconds = gpuCommandBufferSeconds
    }

    /// Sum of the measured host substages (a `nil` substage contributes 0). Does NOT
    /// include `gpuCommandBufferSeconds` (that is retained separately, not a CPU span).
    public var classifiedSeconds: Double {
        let alloc: Double = bufferAllocSeconds ?? 0
        let upload: Double = uploadSeconds ?? 0
        let encode: Double = encodeSeconds ?? 0
        let submit: Double = submitWaitSeconds ?? 0
        let readback: Double = readbackSeconds ?? 0
        return alloc + upload + encode + submit + readback
    }
}

/// A `PairEvaluator` that can additionally report host-side substage timings for its
/// `evaluate`, using an injected monotonic `clock`. The default `PairEvaluator` path is
/// completely untouched; the runner only calls this when stage instrumentation is
/// requested AND the concrete evaluator conforms, so uninstrumented runs never pay for
/// it and non-conforming evaluators (the CPU reference) simply report a `nil` profile.
public protocol StageProfilingEvaluator: PairEvaluator {
    /// Evaluate while timing the internal host substages with `clock` (monotonic
    /// seconds). Returns the same outcomes `evaluate` would, plus the profile. The
    /// outcomes MUST be byte-for-byte identical to `evaluate` for the same input — the
    /// profile is a pure side observation.
    func evaluateProfiled(pairTapes: [[UInt8]], variant: BFFVariant, stepBudget: Int,
                          clock: @escaping () -> Double)
        throws -> (outcomes: [GPUPairOutcome], profile: EvaluatorStageProfile)
}

// MARK: - Per-epoch top-level stage spans

/// The mutually-exclusive top-level host stage spans measured across ONE `runEpoch`, in
/// seconds. Produced only when `runEpoch` is called with a stage clock; `nil` otherwise.
///
/// `classifiedSeconds` is the sum of these exclusive spans. It is compared against the
/// benchmark's independently-measured epoch wall to produce the unclassified remainder —
/// the spans themselves carry no remainder, because they do not know the outer wall.
public struct HostStageSpans: Sendable, Equatable {
    public var mutationPairingSeconds: Double
    public var packingSeconds: Double
    public var evaluateSeconds: Double
    public var scatterSeconds: Double
    public var counterReductionSeconds: Double
    public var programMetricsSeconds: Double
    public var shadowSeconds: Double
    public var digestSeconds: Double
    /// Sub-decomposition of `evaluateSeconds` (Metal host only); `nil` for the CPU
    /// reference. Not added to `classifiedSeconds`.
    public var evaluatorProfile: EvaluatorStageProfile?

    public init(mutationPairingSeconds: Double, packingSeconds: Double,
                evaluateSeconds: Double, scatterSeconds: Double,
                counterReductionSeconds: Double, programMetricsSeconds: Double,
                shadowSeconds: Double, digestSeconds: Double,
                evaluatorProfile: EvaluatorStageProfile? = nil) {
        self.mutationPairingSeconds = mutationPairingSeconds
        self.packingSeconds = packingSeconds
        self.evaluateSeconds = evaluateSeconds
        self.scatterSeconds = scatterSeconds
        self.counterReductionSeconds = counterReductionSeconds
        self.programMetricsSeconds = programMetricsSeconds
        self.shadowSeconds = shadowSeconds
        self.digestSeconds = digestSeconds
        self.evaluatorProfile = evaluatorProfile
    }

    /// Sum of the mutually-exclusive top-level stages (the evaluator substages are NOT
    /// included — they decompose `evaluateSeconds`, which is already counted once here).
    public var classifiedSeconds: Double {
        mutationPairingSeconds + packingSeconds + evaluateSeconds + scatterSeconds
            + counterReductionSeconds + programMetricsSeconds + shadowSeconds
            + digestSeconds
    }
}

// MARK: - Aggregated attribution (schema-3 result field)

/// The aggregated, machine-readable host-stage attribution for one benchmark cell:
/// per-stage mean ms/epoch over the measured epochs, the explicit signed unclassified
/// remainder, and — when the evaluator profiled — the evaluate substage means.
///
/// Reconciliation invariant (checked by tests): the eight top-level stage means plus
/// `unclassifiedMsPerEpoch` equal the mean epoch wall (ms/epoch). When stage timings
/// overrun the enclosing wall, the signed remainder is negative and
/// `reconciliationValid` is false. `classifiedWallFraction` is the measured classified
/// stage sum divided by the measured wall, and can exceed 1 for invalid timing.
///
/// Every optional field encodes as an explicit JSON `null` when unavailable (same
/// convention as the rest of the schema) so the key set is stable.
public struct HostStageAttribution: Sendable, Equatable, Codable {
    public var measuredEpochCount: Int
    public var attributedEpochCount: Int
    public var attributionComplete: Bool
    public var attributionError: String?

    // Top-level stage means (ms/epoch, measured epochs).
    public var mutationPairingMsPerEpoch: Double?
    public var packingMsPerEpoch: Double?
    public var evaluateMsPerEpoch: Double?
    public var scatterMsPerEpoch: Double?
    public var counterReductionMsPerEpoch: Double?
    public var programMetricsMsPerEpoch: Double?
    public var shadowMsPerEpoch: Double?
    public var digestMsPerEpoch: Double?
    /// The named unclassified/remainder component: mean(epoch wall − Σ classified
    /// stages) ms/epoch. This is signed; negative means the classified stage sum
    /// exceeded the enclosing wall and `reconciliationValid` is false.
    public var unclassifiedMsPerEpoch: Double?
    /// Classified stage sum divided by epoch wall. Can exceed 1 when timing is invalid.
    public var classifiedWallFraction: Double?
    /// True when all measured epochs carried spans and the classified stage sum did not
    /// exceed the enclosing wall. False surfaces incomplete or overrun attribution.
    public var reconciliationValid: Bool
    public var reconciliationError: String?

    // Evaluator substages (Metal host only). `evaluatorProfileAvailable` is the reliable
    // flag; the substage means are `nil` unless every measured epoch carried a profile.
    public var evaluatorProfileAvailable: Bool
    public var evaluatorBufferAllocMsPerEpoch: Double?
    public var evaluatorUploadMsPerEpoch: Double?
    public var evaluatorEncodeMsPerEpoch: Double?
    public var evaluatorSubmitWaitMsPerEpoch: Double?
    public var evaluatorReadbackMsPerEpoch: Double?
    /// `evaluate` mean minus the sum of the evaluate substage means (ms/epoch): the part
    /// of the evaluate span not attributed to a named substage. This is signed; negative
    /// means the reported evaluator substages exceeded the enclosing evaluate span.
    /// `nil` when no profile.
    public var evaluatorUnclassifiedMsPerEpoch: Double?
    public var evaluatorReconciliationValid: Bool?
    public var evaluatorReconciliationError: String?

    public init(mutationPairingMsPerEpoch: Double, packingMsPerEpoch: Double,
                evaluateMsPerEpoch: Double, scatterMsPerEpoch: Double,
                counterReductionMsPerEpoch: Double, programMetricsMsPerEpoch: Double,
                shadowMsPerEpoch: Double, digestMsPerEpoch: Double,
                unclassifiedMsPerEpoch: Double, classifiedWallFraction: Double,
                reconciliationValid: Bool, reconciliationError: String? = nil,
                evaluatorProfileAvailable: Bool,
                evaluatorBufferAllocMsPerEpoch: Double? = nil,
                evaluatorUploadMsPerEpoch: Double? = nil,
                evaluatorEncodeMsPerEpoch: Double? = nil,
                evaluatorSubmitWaitMsPerEpoch: Double? = nil,
                evaluatorReadbackMsPerEpoch: Double? = nil,
                evaluatorUnclassifiedMsPerEpoch: Double? = nil,
                evaluatorReconciliationValid: Bool? = nil,
                evaluatorReconciliationError: String? = nil,
                measuredEpochCount: Int = 0,
                attributedEpochCount: Int = 0,
                attributionComplete: Bool = true,
                attributionError: String? = nil) {
        self.measuredEpochCount = measuredEpochCount
        self.attributedEpochCount = attributedEpochCount
        self.attributionComplete = attributionComplete
        self.attributionError = attributionError
        self.mutationPairingMsPerEpoch = mutationPairingMsPerEpoch
        self.packingMsPerEpoch = packingMsPerEpoch
        self.evaluateMsPerEpoch = evaluateMsPerEpoch
        self.scatterMsPerEpoch = scatterMsPerEpoch
        self.counterReductionMsPerEpoch = counterReductionMsPerEpoch
        self.programMetricsMsPerEpoch = programMetricsMsPerEpoch
        self.shadowMsPerEpoch = shadowMsPerEpoch
        self.digestMsPerEpoch = digestMsPerEpoch
        self.unclassifiedMsPerEpoch = unclassifiedMsPerEpoch
        self.classifiedWallFraction = classifiedWallFraction
        self.reconciliationValid = reconciliationValid
        self.reconciliationError = reconciliationError
        self.evaluatorProfileAvailable = evaluatorProfileAvailable
        self.evaluatorBufferAllocMsPerEpoch = evaluatorBufferAllocMsPerEpoch
        self.evaluatorUploadMsPerEpoch = evaluatorUploadMsPerEpoch
        self.evaluatorEncodeMsPerEpoch = evaluatorEncodeMsPerEpoch
        self.evaluatorSubmitWaitMsPerEpoch = evaluatorSubmitWaitMsPerEpoch
        self.evaluatorReadbackMsPerEpoch = evaluatorReadbackMsPerEpoch
        self.evaluatorUnclassifiedMsPerEpoch = evaluatorUnclassifiedMsPerEpoch
        self.evaluatorReconciliationValid = evaluatorReconciliationValid
        self.evaluatorReconciliationError = evaluatorReconciliationError
    }

    /// Fold measured epochs' `(wallSeconds, spans)` into the attribution. `wallSeconds`
    /// is the benchmark's epoch execution wall for that epoch (the same value the result
    /// aggregates for throughput); `spans` is that epoch's `HostStageSpans`. Returns
    /// `nil` when there is nothing to attribute (no measured epochs). When any measured
    /// epoch lacks spans, returns a stable incomplete attribution object with null stage
    /// means rather than reconciling a compacted subset against all-epoch wall.
    public static func aggregate(measured: [(wallSeconds: Double, spans: HostStageSpans?)])
        -> HostStageAttribution? {
        guard !measured.isEmpty else { return nil }
        let attributed = measured.filter { $0.spans != nil }.count
        guard attributed == measured.count else {
            let missing = measured.count - attributed
            return HostStageAttribution.incomplete(
                measuredEpochCount: measured.count,
                attributedEpochCount: attributed,
                error: "missing host stage spans for \(missing) of \(measured.count) measured epochs")
        }
        let n = Double(measured.count)
        let ms = 1000.0 / n     // per-epoch mean, milliseconds

        var mut = 0.0, pack = 0.0, eval = 0.0, scat = 0.0
        var counter = 0.0, metrics = 0.0, shadow = 0.0, digest = 0.0
        var wall = 0.0
        for m in measured {
            let spans = m.spans!
            mut += spans.mutationPairingSeconds
            pack += spans.packingSeconds
            eval += spans.evaluateSeconds
            scat += spans.scatterSeconds
            counter += spans.counterReductionSeconds
            metrics += spans.programMetricsSeconds
            shadow += spans.shadowSeconds
            digest += spans.digestSeconds
            wall += m.wallSeconds
        }
        let classified = mut + pack + eval + scat + counter + metrics + shadow + digest
        let unclassified = wall - classified
        let classifiedFraction = wall > 0 ? classified / wall : 0
        let overrunMs = (classified - wall) * ms
        let reconciliationValid = overrunMs <= 0
        let reconciliationError = reconciliationValid ? nil
            : String(format: "classified host stages exceed epoch wall by %.6f ms/epoch",
                     overrunMs)

        // Evaluator substages are available only if EVERY measured epoch carried a
        // profile (a mixed run reports "not available" rather than a partial mean).
        var profiles: [EvaluatorStageProfile] = []
        profiles.reserveCapacity(measured.count)
        for m in measured {
            if let profile = m.spans!.evaluatorProfile {
                profiles.append(profile)
            }
        }
        let profileAvailable = profiles.count == measured.count && !profiles.isEmpty

        func meanField(_ pick: (EvaluatorStageProfile) -> Double?) -> Double? {
            guard profileAvailable else { return nil }
            // A field is reported only when present on every profile; otherwise nil.
            var sum = 0.0
            for p in profiles {
                guard let v = pick(p) else { return nil }
                sum += v
            }
            return sum * ms
        }

        let allocMs = meanField { $0.bufferAllocSeconds }
        let uploadMs = meanField { $0.uploadSeconds }
        let encodeMs = meanField { $0.encodeSeconds }
        let submitMs = meanField { $0.submitWaitSeconds }
        let readbackMs = meanField { $0.readbackSeconds }
        // Evaluate-internal remainder: the evaluate mean minus whatever substages were
        // uniformly available. Signed, so an overrun is surfaced instead of masked.
        let evaluatorUnclassifiedMs: Double? = profileAvailable
            ? (eval * ms
                - (allocMs ?? 0) - (uploadMs ?? 0) - (encodeMs ?? 0)
                - (submitMs ?? 0) - (readbackMs ?? 0))
            : nil
        let evaluatorValid = evaluatorUnclassifiedMs.map { $0 >= 0 }
        let evaluatorError = evaluatorValid == false
            ? String(format: "evaluator substages exceed evaluate span by %.6f ms/epoch",
                     -(evaluatorUnclassifiedMs ?? 0))
            : nil

        return HostStageAttribution(
            mutationPairingMsPerEpoch: mut * ms,
            packingMsPerEpoch: pack * ms,
            evaluateMsPerEpoch: eval * ms,
            scatterMsPerEpoch: scat * ms,
            counterReductionMsPerEpoch: counter * ms,
            programMetricsMsPerEpoch: metrics * ms,
            shadowMsPerEpoch: shadow * ms,
            digestMsPerEpoch: digest * ms,
            unclassifiedMsPerEpoch: unclassified * ms,
            classifiedWallFraction: classifiedFraction,
            reconciliationValid: reconciliationValid,
            reconciliationError: reconciliationError,
            evaluatorProfileAvailable: profileAvailable,
            evaluatorBufferAllocMsPerEpoch: allocMs,
            evaluatorUploadMsPerEpoch: uploadMs,
            evaluatorEncodeMsPerEpoch: encodeMs,
            evaluatorSubmitWaitMsPerEpoch: submitMs,
            evaluatorReadbackMsPerEpoch: readbackMs,
            evaluatorUnclassifiedMsPerEpoch: evaluatorUnclassifiedMs,
            evaluatorReconciliationValid: evaluatorValid,
            evaluatorReconciliationError: evaluatorError,
            measuredEpochCount: measured.count,
            attributedEpochCount: attributed)
    }

    private static func incomplete(measuredEpochCount: Int, attributedEpochCount: Int,
                                   error: String) -> HostStageAttribution {
        HostStageAttribution(
            mutationPairingMsPerEpoch: 0,
            packingMsPerEpoch: 0,
            evaluateMsPerEpoch: 0,
            scatterMsPerEpoch: 0,
            counterReductionMsPerEpoch: 0,
            programMetricsMsPerEpoch: 0,
            shadowMsPerEpoch: 0,
            digestMsPerEpoch: 0,
            unclassifiedMsPerEpoch: 0,
            classifiedWallFraction: 0,
            reconciliationValid: false,
            reconciliationError: error,
            evaluatorProfileAvailable: false,
            measuredEpochCount: measuredEpochCount,
            attributedEpochCount: attributedEpochCount,
            attributionComplete: false,
            attributionError: error)
            .nullingMeasurements()
    }

    private func nullingMeasurements() -> HostStageAttribution {
        var copy = self
        copy.mutationPairingMsPerEpoch = nil
        copy.packingMsPerEpoch = nil
        copy.evaluateMsPerEpoch = nil
        copy.scatterMsPerEpoch = nil
        copy.counterReductionMsPerEpoch = nil
        copy.programMetricsMsPerEpoch = nil
        copy.shadowMsPerEpoch = nil
        copy.digestMsPerEpoch = nil
        copy.unclassifiedMsPerEpoch = nil
        copy.classifiedWallFraction = nil
        return copy
    }
}

// MARK: - Stable JSON encoding (explicit nulls for unavailable measurements)

extension HostStageAttribution {
    enum CodingKeys: String, CodingKey {
        case measuredEpochCount, attributedEpochCount, attributionComplete,
             attributionError, mutationPairingMsPerEpoch, packingMsPerEpoch,
             evaluateMsPerEpoch,
             scatterMsPerEpoch, counterReductionMsPerEpoch, programMetricsMsPerEpoch,
             shadowMsPerEpoch, digestMsPerEpoch, unclassifiedMsPerEpoch,
             classifiedWallFraction, reconciliationValid, reconciliationError,
             evaluatorProfileAvailable,
             evaluatorBufferAllocMsPerEpoch, evaluatorUploadMsPerEpoch,
             evaluatorEncodeMsPerEpoch, evaluatorSubmitWaitMsPerEpoch,
             evaluatorReadbackMsPerEpoch, evaluatorUnclassifiedMsPerEpoch,
             evaluatorReconciliationValid, evaluatorReconciliationError
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(measuredEpochCount, forKey: .measuredEpochCount)
        try c.encode(attributedEpochCount, forKey: .attributedEpochCount)
        try c.encode(attributionComplete, forKey: .attributionComplete)
        try c.encodeOrNull(attributionError, forKey: .attributionError)
        try c.encodeOrNull(mutationPairingMsPerEpoch, forKey: .mutationPairingMsPerEpoch)
        try c.encodeOrNull(packingMsPerEpoch, forKey: .packingMsPerEpoch)
        try c.encodeOrNull(evaluateMsPerEpoch, forKey: .evaluateMsPerEpoch)
        try c.encodeOrNull(scatterMsPerEpoch, forKey: .scatterMsPerEpoch)
        try c.encodeOrNull(counterReductionMsPerEpoch, forKey: .counterReductionMsPerEpoch)
        try c.encodeOrNull(programMetricsMsPerEpoch, forKey: .programMetricsMsPerEpoch)
        try c.encodeOrNull(shadowMsPerEpoch, forKey: .shadowMsPerEpoch)
        try c.encodeOrNull(digestMsPerEpoch, forKey: .digestMsPerEpoch)
        try c.encodeOrNull(unclassifiedMsPerEpoch, forKey: .unclassifiedMsPerEpoch)
        try c.encodeOrNull(classifiedWallFraction, forKey: .classifiedWallFraction)
        try c.encode(reconciliationValid, forKey: .reconciliationValid)
        try c.encodeOrNull(reconciliationError, forKey: .reconciliationError)
        try c.encode(evaluatorProfileAvailable, forKey: .evaluatorProfileAvailable)
        try c.encodeOrNull(evaluatorBufferAllocMsPerEpoch,
                           forKey: .evaluatorBufferAllocMsPerEpoch)
        try c.encodeOrNull(evaluatorUploadMsPerEpoch, forKey: .evaluatorUploadMsPerEpoch)
        try c.encodeOrNull(evaluatorEncodeMsPerEpoch, forKey: .evaluatorEncodeMsPerEpoch)
        try c.encodeOrNull(evaluatorSubmitWaitMsPerEpoch,
                           forKey: .evaluatorSubmitWaitMsPerEpoch)
        try c.encodeOrNull(evaluatorReadbackMsPerEpoch,
                           forKey: .evaluatorReadbackMsPerEpoch)
        try c.encodeOrNull(evaluatorUnclassifiedMsPerEpoch,
                           forKey: .evaluatorUnclassifiedMsPerEpoch)
        try c.encodeOrNull(evaluatorReconciliationValid,
                           forKey: .evaluatorReconciliationValid)
        try c.encodeOrNull(evaluatorReconciliationError,
                           forKey: .evaluatorReconciliationError)
    }
}
