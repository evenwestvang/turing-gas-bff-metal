import XCTest
import Foundation
import BFFOracle
@testable import BFFMetal

/// Regression coverage for the schema-4 merge composition: host-stage attribution
/// and paper high-order complexity are emitted together, but either predecessor
/// schema-3 shape still decodes with the missing side defaulted honestly.
final class CombinedBenchmarkSchemaTests: XCTestCase {

    private func outcome(steps: UInt32 = 10, noop: UInt32 = 2,
                         halt: HaltReason = .budget) -> GPUPairOutcome {
        GPUPairOutcome(finalTape: [UInt8](repeating: 0, count: BFF.pairTapeSize),
                       steps: steps, noopSteps: noop, copyWrites: 1, loopOps: 0,
                       halt: UInt32(halt.rawValue))
    }

    private func counters(epoch: Int = 1) -> EpochCounters {
        EpochCounters.reduce(epoch: epoch, mutationCount: 0, outcomes: [outcome()])
    }

    private func signals(h: Double, brotli: Double?) -> SoupSignals {
        SoupSignals(entropyBitsPerByte: h, meanProgramEntropyBitsPerByte: h,
                    transitionRate: 0.5, compressionProxyRatio: nil,
                    brotliBitsPerByte: brotli,
                    highOrderComplexity: brotli.map { h - $0 })
    }

    private func spans() -> HostStageSpans {
        HostStageSpans(mutationPairingSeconds: 0.01, packingSeconds: 0.01,
                       evaluateSeconds: 0.02, scatterSeconds: 0.005,
                       counterReductionSeconds: 0.005, programMetricsSeconds: 0,
                       shadowSeconds: 0, digestSeconds: 0.005)
    }

