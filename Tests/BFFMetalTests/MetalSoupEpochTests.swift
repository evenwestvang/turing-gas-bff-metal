#if canImport(Metal)
import XCTest
import BFFOracle
@testable import BFFMetal

/// ACTUAL GPU validation of the small-soup epoch loop — macOS only. Runs a modest
/// soup for several epochs on the system GPU and holds it to the CPU oracle both
/// per-pair (the built-in shadow) and end-to-end (identical scattered soup and
/// digest vs a `CPUPairEvaluator` run of the same config). Skipped, never silently
/// passed, when no Metal device exists.
final class MetalSoupEpochTests: XCTestCase {

    private func makeEvaluator() throws -> MetalBFFEvaluator {
        do {
            return try MetalBFFEvaluator()
        } catch MetalBFFEvaluator.EvaluatorError.noDevice {
            throw XCTSkip("no Metal device available on this host")
        }
    }

    private func config(seed: UInt32 = 42, programs: Int = 16,
                        variant: BFFVariant = .noheads) throws -> SoupConfig {
        // Full shadow (shadowSampleCount nil = every pair) and a modest budget.
        try SoupConfig(seed: seed, programCount: programs, stepBudget: 4096,
                       mutationP32: BFF.defaultMutationP32, variant: variant)
    }

    /// Every shadowed pair matches across several GPU epochs, for both variants.
    func testGPUEpochsHaveNoShadowMismatches() throws {
        let gpu = try makeEvaluator()
        for variant in BFFVariant.allCases {
            var runner = SoupRunner(config: try config(variant: variant))
            let reports = try runner.run(epochs: 6, using: gpu)
            for r in reports {
                XCTAssertEqual(r.shadowChecked, runner.config.pairCount, "\(variant)")
                XCTAssertEqual(r.shadowMismatches, [],
                               (["\(variant)"] + r.shadowMismatches.map(\.summary))
                                   .joined(separator: "\n"))
            }
        }
    }

    /// The GPU-driven run is bit-identical to the CPU-reference run of the same
    /// config: same scattered soup and same digest at every epoch.
    func testGPURunMatchesCPUReferenceEndToEnd() throws {
        let gpu = try makeEvaluator()
        var gpuRunner = SoupRunner(config: try config())
        var cpuRunner = SoupRunner(config: try config())
        for _ in 0 ..< 6 {
            let g = try gpuRunner.runEpoch(using: gpu)
            let c = try cpuRunner.runEpoch(using: CPUPairEvaluator())
            XCTAssertEqual(g.digest, c.digest)
            XCTAssertEqual(g.counters, c.counters)
            XCTAssertEqual(g.metrics, c.metrics)
        }
        XCTAssertEqual(gpuRunner.soup, cpuRunner.soup)
    }
}
#endif
