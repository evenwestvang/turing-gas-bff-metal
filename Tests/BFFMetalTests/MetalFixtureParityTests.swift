#if canImport(Metal)
import XCTest
import BFFOracle
import CBFFShared
@testable import BFFMetal

/// ACTUAL GPU validation — macOS only. These tests execute the dynamic-scan
/// Metal evaluator on the system GPU and hold it to bit-exact parity with the
/// committed cubff fixtures and the CPU oracle. They are skipped (never
/// silently passed) when no Metal device exists.
final class MetalFixtureParityTests: XCTestCase {

    private func makeEvaluator() throws -> MetalBFFEvaluator {
        do {
            return try MetalBFFEvaluator()
        } catch MetalBFFEvaluator.EvaluatorError.noDevice {
            throw XCTSkip("no Metal device available on this host")
        }
    }

    /// Evaluator init already enforces the GPU layout probe; surface it as a
    /// named test so a layout regression is identifiable from the test list.
    func testGPULayoutProbeMatchesHostLayout() throws {
        _ = try makeEvaluator()
    }

    /// The headline check of this checkpoint: every committed cubff evaluator
    /// fixture, executed on the GPU, matches cubff and the oracle exactly —
    /// final 128-byte tapes, cubff op counts, and the full shared accounting.
    func testGPUMatchesCubffFixturesAndOracleOnAllCommittedCases() throws {
        _ = try makeEvaluator() // converts no-device into a skip before running
        let file = try CubffFixtureFile.load(from: FixtureLocation.cubffEvaluatorV1)
        let report = try GPUFixtureParityRunner.run(file: file)

        XCTAssertEqual(report.planningIssues, [])
        XCTAssertEqual(report.caseResults.count, file.cases.count)
        for result in report.caseResults {
            for issue in result.issues {
                XCTFail(issue)
            }
        }
        XCTAssertTrue(report.allPassed, report.summaryLines().joined(separator: "\n"))
    }

    /// Direct evaluator smoke test independent of the fixture machinery: a
    /// balanced countdown loop, checked field by field against the oracle.
    func testDirectEvaluateMatchesOracleOnHandWrittenTape() throws {
        let evaluator = try makeEvaluator()

        // ">++[-]" then nulls: move off cell 0, build 2 at cell 1... kept
        // trivially simple; the oracle is the source of expected values.
        var tape = [UInt8](repeating: 0, count: BFF.pairTapeSize)
        tape[0] = BFFOp.head0Right
        tape[1] = BFFOp.inc
        tape[2] = BFFOp.inc
        tape[3] = BFFOp.loopOpen
        tape[4] = BFFOp.dec
        tape[5] = BFFOp.loopClose

        let oracle = BFFInterpreter.run(pairTape: tape, variant: .noheads,
                                        bracketMode: .dynamicScan,
                                        stepBudget: BFF.stepBudget)
        let outcomes = try evaluator.evaluate(pairTapes: [tape],
                                              variant: .noheads,
                                              stepBudget: BFF.stepBudget)
        XCTAssertEqual(outcomes.count, 1)
        let gpu = outcomes[0]
        XCTAssertEqual(gpu.finalTape, oracle.tape)
        XCTAssertEqual(Int(gpu.steps), oracle.steps)
        XCTAssertEqual(Int(gpu.noopSteps), oracle.noopSteps)
        XCTAssertEqual(Int(gpu.copyWrites), oracle.copyWrites)
        XCTAssertEqual(Int(gpu.loopOps), oracle.loopOps)
        XCTAssertEqual(gpu.halt, UInt32(oracle.halt.rawValue))
    }

    /// Input validation must reject what the shared fields cannot carry.
    func testEvaluateRejectsInvalidInputs() throws {
        let evaluator = try makeEvaluator()
        XCTAssertThrowsError(try evaluator.evaluate(
            pairTapes: [[0, 1, 2]], variant: .noheads, stepBudget: 8192))
        XCTAssertThrowsError(try evaluator.evaluate(
            pairTapes: [[UInt8](repeating: 0, count: BFF.pairTapeSize)],
            variant: .noheads, stepBudget: 0))
        XCTAssertEqual(try evaluator.evaluate(pairTapes: [], variant: .noheads,
                                              stepBudget: 8192), [])
    }
}
#endif
