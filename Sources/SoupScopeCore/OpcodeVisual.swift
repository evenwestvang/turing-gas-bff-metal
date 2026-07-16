import BFFOracle

/// Linear RGB triple in `[0, 1]`, the renderer's byte-color unit.
public struct RGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
    /// Construct from an 8-bit-per-channel hex literal, e.g. `0x2FB8AC`.
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255,
                  Double((hex >> 8) & 0xFF) / 255,
                  Double(hex & 0xFF) / 255)
    }
}

/// The ten BFF opcodes with a fixed visual identity (03 §5). The byte values are
/// taken from `BFFOp` (the shared/oracle constants — 01 §2), so this mapping is
/// exactly the interpreter's and any drift is a test failure. `glyphIndex` is the
/// stable 0…9 slot the render shader's procedural glyph table mirrors.
public enum BFFOpcode: Int, CaseIterable, Sendable {
    case head0Left = 0   // '<'
    case head0Right      // '>'
    case head1Left       // '{'
    case head1Right      // '}'
    case inc             // '+'
    case dec             // '-'
    case write           // '.'
    case read            // ','
    case loopOpen        // '['
    case loopClose       // ']'

    /// The command byte value, from the shared `BFFOp` constants.
    public var byte: UInt8 {
        switch self {
        case .head0Left: return BFFOp.head0Left
        case .head0Right: return BFFOp.head0Right
        case .head1Left: return BFFOp.head1Left
        case .head1Right: return BFFOp.head1Right
        case .inc: return BFFOp.inc
        case .dec: return BFFOp.dec
        case .write: return BFFOp.write
        case .read: return BFFOp.read
        case .loopOpen: return BFFOp.loopOpen
        case .loopClose: return BFFOp.loopClose
        }
    }

    /// Stable palette color (03 §5). Hue encodes the operational family; the copy
    /// pair `.`/`,` (green/magenta) is loudest because copy loops are the hunt.
    public var color: RGB {
        switch self {
        case .head0Left: return RGB(hex: 0x2FB8AC)
        case .head0Right: return RGB(hex: 0x45E0D2)
        case .head1Left: return RGB(hex: 0x3D6FE0)
        case .head1Right: return RGB(hex: 0x6FA0FF)
        case .inc: return RGB(hex: 0xE08A3D)
        case .dec: return RGB(hex: 0xC24B4B)
        case .write: return RGB(hex: 0x46E052)
        case .read: return RGB(hex: 0xE046C8)
        case .loopOpen: return RGB(hex: 0xE0D040)
        case .loopClose: return RGB(hex: 0xB8A81E)
        }
    }

    /// The glyph-table slot; equals `rawValue`, pinned so the shader stays aligned.
    public var glyphIndex: Int { rawValue }
}

/// Deterministic byte → color mapping shared (by mirrored constants) with the
/// render shader. Pure and fully tested on any platform; the shader carries the
/// same literals and is validated against these by unit tests on the Swift side.
public enum OpcodeVisual {

    /// The near-black "vacuum" color for byte 0 (null), 03 §5 `#101014`.
    public static let nullColor = RGB(hex: 0x101014)

    private static let byteToOpcode: [UInt8: BFFOpcode] = {
        var map: [UInt8: BFFOpcode] = [:]
        for op in BFFOpcode.allCases { map[op.byte] = op }
        return map
    }()

    /// Classify a byte as one of the ten opcodes, or `nil` for a data/no-op byte
    /// (including byte 0, which is null — a no-op, not a command).
    public static func classify(_ byte: UInt8) -> BFFOpcode? {
        byteToOpcode[byte]
    }

    /// Color for any byte value: an opcode's palette color, the null vacuum color
    /// for 0, else a low-chroma, slightly blue-tinted grayscale ramp so data shows
    /// structure without competing with commands (03 §5). Deterministic and pinned.
    public static func color(_ byte: UInt8) -> RGB {
        if let op = classify(byte) { return op.color }
        if byte == 0 { return nullColor }
        // Data ramp: sRGB luminance 0.13 + 0.17·(value/255), slight blue tint.
        let lum = 0.13 + 0.17 * (Double(byte) / 255)
        return RGB(min(lum * 0.90, 1), min(lum * 0.96, 1), min(lum * 1.12, 1))
    }
}
