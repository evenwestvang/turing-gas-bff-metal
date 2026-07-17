import XCTest
@testable import BFFOracle

/// Edge cases and interpretation anchors for the deterministic structure metrics and
/// the additive low-entropy soup initializers.
final class StructureMetricsTests: XCTestCase {

    // MARK: - Adjacent transition rate

    func testTransitionRateEdgeCases() {
        XCTAssertEqual(StructureMetrics.transitionRate([] as [UInt8]), 0, "empty")
        XCTAssertEqual(StructureMetrics.transitionRate([7] as [UInt8]), 0, "single byte")
        XCTAssertEqual(StructureMetrics.transitionRate([9, 9, 9, 9] as [UInt8]), 0,
                       "constant run has no transitions")
        XCTAssertEqual(StructureMetrics.transitionRate([1, 2, 1, 2] as [UInt8]), 1.0,
                       "every neighbor differs")
        // [1,1,2,2] -> pairs (1,1),(1,2),(2,2): exactly one differs of three.
        XCTAssertEqual(StructureMetrics.transitionRate([1, 1, 2, 2] as [UInt8]),
                       1.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: - Compression proxy

    func testCompressionProxyEdgeCases() {
        XCTAssertEqual(StructureMetrics.compressionProxyRatio([]), 0, "empty")
        XCTAssertEqual(StructureMetrics.compressionProxyRatio([42]), 1.0, "single literal")

        // All-distinct: no match reaches minMatch, so every byte is a literal token.
        let distinct = (0..<200).map { UInt8($0 % 256) }
        XCTAssertEqual(StructureMetrics.compressionProxyRatio(distinct), 1.0,
                       "monotone-distinct is incompressible under this proxy")

        // Constant run collapses to a literal + one long back-reference: 2 tokens.
        let constant = [UInt8](repeating: 3, count: 100)
        XCTAssertEqual(StructureMetrics.compressionProxyRatio(constant), 2.0 / 100.0,
                       accuracy: 1e-12)

        // Period-2 pattern: two literals prime the window, then one overlapping match.
        let pattern: [UInt8] = [1, 2, 1, 2, 1, 2]
        XCTAssertEqual(StructureMetrics.compressionProxyRatio(pattern), 3.0 / 6.0,
                       accuracy: 1e-12)

        // Two equal bytes cannot form a >=minMatch(3) match: stays incompressible.
        XCTAssertEqual(StructureMetrics.compressionProxyRatio([5, 5]), 1.0)
    }

    func testCompressionProxyIsDeterministic() {
        let bytes = (0..<500).map { UInt8(($0 * 37 + 11) % 17) }
        XCTAssertEqual(StructureMetrics.compressionProxyRatio(bytes),
                       StructureMetrics.compressionProxyRatio(bytes))
        // Repetitive structure compresses below fully-random-over-alphabet noise.
        XCTAssertLessThan(StructureMetrics.compressionProxyRatio(bytes), 1.0)
    }

    // MARK: - Constant soup (H == 0)

    func testConstantSoupIsZeroEntropyAndInert() {
        let soup = BFFRandom.constantSoup(programs: 8)
        XCTAssertEqual(soup.count, 8 * BFF.tapeSize)
        XCTAssertTrue(soup.allSatisfy { $0 == 0 })
        XCTAssertEqual(ByteHistogram(bytes: soup).shannonEntropyBitsPerByte, 0,
                       "constant soup has exactly zero order-0 entropy")
        XCTAssertEqual(StructureMetrics.transitionRate(soup), 0)
    }

    // MARK: - Opcode small-alphabet soup

    func testOpcodeSoupIsDeterministicAndLowEntropy() {
        let a = BFFRandom.opcodeSoup(programs: 64, seed: 7)
        let b = BFFRandom.opcodeSoup(programs: 64, seed: 7)
        XCTAssertEqual(a, b, "same seed => identical soup")
        XCTAssertNotEqual(a, BFFRandom.opcodeSoup(programs: 64, seed: 8),
                          "seed sensitive")

        // Every byte is one of the ten BFF opcodes — an executable, low-entropy soup.
        let alphabet = Set(BFFOp.all)
        XCTAssertTrue(a.allSatisfy { alphabet.contains($0) })

        let hist = ByteHistogram(bytes: a)
        let nonEmptyBins = hist.bins.filter { $0 > 0 }.count
        XCTAssertLessThanOrEqual(nonEmptyBins, BFFOp.all.count,
                                 "at most the alphabet's symbols appear")
        let h = hist.shannonEntropyBitsPerByte
        // Bounded above by log2(alphabet) and, for this size, comfortably below the
        // ~7.9 bits/byte of a uniform-over-256 soup — the point of the mode.
        let maxH = log2(Double(BFFOp.all.count))
        XCTAssertGreaterThan(h, 0)
        XCTAssertLessThanOrEqual(h, maxH + 1e-9)
        XCTAssertLessThan(h, 4.0)
    }

    /// A hand-built two-symbol program has exactly 1 bit/byte — an exact-expected-H
    /// anchor independent of the RNG.
    func testTwoSymbolProgramHasExactlyOneBit() {
        var bytes = [UInt8]()
        for i in 0..<64 { bytes.append(i % 2 == 0 ? 0x2B : 0x2D) } // 32 '+' , 32 '-'
        XCTAssertEqual(ByteHistogram(bytes: bytes).shannonEntropyBitsPerByte, 1.0,
                       accuracy: 1e-12)
    }

    /// The uniform initializer is untouched by the additive modes: same seed still
    /// yields the same bytes, and it is NOT equal to either low-entropy mode.
    func testUniformInitializerUnchangedAndDistinct() {
        let uniform = BFFRandom.initialSoup(programs: 16, seed: 3)
        XCTAssertEqual(uniform, BFFRandom.initialSoup(programs: 16, seed: 3))
        XCTAssertNotEqual(uniform, BFFRandom.constantSoup(programs: 16))
        XCTAssertNotEqual(uniform, BFFRandom.opcodeSoup(programs: 16, seed: 3))
    }
}
