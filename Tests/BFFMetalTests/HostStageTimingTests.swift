import XCTest
import Foundation
import BFFOracle
@testable import BFFMetal

/// Coverage for the opt-in host-stage timing attribution. All of it runs on any platform
/// (no Metal): the CPU reference evaluator drives the top-level stages, and a synthetic
/// `StageProfilingEvaluator` stands in for the Metal evaluator to exercise the substage
/// path the real GPU host takes natively. Nothing here claims a native GPU timing.
final class HostStageTimingTests: XCTestCase {

    // MARK: - Synthetic profiling evaluator (stands in for the Metal host off-Metal)

    /// Wraps the CPU reference and, on the profiled path, records deterministic substage
    /// spans by reading the injected clock between phases — exactly the shape
    /// `MetalBFFEvaluator.evaluateProfiled` produces, but runnable on Linux. The outcomes
    /// are byte-for-byte the plain CPU evaluate.
    private struct ProfilingCPUEvaluator: StageProfilingEvaluator {
        let base = CPUPairEvaluator()
        /// A fake, retained-separately GPU command-buffer time (seconds).
        let gpuSeconds: Double?

        func evaluate(pairTapes: [[UInt8]], variant: BFFVariant,
                      stepBudget: Int) -> [GPUPairOutcome] {
            base.evaluate(pairTapes: pairTapes, variant: variant, stepBudget: stepBudget)
        }

        func evaluateProfiled(pairTapes: [[UInt8]], variant: BFFVariant, stepBudget: Int,
                              clock: @escaping () -> Double)
            throws -> (outcomes: [GPUPairOutcome], profile: EvaluatorStageProfile) {
            let b0 = clock()
            let b1 = clock()                       // alloc = b1 - b0
            let b2 = clock()                       // upload = b2 - b1
            let b3 = clock()                       // encode = b3 - b2
            let outcomes = base.evaluate(pairTapes: pairTapes, variant: variant,
                                         stepBudget: stepBudget)
            let b4 = clock()                       // submit+wait = b4 - b3
            let b5 = clock()                       // readback = b5 - b4
            let profile = EvaluatorStageProfile(
                bufferAllocSeconds: b1 - b0, uploadSeconds: b2 - b1,
                encodeSeconds: b3 - b2, submitWaitSeconds: b4 - b3,
                readbackSeconds: b5 - b4, gpuCommandBufferSeconds: gpuSeconds)
            return (outcomes, profile)
        }
    }

    /// A profiling evaluator that always throws on the profiled path (availability/error).
    private struct ThrowingProfilingEvaluator: StageProfilingEvaluator {
        struct Boom: Error {}
        func evaluate(pairTapes: [[UInt8]], variant: BFFVariant,
                      stepBudget: Int) throws -> [GPUPairOutcome] { throw Boom() }
        func evaluateProfiled(pairTapes: [[UInt8]], variant: BFFVariant, stepBudget: Int,
                              clock: @escaping () -> Double)
            throws -> (outcomes: [GPUPairOutcome], profile: EvaluatorStageProfile) {
            throw Boom()
        }
    }

    // MARK: - Deterministic equivalence: instrumented == uninstrumented

    /// Timing enablement must not perturb the simulation. Two runners over the same
    /// seed/config: one with a stage clock, one without. The soup, digest, counters, and
    /// shadow are byte-for-byte identical every epoch; only the presence of
    /// `stageBreakdown` differs.
    func testRunEpochInstrumentedMatchesUninstrumentedExactly() throws {
        let cfg = try SoupConfig(seed: 4242, programCount: 32, mutationP32: 1 << 22,
                                 shadowSampleCount: 8, initMode: .opcode)
        var plain = SoupRunner(config: cfg)
        var timed = SoupRunner(config: cfg)
        var clock = 0.0

        for _ in 0..<6 {
            let p = try plain.runEpoch(using: CPUPairEvaluator())
            let t = try timed.runEpoch(using: CPUPairEvaluator(),
                                       stageClock: { clock += 1; return clock })

            XCTAssertEqual(p.counters, t.counters, "counters identical")
            XCTAssertEqual(p.digest, t.digest, "digest identical")
            XCTAssertEqual(p.shadowChecked, t.shadowChecked)
            XCTAssertEqual(p.shadowMismatches.count, t.shadowMismatches.count)
            XCTAssertEqual(p.metrics, t.metrics, "per-program metrics identical")
            XCTAssertNil(p.stageBreakdown, "uninstrumented carries no breakdown")
            XCTAssertNotNil(t.stageBreakdown, "instrumented carries a breakdown")
        }
        XCTAssertEqual(plain.soup, timed.soup, "final soup identical")
        XCTAssertEqual(plain.digest, timed.digest)
    }

