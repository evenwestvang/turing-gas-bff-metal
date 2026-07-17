import XCTest
import Foundation
import BFFOracle
@testable import BFFMetal

/// Platform-independent coverage for the benchmark harness: default-init invariance,
/// low-entropy determinism, the aggregation/timing plumbing, ΔH threshold crossing,
/// and an end-to-end run over the CPU reference evaluator (no GPU needed). None of
/// this touches evaluator semantics; it only measures.
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
                             outcomes: [GPUPairOutcome], h: Double) -> EpochObservation {
        let counters = EpochCounters.reduce(epoch: epoch, mutationCount: 0,
                                            outcomes: outcomes)
        let signals = SoupSignals(entropyBitsPerByte: h,
                                  meanProgramEntropyBitsPerByte: h,
                                  transitionRate: 0.5, compressionProxyRatio: 0.9)
        return EpochObservation(epoch: epoch, isWarmup: warmup, wallSeconds: wall,
                                gpuSeconds: gpu, counters: counters,
                                shadowChecked: 0, shadowMismatches: 0, signals: signals)
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
        XCTAssertEqual(r.initialEntropyBitsPerByte, 3.0)
        XCTAssertEqual(r.finalEntropyBitsPerByte, 4.0)
        XCTAssertEqual(r.finalDeltaH, 1.0, accuracy: 1e-9)
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

    // MARK: - Machine-readable contract

    /// The JSON must carry every field the benchmark spec requires, and encode
    /// cleanly. Guards the machine-readable contract against accidental renames.
    func testResultJSONContainsRequiredFields() throws {
        let one = [outcome(steps: 10, noop: 2, halt: .budget, copy: 1)]
        let obs = [observation(epoch: 1, warmup: false, wall: 0.1, gpu: 0.05,
                               outcomes: one, h: 2.0)]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 1, deltaHThresholds: [0.1])
        let initial = SoupSignals(entropyBitsPerByte: 1.5,
                                  meanProgramEntropyBitsPerByte: 1.5,
                                  transitionRate: 0.4, compressionProxyRatio: 0.8)
        let r = BenchmarkAggregator.aggregate(config: cfg, deviceName: "dev",
                                              initialSignals: initial, observations: obs,
                                              finalDigestHex: "00", maxRSSBytes: 42)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(r), as: UTF8.self)

        for key in ["\"config\"", "\"warmupEpochs\"", "\"measuredEpochs\"",
                    "\"wallMsPerEpoch\"", "\"gpuMsPerEpoch\"", "\"hostResidualMsPerEpoch\"",
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

    // MARK: - End-to-end over the CPU reference (no GPU)

    /// Drives the full observe -> aggregate pipeline exactly like the CLI, but with
    /// the CPU reference evaluator, so the plumbing (and opcode-init kinetics) is
    /// exercised on any platform. Uses synthetic per-epoch wall times so the derived
    /// throughput is deterministic; GPU time is honestly nil (no GPU ran).
    func testEndToEndCPUHarnessProducesGrowingEntropyKinetics() throws {
        let cfg = BenchmarkConfig(seed: 5, programCount: 64, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 6,
                                  deltaHThresholds: [0.1, 0.25], sampleInterval: 2)
        let soupConfig = try cfg.soupConfig()

        func run() -> BenchmarkResult {
            var runner = SoupRunner(config: soupConfig)
            let initial = SoupSignals.measure(soup: runner.soup,
                                              programCount: cfg.programCount,
                                              includeCompression: true)
            var obs: [EpochObservation] = []
            for e in 0..<cfg.totalEpochs {
                let completed = e + 1
                let isSample = completed % cfg.sampleInterval == 0
                    || completed == cfg.totalEpochs
                let report = try! runner.runEpoch(using: CPUPairEvaluator())
                let signals = SoupSignals.measure(soup: runner.soup,
                                                  programCount: cfg.programCount,
                                                  includeCompression: isSample)
                obs.append(EpochObservation(
                    epoch: completed, isWarmup: e < cfg.warmupEpochs,
                    wallSeconds: 0.01, gpuSeconds: nil, counters: report.counters,
                    shadowChecked: report.shadowChecked,
                    shadowMismatches: report.shadowMismatches.count, signals: signals))
            }
            return BenchmarkAggregator.aggregate(
                config: cfg, deviceName: nil, initialSignals: initial,
                observations: obs, finalDigestHex: SoupDigest.hexString(runner.digest),
                maxRSSBytes: nil)
        }

        let a = run()
        let b = run()

        // Deterministic end to end.
        XCTAssertEqual(a.finalDigest, b.finalDigest)
        XCTAssertEqual(a.finalEntropyBitsPerByte, b.finalEntropyBitsPerByte)

        // Opcode init starts low; evolution raises whole-soup entropy measurably.
        XCTAssertGreaterThan(a.initialEntropyBitsPerByte, 0)
        XCTAssertLessThan(a.initialEntropyBitsPerByte, 4.0)
        XCTAssertGreaterThan(a.finalDeltaH, 0, "entropy should increase from the opcode floor")

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
}
