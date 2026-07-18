import XCTest
import Foundation
import BFFOracle
@testable import BFFMetal

/// Coverage for the paper-aligned observability layer wired into the benchmark
/// harness: the high-order-complexity crossing tracker, the Brotli measurement
/// cadence (epoch 0 + sample∩signal points + final), deterministic-trajectory
/// equivalence with Brotli on vs off, and the schema-3 null/JSON behavior.
///
/// The real Brotli codec is exercised in `BrotliMetricsTests`; here the injected
/// `measureBrotliBitsPerByte` closure is synthetic, so the plumbing is testable on
/// any platform without linking Brotli.
final class PaperComplexityHarnessTests: XCTestCase {

    // MARK: - High-order-complexity threshold tracking

    func testHighOrderTrackerRecordsFirstCrossing() {
        var t = HighOrderComplexityTracker(thresholds: [0.5, 1.0, 5.0])
        // Absolute complexity climbs 0.2, 0.7, 1.3 at (measured) epochs 0, 4, 8.
        t.observe(epoch: 0, complexity: 0.2, cumulativeWallMs: 0, cumulativeGpuMs: 0)
        t.observe(epoch: 4, complexity: 0.7, cumulativeWallMs: 40, cumulativeGpuMs: 20)
        t.observe(epoch: 8, complexity: 1.3, cumulativeWallMs: 80, cumulativeGpuMs: 40)

        let c = t.crossings
        XCTAssertEqual(c[0].complexity, 0.5)
        XCTAssertTrue(c[0].crossed)
        XCTAssertEqual(c[0].epoch, 4)              // first epoch reaching >= 0.5
        XCTAssertEqual(c[0].wallMsToCross, 40)
        XCTAssertEqual(c[0].gpuMsToCross, 20)
        XCTAssertEqual(c[1].epoch, 8)              // paper threshold >= 1 only at epoch 8
        XCTAssertFalse(c[2].crossed, "5.0 never reached")
        XCTAssertNil(c[2].epoch)
    }

    func testHighOrderTrackerCrossesAtEpochZeroAndKeepsMissingGpu() {
        // A soup already complex at epoch 0 registers a crossing at 0.
        var t = HighOrderComplexityTracker(thresholds: [1.0])
        t.observe(epoch: 0, complexity: 1.5, cumulativeWallMs: 0, cumulativeGpuMs: nil)
        t.observe(epoch: 4, complexity: 2.0, cumulativeWallMs: 9, cumulativeGpuMs: nil)
        XCTAssertEqual(t.crossings[0].epoch, 0, "keeps the first (epoch-0) crossing")
        XCTAssertEqual(t.crossings[0].wallMsToCross, 0)
        XCTAssertNil(t.crossings[0].gpuMsToCross, "missing GPU timing preserved as nil")
    }

    // MARK: - Aggregator: high-order crossing + initial/final fields

    private func outcome(steps: UInt32, noop: UInt32, halt: HaltReason) -> GPUPairOutcome {
        GPUPairOutcome(finalTape: [UInt8](repeating: 0, count: BFF.pairTapeSize),
                       steps: steps, noopSteps: noop, copyWrites: 0, loopOps: 0,
                       halt: UInt32(halt.rawValue))
    }

    private func signals(h: Double, brotli: Double?) -> SoupSignals {
        SoupSignals(entropyBitsPerByte: h, meanProgramEntropyBitsPerByte: h,
                    transitionRate: 0.5, compressionProxyRatio: nil,
                    brotliBitsPerByte: brotli,
                    highOrderComplexity: brotli.map { h - $0 })
    }

    private func observation(epoch: Int, wall: Double, gpu: Double?,
                             signals s: SoupSignals) -> EpochObservation {
        let counters = EpochCounters.reduce(
            epoch: epoch, mutationCount: 0,
            outcomes: [outcome(steps: 10, noop: 2, halt: .budget)])
        return EpochObservation(epoch: epoch, isWarmup: false, wallSeconds: wall,
                                gpuSeconds: gpu, counters: counters,
                                shadowChecked: 0, shadowMismatches: 0, signals: s)
    }

    func testAggregatorHighOrderComplexityCrossingAndFinalFields() {
        // Complexity: initial 0.1, epoch1 0.6, epoch2 2.5 -> crosses paper threshold 1 at epoch 2.
        let initial = signals(h: 3.0, brotli: 2.9)     // 3.0 - 2.9 = 0.1
        let obs = [
            observation(epoch: 1, wall: 0.1, gpu: 0.05, signals: signals(h: 3.5, brotli: 2.9)), // 0.6
            observation(epoch: 2, wall: 0.1, gpu: 0.05, signals: signals(h: 4.5, brotli: 2.0)), // 2.5
        ]
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 2,
                                  highOrderComplexityThresholds: [1.0])
        let r = BenchmarkAggregator.aggregate(config: cfg, deviceName: nil,
                                              initialSignals: initial, observations: obs,
                                              finalDigestHex: "00", maxRSSBytes: nil)

