/// Deterministic, cheap, *structure-sensitive* byte-stream metrics.
///
/// Order-0 Shannon entropy (`ByteHistogram.shannonEntropyBitsPerByte`) is blind to
/// order: a soup and any permutation of its bytes share it. These two metrics react
/// to arrangement, so together with entropy they distinguish "high-entropy noise"
/// from "high-entropy *with repeated structure*" — the regime where replicators and
/// motifs appear. Both are O(n) or O(n·window), deterministic, and dependency-free,
/// so they run on the same benchmark cadence as entropy.
///
/// IMPORTANT — what these are NOT: neither is Kolmogorov complexity, which is
/// uncomputable. `compressionProxyRatio` is a *finite-window greedy LZ77 token
/// count*, an explicit, reproducible proxy for compressibility, not the output of a
/// real codec and not an information-theoretic lower bound. Read them as relative,
/// same-alphabet, same-length signals, not absolute complexities.
public enum StructureMetrics {

    /// Adjacent-byte transition rate: the fraction of adjacent byte pairs that
    /// differ, in `[0, 1]`.
    ///
    /// Interpretation: `0` means every neighbor is identical (a single constant run —
    /// maximal local order); `1` means every neighbor differs (no local runs). Random
    /// bytes over an alphabet of size `k` sit near `1 - 1/k`. It falls when the stream
    /// develops runs/plateaus (e.g. copied regions, filled tapes) even while order-0
    /// entropy stays high, which is exactly the order-blindness entropy misses.
    /// Fewer than two bytes ⇒ `0` (no adjacency to score).
    public static func transitionRate<C: Collection>(_ bytes: C) -> Double
        where C.Element == UInt8 {
        var previous: UInt8? = nil
        var transitions = 0
        var pairs = 0
        for b in bytes {
            if let p = previous {
                pairs += 1
                if p != b { transitions += 1 }
            }
            previous = b
        }
        guard pairs > 0 else { return 0 }
        return Double(transitions) / Double(pairs)
    }

    /// Finite-window greedy LZ77 compression proxy: an estimate of compressed size as
    /// a fraction of input size, in `(0, 1]`. Lower ⇒ more repetition/structure.
    ///
    /// The estimator scans left to right; at each position it looks back up to
    /// `window` bytes for the longest match of at least `minMatch` bytes. A match
    /// emits ONE back-reference token and advances by the match length; otherwise it
    /// emits ONE literal token and advances by one. The ratio is
    /// `tokenCount / inputByteCount` — every token is charged one fixed unit, so a
    /// stream with no repeats is all literals (ratio `1.0`) and a highly repetitive
    /// stream collapses to a few tokens (ratio → `0`).
    ///
    /// This is deterministic and independent of any library. It is a *proxy*: the
    /// unit-cost token model is a stand-in for a real entropy-coded (offset, length)
    /// encoding, chosen so the number is stable and explainable rather than accurate.
    /// Empty input ⇒ `0`. `minMatch` is clamped to at least 2 and `window` to at
    /// least 1 so the scan always terminates.
    public static func compressionProxyRatio(_ bytes: [UInt8],
                                             window: Int = 64,
                                             minMatch: Int = 3) -> Double {
        let n = bytes.count
        guard n > 0 else { return 0 }
        let win = max(1, window)
        let minM = max(2, minMatch)

        var tokens = 0
        var i = 0
        while i < n {
            var bestLen = 0
            // Search the back-window for the longest match starting at i.
            let lowest = i >= win ? i - win : 0
            var start = i - 1
            while start >= lowest {
                var len = 0
                // Match may overlap the current position (classic LZ77 run copy):
                // reference index wraps within [start, i) as it extends past i.
                while i + len < n && bytes[start + len % (i - start)] == bytes[i + len] {
                    len += 1
                }
                if len > bestLen { bestLen = len }
                start -= 1
            }
            if bestLen >= minM {
                tokens += 1
                i += bestLen
            } else {
                tokens += 1
                i += 1
            }
        }
        return Double(tokens) / Double(n)
    }
}
