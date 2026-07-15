#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Global 256-bin byte histogram plus derived Shannon entropy (01 §5, 02 §8).
public struct ByteHistogram: Codable, Equatable, Sendable {
    /// `bins[v]` = number of bytes with value `v`. Always 256 entries.
    public var bins: [UInt64]

    public init(bins: [UInt64]) {
        precondition(bins.count == 256, "histogram must have exactly 256 bins")
        self.bins = bins
    }

    public init<S: Sequence>(bytes: S) where S.Element == UInt8 {
        var bins = [UInt64](repeating: 0, count: 256)
        for b in bytes { bins[Int(b)] += 1 }
        self.bins = bins
    }

    public var totalCount: UInt64 { bins.reduce(0, +) }

    /// Order-0 (plug-in) Shannon entropy of the byte distribution, bits per byte,
    /// in [0, 8]. Empty input yields 0.
    public var shannonEntropyBitsPerByte: Double {
        let total = totalCount
        guard total > 0 else { return 0 }
        let n = Double(total)
        var h = 0.0
        for count in bins where count > 0 {
            let p = Double(count) / n
            h -= p * log2(p)
        }
        return h
    }

    /// Bins whose counts differ from `other`, as `(value, self, other)` triples.
    public func mismatches(against other: ByteHistogram) -> [(value: Int, lhs: UInt64, rhs: UInt64)] {
        var out: [(Int, UInt64, UInt64)] = []
        for v in 0..<256 where bins[v] != other.bins[v] {
            out.append((v, bins[v], other.bins[v]))
        }
        return out
    }
}