        // Initial / final paper fields.
        XCTAssertEqual(r.initialBrotliBitsPerByte!, 2.9, accuracy: 1e-12)
        XCTAssertEqual(r.initialHighOrderComplexity!, 0.1, accuracy: 1e-12)
        XCTAssertEqual(r.finalBrotliBitsPerByte!, 2.0, accuracy: 1e-12)
        XCTAssertEqual(r.finalHighOrderComplexity!, 2.5, accuracy: 1e-12)
        // H0 itself is the whole-soup entropy, already reported.
        XCTAssertEqual(r.finalEntropyBitsPerByte!, 4.5, accuracy: 1e-12)

        // Crossing at >= 1 happens at epoch 2 (epoch 1 is only 0.6).
        XCTAssertEqual(r.highOrderComplexityCrossings.count, 1)
        let x = r.highOrderComplexityCrossings[0]
        XCTAssertEqual(x.complexity, 1.0)
        XCTAssertTrue(x.crossed)
        XCTAssertEqual(x.epoch, 2)
        XCTAssertEqual(x.wallMsToCross!, 200, accuracy: 1e-9)   // cumulative 0.2 s
        XCTAssertEqual(x.gpuMsToCross!, 100, accuracy: 1e-9)
    }

    // MARK: - Runner cadence + determinism + null behavior

    /// With `--brotli` on, the injected closure is called at exactly: epoch 0
    /// (reference) + every sample∩signal point + the final epoch — never every epoch.
    func testBrotliMeasuredOnlyAtSampleCadenceIncludingEpochZeroAndFinal() throws {
        // warmup 0 + measured 6, sampleInterval 3, signalInterval 1 (per-epoch signals).
        // Sample points among completed epochs: 3 and 6 (final). Plus the epoch-0 ref.
        let cfg = BenchmarkConfig(seed: 4, programCount: 24, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 6,
                                  highOrderComplexityThresholds: [1.0], sampleInterval: 3)
        let soupConfig = try cfg.soupConfig()

        var brotliEpochs: [Int] = []
        var onEpochCount = 0
        var firstBrotli = true
        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: true, includeCompression: false,
                           signalInterval: 1, includeBrotli: true),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: includeComp)
            },
            measureBrotliBitsPerByte: { _ in
                brotliEpochs.append(firstBrotli ? 0 : onEpochCount + 1)
                firstBrotli = false
                return 1.0   // synthetic bpb, constant
            },
            onEpoch: { _ in onEpochCount += 1 })

        XCTAssertEqual(brotliEpochs, [0, 3, 6],
                       "brotli measured at epoch-0 reference and sample points 3, 6 (final)")
        // Only the emitted (completed) sample epochs carry brotli in samples[].
        XCTAssertEqual(result.samples.map(\.epoch), [3, 6])
        for s in result.samples {
            XCTAssertNotNil(s.brotliBitsPerByte, "sample \(s.epoch) carries brotli")
            XCTAssertNotNil(s.highOrderComplexity)
            XCTAssertEqual(s.highOrderComplexity!, s.entropyBitsPerByte - 1.0, accuracy: 1e-12)
        }
        XCTAssertNotNil(result.initialBrotliBitsPerByte)
        XCTAssertNotNil(result.finalBrotliBitsPerByte)
        XCTAssertEqual(result.finalBrotliBitsPerByte!, 1.0, accuracy: 1e-12)
    }

    /// Enabling Brotli analysis must not perturb the simulation: the soup digest and
    /// every counter are byte-for-byte identical with Brotli on vs off. (Brotli is a
    /// read-only side computation outside the epoch wall.)
    func testBrotliDoesNotAlterTrajectory() throws {
        let cfg = BenchmarkConfig(seed: 21, programCount: 32, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 9,
                                  highOrderComplexityThresholds: [1.0], sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()

        func run(brotli: Bool) throws -> BenchmarkResult {
            var clock = 0.0
            return try BenchmarkRunner.run(
                config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
                deviceName: nil,
                options: .init(analyzeSignals: true, includeCompression: false,
                               signalInterval: 1, includeBrotli: brotli),
                readMaxRSSBytes: { nil },
                now: { clock += 0.001; return clock },
                gpuSecondsAfterEpoch: { nil },
                measureSignals: { soup, includeComp in
                    SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                        includeCompression: includeComp)
                },
                measureBrotliBitsPerByte: brotli ? { soup in Double(soup.count % 7) } : nil)
        }

        let on = try run(brotli: true)
        let off = try run(brotli: false)
        XCTAssertEqual(on.finalDigest, off.finalDigest, "digest identical with brotli on/off")
        XCTAssertEqual(on.totalPairs, off.totalPairs)
        XCTAssertEqual(on.totalRawSteps, off.totalRawSteps)
        XCTAssertEqual(on.totalCommandSteps, off.totalCommandSteps)
        XCTAssertEqual(on.totalCopyWrites, off.totalCopyWrites)
        XCTAssertEqual(on.haltBudget, off.haltBudget)
        // Same entropy trajectory too — brotli adds fields, never changes existing ones.
        XCTAssertEqual(on.finalEntropyBitsPerByte!, off.finalEntropyBitsPerByte!, accuracy: 1e-12)
        // Brotli fields present only in the on-run.
        XCTAssertNotNil(on.finalBrotliBitsPerByte)
        XCTAssertNil(off.finalBrotliBitsPerByte)
    }

    /// With `--brotli` off (or no closure injected), all paper fields are nil/empty —
    /// honest "not computed", never a fabricated 0 — while the rest of the run is intact.
    func testBrotliOffLeavesPaperFieldsNull() throws {
        let cfg = BenchmarkConfig(seed: 5, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 4,
                                  highOrderComplexityThresholds: [], sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        let r = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: true, includeCompression: false),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: includeComp)
            })

        XCTAssertNil(r.initialBrotliBitsPerByte)
        XCTAssertNil(r.initialHighOrderComplexity)
        XCTAssertNil(r.finalBrotliBitsPerByte)
        XCTAssertNil(r.finalHighOrderComplexity)
        XCTAssertTrue(r.highOrderComplexityCrossings.isEmpty)
        for s in r.samples {
            XCTAssertNil(s.brotliBitsPerByte)
            XCTAssertNil(s.highOrderComplexity)
        }
        // The entropy trajectory is still fully analyzed.
        XCTAssertTrue(r.signalsAnalyzed)
        XCTAssertNotNil(r.finalEntropyBitsPerByte)
    }

    // MARK: - Schema-3 JSON: new keys present; explicit nulls when off

    func testSchema3EmitsPaperKeysAndExplicitNulls() throws {
        // Off run: paper fields must be explicit nulls / empty arrays, not missing keys.
        let cfgOff = BenchmarkConfig(seed: 9, programCount: 8, warmupEpochs: 0,
                                     measuredEpochs: 1)
        let initialOff = signals(h: 1.5, brotli: nil)
        let off = BenchmarkAggregator.aggregate(
            config: cfgOff, deviceName: "dev", initialSignals: initialOff,
            observations: [observation(epoch: 1, wall: 0.1, gpu: 0.05,
                                       signals: signals(h: 1.6, brotli: nil))],
            finalDigestHex: "00", maxRSSBytes: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let jsonOff = String(decoding: try encoder.encode(off), as: UTF8.self)
        for nullKey in ["\"initialBrotliBitsPerByte\":null", "\"initialHighOrderComplexity\":null",
                        "\"finalBrotliBitsPerByte\":null", "\"finalHighOrderComplexity\":null"] {
            XCTAssertTrue(jsonOff.contains(nullKey), "expected explicit \(nullKey)")
        }
        XCTAssertTrue(jsonOff.contains("\"highOrderComplexityCrossings\":[]"))
        // Per-sample paper keys are still present (as nulls) on the emitted sample.
        XCTAssertTrue(jsonOff.contains("\"brotliBitsPerByte\":null"))
        XCTAssertTrue(jsonOff.contains("\"highOrderComplexity\":null"))

        // On run: values populated and the crossing serialized.
        let cfgOn = BenchmarkConfig(seed: 9, programCount: 8, warmupEpochs: 0,
                                    measuredEpochs: 1, highOrderComplexityThresholds: [1.0])
        // Initial complexity 0.5 (below the paper threshold), epoch-1 complexity 3.0
        // (crosses at epoch 1, not epoch 0).
        let on = BenchmarkAggregator.aggregate(
            config: cfgOn, deviceName: "dev", initialSignals: signals(h: 5.0, brotli: 4.5),
            observations: [observation(epoch: 1, wall: 0.1, gpu: 0.05,
                                       signals: signals(h: 5.0, brotli: 2.0))],
            finalDigestHex: "00", maxRSSBytes: 1)
        let jsonOn = String(decoding: try encoder.encode(on), as: UTF8.self)
        XCTAssertTrue(jsonOn.contains("\"finalBrotliBitsPerByte\":2"))
        XCTAssertTrue(jsonOn.contains("\"finalHighOrderComplexity\":3"))
        XCTAssertTrue(jsonOn.contains("\"complexity\":1"), "crossing threshold serialized")

        // Round-trips back to a faithful result.
        let back = try JSONDecoder().decode(BenchmarkResult.self, from: Data(jsonOn.utf8))
        XCTAssertEqual(back.finalHighOrderComplexity!, 3.0, accuracy: 1e-12)
        XCTAssertEqual(back.highOrderComplexityCrossings.first?.epoch, 1)
    }
}
