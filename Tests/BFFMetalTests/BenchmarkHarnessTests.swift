import XCTest
import Foundation
import BFFOracle
@testable import BFFMetal

/// Platform-independent coverage for the benchmark harness: default-init invariance,
/// low-entropy determinism, the aggregation/timing plumbing, ΔH threshold crossing,
/// `--no-samples` metric gating, and an end-to-end run over the CPU reference
/// evaluator (no GPU needed). None of this touches evaluator semantics; it only
/// measures.
final class BenchmarkHarnessTests: XCTestCase {

    // MARK: - Default initialization invariance

    func testDefaultInitModeIsUniformAndUnchanged() throws {
        let config = try SoupConfig(seed: 12345, programCount: 32)
        XCTAssertEqual(config.initMode, .uniform, "uniform must remain the default")

        let runner = SoupRunner(config: config)
        // Byte-for-byte the existing uniform path — the pinned digests depend on this.
        XCTAssertEqual(runner.soup,
                       BFFRandom.initialSoup(programs: 32, seed: 12345))
        XCTAssertEqual(runner.digest,
                       SoupDigest.digest(BFFRandom.initialSoup(programs: 32, seed: 12345)))
    }

    func testLowEntropyInitModesAreDeterministic() throws {
        for mode in [SoupConfig.InitMode.constant, .opcode] {
            let cfg = try SoupConfig(seed: 99, programCount: 16, initMode: mode)
            XCTAssertEqual(SoupRunner(config: cfg).soup, SoupRunner(config: cfg).soup,
                           "\(mode) must be reproducible")
        }
        // Constant mode is exactly the zero-entropy floor.
        let constant = SoupRunner(config: try SoupConfig(seed: 1, programCount: 16,
                                                         initMode: .constant))
        XCTAssertTrue(constant.soup.allSatisfy { $0 == 0 })
        // Opcode mode differs from both uniform and constant.
        let opcode = SoupRunner(config: try SoupConfig(seed: 1, programCount: 16,
                                                       initMode: .opcode))
        XCTAssertNotEqual(opcode.soup, constant.soup)
        XCTAssertNotEqual(opcode.soup,
                          BFFRandom.initialSoup(programs: 16, seed: 1))
    }

    // MARK: - Signal measurement

    func testSoupSignalsMeasureConstantAndOpcode() {
        let constant = BFFRandom.constantSoup(programs: 8)
        let cs = SoupSignals.measure(soup: constant, programCount: 8,
                                     includeCompression: true)
        XCTAssertEqual(cs.entropyBitsPerByte, 0)
        XCTAssertEqual(cs.meanProgramEntropyBitsPerByte, 0)
        XCTAssertEqual(cs.transitionRate, 0)
        XCTAssertNotNil(cs.compressionProxyRatio)

        // Compression proxy omitted unless requested (cost gate).
        let os = SoupSignals.measure(soup: BFFRandom.opcodeSoup(programs: 8, seed: 2),
                                     programCount: 8, includeCompression: false)
        XCTAssertNil(os.compressionProxyRatio)
        XCTAssertGreaterThan(os.entropyBitsPerByte, 0)
    }

    // MARK: - Threshold crossing logic

    func testThresholdTrackerRecordsFirstCrossing() {
        var t = ThresholdTracker(thresholds: [0.5, 1.0, 5.0])
        // deltaH climbs 0.2, 0.6, 1.4 at epochs 1,2,3 with cumulative wall 10,20,35 ms.
        t.observe(epoch: 1, deltaH: 0.2, cumulativeWallMs: 10, cumulativeGpuMs: 4)
        t.observe(epoch: 2, deltaH: 0.6, cumulativeWallMs: 20, cumulativeGpuMs: 9)
        t.observe(epoch: 3, deltaH: 1.4, cumulativeWallMs: 35, cumulativeGpuMs: 15)

        let c = t.crossings
        XCTAssertEqual(c[0].deltaH, 0.5)
        XCTAssertTrue(c[0].crossed)
        XCTAssertEqual(c[0].epoch, 2)                 // first epoch reaching >= 0.5
        XCTAssertEqual(c[0].wallMsToCross, 20)
        XCTAssertEqual(c[0].gpuMsToCross, 9)

        XCTAssertEqual(c[1].epoch, 3)                 // >= 1.0 only at epoch 3
        XCTAssertEqual(c[1].wallMsToCross, 35)

        XCTAssertFalse(c[2].crossed, "5.0 never reached")
        XCTAssertNil(c[2].epoch)
    }

    func testThresholdTrackerDoesNotOverwriteAndHandlesMissingGpu() {
        var t = ThresholdTracker(thresholds: [1.0])
        t.observe(epoch: 1, deltaH: 1.0, cumulativeWallMs: 5, cumulativeGpuMs: nil)
        t.observe(epoch: 2, deltaH: 2.0, cumulativeWallMs: 9, cumulativeGpuMs: nil)
        XCTAssertEqual(t.crossings[0].epoch, 1, "keeps the first crossing")
        XCTAssertEqual(t.crossings[0].wallMsToCross, 5)
        XCTAssertNil(t.crossings[0].gpuMsToCross, "missing GPU timing is preserved as nil")
    }

    // MARK: - Aggregation plumbing

