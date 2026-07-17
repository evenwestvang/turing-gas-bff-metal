import XCTest
@testable import BFFMetal

/// Focused coverage for the strict `--seeds`/`--seed` parser (blocker 6). A benchmark
/// seed is a scientific input, so the parser must reject anything ambiguous rather
/// than silently truncate or wrap — every rejection below would otherwise be a
/// silently-wrong run.
final class SeedParsingTests: XCTestCase {

    // MARK: - Accepted

    func testParsesValidUnsignedDecimals() throws {
        XCTAssertEqual(try parseSeedList("1"), [1])
        XCTAssertEqual(try parseSeedList("0"), [0])
        XCTAssertEqual(try parseSeedList("1,2,3"), [1, 2, 3])
        // Exact UInt32 maximum is accepted.
        XCTAssertEqual(try parseSeedList("4294967295"), [UInt32.max])
        // Leading zeros are unambiguous decimal.
        XCTAssertEqual(try parseSeedList("007"), [7])
    }

    func testSingleSeedRequiresExactlyOneToken() throws {
        XCTAssertEqual(try parseSingleSeed("42"), 42)
        XCTAssertThrowsError(try parseSingleSeed("1,2"))
    }

    // MARK: - Rejected: empties (doubled / leading / trailing commas)

    func testRejectsEmptyTokens() {
        XCTAssertThrowsError(try parseSeedList("")) { assertIsEmptyToken($0) }
        XCTAssertThrowsError(try parseSeedList("1,")) { assertIsEmptyToken($0) }   // trailing
        XCTAssertThrowsError(try parseSeedList(",1")) { assertIsEmptyToken($0) }   // leading
        XCTAssertThrowsError(try parseSeedList("1,,2")) { assertIsEmptyToken($0) } // doubled
    }

    // MARK: - Rejected: signs, whitespace, malformed

    func testRejectsSigns() {
        XCTAssertThrowsError(try parseSeedList("+1")) {
            XCTAssertEqual($0 as? SeedParseError, .signNotAllowed(token: "+1"))
        }
        XCTAssertThrowsError(try parseSeedList("-1")) {
            XCTAssertEqual($0 as? SeedParseError, .signNotAllowed(token: "-1"))
        }
    }

    func testRejectsWhitespace() {
        XCTAssertThrowsError(try parseSeedList(" 1")) { assertIsWhitespace($0) }
        XCTAssertThrowsError(try parseSeedList("1 ")) { assertIsWhitespace($0) }
        XCTAssertThrowsError(try parseSeedList("1, 2")) { assertIsWhitespace($0) }
        XCTAssertThrowsError(try parseSeedList("1\t")) { assertIsWhitespace($0) }
    }

    func testRejectsMalformedAndTrailingJunk() {
        for bad in ["abc", "12a", "0x10", "1.0", "1e3", "٥"] {
            XCTAssertThrowsError(try parseSeedList(bad), "should reject '\(bad)'") {
                XCTAssertEqual($0 as? SeedParseError, .notDecimal(token: bad))
            }
        }
    }

    // MARK: - Rejected: overflow / out of UInt32 domain (never wraps)

    func testRejectsUInt32Overflow() {
        // Fits UInt64 but exceeds the UInt32 seed domain — must NOT wrap to 0.
        XCTAssertThrowsError(try parseSeedList("4294967296")) {
            XCTAssertEqual($0 as? SeedParseError,
                           .outsideUInt32(value: 4_294_967_296, token: "4294967296"))
        }
    }

    func testRejectsUInt64Overflow() {
        // Beyond UInt64 entirely — caught at the lexing stage.
        XCTAssertThrowsError(try parseSeedList("18446744073709551616")) {
            XCTAssertEqual($0 as? SeedParseError,
                           .overflowsUInt64(token: "18446744073709551616"))
        }
    }

    /// The whole point: the value that would truncate to a valid-looking seed is
    /// rejected, not silently wrapped. 4294967296 (2^32) would wrap to 0.
    func testNeverTruncatesOrWraps() {
        XCTAssertThrowsError(try parseSeedList("4294967296"))
        // And a value that would truncate to 1 under 32-bit wraparound (2^32 + 1):
        XCTAssertThrowsError(try parseSeedList("4294967297"))
    }

    // MARK: - Helpers

    private func assertIsEmptyToken(_ error: Error) {
        guard case .emptyToken = error as? SeedParseError else {
            return XCTFail("expected emptyToken, got \(error)")
        }
    }
    private func assertIsWhitespace(_ error: Error) {
        guard case .whitespaceNotAllowed = error as? SeedParseError else {
            return XCTFail("expected whitespaceNotAllowed, got \(error)")
        }
    }
}
