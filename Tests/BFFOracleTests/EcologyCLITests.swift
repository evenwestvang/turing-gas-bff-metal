import Foundation
import XCTest
@testable import BFFOracle

/// Unit tests for the strict-lexical CLI parser and the `BFFECO1` checkpoint
/// file loader (`EcologyCLIParser`, `EcologyCheckpointFile`). These exercise
/// the library functions directly; process-level coverage for the compiled
/// `bff-ecology-epoch` binary lives in `EcologyCLIProcessTests.swift`.
///
/// Normative anchors:
/// - `Docs/Architecture/07-ecological-mode.md` §1 (required labels),
///   §9 (checkpoint/replay contract), §11 (CLI surface `bff-ecology-epoch`).
/// - Strict lexical numeric parsing: ASCII digits only, no signs, no
///   whitespace, no hex, no exponent.
/// - Malformed/oversized/truncated/inconsistent input returns controlled
///   nonzero errors and never traps.
/// - Ecological and well-mixed checkpoint inputs reject each other clearly.
final class EcologyCLIParserTests: XCTestCase {

    // MARK: - Strict lexical numeric parsing

    func testParseUInt32AcceptsBoundaryDecimalValues() throws {
        XCTAssertEqual(try EcologyCLIParser.parseUInt32("0", name: "x"), 0)
        XCTAssertEqual(try EcologyCLIParser.parseUInt32("1", name: "x"), 1)
        XCTAssertEqual(try EcologyCLIParser.parseUInt32("4294967295",
                                                        name: "x"),
                       UInt32.max)
    }

    func testParseUInt32RejectsMalformedInputs() {
        let malformed: [String] = [
            "",           // empty
            " ",          // whitespace
            "1 ",         // trailing whitespace
            " 1",         // leading whitespace
            "1.0",        // decimal point
            "+1",         // sign
            "-1",         // sign
            "0x10",       // hex prefix
            "1e3",        // exponent
            "abc",        // alpha
            "1,2",        // comma
            "１",          // fullwidth digit (non-ASCII)
            "1\u{00A0}",  // non-breaking space
        ]
        for raw in malformed {
            XCTAssertThrowsError(
                try EcologyCLIParser.parseUInt32(raw, name: "test")) { error in
                XCTAssertEqual(error as? EcologyCLIError,
                              .malformedNumber(name: "test", raw: raw),
                              "raw='\(raw)' should be malformed")
            }
        }
    }