    /// The top-level spans are mutually exclusive and non-negative, and their sum is
    /// within the epoch's total instrumented span (marks are monotone).
    func testRunEpochSpansAreOrderedAndNonNegative() throws {
        let cfg = try SoupConfig(seed: 7, programCount: 16, mutationP32: 1 << 22,
                                 shadowSampleCount: 4, initMode: .opcode)
        var runner = SoupRunner(config: cfg)
        var clock = 0.0
        let report = try runner.runEpoch(using: CPUPairEvaluator(),
                                         stageClock: { clock += 1; return clock })
        let s = try XCTUnwrap(report.stageBreakdown)
        for span in [s.mutationPairingSeconds, s.packingSeconds, s.evaluateSeconds,
                     s.scatterSeconds, s.counterReductionSeconds, s.programMetricsSeconds,
                     s.shadowSeconds, s.digestSeconds] {
            XCTAssertGreaterThanOrEqual(span, 0, "no negative span")
        }
        XCTAssertGreaterThan(s.classifiedSeconds, 0)
        XCTAssertNil(s.evaluatorProfile, "CPU reference does not profile substages")
    }

    // MARK: - Aggregation math + reconciliation

    private func spans(mut: Double, pack: Double, eval: Double, scat: Double,
                       counter: Double, metrics: Double, shadow: Double, digest: Double,
                       profile: EvaluatorStageProfile? = nil) -> HostStageSpans {
        HostStageSpans(mutationPairingSeconds: mut, packingSeconds: pack,
                       evaluateSeconds: eval, scatterSeconds: scat,
                       counterReductionSeconds: counter, programMetricsSeconds: metrics,
                       shadowSeconds: shadow, digestSeconds: digest,
                       evaluatorProfile: profile)
    }

    /// Stage means, the explicit remainder, and the classified fraction reconcile: the
    /// eight stage means plus the unclassified remainder equal the mean epoch wall.
    func testAttributionMeansAndRemainderReconcile() throws {
        // Two epochs. classified sum per epoch = 0.1+0.1+0.3+0.05·5 = 0.75; wall = 1.0
        // => remainder 0.25.
        let s = spans(mut: 0.1, pack: 0.1, eval: 0.3, scat: 0.05,
                      counter: 0.05, metrics: 0.05, shadow: 0.05, digest: 0.05)
        let a = try XCTUnwrap(HostStageAttribution.aggregate(
            measured: [(wallSeconds: 1.0, spans: s), (wallSeconds: 1.0, spans: s)]))

        XCTAssertTrue(a.attributionComplete)
        XCTAssertEqual(a.measuredEpochCount, 2)
        XCTAssertEqual(a.attributedEpochCount, 2)
        XCTAssertNil(a.attributionError)
        XCTAssertEqual(a.mutationPairingMsPerEpoch!, 100, accuracy: 1e-9)
        XCTAssertEqual(a.evaluateMsPerEpoch!, 300, accuracy: 1e-9)
        XCTAssertEqual(a.digestMsPerEpoch!, 50, accuracy: 1e-9)
        XCTAssertEqual(a.unclassifiedMsPerEpoch!, 250, accuracy: 1e-6)  // (1.0-0.75)*1000

        let sumStages = a.mutationPairingMsPerEpoch! + a.packingMsPerEpoch!
            + a.evaluateMsPerEpoch! + a.scatterMsPerEpoch! + a.counterReductionMsPerEpoch!
            + a.programMetricsMsPerEpoch! + a.shadowMsPerEpoch! + a.digestMsPerEpoch!
        XCTAssertEqual(sumStages + a.unclassifiedMsPerEpoch!, 1000, accuracy: 1e-6,
                       "stage means + remainder == mean epoch wall")
        XCTAssertEqual(a.classifiedWallFraction!, 0.75, accuracy: 1e-9)
        XCTAssertTrue(a.reconciliationValid)
        XCTAssertNil(a.reconciliationError)
        XCTAssertFalse(a.evaluatorProfileAvailable, "no evaluator profile present")
        XCTAssertNil(a.evaluatorBufferAllocMsPerEpoch)
        XCTAssertNil(a.evaluatorUnclassifiedMsPerEpoch)
        XCTAssertNil(a.evaluatorReconciliationValid)
        XCTAssertNil(a.evaluatorReconciliationError)
    }

