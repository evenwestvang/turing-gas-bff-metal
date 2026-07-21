import Foundation

/// Bounded spatial metrics for the ecology torus.
///
/// Pure deterministic functions over flat byte soups arranged as
/// `width × height` programs of `BFF.tapeSize` (64) bytes each.
/// No Metal, no CLI, no checkpoint/resume, no aggregation, no biological
/// interpretation. All spatial functions validate dimensions and soup size
/// before any allocation; invalid inputs throw `SpatialMetricsError`.
///
/// # Bounds
///
/// Canonical production grid: 512 × 256 = 131,072 sites, 8,388,608 bytes.
/// All spatial functions reject inputs exceeding this bound.
///
/// ## Asymptotic complexity (n = soup byte count)
///
/// - `byteEntropy`: O(n) time, O(256) space
/// - `uniqueProgramCount`: O(n) time, O(n) space (hash set of programs)
/// - `identicalNeighborFraction`: O(n) time, O(1) extra space
/// - `largestCloneComponent`: O(n) time, O(n/64) space (visited + queue)
/// - `byteTurnover`: O(n) time, O(1) extra space
///
/// ## Concrete workspace (canonical 512×256)
///
/// - `uniqueProgramCount`: ~8 MiB hash set (131,072 × 64-byte Data entries)
/// - `largestCloneComponent`: ~512 KiB visited array + queue
/// - Peak total across a full metrics pass: ~9 MiB
public enum SpatialMetrics {

    // MARK: - Canonical bounds

    public static let canonicalWidth = 512
    public static let canonicalHeight = 256
    public static let canonicalSiteCount = canonicalWidth * canonicalHeight
    public static let canonicalSoupByteCount = canonicalSiteCount * BFF.tapeSize

    // MARK: - Validation