    private func combinedResult() -> BenchmarkResult {
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 2,
                                  highOrderComplexityThresholds: [1.0],
                                  sampleInterval: 1)
        let obs = [
            EpochObservation(epoch: 1, isWarmup: false, wallSeconds: 0.10,
                             gpuSeconds: 0.05, counters: counters(epoch: 1),
                             shadowChecked: 0, shadowMismatches: 0,
                             signals: signals(h: 3.0, brotli: 2.5),
                             hostStageSpans: spans()),
            EpochObservation(epoch: 2, isWarmup: false, wallSeconds: 0.10,
                             gpuSeconds: 0.05, counters: counters(epoch: 2),
                             shadowChecked: 0, shadowMismatches: 0,
                             signals: signals(h: 4.0, brotli: 2.0),
                             hostStageSpans: spans())
        ]
        return BenchmarkAggregator.aggregate(
            config: cfg, deviceName: "combined", initialSignals: signals(h: 2.8, brotli: 2.6),
            observations: obs, finalDigestHex: "abc123", maxRSSBytes: 1234,
            instrumentationEnabled: true)
    }

    private func encodedObject(_ result: BenchmarkResult) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeObject(_ object: [String: Any]) throws -> BenchmarkResult {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(BenchmarkResult.self, from: data)
    }

    private func doubleValue(_ object: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(object[key] as? NSNumber, "missing numeric key \(key)").doubleValue
    }

    private func doubleArray(_ object: [String: Any], _ key: String) throws -> [Double] {
        let values = try XCTUnwrap(object[key] as? [NSNumber], "missing numeric array \(key)")
        return values.map(\.doubleValue)
    }

    func testSchema4EmitsHostAttributionAndPaperFamiliesTogether() throws {
        let result = combinedResult()
        let object = try encodedObject(result)

        XCTAssertEqual(object["instrumentationEnabled"] as? Bool, true)
        XCTAssertNotNil(object["hostStageAttribution"] as? [String: Any])
        XCTAssertEqual(try doubleValue(object, "initialBrotliBitsPerByte"), 2.6,
                       accuracy: 1e-12)
        XCTAssertEqual(try doubleValue(object, "finalBrotliBitsPerByte"), 2.0,
                       accuracy: 1e-12)
        XCTAssertEqual(try doubleValue(object, "finalHighOrderComplexity"), 2.0,
                       accuracy: 1e-12)
        XCTAssertEqual((object["highOrderComplexityCrossings"] as? [[String: Any]])?.count, 1)

        let config = try XCTUnwrap(object["config"] as? [String: Any])
        XCTAssertEqual(try doubleArray(config, "highOrderComplexityThresholds"), [1.0])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertTrue(samples.allSatisfy { $0.keys.contains("brotliBitsPerByte") })
        XCTAssertTrue(samples.allSatisfy { $0.keys.contains("highOrderComplexity") })
    }

    func testAttributionOnlySchema3ShapeDecodesWithPaperDefaults() throws {
        var object = try encodedObject(combinedResult())
        for key in ["initialBrotliBitsPerByte", "initialHighOrderComplexity",
                    "finalBrotliBitsPerByte", "finalHighOrderComplexity",
                    "highOrderComplexityCrossings"] {
            object.removeValue(forKey: key)
        }
        var config = try XCTUnwrap(object["config"] as? [String: Any])
        config.removeValue(forKey: "highOrderComplexityThresholds")
        object["config"] = config
        var samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        for i in samples.indices {
            samples[i].removeValue(forKey: "brotliBitsPerByte")
            samples[i].removeValue(forKey: "highOrderComplexity")
        }
        object["samples"] = samples

        let decoded = try decodeObject(object)
        XCTAssertTrue(decoded.instrumentationEnabled)
        XCTAssertNotNil(decoded.hostStageAttribution)
        XCTAssertNil(decoded.initialBrotliBitsPerByte)
        XCTAssertNil(decoded.initialHighOrderComplexity)
        XCTAssertNil(decoded.finalBrotliBitsPerByte)
        XCTAssertNil(decoded.finalHighOrderComplexity)
        XCTAssertTrue(decoded.highOrderComplexityCrossings.isEmpty)
        XCTAssertTrue(decoded.config.highOrderComplexityThresholds.isEmpty)
        XCTAssertNil(decoded.samples.first?.brotliBitsPerByte)
        XCTAssertNil(decoded.samples.first?.highOrderComplexity)
    }

    func testPaperOnlySchema3ShapeDecodesWithAttributionDefaults() throws {
        var object = try encodedObject(combinedResult())
        object.removeValue(forKey: "instrumentationEnabled")
        object.removeValue(forKey: "hostStageAttribution")

        let decoded = try decodeObject(object)
        XCTAssertFalse(decoded.instrumentationEnabled)
        XCTAssertNil(decoded.hostStageAttribution)
        XCTAssertEqual(decoded.initialBrotliBitsPerByte!, 2.6, accuracy: 1e-12)
        XCTAssertEqual(decoded.finalBrotliBitsPerByte!, 2.0, accuracy: 1e-12)
        XCTAssertEqual(decoded.finalHighOrderComplexity!, 2.0, accuracy: 1e-12)
        XCTAssertEqual(decoded.highOrderComplexityCrossings.first?.observedEpoch, 2)
        XCTAssertEqual(decoded.config.highOrderComplexityThresholds, [1.0])
        XCTAssertNotNil(decoded.samples.first?.brotliBitsPerByte)
        XCTAssertNotNil(decoded.samples.first?.highOrderComplexity)
    }

    func testCombinedFlagsPreserveDigestCountersAndTrajectory() throws {
        let cfg = BenchmarkConfig(seed: 21, programCount: 32, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 1, measuredEpochs: 6,
                                  highOrderComplexityThresholds: [1.0],
                                  sampleInterval: 2)
        let soupConfig = try cfg.soupConfig()

        func run(brotli: Bool, stages: Bool) throws -> BenchmarkResult {
            var clock = 0.0
            return try BenchmarkRunner.run(
                config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
                deviceName: nil,
                options: .init(analyzeSignals: true, includeCompression: false,
                               signalInterval: 1, includeBrotli: brotli,
                               instrumentStages: stages),
                readMaxRSSBytes: { nil },
                now: { clock += 0.001; return clock },
                gpuSecondsAfterEpoch: { nil },
                measureSignals: { soup, includeComp in
                    SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                        includeCompression: includeComp)
                },
                measureBrotliBitsPerByte: brotli ? { _ in 1.0 } : nil)
        }

        let baseline = try run(brotli: false, stages: false)
        let combined = try run(brotli: true, stages: true)

        XCTAssertEqual(combined.finalDigest, baseline.finalDigest)
        XCTAssertEqual(combined.totalPairs, baseline.totalPairs)
        XCTAssertEqual(combined.totalRawSteps, baseline.totalRawSteps)
        XCTAssertEqual(combined.totalCommandSteps, baseline.totalCommandSteps)
        XCTAssertEqual(combined.totalCopyWrites, baseline.totalCopyWrites)
        XCTAssertEqual(combined.haltBudget, baseline.haltBudget)
        XCTAssertEqual(combined.haltPCOut, baseline.haltPCOut)
        XCTAssertEqual(combined.haltUnmatched, baseline.haltUnmatched)
        XCTAssertEqual(combined.haltUnknown, baseline.haltUnknown)
        XCTAssertEqual(combined.samples.map(\.epoch), baseline.samples.map(\.epoch))
        XCTAssertEqual(combined.samples.map(\.entropyBitsPerByte),
                       baseline.samples.map(\.entropyBitsPerByte))
        XCTAssertEqual(combined.samples.map(\.deltaHFromInitial),
                       baseline.samples.map(\.deltaHFromInitial))
        XCTAssertTrue(combined.instrumentationEnabled)
        XCTAssertNotNil(combined.hostStageAttribution)
        XCTAssertNotNil(combined.finalBrotliBitsPerByte)
    }

    func testCombinedNoSamplesDoesNotRunBrotliButStillAttributesStages() throws {
        let cfg = BenchmarkConfig(seed: 5, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 3,
                                  highOrderComplexityThresholds: [1.0],
                                  sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        var brotliCalls = 0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: false, includeCompression: false,
                           signalInterval: 1, includeBrotli: true,
                           instrumentStages: true),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                XCTFail("signal analysis must not run under no-samples")
                return SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                           includeCompression: includeComp)
            },
            measureBrotliBitsPerByte: { _ in
                brotliCalls += 1
                return 1.0
            })

        XCTAssertEqual(brotliCalls, 0)
        XCTAssertFalse(result.signalsAnalyzed)
        XCTAssertNil(result.initialBrotliBitsPerByte)
        XCTAssertNil(result.finalBrotliBitsPerByte)
        XCTAssertNil(result.initialHighOrderComplexity)
        XCTAssertNil(result.finalHighOrderComplexity)
        XCTAssertTrue(result.highOrderComplexityCrossings.isEmpty)
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertTrue(result.instrumentationEnabled)
        XCTAssertNotNil(result.hostStageAttribution)
    }

    func testCombinedWrongBrotliNilCompressionIsHonestAndKeepsAttribution() throws {
        let cfg = BenchmarkConfig(seed: 7, programCount: 16, mutationP32: 1 << 22,
                                  initMode: .opcode, warmupEpochs: 0, measuredEpochs: 4,
                                  highOrderComplexityThresholds: [1.0],
                                  sampleInterval: 1)
        let soupConfig = try cfg.soupConfig()
        var clock = 0.0
        let result = try BenchmarkRunner.run(
            config: cfg, soupConfig: soupConfig, evaluator: CPUPairEvaluator(),
            deviceName: nil,
            options: .init(analyzeSignals: true, includeCompression: false,
                           signalInterval: 1, includeBrotli: true,
                           instrumentStages: true),
            readMaxRSSBytes: { nil },
            now: { clock += 0.001; return clock },
            gpuSecondsAfterEpoch: { nil },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: cfg.programCount,
                                    includeCompression: includeComp)
            },
            measureBrotliBitsPerByte: { _ in nil })

        XCTAssertTrue(result.signalsAnalyzed)
        XCTAssertNotNil(result.finalEntropyBitsPerByte)
        XCTAssertNil(result.initialBrotliBitsPerByte)
        XCTAssertNil(result.finalBrotliBitsPerByte)
        XCTAssertNil(result.initialHighOrderComplexity)
        XCTAssertNil(result.finalHighOrderComplexity)
        XCTAssertTrue(result.highOrderComplexityCrossings.isEmpty)
        XCTAssertTrue(result.samples.allSatisfy { $0.brotliBitsPerByte == nil })
        XCTAssertTrue(result.samples.allSatisfy { $0.highOrderComplexity == nil })
        XCTAssertTrue(result.instrumentationEnabled)
        XCTAssertNotNil(result.hostStageAttribution)
    }

    // MARK: - Schema-4 config.timedProgramMetrics encode/decode (predecessor defaults)

    /// `config.timedProgramMetrics` is always present in schema-4 JSON: `true` only
    /// under `--timed-program-metrics`, `false` otherwise. The nested config object
    /// carries it as a plain bool.
    func testTimedProgramMetricsEncodedInSchema4Config() throws {
        var cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 2, sampleInterval: 1)
        XCTAssertFalse(cfg.timedProgramMetrics, "default is false")

        let resultOff = combinedResult()  // uses a default config (timedProgramMetrics=false)
        let objectOff = try encodedObject(resultOff)
        let configOff = try XCTUnwrap(objectOff["config"] as? [String: Any])
        XCTAssertEqual(configOff["timedProgramMetrics"] as? Bool, false,
                       "default config encodes timedProgramMetrics: false")

        // Opt-in config: the field encodes as true and survives a round-trip.
        cfg.timedProgramMetrics = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let dataOn = try encoder.encode(cfg)
        let jsonOn = String(decoding: dataOn, as: UTF8.self)
        XCTAssertTrue(jsonOn.contains("\"timedProgramMetrics\":true"),
                       "opt-in config encodes timedProgramMetrics: true")
        let back = try JSONDecoder().decode(BenchmarkConfig.self, from: dataOn)
        XCTAssertTrue(back.timedProgramMetrics, "round-trip preserves the opt-in")
    }

    /// Predecessor-schema JSON (schema 2 and either schema-3 branch) lacks the
    /// `timedProgramMetrics` key entirely. Decoding must default it to `false` (the
    /// in-epoch metrics scan stays off — the default) so a predecessor document
    /// decodes losslessly without inventing the opt-in.
    func testPredecessorSchemaConfigDecodesTimedProgramMetricsAsFalse() throws {
        // Encode a config, then strip the new key to simulate a predecessor-schema doc.
        let cfg = BenchmarkConfig(seed: 1, programCount: 2, warmupEpochs: 0,
                                  measuredEpochs: 2, sampleInterval: 1,
                                  timedProgramMetrics: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(cfg)) as? [String: Any])
        XCTAssertNotNil(object["timedProgramMetrics"], "sanity: key present before strip")
        object.removeValue(forKey: "timedProgramMetrics")

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BenchmarkConfig.self, from: data)
        XCTAssertFalse(decoded.timedProgramMetrics,
                       "predecessor-schema config defaults timedProgramMetrics to false")
        // The other fields decode faithfully.
        XCTAssertEqual(decoded.seed, cfg.seed)
        XCTAssertEqual(decoded.programCount, cfg.programCount)
        XCTAssertEqual(decoded.sampleInterval, cfg.sampleInterval)
    }

    /// `timedProgramMetrics` is independent of the schema-3 host-attribution and paper
    /// sides: a host-attribution-only schema-3 shape (missing the Brotli keys AND the
    /// new config key) decodes with all three sides at their honest defaults.
    func testTimedProgramMetricsDefaultsIndependentlyOfSchema3Sides() throws {
        let result = combinedResult()
        var object = try encodedObject(result)
        // Strip every schema-3 paper key + the new config key.
        for key in ["initialBrotliBitsPerByte", "initialHighOrderComplexity",
                    "finalBrotliBitsPerByte", "finalHighOrderComplexity",
                    "highOrderComplexityCrossings"] {
            object.removeValue(forKey: key)
        }
        var config = try XCTUnwrap(object["config"] as? [String: Any])
        config.removeValue(forKey: "highOrderComplexityThresholds")
        config.removeValue(forKey: "timedProgramMetrics")
        object["config"] = config
        var samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        for i in samples.indices {
            samples[i].removeValue(forKey: "brotliBitsPerByte")
            samples[i].removeValue(forKey: "highOrderComplexity")
        }
        object["samples"] = samples

        let decoded = try decodeObject(object)
        XCTAssertTrue(decoded.instrumentationEnabled, "host-attribution side preserved")
        XCTAssertNotNil(decoded.hostStageAttribution)
        XCTAssertNil(decoded.initialBrotliBitsPerByte, "paper side defaulted to nil")
        XCTAssertTrue(decoded.highOrderComplexityCrossings.isEmpty)
        XCTAssertTrue(decoded.config.highOrderComplexityThresholds.isEmpty)
        XCTAssertFalse(decoded.config.timedProgramMetrics,
                       "new config key defaulted to false independently")
    }
}
