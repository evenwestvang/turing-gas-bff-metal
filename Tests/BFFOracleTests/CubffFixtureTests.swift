import XCTest
@testable import BFFOracle

/// Evaluator parity against genuine cubff fixtures.
///
/// Every case in `Fixtures/cubff-evaluator-v1.json` was produced by executing the
/// unmodified cubff evaluator (`bff.inc.h`) at the pinned upstream commit — see
/// `Tools/cubff-grounding/generate.sh` and `Docs/CubffGrounding.md`. These tests
/// prove the oracle's `.dynamicScan` interpreter reproduces cubff's two
/// observables (final tape, returned op count) exactly, for both variants.
///
/// This is EVALUATOR parity only. Simulation-level fixtures (`GoldenFixture`,
/// `counter-pcg-v1`) remain a separate, oracle-internal contract; no fixed-seed
/// whole-soup cubff parity is claimed anywhere.
final class CubffFixtureTests: XCTestCase {

    /// The commit this repo is grounded against. Must match the fixture file —
    /// regenerating against a different upstream revision requires re-verifying
    /// the six alignment points in Docs/CubffGrounding.md.
    static let pinnedCommit = "f212e849027c98fcf4b242eccfb5fed435223e23"

    static let file: CubffFixtureFile = {
        guard let url = Bundle.module.url(forResource: "cubff-evaluator-v1",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            fatalError("cubff-evaluator-v1.json missing from test resources")
        }
        return try! CubffFixtureFile.load(from: url)
    }()

    func testProvenanceIsPinned() {
        XCTAssertEqual(Self.file.upstream.commit, Self.pinnedCommit)
        XCTAssertEqual(Self.file.upstream.url,
                       "https://github.com/paradigms-of-intelligence/cubff")
        XCTAssertEqual(Self.file.formatVersion, CubffFixtureFile.currentFormatVersion)
        XCTAssertTrue(Self.file.upstream.sourceFiles.contains("bff.inc.h"))
    }

    /// The curated coverage set must be present — an accidentally truncated or
    /// regenerated-empty fixture file must fail loudly, not pass vacuously.
    func testCoverageIsComplete() {
        let names = Set(Self.file.cases.map(\.name))
        let required = [
            "noheads-all-zero", "noheads-executes-from-zero",
            "noheads-ordinary-ops", "head0-wrap-backward", "head0-wrap-forward",
            "cross-half-write", "cross-half-read", "balanced-loop-countdown",
            "taken-open-skips-body", "loop-close-reenters-body",
            "unmatched-open-taken", "unmatched-close-taken",
            "unmatched-brackets-not-taken", "self-modified-bracket-live-scan",
            "inc-turns-open-into-close", "created-instruction-executes",
            "ops-exclude-comments", "seeded-heads-basic",
            "seeded-heads-zero-seeds", "seeded-heads-mod-128",
            "seeded-heads-unmatched-open", "seeded-heads-wrap-forward",
        ]
        for name in required {
            XCTAssertTrue(names.contains(name), "missing required case \(name)")
        }
        XCTAssertGreaterThanOrEqual(Self.file.cases.count, 50,
                                    "random sweep cases missing")
        XCTAssertTrue(Self.file.cases.contains { $0.variant == "bff" })
        XCTAssertTrue(Self.file.cases.contains { $0.variant == "bff_noheads" })
    }

    /// Every compatible observable of every case must match exactly.
    func testEveryCaseMatchesOracleExactly() {
        for c in Self.file.cases {
            let issues = CubffFixtureComparator.compare(c)
            XCTAssertTrue(issues.isEmpty,
                          "case '\(c.name)' [\(c.variant)]: "
                          + issues.joined(separator: "; "))
        }
    }

    /// Spot-check the semantics the fixtures were designed to pin, so a
    /// regression in the comparator itself (e.g. comparing the wrong field)
    /// cannot silently pass.
    func testKeyCasesPinExpectedSemantics() throws {
        func c(_ name: String) throws -> CubffFixtureFile.Case {
            try XCTUnwrap(Self.file.cases.first { $0.name == name }, name)
        }

        // All-zero tape: 128 executed steps, all comments -> cubff reports 0 ops.
        XCTAssertEqual(try c("noheads-all-zero").expectedOps, 0)

        // A taken-but-unmatched bracket still costs one reported op.
        XCTAssertEqual(try c("unmatched-open-taken").expectedOps, 2)
        XCTAssertEqual(try c("unmatched-close-taken").expectedOps, 2)

        // Budget accounting is exact: the ']'-spin executes its full budget of
        // command bytes.
        XCTAssertEqual(try c("loop-close-reenters-body").expectedOps, 8192)
        XCTAssertEqual(try c("loop-close-reenters-body-small-budget").expectedOps, 100)

        // cubff scans the LIVE tape: the self-modification case must show the
        // dynamic-scan outcome (tape[99] untouched), not the frozen-table one
        // (tape[99] == 3). This is the D1 grounding fact.
        let live = try c("self-modified-bracket-live-scan")
        let expected = try XCTUnwrap(live.expectedTape)
        XCTAssertEqual(expected[99], 0, "cubff followed the frozen-table path?!")
        XCTAssertEqual(expected[100], BFFOp.loopOpen)

        // And the oracle's jumpTable mode must DIVERGE from cubff on that case —
        // the expected-difference fixture for the GPU fast path.
        let input = try XCTUnwrap(live.inputTape)
        let frozen = BFFInterpreter.run(pairTape: input, variant: .noheads,
                                        bracketMode: .jumpTable,
                                        stepBudget: live.stepBudget)
        XCTAssertNotEqual(frozen.tape, expected,
                          "jumpTable mode unexpectedly matches cubff here — "
                          + "the D1 divergence example no longer diverges")
        XCTAssertEqual(frozen.tape[99], 3)
    }
}
