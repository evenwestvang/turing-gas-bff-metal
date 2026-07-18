import XCTest
import Foundation
import BFFOracle
@testable import BFFMetal

/// Coverage for the paper-aligned observability layer wired into the benchmark
/// harness: the high-order-complexity crossing tracker, the Brotli measurement
/// cadence (epoch 0 + sample∩signal points + final), deterministic-trajectory
/// equivalence with Brotli on vs off, and the schema-4 null/JSON behavior.
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
        XCTAssertEqual(c[0].observedEpoch, 4)              // first epoch reaching >= 0.5
        XCTAssertEqual(c[0].previousMeasuredEpoch, 0)     // gap 0→4
        XCTAssertEqual(c[0].crossingEpochCensoring, "interval", "sparse gap ⇒ interval")
        XCTAssertEqual(c[0].wallMsToCross, 40)
        XCTAssertEqual(c[0].gpuMsToCross, 20)
        XCTAssertEqual(c[1].observedEpoch, 8)              // paper threshold >= 1 only at epoch 8
        XCTAssertEqual(c[1].previousMeasuredEpoch, 4)
        XCTAssertEqual(c[1].crossingEpochCensoring, "interval")
        XCTAssertFalse(c[2].crossed, "5.0 never reached")
        XCTAssertNil(c[2].observedEpoch)
        XCTAssertEqual(c[2].previousMeasuredEpoch, 8, "not-crossed tracks last measured epoch")
        XCTAssertEqual(c[2].crossingEpochCensoring, "notCrossed")
    }

    func testHighOrderTrackerCrossesAtEpochZeroAndKeepsMissingGpu() {
        // A soup already complex at epoch 0 registers a crossing at 0.
        var t = HighOrderComplexityTracker(thresholds: [1.0])
        t.observe(epoch: 0, complexity: 1.5, cumulativeWallMs: 0, cumulativeGpuMs: nil)
        t.observe(epoch: 4, complexity: 2.0, cumulativeWallMs: 9, cumulativeGpuMs: nil)
        XCTAssertEqual(t.crossings[0].observedEpoch, 0, "keeps the first (epoch-0) crossing")
        XCTAssertNil(t.crossings[0].previousMeasuredEpoch, "nil at initial observation")
        XCTAssertEqual(t.crossings[0].crossingEpochCensoring, "exact", "epoch-0 ⇒ exact")
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
        XCTAssertEqual(x.observedEpoch, 2)
        XCTAssertEqual(x.previousMeasuredEpoch, 1, "cadence 1 ⇒ gap of 1")
        XCTAssertEqual(x.crossingEpochCensoring, "exact", "cadence 1 ⇒ exact")
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

    // MARK: - Schema-4 JSON: paper keys present; explicit nulls when off

    func testSchema4EmitsPaperKeysAndExplicitNulls() throws {
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
        XCTAssertEqual(back.highOrderComplexityCrossings.first?.observedEpoch, 1)
        XCTAssertEqual(back.highOrderComplexityCrossings.first?.crossingEpochCensoring, "exact")
    }

    // MARK: - Fix #1: nil compression ⇒ empty crossings, never false "not crossed" records

    /// When `--brotli` is on (so `highOrderComplexityThresholds` is populated) but
    /// the injected closure returns `nil` for every epoch (as a non-1.1.0 encoder
    /// would), no `highOrderComplexity` observation ever exists. The crossings array
    /// must be **empty** — never a list of false "not crossed" records that would
    /// imply a measurement was taken.
    func testNilCompressionYieldsEmptyCrossingsNeverFalseNotCrossed() throws {
        // Config carries the paper threshold (as the CLI does when --brotli is on),
        // but the injected closure returns nil — no complexity is ever observed.
        let cfg = BenchmarkConfig(seed: 7, programCount: 8, warmupEpochs: 0,
                                  measuredEpochs: 3,
                                  highOrderComplexityThresholds: [1.0],
                                  sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        let r = try BenchmarkRunner.run(
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
            measureBrotliBitsPerByte: { _ in nil })   // simulates a non-1.1.0 encoder

        XCTAssertTrue(r.highOrderComplexityCrossings.isEmpty,
                      "nil compression must yield empty crossings, not false 'not crossed' records")
        XCTAssertNil(r.initialBrotliBitsPerByte)
        XCTAssertNil(r.finalBrotliBitsPerByte)
        XCTAssertNil(r.initialHighOrderComplexity)
        XCTAssertNil(r.finalHighOrderComplexity)
        for s in r.samples {
            XCTAssertNil(s.brotliBitsPerByte)
            XCTAssertNil(s.highOrderComplexity)
        }
        // The rest of the run is intact.
        XCTAssertTrue(r.signalsAnalyzed)
        XCTAssertNotNil(r.finalEntropyBitsPerByte)
    }

    /// Directly: a tracker that is never fed an observation returns empty crossings.
    func testTrackerNeverFedReturnsEmptyCrossings() {
        let t = HighOrderComplexityTracker(thresholds: [0.5, 1.0, 2.0])
        XCTAssertTrue(t.crossings.isEmpty,
                      "a tracker never fed must return [], not three false 'not crossed' records")
    }

    // MARK: - Fix #2: sparse threshold interval censoring

    /// Epoch-0 crossing: `previousMeasuredEpoch` is nil, censoring is "exact".
    func testCensoringEpochZeroCrossingIsExact() {
        var t = HighOrderComplexityTracker(thresholds: [1.0])
        t.observe(epoch: 0, complexity: 1.5, cumulativeWallMs: 0, cumulativeGpuMs: 0)
        let c = t.crossings[0]
        XCTAssertEqual(c.observedEpoch, 0)
        XCTAssertNil(c.previousMeasuredEpoch, "nil at initial observation")
        XCTAssertEqual(c.crossingEpochCensoring, "exact")
    }

    /// Cadence-1 crossing (every epoch measured): gap of 1 ⇒ "exact".
    func testCensoringCadenceOneCrossingIsExact() {
        var t = HighOrderComplexityTracker(thresholds: [1.0])
        t.observe(epoch: 0, complexity: 0.2, cumulativeWallMs: 0, cumulativeGpuMs: 0)
        t.observe(epoch: 1, complexity: 0.5, cumulativeWallMs: 10, cumulativeGpuMs: 5)
        t.observe(epoch: 2, complexity: 1.3, cumulativeWallMs: 20, cumulativeGpuMs: 10)
        let c = t.crossings[0]
        XCTAssertEqual(c.observedEpoch, 2)
        XCTAssertEqual(c.previousMeasuredEpoch, 1, "cadence 1 ⇒ previous is epoch-1")
        XCTAssertEqual(c.crossingEpochCensoring, "exact", "gap of 1 ⇒ exact")
    }

    /// Sparse-cadence crossing (gap > 1): the true crossing is in an interval.
    func testCensoringSparseCadenceCrossingIsInterval() {
        var t = HighOrderComplexityTracker(thresholds: [1.0])
        t.observe(epoch: 0, complexity: 0.2, cumulativeWallMs: 0, cumulativeGpuMs: 0)
        t.observe(epoch: 5, complexity: 1.3, cumulativeWallMs: 50, cumulativeGpuMs: 25)
        let c = t.crossings[0]
        XCTAssertEqual(c.observedEpoch, 5)
        XCTAssertEqual(c.previousMeasuredEpoch, 0)
        XCTAssertEqual(c.crossingEpochCensoring, "interval",
                       "gap > 1 ⇒ the true crossing is somewhere in (0, 5]")
    }

    /// Final off-cadence observation: the crossing is observed at the final epoch
    /// (off-cadence), so the gap from the previous cadence point is > 1 ⇒ interval.
    func testCensoringFinalOffCadenceObservationIsInterval() {
        var t = HighOrderComplexityTracker(thresholds: [1.0])
        // Epoch 0 (initial), epoch 3 (cadence point), epoch 7 (final, off-cadence).
        t.observe(epoch: 0, complexity: 0.1, cumulativeWallMs: 0, cumulativeGpuMs: 0)
        t.observe(epoch: 3, complexity: 0.4, cumulativeWallMs: 30, cumulativeGpuMs: 15)
        t.observe(epoch: 7, complexity: 1.2, cumulativeWallMs: 70, cumulativeGpuMs: 35)
        let c = t.crossings[0]
        XCTAssertEqual(c.observedEpoch, 7, "crossing first observed at the final epoch")
        XCTAssertEqual(c.previousMeasuredEpoch, 3, "previous measured epoch is the cadence point")
        XCTAssertEqual(c.crossingEpochCensoring, "interval",
                       "final off-cadence ⇒ true crossing is in (3, 7]")
    }

    /// Never-crossed at sparse cadence: `crossed` is false, `observedEpoch` is nil,
    /// `previousMeasuredEpoch` is the last measured epoch, censoring is "notCrossed".
    func testCensoringNeverCrossedTracksLastMeasuredEpoch() {
        var t = HighOrderComplexityTracker(thresholds: [5.0])
        t.observe(epoch: 0, complexity: 0.1, cumulativeWallMs: 0, cumulativeGpuMs: 0)
        t.observe(epoch: 4, complexity: 0.3, cumulativeWallMs: 40, cumulativeGpuMs: 20)
        t.observe(epoch: 8, complexity: 0.5, cumulativeWallMs: 80, cumulativeGpuMs: 40)
        let c = t.crossings[0]
        XCTAssertFalse(c.crossed)
        XCTAssertNil(c.observedEpoch)
        XCTAssertEqual(c.previousMeasuredEpoch, 8, "last measured epoch")
        XCTAssertEqual(c.crossingEpochCensoring, "notCrossed")
    }

    /// The JSON encoding of a sparse-cadence crossing carries the interval fields
    /// explicitly, so machine-readable output cannot imply the true crossing is exact.
    func testSparseCrossingJSONEncodesIntervalNotExact() throws {
        let crossing = HighOrderComplexityCrossing(
            complexity: 1.0, crossed: true, observedEpoch: 7,
            previousMeasuredEpoch: 3, crossingEpochCensoring: "interval",
            wallMsToCross: 70, gpuMsToCross: 35)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(crossing), as: UTF8.self)
        XCTAssertTrue(json.contains("\"crossingEpochCensoring\":\"interval\""))
        XCTAssertTrue(json.contains("\"observedEpoch\":7"))
        XCTAssertTrue(json.contains("\"previousMeasuredEpoch\":3"))
        XCTAssertFalse(json.contains("\"crossingEpochCensoring\":\"exact\""))
    }

    // MARK: - Fix #3: backward decoding of schema-2-shaped JSON

    /// A literal schema-2-shaped JSON (no Brotli/config/crossing keys at all) must
    /// decode without error: optional scalar metrics default to `nil`, arrays and
    /// thresholds default to empty, and no existing field's meaning is changed.
    func testSchemaTwoShapedJSONDecodesBackwardCompatible() throws {
        // Minimal schema-2 result: every schema-2 key present, every later key
        // (Brotli, high-order, crossings, highOrderComplexityThresholds) absent.
        let schemaTwoJSON = """
        {
          "config": {
            "seed": 42,
            "programCount": 256,
            "stepBudget": 8192,
            "mutationP32": 65536,
            "variant": "noheads",
            "initMode": "uniform",
            "shadowSampleCount": 0,
            "warmupEpochs": 1,
            "measuredEpochs": 8,
            "deltaHThresholds": [0.1, 0.5],
            "sampleInterval": 1
          },
          "deviceName": "schema2-host",
          "rngContractID": "counter-pcg-v1",
          "warmupEpochs": 1,
          "measuredEpochs": 8,
          "gpuTimingAvailable": true,
          "wallMsPerEpoch": 1.5,
          "gpuMsPerEpoch": 0.8,
          "hostResidualMsPerEpoch": 0.7,
          "gpuBusyFraction": 0.53,
          "signalAnalysisMsTotal": 0.2,
          "epochsPerSecond": 666.7,
          "pairsPerSecond": 85333,
          "rawStepsPerSecond": 5461333,
          "commandStepsPerSecond": 4266666,
          "totalPairs": 2048,
          "totalRawSteps": 131072,
          "totalCommandSteps": 102400,
          "totalCopyWrites": 512,
          "haltBudget": 100,
          "haltPCOut": 10,
          "haltUnmatched": 5,
          "haltUnknown": 0,
          "signalsAnalyzed": true,
          "initialEntropyBitsPerByte": 7.8,
          "finalEntropyBitsPerByte": 7.9,
          "finalDeltaH": 0.1,
          "finalMeanProgramEntropyBitsPerByte": 7.7,
          "finalTransitionRate": 0.99,
          "finalCompressionProxyRatio": 0.85,
          "thresholdCrossings": [
            {"deltaH": 0.1, "crossed": true, "epoch": 3, "wallMsToCross": 4.5, "gpuMsToCross": 2.4}
          ],
          "shadowCheckedTotal": 0,
          "shadowMismatchTotal": 0,
          "maxRSSBytes": 1048576,
          "samples": [
            {"epoch": 1, "phase": "measured", "wallMs": 1.5, "gpuMs": 0.8,
             "hostResidualMs": 0.7, "rawSteps": 16384, "commandSteps": 12800,
             "copyWrites": 64, "entropyBitsPerByte": 7.85,
             "meanProgramEntropyBitsPerByte": 7.65, "deltaHFromInitial": 0.05,
             "transitionRate": 0.99, "compressionProxyRatio": 0.86}
          ],
          "finalDigest": "abc123"
        }
        """
        let back = try JSONDecoder().decode(BenchmarkResult.self,
                                            from: Data(schemaTwoJSON.utf8))
        // Existing schema-2 fields decode faithfully — no silent meaning change.
        XCTAssertEqual(back.config.seed, 42)
        XCTAssertEqual(back.config.programCount, 256)
        XCTAssertEqual(back.config.deltaHThresholds, [0.1, 0.5])
        XCTAssertEqual(back.finalEntropyBitsPerByte!, 7.9, accuracy: 1e-12)
        XCTAssertEqual(back.thresholdCrossings.count, 1)
        XCTAssertTrue(back.thresholdCrossings[0].crossed)
        XCTAssertEqual(back.thresholdCrossings[0].epoch, 3)
        XCTAssertEqual(back.finalDigest, "abc123")

        // Newer keys default: optional scalars to nil, arrays/thresholds to empty.
        XCTAssertNil(back.initialBrotliBitsPerByte)
        XCTAssertNil(back.initialHighOrderComplexity)
        XCTAssertNil(back.finalBrotliBitsPerByte)
        XCTAssertNil(back.finalHighOrderComplexity)
        XCTAssertTrue(back.highOrderComplexityCrossings.isEmpty)
        XCTAssertTrue(back.config.highOrderComplexityThresholds.isEmpty)
        // Per-sample Brotli keys also default to nil.
        XCTAssertNil(back.samples.first?.brotliBitsPerByte)
        XCTAssertNil(back.samples.first?.highOrderComplexity)
    }
}
