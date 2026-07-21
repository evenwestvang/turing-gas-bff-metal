import XCTest
@testable import BFFOracle

/// Independent tiny-grid fixtures for the bounded spatial metrics library.
/// Every test uses hand-constructed soups with known ground truth — no RNG,
/// no production code paths, no Metal.
final class SpatialMetricsTests: XCTestCase {

    // MARK: - Helpers

    private let ps = BFF.tapeSize  // 64

    /// Build a soup from an array of 64-byte programs.
    private func soup(_ programs: [[UInt8]]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(programs.count * ps)
        for p in programs {
            assert(p.count == ps)
            out.append(contentsOf: p)
        }
        return out
    }

    /// A program filled with a single byte.
    private func prog(_ b: UInt8) -> [UInt8] {
        [UInt8](repeating: b, count: ps)
    }

    /// A program with a distinct pattern per index.
    private func progID(_ id: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: ps)
        p[0] = UInt8(id & 0xFF)
        if id > 255 { p[1] = UInt8((id >> 8) & 0xFF) }
        return p
    }

    // MARK: - byteEntropy

    func testByteEntropyEmpty() {
        XCTAssertEqual(SpatialMetrics.byteEntropy([]), 0, "empty → 0, not NaN")
        XCTAssertFalse(SpatialMetrics.byteEntropy([]).isNaN)
    }

    func testByteEntropyConstant() {
        let bytes = [UInt8](repeating: 42, count: 1000)
        XCTAssertEqual(SpatialMetrics.byteEntropy(bytes), 0,
                       "constant bytes → zero entropy")
    }

    func testByteEntropyUniform256() {
        // One of each byte value → log2(256) = 8
        let bytes = (0..<256).map { UInt8($0) }
        XCTAssertEqual(SpatialMetrics.byteEntropy(bytes), 8.0, accuracy: 1e-12)
    }

    func testByteEntropyTwoValues() {
        // 128 zeros, 128 ones → log2(2) = 1.0
        let bytes = [UInt8](repeating: 0, count: 128) + [UInt8](repeating: 1, count: 128)
        XCTAssertEqual(SpatialMetrics.byteEntropy(bytes), 1.0, accuracy: 1e-12)
    }

    // MARK: - uniqueProgramCount

    func testUniqueProgramCountAllIdentical() throws {
        let p = prog(7)
        let s = soup([p, p, p, p])
        let count = try SpatialMetrics.uniqueProgramCount(soup: s, width: 2, height: 2)
        XCTAssertEqual(count, 1)
    }

    func testUniqueProgramCountAllUnique() throws {
        let s = soup([progID(0), progID(1), progID(2), progID(3)])
        let count = try SpatialMetrics.uniqueProgramCount(soup: s, width: 2, height: 2)
        XCTAssertEqual(count, 4)
    }

    func testUniqueProgramCountMixed() throws {
        let s = soup([progID(0), progID(1), progID(0), progID(2)])
        let count = try SpatialMetrics.uniqueProgramCount(soup: s, width: 2, height: 2)
        XCTAssertEqual(count, 3)
    }

    func testUniqueProgramCountOneSite() throws {
        let s = soup([progID(42)])
        let count = try SpatialMetrics.uniqueProgramCount(soup: s, width: 1, height: 1)
        XCTAssertEqual(count, 1)
    }

    // MARK: - identicalNeighborFraction

    func testIdenticalNeighborFractionAllIdentical() throws {
        let p = prog(5)
        let s = soup([p, p, p, p])
        // 2×2 grid: 4 sites × 2 edges = 8 edges, all identical
        let f = try SpatialMetrics.identicalNeighborFraction(soup: s, width: 2, height: 2)
        XCTAssertEqual(f, 1.0, accuracy: 1e-12)
    }

    func testIdenticalNeighborFractionAllUnique() throws {
        let s = soup([progID(0), progID(1), progID(2), progID(3)])
        // 2×2 grid: all 8 edges connect different programs
        let f = try SpatialMetrics.identicalNeighborFraction(soup: s, width: 2, height: 2)
        XCTAssertEqual(f, 0.0, accuracy: 1e-12)
    }

    func testIdenticalNeighborFractionOneSite() throws {
        let s = soup([prog(9)])
        // 1×1 grid: east wraps to self, south wraps to self → 2 edges, both identical
        let f = try SpatialMetrics.identicalNeighborFraction(soup: s, width: 1, height: 1)
        XCTAssertEqual(f, 1.0, accuracy: 1e-12)
    }

    func testIdenticalNeighborFractionHorizontalOnly() throws {
        // 2×1 grid: [A, A] — east edge identical, south edges wrap to self
        // Total edges = 2×1×2 = 4: site0-east(A==A)=1, site0-south(A==A)=1,
        //                          site1-east(A==A, wraps)=1, site1-south(A==A, wraps)=1
        // Actually 2×1: width=2, height=1. Each site has east+south.
        let p = prog(1)
        let s = soup([p, p])
        let f = try SpatialMetrics.identicalNeighborFraction(soup: s, width: 2, height: 1)
        XCTAssertEqual(f, 1.0, accuracy: 1e-12)
    }

    func testIdenticalNeighborFractionMixedGrid() throws {
        // 2×2 grid:
        // [A B]
        // [A C]
        // East edges: (0,0)-(1,0): A≠B=0, (1,0)-(0,0): B≠A(wrap)=0
        //              (0,1)-(1,1): A≠C=0, (1,1)-(0,1): C≠A(wrap)=0
        // South edges: (0,0)-(0,1): A==A=1, (1,0)-(1,1): B≠C=0
        //               (0,1)-(0,0): A==A(wrap)=1, (1,1)-(1,0): C≠B(wrap)=0
        // identical=2, total=8 → 0.25
        let a = prog(1), b = prog(2), c = prog(3)
        let s = soup([a, b, a, c])
        let f = try SpatialMetrics.identicalNeighborFraction(soup: s, width: 2, height: 2)
        XCTAssertEqual(f, 0.25, accuracy: 1e-12)
    }

    // MARK: - largestCloneComponent

    func testLargestCloneComponentAllIdentical() throws {
        let p = prog(5)
        let s = soup([p, p, p, p])
        // 2×2 torus: all 4 connected → size 4, fraction 1.0
        let (size, frac) = try SpatialMetrics.largestCloneComponent(soup: s, width: 2, height: 2)
        XCTAssertEqual(size, 4)
        XCTAssertEqual(frac, 1.0, accuracy: 1e-12)
    }

    func testLargestCloneComponentAllUnique() throws {
        let s = soup([progID(0), progID(1), progID(2), progID(3)])
        let (size, frac) = try SpatialMetrics.largestCloneComponent(soup: s, width: 2, height: 2)
        XCTAssertEqual(size, 1)
        XCTAssertEqual(frac, 0.25, accuracy: 1e-12)
    }

    func testLargestCloneComponentDisconnectedClones() throws {
        // 4×2 grid:
        // [A B A B]
        // [C D C D]
        // A's are at (0,0) and (2,0). They are not adjacent (site 0 and site 2
        // have site 1 between them). Each A is isolated → largest = 1
        // B's at (1,0) and (3,0): also not adjacent (wrap: 3→0 is A, not B)
        // C's at (0,1) and (2,1): not adjacent
        // D's at (1,1) and (3,1): not adjacent
        let a = prog(1), b = prog(2), c = prog(3), d = prog(4)
        let s = soup([a, b, a, b, c, d, c, d])
        let (size, frac) = try SpatialMetrics.largestCloneComponent(soup: s, width: 4, height: 2)
        XCTAssertEqual(size, 1)
        XCTAssertEqual(frac, 1.0 / 8.0, accuracy: 1e-12)
    }

    func testLargestCloneComponentConnectedPair() throws {
        // 2×2 grid:
        // [A A]
        // [B C]
        // Sites 0 and 1 are both A, adjacent east → component size 2
        let a = prog(1), b = prog(2), c = prog(3)
        let s = soup([a, a, b, c])
        let (size, frac) = try SpatialMetrics.largestCloneComponent(soup: s, width: 2, height: 2)
        XCTAssertEqual(size, 2)
        XCTAssertEqual(frac, 0.5, accuracy: 1e-12)
    }

    func testLargestCloneComponentToroidalWrap() throws {
        // 3×1 grid: [A A A] — all identical, toroidal east wraps connect them all
        let p = prog(7)
        let s = soup([p, p, p])
        let (size, frac) = try SpatialMetrics.largestCloneComponent(soup: s, width: 3, height: 1)
        XCTAssertEqual(size, 3)
        XCTAssertEqual(frac, 1.0, accuracy: 1e-12)
    }

    func testLargestCloneComponentOneSite() throws {
        let s = soup([prog(42)])
        let (size, frac) = try SpatialMetrics.largestCloneComponent(soup: s, width: 1, height: 1)
        XCTAssertEqual(size, 1)
        XCTAssertEqual(frac, 1.0, accuracy: 1e-12)
    }

    // MARK: - byteTurnover

    func testByteTurnoverIdentical() throws {
        let s = [UInt8](repeating: 5, count: 100)
        let f = try SpatialMetrics.byteTurnover(s, s)
        XCTAssertEqual(f, 0.0, accuracy: 1e-12)
    }

    func testByteTurnoverAllChanged() throws {
        let a = [UInt8](repeating: 0, count: 100)
        let b = [UInt8](repeating: 1, count: 100)
        let f = try SpatialMetrics.byteTurnover(a, b)
        XCTAssertEqual(f, 1.0, accuracy: 1e-12)
    }

    func testByteTurnoverHalfChanged() throws {
        let a = [UInt8](repeating: 0, count: 100)
        var b = [UInt8](repeating: 1, count: 50) + [UInt8](repeating: 0, count: 50)
        b.reserveCapacity(100)
        // Actually let's be precise:
        let bb = [UInt8](repeating: 1, count: 50) + [UInt8](repeating: 0, count: 50)
        let f = try SpatialMetrics.byteTurnover(a, bb)
        XCTAssertEqual(f, 0.5, accuracy: 1e-12)
    }

    func testByteTurnoverEmpty() throws {
        let f = try SpatialMetrics.byteTurnover([], [])
        XCTAssertEqual(f, 0.0, "empty soups → 0, not NaN")
        XCTAssertFalse(f.isNaN)
    }

    func testByteTurnoverSizeMismatch() {
        let a = [UInt8](repeating: 0, count: 10)
        let b = [UInt8](repeating: 0, count: 20)
        XCTAssertThrowsError(try SpatialMetrics.byteTurnover(a, b)) { error in
            guard case .turnoverSizeMismatch(let before, let after) =
                error as? SpatialMetricsError else {
                XCTFail("wrong error: \(error)"); return
            }
            XCTAssertEqual(before, 10)
            XCTAssertEqual(after, 20)
        }
    }

    // MARK: - Validation errors

    func testZeroDimensionsRejected() {
        let s = [UInt8](repeating: 0, count: 64)
        XCTAssertThrowsError(
            try SpatialMetrics.uniqueProgramCount(soup: s, width: 0, height: 2)
        ) { error in
            guard case .zeroDimensions = error as? SpatialMetricsError else {
                XCTFail("expected zeroDimensions, got \(error)"); return
            }
        }
    }

    func testSoupByteCountMismatch() {
        let s = [UInt8](repeating: 0, count: 10)
        XCTAssertThrowsError(
            try SpatialMetrics.uniqueProgramCount(soup: s, width: 2, height: 2)
        ) { error in
            guard case .soupByteCountMismatch(let actual, let expected) =
                error as? SpatialMetricsError else {
                XCTFail("expected soupByteCountMismatch, got \(error)"); return
            }
            XCTAssertEqual(actual, 10)
            XCTAssertEqual(expected, 256)
        }
    }

    func testExceedsCanonicalMaximum() {
        // 513 × 256 > 131,072 sites
        let siteCount = 513 * 256
        let s = [UInt8](repeating: 0, count: siteCount * ps)
        XCTAssertThrowsError(
            try SpatialMetrics.uniqueProgramCount(soup: s, width: 513, height: 256)
        ) { error in
            guard case .exceedsCanonicalMaximum = error as? SpatialMetricsError else {
                XCTFail("expected exceedsCanonicalMaximum, got \(error)"); return
            }
        }
    }

    // MARK: - Canonical-scale performance test

    func testCanonicalScalePerformance() throws {
        // 512×256 = 131,072 sites, 8,388,608 bytes.
        // Use a simple pattern: program[i] = byte i mod 256 in first position.
        // This creates no large clone components (each program differs by first byte)
        // unless i mod 256 wraps, creating small components of size 512.
        // Actually: site 0 and site 256 both have first byte 0 → they are NOT
        // adjacent in the 512-wide grid (they're one row apart). The identical
        // programs are separated by 512 sites → no clone adjacency.
        let siteCount = SpatialMetrics.canonicalSiteCount
        var soup = [UInt8](repeating: 0, count: siteCount * ps)
        for site in 0..<siteCount {
            soup[site * ps] = UInt8(site % 256)
        }

        // Entropy
        let entropy = SpatialMetrics.byteEntropy(soup)
        XCTAssertGreaterThan(entropy, 7.0, "256 distinct first bytes → near-max entropy")
        XCTAssertLessThanOrEqual(entropy, 8.0)

        // Unique programs
        let unique = try SpatialMetrics.uniqueProgramCount(soup: soup, width: 512, height: 256)
        // Programs 0..255 have distinct first bytes, but program 256 == program 0, etc.
        // 131072 sites / 256 distinct → 512 unique programs
        XCTAssertEqual(unique, 256)

        // Identical neighbor fraction: neighbors differ in first byte most of the time.
        // Only when site and site+1 have same first byte (every 256 sites).
        // In 512-wide rows: sites 0..255 have bytes 0..255, sites 256..511 repeat.
        // East edge (x, x+1): identical only if x and x+1 have same first byte,
        // which happens at x=255 (both 255 and 0 mod 256 → 255≠0, not identical).
        // Actually x=255: byte=255, x+1=256: byte=0 → different.
        // So NO east edges are identical in the interior.
        // South edge (x, y)-(x, y+1): site[y][x] and site[y+1][x].
        // First bytes: y*512 + x mod 256 vs (y+1)*512 + x mod 256.
        // For y=0: x mod 256 vs 512+x mod 256 = x mod 256 → SAME for all x!
        // Wait: (0*512 + x) mod 256 = x mod 256. (1*512 + x) mod 256 = (512+x) mod 256
        // 512 mod 256 = 0, so (512+x) mod 256 = x mod 256 → identical for all x.
        // So all 512 south edges in row 0→1 are identical. And similarly
        // for rows 0→1, 2→3, ... (even→odd rows).
        // For rows 1→2: (512+x) mod 256 = x mod 256 vs (1024+x) mod 256 = x mod 256 → same.
        // Actually ALL south edges are identical! (y*512+x) mod 256 = x mod 256
        // and ((y+1)*512+x) mod 256 = (512+x) mod 256 = x mod 256.
        // So 512*256 = 131,072 south edges all identical.
        // East edges: (y*512+x) mod 256 vs (y*512+x+1) mod 256 → different for all
        // except when x mod 256 = 255 and (x+1) mod 256 = 0 → different.
        // So 0 east edges identical. But toroidal wrap: x=511 to x=0:
        // (y*512+511) mod 256 = 255 vs (y*512+0) mod 256 = 0 → different.
        // So 0 east edges identical, 131,072 south edges identical.
        // Total edges = 131,072 * 2 = 262,144. Identical = 131,072. Fraction = 0.5.
        let frac = try SpatialMetrics.identicalNeighborFraction(soup: soup, width: 512, height: 256)
        XCTAssertEqual(frac, 0.5, accuracy: 1e-12)

        // Largest clone component: all programs in a column share the same first byte
        // (because y*512+x mod 256 = x mod 256 regardless of y).
        // So column x has 256 sites all with first byte x mod 256.
        // But are they connected? Site (x, 0) and (x, 1) are south neighbors.
        // Their programs: first byte x mod 256 for both. But do the OTHER 63 bytes
        // match? In our soup, only byte[0] varies, rest are 0. So yes, full 64-byte
        // programs are identical within a column.
        // So each column of 256 sites is one component. But toroidal:
        // column x and column x+512 → same column (width=512). So 512 columns × 256
        // sites each = 512 components of size 256.
        // Wait — are different columns with the same x mod 256 connected?
        // Column x and column x+256: same first byte, but they are NOT adjacent
        // (they differ by 256 in x, which is more than 1).
        // But column 0 and column 1 differ in first byte (0 vs 1) → not identical.
        // So: 512 columns, each forming a vertical ring of 256 identical programs.
        // Largest = 256, fraction = 256 / 131,072 = 1/512.
        let (size, compFrac) = try SpatialMetrics.largestCloneComponent(
            soup: soup, width: 512, height: 256)
        XCTAssertEqual(size, 256)
        XCTAssertEqual(compFrac, 1.0 / 512.0, accuracy: 1e-12)

        // No fragile wall-time assertion — just verify it completes.
    }
}
