import XCTest
@testable import BFFOracle

/// The paper high-order-complexity *arithmetic* (H0 − brotli_bpb), tested pure —
/// no Brotli, no Metal. The real codec path is covered by `BrotliMetricsTests`.
final class PaperComplexityTests: XCTestCase {

    func testBrotliBitsPerByteIsCubffFormula() {
        // cubff: brotli_bpb = brotli_size * 8 / soupByteCount.
        // 20 compressed bytes over a 64-byte soup -> 160 bits / 64 = 2.5 bits/byte.
        XCTAssertEqual(
            PaperComplexity.brotliBitsPerByte(compressedByteCount: 20, soupByteCount: 64),
            2.5, accuracy: 1e-12)
        // Incompressible: compressed == input -> 8 bits/byte (the H0 ceiling).
        XCTAssertEqual(
            PaperComplexity.brotliBitsPerByte(compressedByteCount: 256, soupByteCount: 256),
            8.0, accuracy: 1e-12)
    }

    func testBrotliBitsPerByteEmptySoupIsZero() {
        XCTAssertEqual(
            PaperComplexity.brotliBitsPerByte(compressedByteCount: 1, soupByteCount: 0), 0)
        XCTAssertEqual(
            PaperComplexity.brotliBitsPerByte(compressedByteCount: 0, soupByteCount: 0), 0)
    }

    func testHighOrderComplexityIsH0MinusBpb() {
        // higher_entropy = h0 - brotli_bpb.
        XCTAssertEqual(
            PaperComplexity.highOrderComplexity(h0: 7.9, brotliBitsPerByte: 6.4),
            1.5, accuracy: 1e-12)
        // A soup no more compressible than its order-0 entropy predicts -> ~0 complexity.
        XCTAssertEqual(
            PaperComplexity.highOrderComplexity(h0: 8.0, brotliBitsPerByte: 8.0),
            0.0, accuracy: 1e-12)
        // Order-0 entropy above the compressed rate -> positive high-order structure.
        XCTAssertGreaterThan(
            PaperComplexity.highOrderComplexity(h0: 5.0, brotliBitsPerByte: 2.0), 0)
    }

    func testPaperThresholdIsOne() {
        XCTAssertEqual(PaperComplexity.defaultThreshold, 1.0)
    }

    /// The two halves compose: from a soup's H0 and its compressed size we recover the
    /// same high-order complexity cubff logs, end to end (arithmetic only).
    func testEndToEndComposition() {
        let h0 = 7.8
        let bpb = PaperComplexity.brotliBitsPerByte(compressedByteCount: 40, soupByteCount: 128)
        // 40*8/128 = 2.5
        XCTAssertEqual(bpb, 2.5, accuracy: 1e-12)
        XCTAssertEqual(PaperComplexity.highOrderComplexity(h0: h0, brotliBitsPerByte: bpb),
                       5.3, accuracy: 1e-12)
    }
}
