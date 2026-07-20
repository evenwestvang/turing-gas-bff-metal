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

/// Shared canvas-only visualization theme. The Metal shader mirrors these exact
/// literals; Swift keeps the contract testable without parsing shader source.
public enum SoupVisualizationTheme: Sendable {
    public static let background = RGB(hex: 0xF4F0E8)
    public static let programBoundary = RGB(hex: 0x181614)
    public static let byteBoundary = RGB(hex: 0xBDBAB4)
    public static let glyphDarkInk = RGB(hex: 0x171412)
    public static let glyphLightInk = RGB(hex: 0xFAF7EF)

    public static func luminance(_ color: RGB) -> Double {
        color.r * 0.299 + color.g * 0.587 + color.b * 0.114
    }

    private static func clamped01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    public static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let u = clamped01(t)
        if u <= 0 { return a }
        if u >= 1 { return b }
        return RGB(a.r + (b.r - a.r) * u,
                   a.g + (b.g - a.g) * u,
                   a.b + (b.b - a.b) * u)
    }

    public static func glyphInk(forBase color: RGB) -> RGB {
        luminance(color) > 0.45 ? glyphDarkInk : glyphLightInk
    }

    public static func edgeColor(base: RGB,
                                 classification: LODModel.GridEdgeClassification,
                                 programBoundaryBlend: Double,
                                 byteBoundaryBlend: Double) -> RGB {
        let alpha = LODModel.gridEdgeAlpha(classification,
                                           programBoundaryBlend: programBoundaryBlend,
                                           byteBoundaryBlend: byteBoundaryBlend)
        switch classification {
        case .program:
            return mix(base, programBoundary, alpha)
        case .interiorByte:
            return mix(base, byteBoundary, alpha)
        case .none:
            return base
        }
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
    /// pair `.`/`,` stays distinct inside the restrained editorial palette.
    public var color: RGB {
        switch self {
        case .head0Left: return RGB(hex: 0x4E928C)
        case .head0Right: return RGB(hex: 0x6FAEA8)
        case .head1Left: return RGB(hex: 0x5D78A0)
        case .head1Right: return RGB(hex: 0x879CBC)
        case .inc: return RGB(hex: 0xC97767)
        case .dec: return RGB(hex: 0xA95C57)
        case .write: return RGB(hex: 0x6B9B7A)
        case .read: return RGB(hex: 0xB4778E)
        case .loopOpen: return RGB(hex: 0x8480AE)
        case .loopClose: return RGB(hex: 0x9A8E5C)
        }
    }

    /// The glyph-table slot; equals `rawValue`, pinned so the shader stays aligned.
    public var glyphIndex: Int { rawValue }
}

/// Deterministic byte → color mapping shared (by mirrored constants) with the
/// render shader. Pure and fully tested on any platform; the shader carries the
/// same literals and is validated against these by unit tests on the Swift side.
public enum OpcodeVisual {

    /// Warm paper color for byte 0 (null), distinct from the canvas and seams.
    public static let nullColor = RGB(hex: 0xEEE9DF)
    public static let dataRampLow = RGB(hex: 0xE7E1D7)
    public static let dataRampHigh = RGB(hex: 0x8F9A9B)

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

    /// Color for any byte value: an opcode's palette color, the null paper color
    /// for 0, else a low-chroma neutral ramp so data shows structure without
    /// competing with commands. Deterministic and pinned.
    public static func color(_ byte: UInt8) -> RGB {
        if let op = classify(byte) { return op.color }
        if byte == 0 { return nullColor }
        return SoupVisualizationTheme.mix(dataRampLow, dataRampHigh, Double(byte) / 255)
    }
}
