import XCTest
import Foundation
import BFFOracle
@testable import BrotliMetrics

/// Verifies the Brotli integration reproduces the authoritative Brotli 1.1.0
/// quality-2 compressed byte counts, and that the version-provenance gate behaves.
///
/// The fixtures (`Fixtures/brotli-1.1.0-q2.json`) are minted by
/// `Tools/brotli-fixtures/generate.sh` from the pinned Brotli 1.1.0 tag using
/// exactly cubff's call: `BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC)`. For
/// the small inputs here the counts are byte-identical under Brotli 1.0.9 and
/// 1.1.0 (verified — they diverge only at soup scale), so the exact-count
/// assertions run on either host; on any *other* linked version they skip rather
/// than fail spuriously.
final class BrotliFixtureTests: XCTestCase {

    private struct FixtureFile: Codable {
        struct Brotli: Codable { let url, commit, version, versionHex, build: String }
        struct Parameters: Codable { let quality, lgwin: Int; let mode, call: String }
        struct Case: Codable {
            let name, note, inputHex: String
            let inputByteCount, compressedByteCount: Int
        }
        let formatVersion: Int
        let brotli: Brotli
        let parameters: Parameters
        let observables: String
        let cases: [Case]
    }

    /// Brotli version words we have directly verified produce these q2 counts.
    private static let pinned: UInt32 = 0x1001000   // 1.1.0 (authoritative)
    private static let verified109: UInt32 = 0x1000009 // 1.0.9 (byte-identical for these inputs)

    private func loadFixtures() throws -> FixtureFile {
        guard let url = Bundle.module.url(forResource: "brotli-1.1.0-q2",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("brotli fixture resource not bundled")
        }
        return try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
    }

    private func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(hex.count / 2)
        var it = hex.makeIterator()
        while let hi = it.next() {
            guard let lo = it.next(), let h = hi.hexDigitValue, let l = lo.hexDigitValue
            else { return nil }
            out.append(UInt8(h << 4 | l))
        }
        return out
    }

    // MARK: - Provenance is pinned in the fixture and gate is consistent

    func testFixtureProvenanceIsBrotli110Quality2() throws {
        let f = try loadFixtures()
        XCTAssertEqual(f.formatVersion, 1)
        XCTAssertEqual(f.brotli.version, "1.1.0")
        XCTAssertEqual(f.brotli.versionHex, "0x1001000")
        XCTAssertEqual(f.brotli.commit, "ed738e842d2fbdf2d6459e39267a633c4a9b2f5d")
        XCTAssertEqual(f.parameters.quality, 2)
        XCTAssertEqual(f.parameters.lgwin, 24)
        XCTAssertEqual(f.parameters.mode, "generic")
        XCTAssertFalse(f.cases.isEmpty)
    }

    /// The runtime provenance gate must match the raw version word exactly, so a
    /// non-1.1.0 encoder can never be mistaken for the paper's.
    func testProvenanceGateMatchesEncoderVersion() {
        XCTAssertEqual(BrotliCompressor.paperVersionHex, 0x1001000)
        XCTAssertEqual(BrotliCompressor.isPaperPinned,
                       BrotliCompressor.encoderVersion == 0x1001000)
        // paperBitsPerByte is emitted iff the encoder is pinned to 1.1.0.
        let bpb = BrotliCompressor.paperBitsPerByte(soup: [UInt8](repeating: 0, count: 64))
        if BrotliCompressor.isPaperPinned {
            XCTAssertNotNil(bpb, "1.1.0 must produce the paper metric")
        } else {
            XCTAssertNil(bpb, "a non-1.1.0 encoder must report the paper metric as nil")
        }
    }

    // MARK: - Exact compressed byte counts

    func testCompressedByteCountsMatchAuthoritativeFixtures() throws {
        let f = try loadFixtures()
        let v = BrotliCompressor.encoderVersion
        guard v == Self.pinned || v == Self.verified109 else {
            throw XCTSkip("linked Brotli \(BrotliCompressor.encoderVersionString) is neither "
                          + "1.1.0 nor the verified-identical 1.0.9; exact q2 counts not asserted")
        }
        for c in f.cases {
            guard let input = bytes(fromHex: c.inputHex), input.count == c.inputByteCount else {
                return XCTFail("case \(c.name): undecodable or wrong-length inputHex")
            }
            let got = BrotliCompressor.quality2CompressedByteCount(input)
            XCTAssertEqual(got, c.compressedByteCount,
                           "case \(c.name): q2 compressed byte count must match the "
                           + "authoritative Brotli 1.1.0 fixture")
        }
    }

    /// The paper bits/byte equals `compressedBytes * 8 / soupBytes` for a non-empty
    /// case — the exact cubff `brotli_bpb`. Only asserted when pinned to 1.1.0.
    func testPaperBitsPerByteMatchesFormula() throws {
        try XCTSkipUnless(BrotliCompressor.isPaperPinned,
                          "paper bpb only defined against Brotli 1.1.0")
        let f = try loadFixtures()
        guard let c = f.cases.first(where: { $0.inputByteCount > 0 }),
              let input = bytes(fromHex: c.inputHex) else {
            return XCTFail("no non-empty fixture case")
        }
        let bpb = try XCTUnwrap(BrotliCompressor.paperBitsPerByte(soup: input))
        let expected = Double(c.compressedByteCount) * 8.0 / Double(c.inputByteCount)
        XCTAssertEqual(bpb, expected, accuracy: 1e-12)
    }
}