    func testParseUInt32RejectsOutOfRange() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parseUInt32("4294967296", name: "--seed")
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .outOfRange(name: "--seed", raw: "4294967296"))
        }
        XCTAssertThrowsError(
            try EcologyCLIParser.parseUInt32("99999999999999999999",
                                              name: "--mutation-p32")
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .outOfRange(name: "--mutation-p32",
                                       raw: "99999999999999999999"))
        }
    }

    func testParseNonNegativeIntAcceptsAndRejects() throws {
        XCTAssertEqual(try EcologyCLIParser.parseNonNegativeInt("0",
                                                                name: "x"), 0)
        XCTAssertEqual(try EcologyCLIParser.parseNonNegativeInt("12345",
                                                                name: "x"), 12345)
        // Out-of-range on Int (even on 64-bit, this exceeds Int.max).
        XCTAssertThrowsError(
            try EcologyCLIParser.parseNonNegativeInt("99999999999999999999",
                                                     name: "--epochs")
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .outOfRange(name: "--epochs",
                                       raw: "99999999999999999999"))
        }
        // Same lexical rules as UInt32.
        XCTAssertThrowsError(
            try EcologyCLIParser.parseNonNegativeInt("-1", name: "--epochs")
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .malformedNumber(name: "--epochs", raw: "-1"))
        }
        XCTAssertThrowsError(
            try EcologyCLIParser.parseNonNegativeInt("0x10", name: "--budget")
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .malformedNumber(name: "--budget", raw: "0x10"))
        }
    }

    // MARK: - Option parsing

    func testParseMinimalSeedOnly() throws {
        let opts = try EcologyCLIParser.parse(args: ["--seed", "7"])
        XCTAssertEqual(opts.seed, 7)
        XCTAssertEqual(opts.epochs, 0)
        XCTAssertNil(opts.stepBudget)
        XCTAssertNil(opts.mutationP32)
        // The parser intentionally leaves variant/bracketMode nil when the
        // flags are absent; `main` applies the defaults (`bff-ecology-epoch`
        // main.swift: `options.variant ?? .noheads`,
        // `options.bracketMode ?? .dynamicScan`). Asserting a default here
        // would couple the parser to a policy that lives in the CLI entry
        // point and weaken the rejection contract for `--info`/`--checkpoint`.
        XCTAssertNil(opts.variant)
        XCTAssertNil(opts.bracketMode)
        XCTAssertNil(opts.checkpointURL)
        XCTAssertNil(opts.saveURL)
        XCTAssertFalse(opts.infoOnly)
    }

    func testParseFullConfig() throws {
        let opts = try EcologyCLIParser.parse(args: [
            "--seed", "123",
            "--epochs", "4",
            "--budget", "256",
            "--mutation-p32", "1024",
            "--variant", "bff",
            "--brackets", "jumpTable",
            "--save", "/tmp/cp.json",
        ])
        XCTAssertEqual(opts.seed, 123)
        XCTAssertEqual(opts.epochs, 4)
        XCTAssertEqual(opts.stepBudget, 256)
        XCTAssertEqual(opts.mutationP32, 1024)
        XCTAssertEqual(opts.variant, .seededHeads)
        XCTAssertEqual(opts.bracketMode, .jumpTable)
        XCTAssertEqual(opts.saveURL?.path, "/tmp/cp.json")
        XCTAssertNil(opts.checkpointURL)
        XCTAssertFalse(opts.infoOnly)
    }

    func testParseCheckpointMode() throws {
        let opts = try EcologyCLIParser.parse(args: [
            "--checkpoint", "/tmp/cp.json",
            "--epochs", "3",
        ])
        XCTAssertEqual(opts.checkpointURL?.path, "/tmp/cp.json")
        XCTAssertEqual(opts.epochs, 3)
        XCTAssertNil(opts.seed)
        XCTAssertNil(opts.stepBudget)
        XCTAssertFalse(opts.infoOnly)
    }

    func testParseInfoModeRequiresCheckpoint() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--info"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError, .infoRequiresCheckpoint)
        }
    }

    func testParseInfoModeAcceptsCheckpointOnly() throws {
        let opts = try EcologyCLIParser.parse(args: [
            "--info", "--checkpoint", "/tmp/cp.json",
        ])
        XCTAssertTrue(opts.infoOnly)
        XCTAssertEqual(opts.checkpointURL?.path, "/tmp/cp.json")
        XCTAssertEqual(opts.epochs, 0)
        XCTAssertNil(opts.saveURL)
    }

    func testParseInfoModeRejectsSaveAndEpochs() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--info", "--checkpoint", "cp.json",
                                              "--save", "out.json"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError, .infoIncompatible("--save"))
        }
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--info", "--checkpoint", "cp.json",
                                              "--epochs", "1"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError, .infoIncompatible("--epochs"))
        }
    }

    func testParseInfoModeRejectsConfigShape() {
        for (flag, val) in [("--seed", "1"), ("--budget", "8"),
                            ("--mutation-p32", "0"),
                            ("--variant", "bff"),
                            ("--brackets", "jumpTable")] {
            XCTAssertThrowsError(
                try EcologyCLIParser.parse(args: ["--info",
                                                  "--checkpoint", "cp.json",
                                                  flag, val])
            ) { error in
                guard case .infoIncompatible = (error as? EcologyCLIError) else {
                    XCTFail("\(flag) under --info should be .infoIncompatible, got \(error)")
                    return
                }
            }
        }
    }

    func testParseRejectsSeedAndCheckpointTogether() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "1",
                                              "--checkpoint", "cp.json"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .checkpointAndSeedMutuallyExclusive)
        }
    }

    func testParseRejectsConfigShapeWithCheckpoint() {
        // --budget with --checkpoint must be rejected (the budget is part of
        // the checkpoint's signed metadata).
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--checkpoint", "cp.json",
                                              "--budget", "8"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .checkpointAndConfigShapeConflict("--budget"))
        }
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--checkpoint", "cp.json",
                                              "--mutation-p32", "0"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .checkpointAndConfigShapeConflict("--mutation-p32"))
        }
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--checkpoint", "cp.json",
                                              "--variant", "bff"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .checkpointAndConfigShapeConflict("--variant"))
        }
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--checkpoint", "cp.json",
                                              "--brackets", "jumpTable"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .checkpointAndConfigShapeConflict("--brackets"))
        }
    }

    func testParseRequiresSeedWithoutCheckpoint() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--epochs", "4"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .seedRequiredWithoutCheckpoint)
        }
    }

    func testParseRejectsUnknownOption() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "1", "--nonsense"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError, .unknownOption("--nonsense"))
        }
    }

    func testParseRejectsMissingValue() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError, .missingValue("--seed"))
        }
    }

    func testParseRejectsNonPositiveBudget() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "1", "--budget", "0"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError, .stepBudgetNotPositive(0))
        }
        // "-1" is malformed (sign) before it can be a non-positive budget.
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "1", "--budget", "-1"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .malformedNumber(name: "--budget", raw: "-1"))
        }
    }

    func testParseRejectsInvalidEnum() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "1", "--variant", "fast"])
        ) { error in
            guard case .invalidEnum(let name, let raw, _) = (error as? EcologyCLIError) else {
                XCTFail("expected invalidEnum, got \(error)")
                return
            }
            XCTAssertEqual(name, "--variant")
            XCTAssertEqual(raw, "fast")
        }
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "1", "--brackets", "fast"])
        ) { error in
            guard case .invalidEnum(let name, let raw, _) = (error as? EcologyCLIError) else {
                XCTFail("expected invalidEnum, got \(error)")
                return
            }
            XCTAssertEqual(name, "--brackets")
            XCTAssertEqual(raw, "fast")
        }
    }

    func testParseStrictSeedOutOfRange() {
        // 2^32 is one past UInt32.max; the strict parser must reject it
        // (not truncate).
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "4294967296"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .outOfRange(name: "--seed", raw: "4294967296"))
        }
    }

    func testParseStrictSeedRejectsHexPrefix() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", "0x10"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .malformedNumber(name: "--seed", raw: "0x10"))
        }
    }

    func testParseStrictSeedRejectsLeadingWhitespace() {
        XCTAssertThrowsError(
            try EcologyCLIParser.parse(args: ["--seed", " 1"])
        ) { error in
            XCTAssertEqual(error as? EcologyCLIError,
                           .malformedNumber(name: "--seed", raw: " 1"))
        }
    }

    func testErrorDescriptionsAreHumanReadable() {
        // Spot-check that the descriptions are non-empty and name the offending
        // field — the CLI surfaces these verbatim on stderr.
        XCTAssertFalse(EcologyCLIError.malformedNumber(name: "--seed",
                                                       raw: "0x10").description.isEmpty)
        XCTAssertTrue(EcologyCLIError.malformedNumber(name: "--seed",
                                                     raw: "0x10").description
            .contains("--seed"))
        XCTAssertTrue(EcologyCLIError.outOfRange(name: "--seed",
                                                 raw: "4294967296").description
            .contains("out of range"))
        XCTAssertTrue(EcologyCLIError.checkpointAndSeedMutuallyExclusive.description
            .contains("mutually exclusive"))
    }
}