    /// If classified stages exceed the measured wall, the signed remainder goes
    /// negative and the stable reconciliation fields surface the invalid timing.
    func testAttributionRemainderIsSignedWhenClassifiedExceedsWall() throws {
        let s = spans(mut: 0.6, pack: 0.6, eval: 0.6, scat: 0, counter: 0,
                      metrics: 0, shadow: 0, digest: 0)             // classified 1.8
        let a = try XCTUnwrap(HostStageAttribution.aggregate(measured: [(wallSeconds: 1.0, spans: s)]))
        XCTAssertEqual(a.unclassifiedMsPerEpoch!, -800, accuracy: 1e-9)
        XCTAssertEqual(a.classifiedWallFraction!, 1.8, accuracy: 1e-9)
        XCTAssertFalse(a.reconciliationValid)
        XCTAssertNotNil(a.reconciliationError)
        XCTAssertEqual((a.mutationPairingMsPerEpoch! + a.packingMsPerEpoch!
                        + a.evaluateMsPerEpoch! + a.unclassifiedMsPerEpoch!),
                       1000, accuracy: 1e-9)
    }

    func testTopLevelAttributionOverrunToleranceBoundary() throws {
        let tolerance = TimingReconciliationTolerance.seconds(enclosingSeconds: 1.0,
                                                              classifiedSeconds: 1.0)
        let edgeStep = tolerance * 1e-6
        let within = tolerance - edgeStep
        let beyond = tolerance + edgeStep

        let withinSpans = spans(mut: 1.0 + within, pack: 0, eval: 0, scat: 0,
                                counter: 0, metrics: 0, shadow: 0, digest: 0)
        let withinAttribution = try XCTUnwrap(HostStageAttribution.aggregate(
            measured: [(wallSeconds: 1.0, spans: withinSpans)]))
        XCTAssertLessThan(withinAttribution.unclassifiedMsPerEpoch!, 0)
        XCTAssertEqual(withinAttribution.unclassifiedMsPerEpoch!, -within * 1000,
                       accuracy: 1e-12)
        XCTAssertTrue(withinAttribution.reconciliationValid)
        XCTAssertNil(withinAttribution.reconciliationError)

        let beyondSpans = spans(mut: 1.0 + beyond, pack: 0, eval: 0, scat: 0,
                                counter: 0, metrics: 0, shadow: 0, digest: 0)
        let beyondAttribution = try XCTUnwrap(HostStageAttribution.aggregate(
            measured: [(wallSeconds: 1.0, spans: beyondSpans)]))
        XCTAssertLessThan(beyondAttribution.unclassifiedMsPerEpoch!, 0)
        XCTAssertEqual(beyondAttribution.unclassifiedMsPerEpoch!, -beyond * 1000,
                       accuracy: 1e-12)
        XCTAssertFalse(beyondAttribution.reconciliationValid)
        XCTAssertNotNil(beyondAttribution.reconciliationError)
    }