    private func outcome(steps: UInt32, noop: UInt32, halt: HaltReason,
                         copy: UInt32 = 0) -> GPUPairOutcome {
        GPUPairOutcome(finalTape: [UInt8](repeating: 0, count: BFF.pairTapeSize),
                       steps: steps, noopSteps: noop, copyWrites: copy,
                       loopOps: 0, halt: UInt32(halt.rawValue))
    }

    private func observation(epoch: Int, warmup: Bool, wall: Double, gpu: Double?,
                             outcomes: [GPUPairOutcome], h: Double,
                             signals: SoupSignals? = nil,
                             analysis: Double? = nil) -> EpochObservation {
        let counters = EpochCounters.reduce(epoch: epoch, mutationCount: 0,
                                            outcomes: outcomes)
        let s = signals ?? SoupSignals(entropyBitsPerByte: h,
                                       meanProgramEntropyBitsPerByte: h,
                                       transitionRate: 0.5, compressionProxyRatio: 0.9)
        return EpochObservation(epoch: epoch, isWarmup: warmup, wallSeconds: wall,
                                gpuSeconds: gpu, counters: counters,
                                shadowChecked: 0, shadowMismatches: 0, signals: s,
                                analysisSeconds: analysis)
    }

    func testAggregatorTimingAndThroughput() {
        // Two pairs/epoch. Warmup epoch is excluded from timing and counters.
        let two = [outcome(steps: 100, noop: 40, halt: .budget, copy: 3),
                   outcome(steps: 50, noop: 10, halt: .pcOut, copy: 1)]
        let obs = [
            observation(epoch: 1, warmup: true, wall: 1.0, gpu: 0.9, outcomes: two, h: 3.0),
            observation(epoch: 2, warmup: false, wall: 0.2, gpu: 0.1, outcomes: two, h: 3.5),
            observation(epoch: 3, warmup: false, wall: 0.2, gpu: 0.1, outcomes: two, h: 4.0),
        ]
        let cfg = BenchmarkConfig(seed: 1, programCount: 4, warmupEpochs: 1,
                                  measuredEpochs: 2, deltaHThresholds: [0.5, 1.0])
        let initial = SoupSignals(entropyBitsPerByte: 3.0,
                                  meanProgramEntropyBitsPerByte: 3.0,
                                  transitionRate: 0.5, compressionProxyRatio: 0.9)
        let r = BenchmarkAggregator.aggregate(config: cfg, deviceName: "test",
                                              initialSignals: initial, observations: obs,
                                              finalDigestHex: "deadbeefdeadbeef",
                                              maxRSSBytes: 1234)

        XCTAssertEqual(r.warmupEpochs, 1)
        XCTAssertEqual(r.measuredEpochs, 2)
        XCTAssertTrue(r.gpuTimingAvailable)
        XCTAssertTrue(r.signalsAnalyzed)

        // Measured wall = 0.4 s over 2 epochs -> 200 ms/epoch; gpu 0.2 s -> 100 ms.
        XCTAssertEqual(r.wallMsPerEpoch, 200, accuracy: 1e-9)
        XCTAssertEqual(r.gpuMsPerEpoch!, 100, accuracy: 1e-9)
        XCTAssertEqual(r.hostResidualMsPerEpoch!, 100, accuracy: 1e-9) // (0.4-0.2)/2*1000
        XCTAssertEqual(r.gpuBusyFraction!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.epochsPerSecond, 5.0, accuracy: 1e-9)          // 2 / 0.4

        // Counters are measured-only (warmup excluded): 2 epochs x 2 pairs = 4.
        XCTAssertEqual(r.totalPairs, 4)
        XCTAssertEqual(r.totalRawSteps, 2 * (100 + 50))
        XCTAssertEqual(r.totalCommandSteps, 2 * ((100 - 40) + (50 - 10)))
        XCTAssertEqual(r.totalCopyWrites, 2 * (3 + 1))
        XCTAssertEqual(r.haltBudget, 2)
        XCTAssertEqual(r.haltPCOut, 2)
        XCTAssertEqual(r.pairsPerSecond, 10.0, accuracy: 1e-9)          // 4 / 0.4

        // Kinetics span the whole run: ΔH from 3.0 -> 4.0.
        XCTAssertEqual(r.initialEntropyBitsPerByte!, 3.0)
        XCTAssertEqual(r.finalEntropyBitsPerByte!, 4.0)
        XCTAssertEqual(r.finalDeltaH!, 1.0, accuracy: 1e-9)
        // ΔH>=0.5 first at epoch 2, ΔH>=1.0 at epoch 3 (warmup counts as evolution).
        XCTAssertEqual(r.thresholdCrossings[0].epoch, 2)
        XCTAssertEqual(r.thresholdCrossings[1].epoch, 3)
        XCTAssertEqual(r.maxRSSBytes, 1234)
    }