final class EcologyCheckpointFileTests: XCTestCase {

    private func quickHaltingSoup() -> [UInt8] {
        var soup = [UInt8](repeating: 0, count: EcologyTopology.soupByteCount)
        for site in 0..<EcologyTopology.siteCount {
            soup[site * BFF.tapeSize] = BFFOp.loopClose
        }
        return soup
    }

    private func makeCheckpointData() throws -> Data {
        let config = EcologyConfig(seed: 5, stepBudget: 16, mutationP32: 0)
        var runner = try EcologyOracleRunner(config: config, soup: quickHaltingSoup())
        try runner.runEpoch()
        return try EcologyCheckpoint(capturing: runner).jsonData()
    }

    /// Decode a checkpoint through the synthesized `Codable` path (which
    /// performs no contract validation), apply `mutate`, and re-encode with
    /// the production `jsonData()` formatter settings (`.prettyPrinted`,
    /// `.sortedKeys`). This bypasses `validateMetadata()` so a malformed
    /// checkpoint can be serialized, then routed back through
    /// `EcologyCheckpointFile.decode` to assert the controlled rejection.
    /// Returns the re-encoded bytes and the decoded mutated checkpoint so each
    /// caller can prove the mutation took effect before asserting rejection.
    ///
    /// String-patching the pretty-printed JSON is unsafe here: Foundation
    /// pretty-prints with a `" : "` separator, so a needle like
    /// `"engineID":"ecology-v1"` never matches and the replacement silently
    /// no-ops, leaving the test asserting a rejection of unmutated (valid)
    /// input. Mutating the decoded value and re-encoding through the same
    /// production formatter is immune to that class of bug.
    private func reencodeCheckpoint(
        from data: Data,
        mutate: (inout EcologyCheckpoint) -> Void
    ) throws -> (bytes: Data, mutated: EcologyCheckpoint) {
        var cp = try JSONDecoder().decode(EcologyCheckpoint.self, from: data)
        mutate(&cp)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(cp)
        let mutated = try JSONDecoder().decode(EcologyCheckpoint.self, from: bytes)
        return (bytes, mutated)
    }