    /// Instrumented attribution requires every measured epoch to carry spans. A mixed
    /// set is surfaced as incomplete with stable null measurements, never compacted into
    /// a subset that reconciles against the all-epoch wall.
    func testAttributionSurfacesIncompleteMeasuredSpans() throws {
        let s = spans(mut: 0.1, pack: 0.1, eval: 0.2, scat: 0, counter: 0,
                      metrics: 0, shadow: 0, digest: 0)
        let a = try XCTUnwrap(HostStageAttribution.aggregate(
            measured: [(wallSeconds: 1.0, spans: s), (wallSeconds: 1.0, spans: nil)]))
        XCTAssertFalse(a.attributionComplete)
        XCTAssertEqual(a.measuredEpochCount, 2)
        XCTAssertEqual(a.attributedEpochCount, 1)
        XCTAssertNotNil(a.attributionError)
        XCTAssertFalse(a.reconciliationValid)
        XCTAssertNotNil(a.reconciliationError)
        XCTAssertNil(a.mutationPairingMsPerEpoch)
        XCTAssertNil(a.unclassifiedMsPerEpoch)
        XCTAssertNil(a.classifiedWallFraction)
    }

    func testAggregatorDoesNotCompactMixedMeasuredSpanAvailability() throws {
        let one = GPUPairOutcome(finalTape: [UInt8](repeating: 0, count: BFF.pairTapeSize),
                                 steps: 10, noopSteps: 2, copyWrites: 1, loopOps: 0,
                                 halt: UInt32(HaltReason.budget.rawValue))
        let counters = EpochCounters.reduce(epoch: 1, mutationCount: 0, outcomes: [one])
        let s = spans(mut: 0.1, pack: 0.1, eval: 0.2, scat: 0, counter: 0,
                      metrics: 0, shadow: 0, digest: 0)
        let observations = [
            EpochObservation(epoch: 1, isWarmup: false, wallSeconds: 1.0,
                             gpuSeconds: nil, counters: counters, shadowChecked: 0,
                             shadowMismatches: 0, signals: nil, hostStageSpans: s),
            EpochObservation(epoch: 2, isWarmup: false, wallSeconds: 1.0,
                             gpuSeconds: nil, counters: counters, shadowChecked: 0,
                             shadowMismatches: 0, signals: nil, hostStageSpans: nil)
        ]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 2)
        let result = BenchmarkAggregator.aggregate(
            config: cfg, deviceName: nil, initialSignals: nil, observations: observations,
            finalDigestHex: "00", maxRSSBytes: nil, instrumentationEnabled: true)