    func testAggregatorMarksGpuUnavailableWhenAnyMeasuredEpochLacksTiming() {
        let one = [outcome(steps: 10, noop: 0, halt: .budget)]
        let obs = [
            observation(epoch: 1, warmup: false, wall: 0.2, gpu: 0.1, outcomes: one, h: 1),
            observation(epoch: 2, warmup: false, wall: 0.2, gpu: nil, outcomes: one, h: 1),
        ]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 2)
        let initial = SoupSignals(entropyBitsPerByte: 1,
                                  meanProgramEntropyBitsPerByte: 1,
                                  transitionRate: 0, compressionProxyRatio: nil)
        let r = BenchmarkAggregator.aggregate(config: cfg, deviceName: nil,
                                              initialSignals: initial, observations: obs,
                                              finalDigestHex: "0", maxRSSBytes: nil)
        XCTAssertFalse(r.gpuTimingAvailable)
        XCTAssertNil(r.gpuMsPerEpoch)
        XCTAssertNil(r.hostResidualMsPerEpoch)
        XCTAssertNil(r.gpuBusyFraction)
        // Wall-based numbers survive even without GPU timing.
        XCTAssertEqual(r.wallMsPerEpoch, 200, accuracy: 1e-9)
        XCTAssertGreaterThan(r.epochsPerSecond, 0)
    }

    // MARK: - Signal analysis wall attribution

    /// When signals are analyzed, `signalAnalysisMsTotal` sums the per-epoch analysis
    /// wall plus the initial-measurement wall — kept entirely separate from the epoch
    /// execution wall (which drives throughput).
    func testAggregatorSumsSignalAnalysisWallSeparately() {
        let one = [outcome(steps: 10, noop: 0, halt: .budget)]
        let obs = [
            observation(epoch: 1, warmup: false, wall: 0.5, gpu: 0.4, outcomes: one,
                        h: 2.0, analysis: 0.010),
            observation(epoch: 2, warmup: false, wall: 0.5, gpu: 0.4, outcomes: one,
                        h: 2.5, analysis: 0.020),
        ]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 2)
        let initial = SoupSignals(entropyBitsPerByte: 2.0,
                                  meanProgramEntropyBitsPerByte: 2.0,
                                  transitionRate: 0.5, compressionProxyRatio: 0.9)
        let r = BenchmarkAggregator.aggregate(config: cfg, deviceName: nil,
                                              initialSignals: initial, observations: obs,
                                              finalDigestHex: "0", maxRSSBytes: nil,
                                              initialAnalysisSeconds: 0.005)
        // (0.010 + 0.020 + 0.005) s -> 35 ms, independent of the 1000 ms epoch wall.
        XCTAssertEqual(r.signalAnalysisMsTotal!, 35, accuracy: 1e-9)
        XCTAssertEqual(r.wallMsPerEpoch, 500, accuracy: 1e-9)
    }

    // MARK: - --no-samples gating (blocker 1): no signal code runs

    /// Drives the real epoch loop (`BenchmarkRunner`) with the CPU reference and a
    /// COUNTING `measureSignals` closure. Under `--no-samples` (throughputOnly) the
    /// count must be exactly zero — proving no entropy scan, transition scan, or LZ
    /// proxy is invoked — and every kinetics field / host-analysis field is absent.
    func testNoSamplesInvokesNoSampleMetricCode() throws {
        let cfg = BenchmarkConfig(seed: 3, programCount: 16, initMode: .opcode,
                                  warmupEpochs: 1, measuredEpochs: 3,
                                  deltaHThresholds: [0.1], sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()

        var measureCalls = 0
        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil, options: .throughputOnly, readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                measureCalls += 1
                return SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                           includeCompression: includeComp)
            })

        XCTAssertEqual(measureCalls, 0,
                       "no sample-only metric code may run under --no-samples")
        XCTAssertFalse(result.signalsAnalyzed)
        XCTAssertNil(result.initialEntropyBitsPerByte)
        XCTAssertNil(result.finalEntropyBitsPerByte)
        XCTAssertNil(result.finalDeltaH)
        XCTAssertNil(result.finalTransitionRate)
        XCTAssertNil(result.finalCompressionProxyRatio)
        XCTAssertNil(result.signalAnalysisMsTotal, "host analysis cost is not computed")
        XCTAssertTrue(result.thresholdCrossings.isEmpty)
        XCTAssertTrue(result.samples.isEmpty)
        // Mandatory metrics that DO remain: counters and the final digest (both inside
        // the epoch wall, not sample metrics).
        XCTAssertGreaterThan(result.totalRawSteps, 0)
        XCTAssertEqual(result.finalDigest.count, 16)
        XCTAssertGreaterThan(result.epochsPerSecond, 0)
    }

    /// The companion: with analysis ON, the closure IS invoked and kinetics + host
    /// analysis cost are present. Compression stays off unless opted in.
    func testAnalyzeSignalsInvokesSampleMetricCode() throws {
        let cfg = BenchmarkConfig(seed: 3, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 3,
                                  deltaHThresholds: [0.05], sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()

        var measureCalls = 0
        var compressionRequested = false
        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: true, includeCompression: false),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                measureCalls += 1
                if includeComp { compressionRequested = true }
                return SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                           includeCompression: includeComp)
            })

        // initial measurement + one per epoch.
        XCTAssertEqual(measureCalls, 1 + cfg.totalEpochs)
        XCTAssertFalse(compressionRequested, "LZ proxy stays off without --compression")
        XCTAssertTrue(result.signalsAnalyzed)
        XCTAssertNotNil(result.initialEntropyBitsPerByte)
        XCTAssertNotNil(result.finalDeltaH)
        XCTAssertNotNil(result.signalAnalysisMsTotal)
        XCTAssertNil(result.finalCompressionProxyRatio,
                     "compression is opt-in; nil == not computed")
    }

    /// Opting compression in requests it only on sampled epochs + the final, never
    /// every epoch — bounding the one expensive signal.
    func testCompressionIsOptInAndBoundedToSampleCadence() throws {
        let cfg = BenchmarkConfig(seed: 4, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 6,
                                  sampleInterval: 3)
        let soupConfig = try cfg.soupConfig()

        var compressionCalls = 0
        var totalCalls = 0
        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: true, includeCompression: true),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                totalCalls += 1
                if includeComp { compressionCalls += 1 }
                return SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                           includeCompression: includeComp)
            })

        // initial + 6 epochs = 7 calls; compression only at initial + epochs 3 and 6.
        XCTAssertEqual(totalCalls, 1 + 6)
        XCTAssertLessThan(compressionCalls, totalCalls,
                          "compression must not run on every measurement")
        XCTAssertNotNil(result.finalCompressionProxyRatio)
    }

    // MARK: - Sparse signal-analysis cadence (--signal-interval)

    /// Build a runner invocation over the CPU reference that records, per epoch, whether
    /// signals were measured. Returns (result, epochsMeasured, compressionEpochs) where
    /// the epoch lists are the *completed* epoch indices at which the closure ran /
    /// requested compression. The epoch-0 (initial) measurement is counted separately
    /// via `initialMeasured`.
    private struct CadenceProbe {
        var result: BenchmarkResult
        var totalCalls: Int
        var initialMeasured: Bool
        var perEpochSignalEpochs: [Int]     // sample epochs that carried signals
        var compressionCalls: Int
    }

    /// Drive the real `BenchmarkRunner` with a synthetic clock and a probe closure.
    /// `sampleInterval == 1` so every measured epoch that carries signals surfaces as a
    /// sample, letting the test read the measurement cadence off `result.samples`.
    private func runCadence(seed: UInt32 = 11, programCount: Int = 24,
                            warmup: Int, measured: Int,
                            signalInterval: Int, sampleInterval: Int = 1,
                            thresholds: [Double] = [],
                            compression: Bool = false) throws -> CadenceProbe {
        let cfg = BenchmarkConfig(seed: seed, programCount: programCount,
                                  mutationP32: 1 << 22, initMode: .opcode,
                                  warmupEpochs: warmup, measuredEpochs: measured,
                                  deltaHThresholds: thresholds,
                                  sampleInterval: sampleInterval)
        let soupConfig = try cfg.soupConfig()
        var totalCalls = 0
        var compressionCalls = 0
        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: true, includeCompression: compression,
                           signalInterval: signalInterval),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                totalCalls += 1
                if includeComp { compressionCalls += 1 }
                return SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                           includeCompression: includeComp)
            })
        return CadenceProbe(result: result, totalCalls: totalCalls,
                            initialMeasured: result.initialEntropyBitsPerByte != nil,
                            perEpochSignalEpochs: result.samples.map(\.epoch),
                            compressionCalls: compressionCalls)
    }

    /// Signals are measured at exactly: epoch 0 (initial), every Nth completed epoch,
    /// and the final completed epoch — and nowhere else.
    func testSignalIntervalMeasuresExactCadence() throws {
        // warmup 1 + measured 8 = 9 total, N = 4: completed 4, 8, then 9 (final).
        let p = try runCadence(warmup: 1, measured: 8, signalInterval: 4)
        XCTAssertTrue(p.initialMeasured, "epoch-0 reference is always measured")
        XCTAssertEqual(p.perEpochSignalEpochs, [4, 8, 9],
                       "measured at every 4th completed epoch plus the final epoch")
        // Total closure calls = initial (1) + the three cadence epochs.
        XCTAssertEqual(p.totalCalls, 1 + 3)
        XCTAssertTrue(p.result.signalsAnalyzed, "sparse cadence still counts as analyzed")
    }

    /// Epoch 0 is captured before any mutation/evaluation: the initial reference equals
    /// a direct measurement of the un-evolved opcode soup.
    func testSignalIntervalCapturesEpochZeroBeforeMutation() throws {
        let cfg = BenchmarkConfig(seed: 7, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 5,
                                  sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()
        let pristine = SoupRunner(config: soupConfig).soup
        let expectedInitialH = SoupSignals.measure(
            soup: pristine, programCount: cfg.programCount,
            includeCompression: false).entropyBitsPerByte

        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: true, includeCompression: false,
                           signalInterval: 3),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: includeComp)
            })
        XCTAssertEqual(result.initialEntropyBitsPerByte!, expectedInitialH, accuracy: 1e-12,
                       "epoch-0 reference is the pre-mutation soup, measured before the loop")
    }

    /// The final completed epoch is always measured even when the total is not divisible
    /// by the signal interval.
    func testSignalIntervalCapturesFinalEpochWhenNotDivisible() throws {
        // warmup 0 + measured 10 = 10 total, N = 4: completed 4, 8, then 10 (final,
        // 10 % 4 != 0 but still captured).
        let p = try runCadence(warmup: 0, measured: 10, signalInterval: 4)
        XCTAssertEqual(p.perEpochSignalEpochs, [4, 8, 10])
        XCTAssertEqual(p.perEpochSignalEpochs.last, 10, "final epoch captured off-cadence")
        XCTAssertNotNil(p.result.finalEntropyBitsPerByte)
        XCTAssertNotNil(p.result.finalDeltaH)
    }

    /// ΔH thresholds require the per-epoch trajectory; a sparse interval is rejected as
    /// a usage error, while per-epoch (interval 1) and no-threshold cases are allowed.
    func testValidateSignalCadenceRejectsSparseWithThresholds() {
        XCTAssertThrowsError(try validateSignalCadence(signalInterval: 10,
                                                       deltaHThresholdCount: 2)) { error in
            XCTAssertEqual(error as? SignalCadenceError,
                           .thresholdsRequirePerEpochSignals(signalInterval: 10))
        }
        // Per-epoch signals + thresholds: allowed.
        XCTAssertNoThrow(try validateSignalCadence(signalInterval: 1,
                                                   deltaHThresholdCount: 2))
        // Sparse interval, no thresholds: allowed (cadence-only analysis).
        XCTAssertNoThrow(try validateSignalCadence(signalInterval: 10,
                                                   deltaHThresholdCount: 0))
    }

    /// A sparse trajectory equals the corresponding points of a per-epoch trajectory for
    /// the same deterministic run: signal measurement is a read-only side computation,
    /// so the soup evolution — and thus every measured value at a shared epoch — is
    /// identical. (Compression off to isolate the entropy/transition trajectory.)
    func testSparseTrajectoryMatchesPerEpochAtSharedEpochs() throws {
        let dense = try runCadence(warmup: 1, measured: 12, signalInterval: 1)
        let sparse = try runCadence(warmup: 1, measured: 12, signalInterval: 5)

        // Same run => identical soup fingerprint regardless of measurement cadence.
        XCTAssertEqual(dense.result.finalDigest, sparse.result.finalDigest)

        let denseByEpoch = Dictionary(uniqueKeysWithValues:
            dense.result.samples.map { ($0.epoch, $0) })
        XCTAssertFalse(sparse.result.samples.isEmpty)
        // Sparse epochs are a strict subset of the dense (every-epoch) sample epochs.
        for s in sparse.result.samples {
            guard let d = denseByEpoch[s.epoch] else {
                return XCTFail("sparse epoch \(s.epoch) missing from the per-epoch run")
            }
            XCTAssertEqual(s.entropyBitsPerByte, d.entropyBitsPerByte, accuracy: 1e-12,
                           "entropy at epoch \(s.epoch) must match the per-epoch value")
            XCTAssertEqual(s.meanProgramEntropyBitsPerByte,
                           d.meanProgramEntropyBitsPerByte, accuracy: 1e-12)
            XCTAssertEqual(s.deltaHFromInitial, d.deltaHFromInitial, accuracy: 1e-12)
            XCTAssertEqual(s.transitionRate, d.transitionRate, accuracy: 1e-12)
        }
        // Sparse initial/final kinetics equal the per-epoch ones (both measure epoch 0
        // and the final epoch).
        XCTAssertEqual(sparse.result.initialEntropyBitsPerByte!,
                       dense.result.initialEntropyBitsPerByte!, accuracy: 1e-12)
        XCTAssertEqual(sparse.result.finalEntropyBitsPerByte!,
                       dense.result.finalEntropyBitsPerByte!, accuracy: 1e-12)
        XCTAssertEqual(sparse.result.finalDeltaH!, dense.result.finalDeltaH!,
                       accuracy: 1e-12)
    }

    /// The soup fingerprint, aggregate counters, and throughput denominators are
    /// byte-for-byte identical across the default (per-epoch), sparse, and disabled
    /// (`--no-samples`) analysis policies: signal analysis never perturbs the simulation.
    func testDigestAndCountersIdenticalAcrossAnalysisPolicies() throws {
        let cfg = BenchmarkConfig(seed: 21, programCount: 32, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 9,
                                  sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()

        func run(_ options: BenchmarkRunner.Options) throws -> BenchmarkResult {
            var clock = 0.0
            return try BenchmarkRunner.run(
                config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
                deviceName: nil, options: options, readMaxRSSBytes: { nil },
                now: { clock += 0.001; return clock },
                gpuSecondsAfterEpoch: { nil },
                measureSignals: { soup, includeComp in
                    SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                        includeCompression: includeComp)
                })
        }

        let dense = try run(.init(analyzeSignals: true, includeCompression: false,
                                  signalInterval: 1))
        let sparse = try run(.init(analyzeSignals: true, includeCompression: false,
                                   signalInterval: 4))
        let disabled = try run(.throughputOnly)

        for other in [sparse, disabled] {
            XCTAssertEqual(dense.finalDigest, other.finalDigest, "digest must match")
            XCTAssertEqual(dense.totalPairs, other.totalPairs)
            XCTAssertEqual(dense.totalRawSteps, other.totalRawSteps)
            XCTAssertEqual(dense.totalCommandSteps, other.totalCommandSteps)
            XCTAssertEqual(dense.totalCopyWrites, other.totalCopyWrites)
            XCTAssertEqual(dense.haltBudget, other.haltBudget)
            XCTAssertEqual(dense.haltPCOut, other.haltPCOut)
            XCTAssertEqual(dense.haltUnmatched, other.haltUnmatched)
            XCTAssertEqual(dense.haltUnknown, other.haltUnknown)
            XCTAssertEqual(dense.measuredEpochs, other.measuredEpochs)
        }
        // Policies differ only in whether/where kinetics were computed.
        XCTAssertTrue(dense.signalsAnalyzed)
        XCTAssertTrue(sparse.signalsAnalyzed)
        XCTAssertFalse(disabled.signalsAnalyzed)
    }

    /// Compression stays independent of the signal cadence and never broadens: with a
    /// sparse interval the LZ proxy runs only where an emission point and a measured
    /// epoch coincide, so it runs no more often than a per-epoch run would — and never
    /// on an epoch where signals were not measured at all.
    func testCompressionIndependentAndBoundedUnderSparseSignals() throws {
        // warmup 0 + measured 12, signalInterval 4 => signals at 4, 8, 12(final).
        // sampleInterval 1 => every measured epoch is an emission point, so compression
        // is requested at each signal epoch (+ the initial reference).
        let sparse = try runCadence(warmup: 0, measured: 12, signalInterval: 4,
                                    sampleInterval: 1, compression: true)
        XCTAssertEqual(sparse.perEpochSignalEpochs, [4, 8, 12])
        // Compression calls: initial (1) + the three measured signal epochs = 4.
        XCTAssertEqual(sparse.compressionCalls, 1 + 3)
        // Never exceeds total measurements (LZ is a strict subset of measurements).
        XCTAssertLessThanOrEqual(sparse.compressionCalls, sparse.totalCalls)
        XCTAssertNotNil(sparse.result.finalCompressionProxyRatio,
                        "the final epoch is always both a signal point and a sample point")

        // A per-epoch run with the SAME emission cadence computes LZ at least as often —
        // sparse never broadens LZ work.
        let dense = try runCadence(warmup: 0, measured: 12, signalInterval: 1,
                                   sampleInterval: 1, compression: true)
        XCTAssertGreaterThanOrEqual(dense.compressionCalls, sparse.compressionCalls,
                                    "sparse analysis must not run LZ more than per-epoch does")

        // And compression truly stays opt-in: with it off, the proxy is never requested.
        let noComp = try runCadence(warmup: 0, measured: 12, signalInterval: 4,
                                    sampleInterval: 1, compression: false)
        XCTAssertEqual(noComp.compressionCalls, 0, "LZ proxy never runs without --compression")
        XCTAssertNil(noComp.result.finalCompressionProxyRatio)
    }

    // MARK: - Machine-readable contract

    /// The JSON must carry every field the benchmark spec requires, and encode
    /// cleanly. Guards the machine-readable contract against accidental renames.
    func testResultJSONContainsRequiredFields() throws {
        let one = [outcome(steps: 10, noop: 2, halt: .budget, copy: 1)]
        let obs = [observation(epoch: 1, warmup: false, wall: 0.1, gpu: 0.05,
                               outcomes: one, h: 2.0, analysis: 0.002)]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 1, deltaHThresholds: [0.1])
        let initial = SoupSignals(entropyBitsPerByte: 1.5,
                                  meanProgramEntropyBitsPerByte: 1.5,
                                  transitionRate: 0.4, compressionProxyRatio: 0.8)
        let r = BenchmarkAggregator.aggregate(config: cfg, deviceName: "dev",
                                              initialSignals: initial, observations: obs,
                                              finalDigestHex: "00", maxRSSBytes: 42,
                                              initialAnalysisSeconds: 0.001)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(r), as: UTF8.self)

        for key in ["\"config\"", "\"warmupEpochs\"", "\"measuredEpochs\"",
                    "\"wallMsPerEpoch\"", "\"gpuMsPerEpoch\"", "\"hostResidualMsPerEpoch\"",
                    "\"signalAnalysisMsTotal\"", "\"signalsAnalyzed\"",
                    "\"epochsPerSecond\"", "\"pairsPerSecond\"", "\"rawStepsPerSecond\"",
                    "\"commandStepsPerSecond\"", "\"haltBudget\"", "\"haltPCOut\"",
                    "\"haltUnmatched\"", "\"totalCopyWrites\"", "\"gpuTimingAvailable\"",
                    "\"initialEntropyBitsPerByte\"", "\"finalDeltaH\"",
                    "\"thresholdCrossings\"", "\"finalTransitionRate\"",
                    "\"finalCompressionProxyRatio\"", "\"maxRSSBytes\"",
                    "\"finalDigest\"", "\"samples\""] {
            XCTAssertTrue(json.contains(key), "missing \(key) in result JSON")
        }
    }

    /// The signal-measurement cadence is a CLI-only control: it must NOT add a JSON key
    /// anywhere in the machine-readable result (schema 2 key set is frozen). The nested
    /// `config` object in particular must not gain a `signalInterval` field.
    func testSignalIntervalAddsNoJSONKey() throws {
        let one = [outcome(steps: 10, noop: 2, halt: .budget, copy: 1)]
        let obs = [observation(epoch: 1, warmup: false, wall: 0.1, gpu: 0.05,
                               outcomes: one, h: 2.0, analysis: 0.002)]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 1)
        let initial = SoupSignals(entropyBitsPerByte: 1.5,
                                  meanProgramEntropyBitsPerByte: 1.5,
                                  transitionRate: 0.4, compressionProxyRatio: 0.8)
        let r = BenchmarkAggregator.aggregate(config: cfg, deviceName: "dev",
                                              initialSignals: initial, observations: obs,
                                              finalDigestHex: "00", maxRSSBytes: 42)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(r), as: UTF8.self)
        XCTAssertFalse(json.contains("signalInterval"),
                       "the signal cadence must not appear in the JSON schema")
        // The documented emission-cadence key `sampleInterval` is unchanged/present.
        XCTAssertTrue(json.contains("\"sampleInterval\""))
    }

    // MARK: - End-to-end over the CPU reference (no GPU)

    /// Drives the full observe -> aggregate pipeline via the real `BenchmarkRunner`,
    /// but with the CPU reference evaluator, so the plumbing (and opcode-init kinetics)
    /// is exercised on any platform. Uses a synthetic monotonic clock so the derived
    /// throughput is deterministic; GPU time is honestly nil (no GPU ran).
    func testEndToEndCPUHarnessProducesGrowingEntropyKinetics() throws {
        let cfg = BenchmarkConfig(seed: 5, programCount: 64, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 6,
                                  deltaHThresholds: [0.1, 0.25], sampleInterval: 2)
        let soupConfig = try cfg.soupConfig()

        func run() throws -> BenchmarkResult {
            var clock = 0.0
            return try BenchmarkRunner.run(
                config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
                deviceName: nil,
                options: .init(analyzeSignals: true, includeCompression: true),
                readMaxRSSBytes: { nil },
                now: { clock += 0.01; return clock },
                gpuSecondsAfterEpoch: { nil },
                measureSignals: { soup, includeComp in
                    SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                        includeCompression: includeComp)
                })
        }

        let a = try run()
        let b = try run()

        // Deterministic end to end.
        XCTAssertEqual(a.finalDigest, b.finalDigest)
        XCTAssertEqual(a.finalEntropyBitsPerByte, b.finalEntropyBitsPerByte)

        // Opcode init starts low; evolution raises whole-soup entropy measurably.
        XCTAssertGreaterThan(a.initialEntropyBitsPerByte!, 0)
        XCTAssertLessThan(a.initialEntropyBitsPerByte!, 4.0)
        XCTAssertGreaterThan(a.finalDeltaH!, 0, "entropy should increase from the opcode floor")

        // GPU timing honestly absent; wall-derived throughput present.
        XCTAssertFalse(a.gpuTimingAvailable)
        XCTAssertNil(a.gpuMsPerEpoch)
        XCTAssertEqual(a.measuredEpochs, 6)
        XCTAssertGreaterThan(a.pairsPerSecond, 0)

        // Samples are bounded by the interval, carry the phase, and include the final.
        XCTAssertFalse(a.samples.isEmpty)
        XCTAssertLessThanOrEqual(a.samples.count, cfg.totalEpochs)
        XCTAssertEqual(a.samples.last?.epoch, cfg.totalEpochs)
        XCTAssertNotNil(a.samples.last?.compressionProxyRatio)
        // Every sample's phase label agrees with the warmup boundary.
        for s in a.samples {
            XCTAssertEqual(s.phase, s.epoch <= cfg.warmupEpochs ? "warmup" : "measured")
        }
    }

    // MARK: - Process peak RSS policy (blocker 1)

    /// The factored max-aggregation policy: keep the maximum *available* reading;
    /// ignore unavailable (`nil`) samples; report `nil` only if every sample was
    /// unavailable. Independent of platform units (the caller normalizes those).
    func testPeakRSSSamplerKeepsMaxAndIgnoresUnavailable() {
        var empty = PeakRSSSampler()
        XCTAssertNil(empty.peakBytes, "no samples -> unavailable")
        empty.sample(nil)
        XCTAssertNil(empty.peakBytes, "an unavailable reading stays unavailable")

        var s = PeakRSSSampler()
        s.sample(100)
        s.sample(nil)          // unavailable must never lower the peak
        s.sample(300)
        s.sample(200)          // a lower reading must never lower the peak
        XCTAssertEqual(s.peakBytes, 300)

        // First reading unavailable, then a real one: peak is the real one.
        var late = PeakRSSSampler()
        late.sample(nil)
        late.sample(50)
        XCTAssertEqual(late.peakBytes, 50)
    }

    /// End-to-end through the real runner: RSS is read at pre-cell, post-allocation,
    /// and post-cell (exactly three reads), and the reported ceiling is their maximum.
    func testRunSamplesPeakRSSAtThreePointsAndReportsMax() throws {
        let cfg = BenchmarkConfig(seed: 7, programCount: 8, warmupEpochs: 1,
                                  measuredEpochs: 2)
        let soupConfig = try cfg.soupConfig()

        var readings = [100, 999, 400]      // pre, post-alloc, post-cell
        var reads = 0
        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil, options: .throughputOnly,
            readMaxRSSBytes: { defer { reads += 1 }; return readings[reads] },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: includeComp)
            })
        XCTAssertEqual(reads, 3, "RSS sampled exactly pre-cell, post-alloc, post-cell")
        XCTAssertEqual(result.maxRSSBytes, 999, "reports the max high-water reading")

        // All-unavailable readings collapse to nil (not a fabricated 0).
        readings = []; reads = 0; clock = 0
        let none = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil, options: .throughputOnly,
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: includeComp)
            })
        XCTAssertNil(none.maxRSSBytes)
    }

    // MARK: - Raw metrics policy (blocker 2): disabling in-epoch ProgramMetrics

    /// Disabling per-program metric construction must not change the simulation: the
    /// soup trajectory, digest, and every counter are byte-for-byte identical to a
    /// metrics-enabled run over the same seed/config/epochs. Only `EpochReport.metrics`
    /// differs (full vs empty), and the invocation counter proves the scan really was
    /// skipped — not merely that the array came back empty.
    func testMetricsDisabledPreservesDigestCountersSoupAndProvesNoScan() throws {
        let cfg = try SoupConfig(seed: 4242, programCount: 32, mutationP32: 1 << 22,
                                 initMode: .opcode)
        var full = SoupRunner(config: cfg)
        var raw = SoupRunner(config: cfg)
        let epochs = 5

        for _ in 0..<epochs {
            let f = try full.runEpoch(using: CPUPairEvaluator(), metrics: .enabled)
            let r = try raw.runEpoch(using: CPUPairEvaluator(), metrics: .disabled)

            // Identical simulation outputs.
            XCTAssertEqual(f.counters, r.counters, "counters must match exactly")
            XCTAssertEqual(f.digest, r.digest, "post-epoch digest must match exactly")
            XCTAssertEqual(f.shadowChecked, r.shadowChecked)
            XCTAssertEqual(f.shadowMismatches.count, r.shadowMismatches.count)

            // Metrics: full vs empty, only under the explicit opt-out.
            XCTAssertEqual(f.metrics.count, cfg.programCount)
            XCTAssertTrue(r.metrics.isEmpty, "metrics empty only under .disabled")
        }

        // Soup trajectory identical after the whole run.
        XCTAssertEqual(full.soup, raw.soup)
        XCTAssertEqual(full.digest, raw.digest)

        // Invocation-proof seam: the scan ran every epoch when enabled, never when
        // disabled.
        XCTAssertEqual(full.programMetricBuildCount, epochs)
        XCTAssertEqual(raw.programMetricBuildCount, 0,
                       "no per-program metric construction under .disabled")
    }

    /// The default `runEpoch` policy is `.enabled`, so every existing app/oracle/CLI
    /// caller keeps building metrics with no source change.
    func testRunEpochDefaultsToMetricsEnabled() throws {
        let cfg = try SoupConfig(seed: 1, programCount: 8)
        var runner = SoupRunner(config: cfg)
        let report = try runner.runEpoch(using: CPUPairEvaluator())
        XCTAssertEqual(report.metrics.count, cfg.programCount)
        XCTAssertEqual(runner.programMetricBuildCount, 1)
    }

    // MARK: - Stable schema-2 JSON: explicit nulls, no vanishing keys (blocker 4)

    /// A `--no-samples` (throughput-only) run must still emit EVERY documented optional
    /// field as an explicit JSON `null` — the keys may not disappear — and empty
    /// collections must stay explicit `[]`. This is the machine-readable stability
    /// contract consumers depend on.
    func testNoSamplesResultEmitsExplicitNullsNotMissingKeys() throws {
        let cfg = BenchmarkConfig(seed: 9, programCount: 8, warmupEpochs: 1,
                                  measuredEpochs: 2, deltaHThresholds: [0.1])
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        let r = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil, options: .throughputOnly, readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: includeComp)
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(r), as: UTF8.self)

        // Every optional field present as an explicit null (not omitted).
        for nullKey in ["\"gpuMsPerEpoch\":null", "\"hostResidualMsPerEpoch\":null",
                        "\"gpuBusyFraction\":null", "\"signalAnalysisMsTotal\":null",
                        "\"initialEntropyBitsPerByte\":null",
                        "\"finalEntropyBitsPerByte\":null", "\"finalDeltaH\":null",
                        "\"finalMeanProgramEntropyBitsPerByte\":null",
                        "\"finalTransitionRate\":null",
                        "\"finalCompressionProxyRatio\":null",
                        "\"maxRSSBytes\":null", "\"deviceName\":null"] {
            XCTAssertTrue(json.contains(nullKey), "expected explicit \(nullKey)")
        }
        // Empty collections stay explicit arrays; the always-present flag is false.
        XCTAssertTrue(json.contains("\"thresholdCrossings\":[]"))
        XCTAssertTrue(json.contains("\"samples\":[]"))
        XCTAssertTrue(json.contains("\"signalsAnalyzed\":false"))

        // Round-trips back to a decodable, faithful result.
        let back = try JSONDecoder().decode(BenchmarkResult.self,
                                            from: Data(json.utf8))
        XCTAssertFalse(back.signalsAnalyzed)
        XCTAssertNil(back.finalDeltaH)
        XCTAssertNil(back.maxRSSBytes)
        XCTAssertEqual(back.finalDigest, r.finalDigest)
    }

    /// A non-crossed ΔH threshold must still serialize its `epoch`/`wallMsToCross`/
    /// `gpuMsToCross` as explicit nulls inside the array element.
    func testUncrossedThresholdSerializesExplicitNulls() throws {
        let c = ThresholdCrossing(deltaH: 5.0, crossed: false, epoch: nil,
                                  wallMsToCross: nil, gpuMsToCross: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(c), as: UTF8.self)
        XCTAssertTrue(json.contains("\"epoch\":null"))
        XCTAssertTrue(json.contains("\"wallMsToCross\":null"))
        XCTAssertTrue(json.contains("\"gpuMsToCross\":null"))
    }

    // MARK: - Exit-code policy (blocker 5)

    /// The documented exit-code mapping: a missing Metal device normalizes to 2
    /// (metal unavailable); every other init/runtime failure is a distinct 1.
    func testEvaluatorInitExitCodePolicy() {
        XCTAssertEqual(EvaluatorInitOutcome.metalUnavailable.exitCode, 2)
        XCTAssertEqual(EvaluatorInitOutcome.runtimeFailure.exitCode, 1)
        XCTAssertEqual(BenchmarkExitCode.success, 0)
        XCTAssertEqual(BenchmarkExitCode.runtimeFailure, 1)
        XCTAssertEqual(BenchmarkExitCode.metalUnavailable, 2)
        XCTAssertEqual(BenchmarkExitCode.gpuTimingUnavailable, 3)
        XCTAssertEqual(BenchmarkExitCode.usage, 64)
    }
}
