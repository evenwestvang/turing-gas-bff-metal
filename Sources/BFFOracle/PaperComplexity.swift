/// Paper-aligned high-order complexity: the *definition* half, kept pure and
/// platform-independent so it is unit-tested without Brotli or Metal.
///
/// This mirrors the metric cubff logs as `higher_entropy`
/// (paradigms-of-intelligence/cubff, `common_language.h`; see
/// `Docs/CubffGrounding.md`):
///
/// - **H0** — whole-soup order-0 Shannon entropy, bits/byte
///   (`ByteHistogram.shannonEntropyBitsPerByte`). cubff's `h0`.
/// - **Brotli bpb** — `brotli_size * 8 / soupByteCount`: the compressed size of
///   the *whole soup* under Brotli 1.1.0 quality 2 (lgwin 24, generic), expressed
///   as bits per input byte. The compression itself lives behind the Brotli
///   integration (`BrotliMetrics`), pinned to encoder version 1.1.0; this type
///   only does the arithmetic once a compressed byte count is in hand.
/// - **High-order complexity** — `H0 − brotli_bpb`. Positive when the soup is
///   *more* compressible than its order-0 entropy predicts, i.e. it carries
///   higher-order structure a real codec exploits. The paper's threshold of
///   interest is `>= 1` bit/byte.
///
/// This is deliberately NOT the same thing as `StructureMetrics.compressionProxyRatio`
/// (the finite-window greedy-LZ77 proxy). That proxy is a reproducible, codec-free
/// *ratio* and must never be described as paper-equivalent; only the real Brotli
/// 1.1.0 q2 path below reproduces the paper's number.
public enum PaperComplexity {

    /// The paper's high-order-complexity threshold, in bits/byte. A soup is at or
    /// past the paper's regime of interest once `H0 − brotli_bpb >= 1`.
    public static let defaultThreshold: Double = 1.0

    /// Brotli bits-per-byte: the compressed byte count as bits per *input* byte.
    /// Exactly cubff's `brotli_bpb = brotli_size * 8.0 / (num_programs *
    /// kSingleTapeSize)`, where the denominator is the soup byte count.
    ///
    /// `soupByteCount <= 0` yields 0 (an empty soup has no bits/byte to report).
    public static func brotliBitsPerByte(compressedByteCount: Int,
                                         soupByteCount: Int) -> Double {
        guard soupByteCount > 0 else { return 0 }
        return Double(compressedByteCount) * 8.0 / Double(soupByteCount)
    }

    /// High-order complexity `H0 − brotli_bpb` (cubff's `higher_entropy`).
    public static func highOrderComplexity(h0: Double,
                                           brotliBitsPerByte: Double) -> Double {
        h0 - brotliBitsPerByte
    }
}