    // MARK: - Valid round-trip

    func testLoadValidCheckpoint() throws {
        let data = try makeCheckpointData()
        let checkpoint = try EcologyCheckpointFile.decode(data: data)
        XCTAssertEqual(checkpoint.magic, "BFFECO1")
        XCTAssertEqual(checkpoint.schemaVersion, 1)
        XCTAssertEqual(checkpoint.engineID, "ecology-v1")
    }

    func testLoadFromDiskRoundTrips() throws {
        let data = try makeCheckpointData()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eco-cli-unit-\(UUID().uuidString).json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let checkpoint = try EcologyCheckpointFile.load(from: url)
        XCTAssertEqual(checkpoint.soupBase64,
                       try EcologyCheckpoint.decode(from: data).soupBase64)
    }

    // MARK: - Malformed input rejection (no trap)

    func testEmptyFileRejected() {
        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: Data())
        ) { error in
            XCTAssertEqual(error as? EcologyCheckpointLoadError, .empty)
        }
    }

    func testOversizedRejectedBeforeJSONParse() {
        // One byte over the limit; never parsed.
        let oversized = Data(count: EcologyCheckpointFile.maxCheckpointBytes + 1)
        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: oversized)
        ) { error in
            guard case .oversized(let n) = (error as? EcologyCheckpointLoadError) else {
                XCTFail("expected oversized, got \(error)")
                return
            }
            XCTAssertEqual(n, EcologyCheckpointFile.maxCheckpointBytes + 1)
        }
    }

    func testTruncatedJSONRejected() {
        // Truncated JSON: starts a valid object but is cut off mid-stream.
        let truncated = Data("{\"magic\":\"BFFECO1\",".utf8)
        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: truncated)
        ) { error in
            guard case .invalidJSON = (error as? EcologyCheckpointLoadError) else {
                XCTFail("expected invalidJSON, got \(error)")
                return
            }
        }
    }

    func testNotJSONAtAllRejected() {
        let notJSON = Data("not json at all".utf8)
        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: notJSON)
        ) { error in
            guard case .invalidJSON = (error as? EcologyCheckpointLoadError) else {
                XCTFail("expected invalidJSON, got \(error)")
                return
            }
        }
    }

    func testUnreadableFileRejected() {
        let missing = URL(fileURLWithPath: "/dev/null/does-not-exist.json")
        XCTAssertThrowsError(
            try EcologyCheckpointFile.load(from: missing)
        ) { error in
            guard case .fileUnreadable = (error as? EcologyCheckpointLoadError) else {
                XCTFail("expected fileUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - Contract violation (wrong magic / engine / etc.)

    func testWrongMagicRejected() throws {
        let data = try makeCheckpointData()
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"BFFECO1\"",
                                         with: "\"BFFECO2\"")
        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: Data(text.utf8))
        ) { error in
            XCTAssertEqual(error as? EcologyCheckpointLoadError,
                           .contractViolation(
                               EcologyContractError.magic("BFFECO2").description))
        }
    }

    func testWrongEngineIDRejected() throws {
        let data = try makeCheckpointData()
        let original = try JSONDecoder().decode(EcologyCheckpoint.self, from: data)
        let reencoded = try reencodeCheckpoint(from: data) { cp in
            cp.engineID = "well-mixed"
        }
        // Prove the mutation actually took effect in the re-encoded bytes
        // before asserting rejection: the field must hold the intended bad
        // value and the bytes must differ from the valid checkpoint.
        XCTAssertEqual(reencoded.mutated.engineID, "well-mixed")
        XCTAssertNotEqual(reencoded.mutated.engineID, original.engineID)
        XCTAssertNotEqual(reencoded.bytes, data)

        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: reencoded.bytes)
        ) { error in
            XCTAssertEqual(error as? EcologyCheckpointLoadError,
                           .contractViolation(
                               EcologyContractError.engineID("well-mixed").description))
        }
    }

    func testWrongSchemaVersionRejected() throws {
        let data = try makeCheckpointData()
        let original = try JSONDecoder().decode(EcologyCheckpoint.self, from: data)
        let reencoded = try reencodeCheckpoint(from: data) { cp in
            cp.schemaVersion = 2
        }
        // Prove the mutation took effect before asserting rejection.
        XCTAssertEqual(reencoded.mutated.schemaVersion, 2)
        XCTAssertNotEqual(reencoded.mutated.schemaVersion, original.schemaVersion)
        XCTAssertNotEqual(reencoded.bytes, data)

        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: reencoded.bytes)
        ) { error in
            XCTAssertEqual(error as? EcologyCheckpointLoadError,
                           .contractViolation(
                               EcologyContractError.schemaVersion(2).description))
        }
    }

    func testMalformedStepBudgetRejectedWithoutTrap() throws {
        let data = try makeCheckpointData()
        let original = try JSONDecoder().decode(EcologyCheckpoint.self, from: data)
        let reencoded = try reencodeCheckpoint(from: data) { cp in
            cp.stepBudget = 0
        }
        // Prove the mutation took effect before asserting rejection.
        XCTAssertEqual(reencoded.mutated.stepBudget, 0)
        XCTAssertNotEqual(reencoded.mutated.stepBudget, original.stepBudget)
        XCTAssertNotEqual(reencoded.bytes, data)

        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: reencoded.bytes)
        ) { error in
            XCTAssertEqual(error as? EcologyCheckpointLoadError,
                           .contractViolation(
                               EcologyContractError.invalidStepBudget(0).description))
        }
    }

    func testCorruptSoupBase64Rejected() throws {
        let data = try makeCheckpointData()
        let original = try JSONDecoder().decode(EcologyCheckpoint.self, from: data)
        // Replace the base64 soup field with invalid base64 characters. The
        // synthesized Codable path treats `soupBase64` as an opaque String, so
        // this re-encodes without triggering `soupBytes()` validation.
        let reencoded = try reencodeCheckpoint(from: data) { cp in
            cp.soupBase64 = "@@@@"
        }
        // Prove the mutation took effect before asserting rejection.
        XCTAssertEqual(reencoded.mutated.soupBase64, "@@@@")
        XCTAssertNotEqual(reencoded.mutated.soupBase64, original.soupBase64)
        XCTAssertNotEqual(reencoded.bytes, data)

        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: reencoded.bytes)
        ) { error in
            guard case .contractViolation = (error as? EcologyCheckpointLoadError) else {
                XCTFail("expected contractViolation, got \(error)")
                return
            }
        }
    }

    // MARK: - Cross-engine rejection

    func testWellMixedGoldenFixtureRejected() throws {
        // A real well-mixed fixture: built from the grounded Simulation type.
        let wellMixed = GoldenFixture(capturing:
            Simulation(config: SimulationConfig(
                seed: 1, populationSize: 8, stepBudget: 8,
                mutationP32: 0, variant: .noheads, bracketMode: .dynamicScan)),
            source: "unit-test")
        let data = try wellMixed.jsonData()

        // The ecology file loader must reject this with the clear
        // wrongEngineFixture error, not an opaque DecodingError.
        XCTAssertThrowsError(
            try EcologyCheckpointFile.decode(data: data)
        ) { error in
            guard case .wrongEngineFixture(let desc) = (error as? EcologyCheckpointLoadError) else {
                XCTFail("expected wrongEngineFixture, got \(error)")
                return
            }
            XCTAssertTrue(desc.contains("well-mixed"),
                          "rejection message should name the well-mixed engine")
        }
    }

    func testEcologyCheckpointRejectedByWellMixedLoader() throws {
        // The inverse direction: an ecology checkpoint is rejected by the
        // well-mixed GoldenFixture decoder. This is already covered by
        // EcologyTests.testCheckpointRoundTripAndContractRejection; we re-pin
        // it here at the file-loader boundary so the cross-engine contract is
        // asserted symmetrically in one place.
        let data = try makeCheckpointData()
        XCTAssertThrowsError(try GoldenFixture.decode(from: data)) { error in
            // GoldenFixture.decode either fails the formatVersion check or
            // the JSONDecoder; both are controlled nonzero errors.
            XCTAssertTrue(error is GoldenFixture.FixtureError
                          || error is DecodingError)
        }
    }

    // MARK: - Continuation parity at the library boundary

    func testSaveRestoreContinuationMatchesUninterruptedRun() throws {
        // Mirrors the contract that the CLI process-level test relies on:
        // uninterrupted 7 epochs vs. split 3 + restore + 4 epochs must yield
        // identical state, digest, and counters.
        let config = EcologyConfig(seed: 88, stepBudget: 16, mutationP32: 0)
        let soup = quickHaltingSoup()

        var uninterrupted = try EcologyOracleRunner(config: config, soup: soup)
        try uninterrupted.run(epochs: 7)

        var split = try EcologyOracleRunner(config: config, soup: soup)
        try split.run(epochs: 3)
        let checkpoint = EcologyCheckpoint(capturing: split)
        var restored = try EcologyOracleRunner(checkpoint: checkpoint)
        try restored.run(epochs: 4)

        XCTAssertEqual(restored.epoch, uninterrupted.epoch)
        XCTAssertEqual(restored.digest, uninterrupted.digest)
        XCTAssertEqual(restored.soup, uninterrupted.soup)
        XCTAssertEqual(restored.lastEpochCounters, uninterrupted.lastEpochCounters)
    }
}
