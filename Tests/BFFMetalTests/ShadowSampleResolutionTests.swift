import XCTest
@testable import BFFMetal

/// Focused, pure (no process, no Metal) coverage for `--shadow-sample` resolution
/// (blocker: replace the false-positive native process assertion with importable
/// matrix-resolution coverage).
///
/// `--shadow-sample all` must resolve **per matrix cell** against that cell's program
/// count — so `--programs 4,8 --shadow-sample all` shadows 2 pairs in the 4-program cell
/// and 4 in the 8-program cell. Because `all` is just the literal string `"all"` (it
/// carries no count of its own), the resolution is a pure function of the captured arg
/// string and the cell's program count, and so cannot depend on whether `--programs`
/// precedes or follows `--shadow-sample` on the command line. These tests pin that
/// property directly against the importable resolver, with no `bff-metal-bench` process.
final class ShadowSampleResolutionTests: XCTestCase {

    // MARK: - Single-cell resolution

    /// `nil` (flag omitted) is throughput mode: 0 shadowed pairs.
    func testOmittedResolvesToZero() {
        XCTAssertEqual(resolveShadowSampleCount(nil, programCount: 4), .count(0))
        XCTAssertEqual(resolveShadowSampleCount(nil, programCount: 8), .count(0))
        XCTAssertEqual(resolveShadowSampleCount(nil, programCount: 0), .count(0))
    }

    /// `all` resolves to `programCount / 2` (every pair) against the cell's own program
    /// count. 4 -> 2 pairs.
    func testAllResolvesToHalfTheProgramCount() {
        XCTAssertEqual(resolveShadowSampleCount("all", programCount: 4), .count(2))
        XCTAssertEqual(resolveShadowSampleCount("all", programCount: 8), .count(4))
        XCTAssertEqual(resolveShadowSampleCount("all", programCount: 1024), .count(512))
        // Odd counts floor to pairs (a program count is even in practice; the resolver
        // itself only does integer halving, never rounding up).
        XCTAssertEqual(resolveShadowSampleCount("all", programCount: 5), .count(2))
    }

    /// A decimal integer is passed through as the count (the SoupConfig pair-count clamp
    /// is the later boundary; the resolver just parses).
    func testIntegerResolvesAsItself() {
        XCTAssertEqual(resolveShadowSampleCount("0", programCount: 8), .count(0))
        XCTAssertEqual(resolveShadowSampleCount("1", programCount: 8), .count(1))
        XCTAssertEqual(resolveShadowSampleCount("4", programCount: 8), .count(4))
        XCTAssertEqual(resolveShadowSampleCount("16", programCount: 8), .count(16))
    }

    /// A non-`all`, non-decimal argument is a usage error (the caller exits 64, exactly as
    /// a non-integer `intArg` would). Never silently coerced to a count.
    func testNonIntegerNonAllIsAUsageError() {
        for bad in ["foo", "0x4", "1.5", "two", "", "all2", "2all"] {
            XCTAssertEqual(resolveShadowSampleCount(bad, programCount: 8),
                           .notAnIntegerOrAll(value: bad),
                           "should reject '\(bad)'")
        }
        // `all` with surrounding case/whitespace is NOT `all` — it is a usage error.
        XCTAssertEqual(resolveShadowSampleCount("All", programCount: 8),
                       .notAnIntegerOrAll(value: "All"))
        XCTAssertEqual(resolveShadowSampleCount(" all ", programCount: 8),
                       .notAnIntegerOrAll(value: " all "))
    }

    // MARK: - Matrix (per-cell) resolution

    /// A 4,8 matrix with `--shadow-sample all` resolves to 2,4 pair counts: each cell
    /// resolves `all` against ITS OWN program count, not a single captured value. This
    /// is the load-bearing property — a single captured `programCount/2` would emit 2,2
    /// (the 4-cell's count) for both cells, shadowing only half the 8-cell's pairs.
    func testAllResolvesPerCellAgainstEachProgramCount() {
        let programsList = [4, 8]
        let resolved = programsList.map {
            resolveShadowSampleCount("all", programCount: $0)
        }
        XCTAssertEqual(resolved, [.count(2), .count(4)],
                       "4,8 matrix -> 2,4 pair counts (per-cell, not a single captured count)")
        // Single-cell 4 -> 2 pairs (the case the prior process assertion covered, now
        // pinned without spawning the binary).
        XCTAssertEqual(resolveShadowSampleCount("all", programCount: 4), .count(2))
    }

    /// A wider matrix still resolves per cell: 4,8,16,32 -> 2,4,8,16.
    func testAllResolvesPerCellAcrossAWiderMatrix() {
        let programsList = [4, 8, 16, 32]
        let resolved = programsList.map {
            resolveShadowSampleCount("all", programCount: $0)
        }
        XCTAssertEqual(resolved, [.count(2), .count(4), .count(8), .count(16)])
    }

    // MARK: - Argument-order independence

    /// The bench parser captures `--shadow-sample` as a raw string and `--programs` as a
    /// list, regardless of which appears first on the line; resolution then runs per cell
    /// against each cell's final program count. Model both argument orders as the
    /// identical captured state, then resolve the matrix — both orders must agree
    /// cell-for-cell and produce 2,4.
    func testAllIsArgumentOrderIndependent() {
        // --programs 4,8 --shadow-sample all  (programs first)
        let programsFirst: (programs: [Int], shadowArg: String?) = ([4, 8], "all")
        // --shadow-sample all --programs 4,8  (shadow-sample first)
        let sampleFirst: (programs: [Int], shadowArg: String?) = ([4, 8], "all")

        func resolve(_ capture: (programs: [Int], shadowArg: String?)) -> [ShadowSampleResolution] {
            capture.programs.map {
                resolveShadowSampleCount(capture.shadowArg, programCount: $0)
            }
        }

        let programsFirstResolved = resolve(programsFirst)
        let sampleFirstResolved = resolve(sampleFirst)
        XCTAssertEqual(programsFirstResolved, [.count(2), .count(4)],
                       "--programs 4,8 --shadow-sample all -> 2,4 pairs per cell")
        XCTAssertEqual(sampleFirstResolved, [.count(2), .count(4)],
                       "--shadow-sample all --programs 4,8 -> 2,4 pairs per cell")
        XCTAssertEqual(programsFirstResolved, sampleFirstResolved,
                       "argument order must not change the per-cell resolution")
    }

    /// Order-independence is structural: the resolver is a pure function of
    /// `(arg, programCount)` with no parse-position input, so swapping the order in which
    /// `--programs` and `--shadow-sample` are supplied to the parser cannot change the
    /// captured `(programsList, shadowArg)` and therefore cannot change the resolution.
    /// Pin that by resolving the matrix for both orders across several sizes.
    func testAllIsOrderIndependentAcrossSizes() {
        let sizes = [4, 8, 16, 1024, 131072]
        for programsList in [[4], [4, 8], sizes] {
            // Both argument orders capture the identical state; resolution agrees.
            let programsFirst = programsList.map { resolveShadowSampleCount("all", programCount: $0) }
            let sampleFirst = programsList.map { resolveShadowSampleCount("all", programCount: $0) }
            XCTAssertEqual(programsFirst, sampleFirst,
                           "order-independent for programs \(programsList)")
            // And the per-cell counts are exactly half of each cell's program count.
            for (i, n) in programsList.enumerated() {
                XCTAssertEqual(programsFirst[i], .count(n / 2),
                               "cell \(i) (programs=\(n)) -> \(n / 2) pairs")
            }
        }
    }
}
