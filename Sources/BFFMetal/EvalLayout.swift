import BFFOracle
import CBFFShared

/// Platform-independent view of the shared CPU/MSL layout contract
/// (`Sources/CBFFShared/include/BFFShared.h`).
///
/// Everything here compiles and is tested on Linux; only the Metal dispatch code
/// that consumes it is macOS-gated. The documented literals live in the header's
/// `_Static_assert`s; this type re-derives the same facts from Swift's own
/// `MemoryLayout` of the imported structs, so the host tests prove that what
/// Swift will serialize is byte-identical to what C declared — and the GPU probe
/// proves the same for what Metal compiled.
public enum BFFEvalLayout {

    /// Words `bff_layout_probe` writes, in the exact order the kernel writes
    /// them, computed from the HOST layout of the imported C structs:
    ///
    ///     [0] sizeof(BFFEvalParams)   [1] alignof(BFFEvalParams)
    ///     [2] offsetof(pairCount)     [3] offsetof(stepBudget)
    ///     [4] offsetof(variant)       [5] offsetof(reserved)
    ///     [6] sizeof(BFFEvalResult)   [7] alignof(BFFEvalResult)
    ///     [8] offsetof(steps)         [9] offsetof(noopSteps)
    ///    [10] offsetof(copyWrites)   [11] offsetof(loopOps)
    ///    [12] offsetof(halt)
    ///
    /// The GPU-side words must equal these exactly for buffers to be readable.
    public static func hostProbeWords() -> [UInt32] {
        func word(_ value: Int?) -> UInt32 {
            guard let value, let narrowed = UInt32(exactly: value) else {
                fatalError("shared struct field offset unavailable — layout contract broken")
            }
            return narrowed
        }
        return [
            word(MemoryLayout<BFFEvalParams>.size),
            word(MemoryLayout<BFFEvalParams>.alignment),
            word(MemoryLayout<BFFEvalParams>.offset(of: \.pairCount)),
            word(MemoryLayout<BFFEvalParams>.offset(of: \.stepBudget)),
            word(MemoryLayout<BFFEvalParams>.offset(of: \.variant)),
            word(MemoryLayout<BFFEvalParams>.offset(of: \.reserved)),
            word(MemoryLayout<BFFEvalResult>.size),
            word(MemoryLayout<BFFEvalResult>.alignment),
            word(MemoryLayout<BFFEvalResult>.offset(of: \.steps)),
            word(MemoryLayout<BFFEvalResult>.offset(of: \.noopSteps)),
            word(MemoryLayout<BFFEvalResult>.offset(of: \.copyWrites)),
            word(MemoryLayout<BFFEvalResult>.offset(of: \.loopOps)),
            word(MemoryLayout<BFFEvalResult>.offset(of: \.halt)),
        ]
    }

    /// Number of `uint32_t` words the probe kernel writes.
    public static var probeWordCount: Int { 13 }

    /// The header's variant encoding for an oracle variant.
    public static func variantCode(_ variant: BFFVariant) -> UInt32 {
        switch variant {
        case .noheads: return UInt32(BFF_VARIANT_NOHEADS)
        case .seededHeads: return UInt32(BFF_VARIANT_SEEDED_HEADS)
        }
    }

    /// Largest step budget the shared `uint32_t` field can carry.
    public static var maxStepBudget: Int { Int(UInt32.max) }
}