        let a = try XCTUnwrap(result.hostStageAttribution)
        XCTAssertFalse(a.attributionComplete)
        XCTAssertEqual(a.measuredEpochCount, 2)
        XCTAssertEqual(a.attributedEpochCount, 1)
        XCTAssertNil(a.mutationPairingMsPerEpoch)
        XCTAssertNil(a.unclassifiedMsPerEpoch)
    }

    /// Evaluator substages are reported only when EVERY measured epoch carried a profile;
    /// the evaluate-internal remainder is evaluate − Σ substages.
    func testAttributionEvaluatorSubstagesRequireUniformAvailability() throws {
        let profile = EvaluatorStageProfile(
            bufferAllocSeconds: 0.02, uploadSeconds: 0.03, encodeSeconds: 0.05,
            submitWaitSeconds: 0.15, readbackSeconds: 0.04, gpuCommandBufferSeconds: 0.10)
        let withP = spans(mut: 0.05, pack: 0.05, eval: 0.30, scat: 0.02, counter: 0.02,
                          metrics: 0.0, shadow: 0.0, digest: 0.01, profile: profile)
        let withoutP = spans(mut: 0.05, pack: 0.05, eval: 0.30, scat: 0.02, counter: 0.02,
                             metrics: 0.0, shadow: 0.0, digest: 0.01, profile: nil)

        // All profiled: substages present, availability true.
        let all = try XCTUnwrap(HostStageAttribution.aggregate(
            measured: [(wallSeconds: 0.5, spans: withP), (wallSeconds: 0.5, spans: withP)]))
        XCTAssertTrue(all.evaluatorProfileAvailable)
        XCTAssertEqual(all.evaluatorBufferAllocMsPerEpoch!, 20, accuracy: 1e-9)
        XCTAssertEqual(all.evaluatorSubmitWaitMsPerEpoch!, 150, accuracy: 1e-9)
        // evaluate 300 ms − (20+30+50+150+40)=290 => 10 ms unclassified inside evaluate.
        XCTAssertEqual(all.evaluatorUnclassifiedMsPerEpoch!, 10, accuracy: 1e-6)
        XCTAssertEqual(all.evaluatorReconciliationValid, true)
        XCTAssertNil(all.evaluatorReconciliationError)

        // Mixed: one epoch lacks a profile -> not available, substage means nil.
        let mixed = try XCTUnwrap(HostStageAttribution.aggregate(
            measured: [(wallSeconds: 0.5, spans: withP), (wallSeconds: 0.5, spans: withoutP)]))
        XCTAssertFalse(mixed.evaluatorProfileAvailable)
        XCTAssertNil(mixed.evaluatorBufferAllocMsPerEpoch)
        XCTAssertNil(mixed.evaluatorUnclassifiedMsPerEpoch)
        XCTAssertNil(mixed.evaluatorReconciliationValid)
    }

    /// Evaluator substages that exceed the enclosing evaluate span are not masked; the
    /// signed evaluator remainder goes negative and the evaluator reconciliation fields
    /// carry the error.
    func testEvaluatorSubstageOverrunIsSurfaced() throws {
        let profile = EvaluatorStageProfile(
            bufferAllocSeconds: 0.10, uploadSeconds: 0.10, encodeSeconds: 0.10,
            submitWaitSeconds: 0.10, readbackSeconds: 0.10)
        let s = spans(mut: 0.05, pack: 0.05, eval: 0.30, scat: 0.02, counter: 0.02,
                      metrics: 0, shadow: 0, digest: 0.01, profile: profile)
        let a = try XCTUnwrap(HostStageAttribution.aggregate(measured: [(wallSeconds: 0.6, spans: s)]))
        XCTAssertTrue(a.evaluatorProfileAvailable)
        XCTAssertEqual(a.evaluatorUnclassifiedMsPerEpoch!, -200, accuracy: 1e-9)
        XCTAssertEqual(a.evaluatorReconciliationValid, false)
        XCTAssertNotNil(a.evaluatorReconciliationError)
    }

    func testEvaluatorSubstageOverrunToleranceBoundary() throws {
        let tolerance = TimingReconciliationTolerance.seconds(enclosingSeconds: 1.0,
                                                              classifiedSeconds: 1.0)
        let edgeStep = tolerance * 1e-6
        let within = tolerance - edgeStep
        let beyond = tolerance + edgeStep

        func attribution(overrun: Double) throws -> HostStageAttribution {
            let profile = EvaluatorStageProfile(
                bufferAllocSeconds: 1.0 + overrun, uploadSeconds: 0,
                encodeSeconds: 0, submitWaitSeconds: 0, readbackSeconds: 0)
            let s = spans(mut: 0, pack: 0, eval: 1.0, scat: 0, counter: 0,
                          metrics: 0, shadow: 0, digest: 0, profile: profile)
            return try XCTUnwrap(HostStageAttribution.aggregate(
                measured: [(wallSeconds: 1.1, spans: s)]))
        }

        let withinAttribution = try attribution(overrun: within)
        XCTAssertLessThan(withinAttribution.evaluatorUnclassifiedMsPerEpoch!, 0)
        XCTAssertEqual(withinAttribution.evaluatorUnclassifiedMsPerEpoch!,
                       -within * 1000, accuracy: 1e-12)
        XCTAssertEqual(withinAttribution.evaluatorReconciliationValid, true)
        XCTAssertNil(withinAttribution.evaluatorReconciliationError)

        let beyondAttribution = try attribution(overrun: beyond)
        XCTAssertLessThan(beyondAttribution.evaluatorUnclassifiedMsPerEpoch!, 0)
        XCTAssertEqual(beyondAttribution.evaluatorUnclassifiedMsPerEpoch!,
                       -beyond * 1000, accuracy: 1e-12)
        XCTAssertEqual(beyondAttribution.evaluatorReconciliationValid, false)
        XCTAssertNotNil(beyondAttribution.evaluatorReconciliationError)
    }

    /// The retained GPU command-buffer time is separate from the CPU submit+wait span and
    /// is never folded into the classified CPU sum.
    func testEvaluatorProfileKeepsGpuSeparateFromCpuSpans() {
        let p = EvaluatorStageProfile(
            bufferAllocSeconds: 0.01, uploadSeconds: 0.01, encodeSeconds: 0.01,
            submitWaitSeconds: 0.20, readbackSeconds: 0.01, gpuCommandBufferSeconds: 0.18)
        // classifiedSeconds is the CPU substage sum only (no GPU time).
        XCTAssertEqual(p.classifiedSeconds, 0.24, accuracy: 1e-9)
    }

    // MARK: - End-to-end through the runner

    /// Instrumentation on: `instrumentationEnabled` true, an attribution is produced, and
    /// its stage means + remainder reconcile to the reported `wallMsPerEpoch`. The CPU
    /// reference does not profile, so evaluator substages are nil / not available.
    func testBenchmarkRunnerInstrumentedReconcilesToWall() throws {
        let cfg = BenchmarkConfig(seed: 5, programCount: 32, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 6)
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        let r = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: false, includeCompression: false,
                           instrumentStages: true),
            readMaxRSSBytes: { nil },
            now: { clock += 1; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, inc in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: inc) })

        XCTAssertTrue(r.instrumentationEnabled)
        let a = try XCTUnwrap(r.hostStageAttribution)
        let sum = a.mutationPairingMsPerEpoch! + a.packingMsPerEpoch! + a.evaluateMsPerEpoch!
            + a.scatterMsPerEpoch! + a.counterReductionMsPerEpoch!
            + a.programMetricsMsPerEpoch! + a.shadowMsPerEpoch! + a.digestMsPerEpoch!
        XCTAssertEqual(sum + a.unclassifiedMsPerEpoch!, r.wallMsPerEpoch, accuracy: 1e-6,
                       "attribution reconciles to the measured epoch wall")
        XCTAssertTrue(a.reconciliationValid)
        XCTAssertNil(a.reconciliationError)
        XCTAssertGreaterThanOrEqual(a.unclassifiedMsPerEpoch!, 0)
        XCTAssertGreaterThanOrEqual(a.classifiedWallFraction!, 0)
        XCTAssertFalse(a.evaluatorProfileAvailable, "CPU reference has no substages")
        XCTAssertNil(a.evaluatorSubmitWaitMsPerEpoch)
    }

    /// Instrumentation off: `instrumentationEnabled` false and `hostStageAttribution` is
    /// nil — but the digest, counters, and throughput denominators are byte-for-byte
    /// identical to the instrumented run, proving timing never perturbs the run.
    func testBenchmarkRunnerInstrumentationDoesNotChangeResults() throws {
        let cfg = BenchmarkConfig(seed: 11, programCount: 24, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 5)
        let soupConfig = try cfg.soupConfig()

        func run(_ instrument: Bool) throws -> BenchmarkResult {
            var clock = 0.0
            return try BenchmarkRunner.run(
                config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
                deviceName: nil,
                options: .init(analyzeSignals: false, includeCompression: false,
                               instrumentStages: instrument),
                readMaxRSSBytes: { nil },
                now: { clock += 1; return clock },
                gpuSecondsAfterEpoch: { nil },
                measureSignals: { soup, inc in
                    SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                        includeCompression: inc) })
        }
        let on = try run(true)
        let off = try run(false)

        XCTAssertTrue(on.instrumentationEnabled)
        XCTAssertNotNil(on.hostStageAttribution)
        XCTAssertFalse(off.instrumentationEnabled)
        XCTAssertNil(off.hostStageAttribution, "attribution null when off")

        XCTAssertEqual(on.finalDigest, off.finalDigest, "digest identical")
        XCTAssertEqual(on.totalPairs, off.totalPairs)
        XCTAssertEqual(on.totalRawSteps, off.totalRawSteps)
        XCTAssertEqual(on.totalCommandSteps, off.totalCommandSteps)
        XCTAssertEqual(on.haltBudget, off.haltBudget)
        XCTAssertEqual(on.measuredEpochs, off.measuredEpochs)
    }

    /// The profiled evaluator path (the shape the Metal host takes) surfaces evaluator
    /// substages: availability true, each substage mean present, the GPU time retained
    /// separately, and the evaluate substages summing within the evaluate span.
    func testBenchmarkRunnerWithProfilingEvaluatorSurfacesSubstages() throws {
        let cfg = BenchmarkConfig(seed: 9, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 4)
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        let r = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig,
            evaluator: ProfilingCPUEvaluator(gpuSeconds: 0.5),
            deviceName: "synthetic",
            options: .init(analyzeSignals: false, includeCompression: false,
                           instrumentStages: true),
            readMaxRSSBytes: { nil },
            now: { clock += 1; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, inc in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: inc) })

        let a = try XCTUnwrap(r.hostStageAttribution)
        XCTAssertTrue(a.evaluatorProfileAvailable, "profiled evaluator reports substages")
        XCTAssertNotNil(a.evaluatorBufferAllocMsPerEpoch)
        XCTAssertNotNil(a.evaluatorUploadMsPerEpoch)
        XCTAssertNotNil(a.evaluatorEncodeMsPerEpoch)
        XCTAssertNotNil(a.evaluatorSubmitWaitMsPerEpoch)
        XCTAssertNotNil(a.evaluatorReadbackMsPerEpoch)
        XCTAssertNotNil(a.evaluatorUnclassifiedMsPerEpoch)
        // Substage means sum within the evaluate mean (evaluate span brackets them).
        let subSum = a.evaluatorBufferAllocMsPerEpoch! + a.evaluatorUploadMsPerEpoch!
            + a.evaluatorEncodeMsPerEpoch! + a.evaluatorSubmitWaitMsPerEpoch!
            + a.evaluatorReadbackMsPerEpoch!
        XCTAssertLessThanOrEqual(subSum, a.evaluateMsPerEpoch! + 1e-6)
        XCTAssertGreaterThan(subSum, 0)
    }

    // MARK: - Evaluator error path

    /// A profiling evaluator that throws on the profiled path propagates the error and
    /// leaves the runner state untouched (the epoch is not committed).
    func testProfilingEvaluatorErrorLeavesRunUntouched() throws {
        let cfg = try SoupConfig(seed: 3, programCount: 8, initMode: .opcode)
        var runner = SoupRunner(config: cfg)
        let before = runner.soup
        var clock = 0.0
        XCTAssertThrowsError(try runner.runEpoch(
            using: ThrowingProfilingEvaluator(),
            stageClock: { clock += 1; return clock }))
        XCTAssertEqual(runner.soup, before, "soup untouched after evaluator error")
        XCTAssertEqual(runner.epoch, 0, "epoch not advanced")
    }

    // MARK: - Stable JSON: keys + explicit nulls

    /// An instrumented CPU run's JSON carries the `hostStageAttribution` object with every
    /// top-level stage key present, and the Metal-only evaluator substage keys as explicit
    /// `null` (CPU reference does not profile). `instrumentationEnabled` is `true`.
    func testInstrumentedResultJSONKeysAndCpuEvaluatorNulls() throws {
        let cfg = BenchmarkConfig(seed: 2, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 3)
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        let r = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: false, includeCompression: false,
                           instrumentStages: true),
            readMaxRSSBytes: { nil },
            now: { clock += 1; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, inc in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: inc) })

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try enc.encode(r), as: UTF8.self)

        XCTAssertTrue(json.contains("\"instrumentationEnabled\":true"))
        for key in ["\"mutationPairingMsPerEpoch\"", "\"packingMsPerEpoch\"",
                    "\"evaluateMsPerEpoch\"", "\"scatterMsPerEpoch\"",
                    "\"counterReductionMsPerEpoch\"", "\"programMetricsMsPerEpoch\"",
                    "\"shadowMsPerEpoch\"", "\"digestMsPerEpoch\"",
                    "\"unclassifiedMsPerEpoch\"", "\"classifiedWallFraction\"",
                    "\"reconciliationValid\"", "\"reconciliationError\"",
                    "\"measuredEpochCount\"", "\"attributedEpochCount\"",
                    "\"attributionComplete\"", "\"attributionError\"",
                    "\"evaluatorProfileAvailable\"",
                    "\"evaluatorReconciliationValid\"",
                    "\"evaluatorReconciliationError\""] {
            XCTAssertTrue(json.contains(key), "missing \(key)")
        }
        XCTAssertTrue(json.contains("\"attributionComplete\":true"))
        XCTAssertTrue(json.contains("\"attributionError\":null"))
        XCTAssertTrue(json.contains("\"reconciliationValid\":true"))
        XCTAssertTrue(json.contains("\"reconciliationError\":null"))
        // CPU evaluator: substage fields present as explicit nulls, availability false.
        XCTAssertTrue(json.contains("\"evaluatorProfileAvailable\":false"))
        for nullKey in ["\"evaluatorBufferAllocMsPerEpoch\":null",
                        "\"evaluatorUploadMsPerEpoch\":null",
                        "\"evaluatorEncodeMsPerEpoch\":null",
                        "\"evaluatorSubmitWaitMsPerEpoch\":null",
                        "\"evaluatorReadbackMsPerEpoch\":null",
                        "\"evaluatorUnclassifiedMsPerEpoch\":null",
                        "\"evaluatorReconciliationValid\":null",
                        "\"evaluatorReconciliationError\":null"] {
            XCTAssertTrue(json.contains(nullKey), "expected explicit \(nullKey)")
        }

        // Round-trips back to a faithful, decodable result.
        let back = try JSONDecoder().decode(BenchmarkResult.self, from: Data(json.utf8))
        XCTAssertTrue(back.instrumentationEnabled)
        XCTAssertNotNil(back.hostStageAttribution)
        XCTAssertFalse(back.hostStageAttribution!.evaluatorProfileAvailable)
        XCTAssertNil(back.hostStageAttribution!.evaluatorSubmitWaitMsPerEpoch)
    }

    /// An uninstrumented run emits `instrumentationEnabled:false` and
    /// `hostStageAttribution:null` — the keys never vanish (stable schema-3 key set).
    func testUninstrumentedResultEmitsExplicitNullAttribution() throws {
        let one = GPUPairOutcome(finalTape: [UInt8](repeating: 0, count: BFF.pairTapeSize),
                                 steps: 10, noopSteps: 2, copyWrites: 1, loopOps: 0,
                                 halt: UInt32(HaltReason.budget.rawValue))
        let obs = [EpochObservation(
            epoch: 1, isWarmup: false, wallSeconds: 0.1, gpuSeconds: nil,
            counters: EpochCounters.reduce(epoch: 1, mutationCount: 0, outcomes: [one]),
            shadowChecked: 0, shadowMismatches: 0, signals: nil)]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 1)
        let r = BenchmarkAggregator.aggregate(
            config: cfg, deviceName: nil, initialSignals: nil, observations: obs,
            finalDigestHex: "00", maxRSSBytes: nil)   // instrumentationEnabled defaults false

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try enc.encode(r), as: UTF8.self)
        XCTAssertTrue(json.contains("\"instrumentationEnabled\":false"))
        XCTAssertTrue(json.contains("\"hostStageAttribution\":null"))

        let back = try JSONDecoder().decode(BenchmarkResult.self, from: Data(json.utf8))
        XCTAssertFalse(back.instrumentationEnabled)
        XCTAssertNil(back.hostStageAttribution)
    }
}