    @usableFromInline
    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw SpatialMetricsError.zeroDimensions
        }
        let (siteCount, ovf1) = width.multipliedReportingOverflow(by: height)
        guard !ovf1, siteCount > 0 else {
            throw SpatialMetricsError.dimensionOverflow(width: width, height: height)
        }
        guard siteCount <= canonicalSiteCount else {
            throw SpatialMetricsError.exceedsCanonicalMaximum(
                width: width, height: height, max: canonicalSiteCount)
        }
        let (byteCount, ovf2) =
            siteCount.multipliedReportingOverflow(by: BFF.tapeSize)
        guard !ovf2, byteCount > 0 else {
            throw SpatialMetricsError.dimensionOverflow(width: width, height: height)
        }
    }

    @usableFromInline
    static func validateSoup(
        _ soup: [UInt8], width: Int, height: Int
    ) throws -> Int {
        try validateDimensions(width: width, height: height)
        let expected = width * height * BFF.tapeSize
        guard soup.count == expected else {
            throw SpatialMetricsError.soupByteCountMismatch(
                actual: soup.count, expected: expected)
        }
        return expected
    }

    // MARK: - Global byte Shannon entropy

    /// Order-0 Shannon entropy of all bytes in the soup, bits per byte,
    /// in `[0, 8]`.
    ///
    /// Deterministic `Double` computed from exact 256-bin counts.
    /// Empty soup → `0` (not NaN). No spatial validation — this is a
    /// global property of the byte stream, independent of grid layout.
    public static func byteEntropy(_ soup: [UInt8]) -> Double {
        ByteHistogram(bytes: soup).shannonEntropyBitsPerByte
    }

    // MARK: - Exact unique program count

    /// Exact count of distinct 64-byte programs in the soup.
    ///
    /// Each program is the contiguous slice
    /// `soup[siteID * 64 ..< (siteID + 1) * 64]`.
    /// The soup must form a valid `width × height` grid.
    public static func uniqueProgramCount(
        soup: [UInt8], width: Int, height: Int
    ) throws -> Int {
        let _ = try validateSoup(soup, width: width, height: height)
        let programSize = BFF.tapeSize
        let siteCount = width * height
        var seen = Set<Data>()
        seen.reserveCapacity(siteCount)
        for siteID in 0..<siteCount {
            let start = siteID * programSize
            seen.insert(Data(soup[start..<start + programSize]))
        }
        return seen.count
    }

    // MARK: - Identical-neighbor edge fraction

    /// Fraction of undirected toroidal von Neumann edges whose endpoint
    /// programs are byte-identical, in `[0, 1]`.
    ///
    /// Undirected edges: for each site, count East and South only
    /// (West and North are the same edges from the neighbor's side).
    /// Total edges = `width × height × 2`.
    /// A 1×1 grid has two self-edges (east and south both wrap to itself),
    /// both trivially identical → fraction `1.0`.
    public static func identicalNeighborFraction(
        soup: [UInt8], width: Int, height: Int
    ) throws -> Double {
        let _ = try validateSoup(soup, width: width, height: height)
        let ps = BFF.tapeSize
        let totalEdges = width * height * 2
        guard totalEdges > 0 else { return 0 }

        var identical = 0
        for y in 0..<height {
            for x in 0..<width {
                let site = y * width + x
                // East (toroidal wrap)
                let eastSite = y * width + ((x + 1) % width)
                if programsEqual(soup, site, eastSite, ps) { identical += 1 }
                // South (toroidal wrap)
                let southSite = ((y + 1) % height) * width + x
                if programsEqual(soup, site, southSite, ps) { identical += 1 }
            }
        }
        return Double(identical) / Double(totalEdges)
    }

    // MARK: - Largest connected exact-clone component

    /// Largest connected component of byte-identical adjacent programs
    /// on the toroidal von Neumann graph.
    ///
    /// Two sites are connected iff they are von Neumann neighbors
    /// (N, S, E, W with toroidal wrap) AND their 64-byte programs are
    /// byte-identical. Uses iterative BFS (no recursion).
    ///
    /// Returns `(size, fraction)` where `fraction = size / siteCount`.
    public static func largestCloneComponent(
        soup: [UInt8], width: Int, height: Int
    ) throws -> (size: Int, fraction: Double) {
        let _ = try validateSoup(soup, width: width, height: height)
        let ps = BFF.tapeSize
        let siteCount = width * height
        guard siteCount > 0 else { return (0, 0) }

        var visited = [Bool](repeating: false, count: siteCount)
        var largest = 0

        for seed in 0..<siteCount {
            if visited[seed] { continue }
            visited[seed] = true
            var queue = [seed]
            var head = 0
            var componentSize = 0

            while head < queue.count {
                let site = queue[head]
                head += 1
                componentSize += 1

                let x = site % width
                let y = site / width
                let neighbors = [
                    y * width + ((x + 1) % width),              // East
                    y * width + ((x - 1 + width) % width),      // West
                    ((y + 1) % height) * width + x,             // South
                    ((y - 1 + height) % height) * width + x,    // North
                ]
                for nb in neighbors {
                    if visited[nb] { continue }
                    if programsEqual(soup, site, nb, ps) {
                        visited[nb] = true
                        queue.append(nb)
                    }
                }
            }
            if componentSize > largest { largest = componentSize }
        }
        return (largest, Double(largest) / Double(siteCount))
    }

    // MARK: - Byte turnover

    /// Fraction of bytes that differ between two equally sized soups,
    /// in `[0, 1]`.
    ///
    /// Both soups must have the same byte count; throws otherwise.
    /// Empty soups → `0` (no bytes to compare). No spatial validation —
    /// this is a byte-level comparison independent of grid layout.
    public static func byteTurnover(
        _ before: [UInt8], _ after: [UInt8]
    ) throws -> Double {
        guard before.count == after.count else {
            throw SpatialMetricsError.turnoverSizeMismatch(
                before: before.count, after: after.count)
        }
        let n = before.count
        guard n > 0 else { return 0 }
        var changed = 0
        for i in 0..<n {
            if before[i] != after[i] { changed += 1 }
        }
        return Double(changed) / Double(n)
    }

    // MARK: - Internal helpers

    @usableFromInline
    static func programsEqual(
        _ soup: [UInt8], _ a: Int, _ b: Int, _ ps: Int
    ) -> Bool {
        let aStart = a * ps
        let bStart = b * ps
        for i in 0..<ps {
            if soup[aStart + i] != soup[bStart + i] { return false }
        }
        return true
    }
}

// MARK: - Errors

public enum SpatialMetricsError: Error, Equatable, CustomStringConvertible {
    case zeroDimensions
    case soupByteCountMismatch(actual: Int, expected: Int)
    case dimensionOverflow(width: Int, height: Int)
    case exceedsCanonicalMaximum(width: Int, height: Int, max: Int)
    case turnoverSizeMismatch(before: Int, after: Int)

    public var description: String {
        switch self {
        case .zeroDimensions:
            return "width and height must both be positive"
        case .soupByteCountMismatch(let actual, let expected):
            return "soup is \(actual) bytes, expected \(expected)"
        case .dimensionOverflow(let w, let h):
            return "width × height overflow: \(w) × \(h)"
        case .exceedsCanonicalMaximum(let w, let h, let max):
            return "site count \(w * h) exceeds canonical maximum \(max)"
        case .turnoverSizeMismatch(let before, let after):
            return "turnover soups differ in size: \(before) vs \(after)"
        }
    }
}
