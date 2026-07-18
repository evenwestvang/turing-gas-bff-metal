import CBrotli
import BFFOracle

/// The Brotli integration: the *measurement* half of the paper's high-order
/// complexity, kept in its own target so only `bff-metal-bench` (and this
/// target's tests) link Brotli — the oracle, the Metal evaluator, and the app
/// never do. The *definition* half (H0 − brotli_bpb, thresholds) is
/// `BFFOracle.PaperComplexity`, which needs no Brotli at all.
///
/// Every knob matches cubff's `higher_entropy` measurement byte-for-byte
/// (paradigms-of-intelligence/cubff, `common_language.h`; see
/// `Docs/CubffGrounding.md`): `BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC,
/// …)` — quality 2, lgwin 24 (`BROTLI_MAX_WINDOW_BITS`), generic mode, the whole
/// soup in one shot, output sized by `BrotliEncoderMaxCompressedSize`.
public enum BrotliCompressor {

    /// `BROTLI_MAKE_HEX_VERSION(1, 1, 0)` — the exact encoder the paper metric is
    /// defined against. (`BrotliEncoderVersion()` packs major/minor/patch as
    /// `(major << 24) | (minor << 12) | patch`.)
    public static let paperVersionHex: UInt32 = 0x1001000

    /// The linked encoder's version word.
    public static var encoderVersion: UInt32 { BrotliEncoderVersion() }

    /// Human-readable `major.minor.patch` of the linked encoder.
    public static var encoderVersionString: String {
        let v = encoderVersion
        return "\((v >> 24) & 0xFFF).\((v >> 12) & 0xFFF).\(v & 0xFFF)"
    }

    /// True iff the linked Brotli is exactly 1.1.0. The paper bits/byte is emitted
    /// ONLY when this holds; against any other encoder the metric is reported as
    /// "not computed" (`nil`) rather than a subtly-wrong number, because quality-2
    /// output diverges across encoder versions at soup scale (see
    /// `Docs/CubffGrounding.md`). This is what makes the dependency
    /// *version-pinned* rather than an unversioned system-library gamble.
    public static var isPaperPinned: Bool { encoderVersion == paperVersionHex }

    /// Compressed byte count of `bytes` under cubff's exact quality-2 call. Returns
    /// the encoder's `*encoded_size`, or `nil` only if the encoder reports failure
    /// (never for valid input). Runs on any linked Brotli version — provenance
    /// gating is `paperBitsPerByte`'s / the caller's responsibility, so the fixture
    /// test can exercise the raw call even on a non-1.1.0 host.
    public static func quality2CompressedByteCount(_ bytes: [UInt8]) -> Int? {
        let n = bytes.count
        var cap = BrotliEncoderMaxCompressedSize(n)
        if cap == 0 { cap = 64 }   // MaxCompressedSize(0) can be 0; an empty input still emits a stream
        var out = [UInt8](repeating: 0, count: cap)
        var outSize = cap
        var scratch: UInt8 = 0

        let ok: Int32 = withUnsafeMutablePointer(to: &scratch) { scratchPtr in
            out.withUnsafeMutableBufferPointer { outBuf in
                bytes.withUnsafeBufferPointer { inBuf in
                    // Empty arrays have a nil baseAddress; give Brotli a valid
                    // (unread, size-0) pointer so the empty case is well-defined.
                    let inPtr = inBuf.baseAddress ?? UnsafePointer(scratchPtr)
                    return BrotliEncoderCompress(2, 24, BROTLI_MODE_GENERIC,
                                                 n, inPtr, &outSize, outBuf.baseAddress)
                }
            }
        }
        return ok != 0 ? outSize : nil
    }

    /// Paper Brotli bits/byte for a soup: `compressedBytes * 8 / soupBytes`, using
    /// the exact quality-2 call. Returns `nil` when the linked encoder is not the
    /// pinned 1.1.0 (honest "not computed") or when compression fails. This is the
    /// one entry point the benchmark's paper-metric path calls.
    public static func paperBitsPerByte(soup: [UInt8]) -> Double? {
        guard isPaperPinned else { return nil }
        guard let compressed = quality2CompressedByteCount(soup) else { return nil }
        return PaperComplexity.brotliBitsPerByte(compressedByteCount: compressed,
                                                 soupByteCount: soup.count)
    }
}
