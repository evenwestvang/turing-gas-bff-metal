import XCTest
import BFFOracle
@testable import BFFMetal

/// Platform-independent tests of the parity comparator, using the CPU oracle to
/// simulate a correct GPU (valid because the oracle is proven bit-identical to
/// cubff on these fixtures by CubffFixtureTests) and hand-corrupted outcomes to
/// prove every mismatch produces an actionable diagnostic.
final class GPUFixtureComparatorTests: XCTestCase {

    /// A GPU outcome exactly as a semantically correct kernel would produce it.
    private func oracleOutcome(for c: CubffFixtureFile.Case) throws -> GPUPairOutcome {
        let input = try XCTUnwrap(c.inputTape)
        let variant = try XCTUnwrap(c.oracleVariant)
        let r = BFFInterpreter.run(pairTape: input, variant: variant,
                                   bracketMode: .dynamicScan,
                                   stepBudget: c.stepBudget)
        return GPUPairOutcome(finalTape: r.tape,
                              steps: UInt32(r.steps),
                              noopSteps: UInt32(r.noopSteps),
                              copyWrites: UInt32(r.copyWrites),
                              loopOps: UInt32(r.loopOps),
                              halt: UInt32(r.halt.rawValue))
    }

    /// A correct evaluator passes every committed case — the full comparator
    /// chain (fixture anchor + oracle anchor) reports clean.
    func testOracleSimulatedGPUPassesAllCommittedCases() throws {
        let file = try CubffFixtureFile.load(from: FixtureLocation.cubffEvaluatorV1)
        for c in file.cases {
            let issues = GPUFixtureComparator.compare(fixtureCase: c,
                                                      gpu: try oracleOutcome(for: c))
            XCTAssertEqual(issues, [], "case \(c.name) should be clean")
        }
    }

    func testCorruptedTapeByteIsDiagnosedWithIndexAndValues() throws {
        let file = try CubffFixtureFile.load(from: FixtureLocation.cubffEvaluatorV1)
        let c = try XCTUnwrap(file.cases.first { $0.name == "balanced-loop-countdown" })
        var gpu = try oracleOutcome(for: c)
        gpu.finalTape[37] &+= 1

        let issues = GPUFixtureComparator.compare(fixtureCase: c, gpu: gpu)
        XCTAssertEqual(issues.count, 2, "both anchors should flag the tape: \(issues)")
        for issue in issues {
            XCTAssertTrue(issue.contains(c.name), issue)
            XCTAssertTrue(issue.contains("index 37"), issue)
        }
        XCTAssertTrue(issues[0].contains("cubff"), issues[0])
        XCTAssertTrue(issues[1].contains("oracle"), issues[1])
    }

    func testWrongOpCountIsDiagnosed() throws {
        let file = try CubffFixtureFile.load(from: FixtureLocation.cubffEvaluatorV1)
        let c = try XCTUnwrap(file.cases.first { $0.name == "noheads-ordinary-ops" })
        var gpu = try oracleOutcome(for: c)
        gpu.steps += 1 // corrupts both raw steps and the derived cubff op count

        let issues = GPUFixtureComparator.compare(fixtureCase: c, gpu: gpu)
        XCTAssertTrue(issues.contains { $0.contains("op count") &&
                                        $0.contains("\(c.expectedOps)") },
                      "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("budgeted steps") }, "\(issues)")
    }

    func testNoopAccountingIsSeparatelyDiagnosed() throws {
        let file = try CubffFixtureFile.load(from: FixtureLocation.cubffEvaluatorV1)
        let c = try XCTUnwrap(file.cases.first { $0.name == "ops-exclude-comments" })
        var gpu = try oracleOutcome(for: c)
        // Same raw steps, wrong comment split: cubff op count shifts too.
        gpu.noopSteps += 1

        let issues = GPUFixtureComparator.compare(fixtureCase: c, gpu: gpu)
        XCTAssertTrue(issues.contains { $0.contains("no-op steps") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("op count") }, "\(issues)")
        XCTAssertFalse(issues.contains { $0.contains("budgeted steps") },
                       "raw budget accounting was untouched: \(issues)")
    }

    func testWrongHaltAndCountersAreDiagnosed() throws {
        let file = try CubffFixtureFile.load(from: FixtureLocation.cubffEvaluatorV1)
        let c = try XCTUnwrap(file.cases.first { $0.name == "unmatched-open-taken" })
        var gpu = try oracleOutcome(for: c)
        XCTAssertEqual(gpu.halt, UInt32(HaltReason.unmatched.rawValue),
                       "fixture precondition: this case halts on unmatched")
        gpu.halt = UInt32(HaltReason.budget.rawValue)
        gpu.copyWrites += 1
        gpu.loopOps += 1

        let issues = GPUFixtureComparator.compare(fixtureCase: c, gpu: gpu)
        XCTAssertTrue(issues.contains { $0.contains("halt reason") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("copyWrites") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("loopOps") }, "\(issues)")
    }

    func testWrongSizeGPUTapeIsRejected() throws {
        let c = try TestFixtures.singleCase(.init(name: "size-check"))
        let gpu = GPUPairOutcome(finalTape: [0, 1, 2], steps: 0, noopSteps: 0,
                                 copyWrites: 0, loopOps: 0, halt: 1)
        let issues = GPUFixtureComparator.compare(fixtureCase: c, gpu: gpu)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("3 bytes"), issues[0])
    }

    func testCommandStepsDerivation() {
        let gpu = GPUPairOutcome(finalTape: [], steps: 8192, noopSteps: 4096,
                                 copyWrites: 0, loopOps: 0, halt: 1)
        XCTAssertEqual(gpu.commandSteps, 4096,
                       "cubff op count = budgeted steps - no-op steps")
    }
}
