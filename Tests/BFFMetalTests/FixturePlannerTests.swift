import XCTest
import BFFOracle
@testable import BFFMetal

/// Platform-independent tests of the dispatch planner (no GPU involved).
final class FixturePlannerTests: XCTestCase {

    // MARK: Grouping

    func testGroupsByVariantAndBudgetPreservingOrder() throws {
        let file = try TestFixtures.file([
            .init(name: "a", variant: "bff_noheads", stepBudget: 8192),
            .init(name: "b", variant: "bff", stepBudget: 8192),
            .init(name: "c", variant: "bff_noheads", stepBudget: 100),
            .init(name: "d", variant: "bff_noheads", stepBudget: 8192),
            .init(name: "e", variant: "bff", stepBudget: 8192),
        ])
        let (groups, issues) = EvaluatorFixturePlanner.plan(for: file)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(groups, [
            EvaluatorDispatchGroup(variant: .noheads, stepBudget: 8192, caseIndices: [0, 3]),
            EvaluatorDispatchGroup(variant: .seededHeads, stepBudget: 8192, caseIndices: [1, 4]),
            EvaluatorDispatchGroup(variant: .noheads, stepBudget: 100, caseIndices: [2]),
        ])
    }

    func testEveryPlannedIndexIsUniqueAndInRange() throws {
        let file = try TestFixtures.file((0..<10).map {
            .init(name: "case-\($0)",
                  variant: $0 % 2 == 0 ? "bff_noheads" : "bff",
                  stepBudget: $0 < 5 ? 8192 : 100)
        })
        let (groups, issues) = EvaluatorFixturePlanner.plan(for: file)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(groups.flatMap(\.caseIndices).sorted(), Array(0..<10))
    }

    // MARK: Rejections (reported, never silently dropped)

    func testUnknownVariantIsReported() throws {
        let file = try TestFixtures.file([
            .init(name: "weird", variant: "bff_mystery"),
            .init(name: "fine"),
        ])
        let (groups, issues) = EvaluatorFixturePlanner.plan(for: file)
        XCTAssertEqual(groups.flatMap(\.caseIndices), [1])
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("weird"))
        XCTAssertTrue(issues[0].contains("bff_mystery"))
    }

    func testBadTapesAreReported() throws {
        let file = try TestFixtures.file([
            .init(name: "short-input", inputHex: "0000"),
            .init(name: "bad-hex-expected",
                  expectedHex: String(repeating: "zz", count: 128)),
        ])
        let (groups, issues) = EvaluatorFixturePlanner.plan(for: file)
        XCTAssertTrue(groups.isEmpty)
        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues[0].contains("short-input"))
        XCTAssertTrue(issues[1].contains("bad-hex-expected"))
    }

    func testUnrepresentableBudgetsAreReported() throws {
        let file = try TestFixtures.file([
            .init(name: "zero-budget", stepBudget: 0),
            .init(name: "negative-budget", stepBudget: -1),
            .init(name: "oversized-budget",
                  stepBudget: BFFEvalLayout.maxStepBudget + 1),
            .init(name: "max-budget", stepBudget: BFFEvalLayout.maxStepBudget),
        ])
        let (groups, issues) = EvaluatorFixturePlanner.plan(for: file)
        XCTAssertEqual(groups.flatMap(\.caseIndices), [3],
                       "exactly UInt32.max is still representable")
        XCTAssertEqual(issues.count, 3)
        for issue in issues {
            XCTAssertTrue(issue.contains("budget"), issue)
        }
    }

    // MARK: The real committed fixture file

    func testCommittedFixtureFilePlansCompletely() throws {
        let file = try CubffFixtureFile.load(from: FixtureLocation.cubffEvaluatorV1)
        let (groups, issues) = EvaluatorFixturePlanner.plan(for: file)
        XCTAssertEqual(issues, [], "every committed case must be dispatchable")
        XCTAssertEqual(groups.flatMap(\.caseIndices).sorted(),
                       Array(file.cases.indices),
                       "every committed case must appear in exactly one dispatch")
        // Both grounded initial states are actually exercised on the GPU.
        XCTAssertTrue(groups.contains { $0.variant == .noheads })
        XCTAssertTrue(groups.contains { $0.variant == .seededHeads })
        // The fixture-configurable budget is real: the small-budget spin case
        // must land in its own dispatch.
        XCTAssertTrue(groups.contains { $0.stepBudget != BFF.stepBudget },
                      "committed fixtures include a non-default budget")
    }
}
