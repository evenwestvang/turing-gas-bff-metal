/// Continuous level-of-detail blend as a function of the zoom variable `bytePx`
/// (03 §3). There are no discrete render modes — only smooth blend factors, so
/// zooming is perfectly continuous and there is never a hard two-screen switch.
///
/// | band | bytePx | what shows |
/// |------|--------|------------|
/// | macro          | `< macroEnd`            | aggregate entropy/activity field |
/// | macro↔micro    | `macroStart … macroEnd` | crossfade of the two |
/// | byte colors    | `≥ macroEnd`            | per-byte opcode palette |
/// | glyph overlay  | `glyphStart … glyphEnd` | procedural opcode marks fade in |
///
/// All thresholds are constants here (the one shared source of truth; the shader
/// receives the *evaluated* blend factors, not the thresholds, so this Swift model
/// is the tested definition and the shader cannot drift from it).
public struct LODModel: Equatable, Sendable {
    /// `bytePx` where the macro→micro crossfade begins.
    public var macroStart: Double
    /// `bytePx` where micro (byte colors) is fully opaque.
    public var macroEnd: Double
    /// `bytePx` where opcode glyph marks begin to appear.
    public var glyphStart: Double
    /// `bytePx` where opcode glyph marks are fully opaque.
    public var glyphEnd: Double

    public init(macroStart: Double = 0.5, macroEnd: Double = 1.5,
                glyphStart: Double = 12, glyphEnd: Double = 18) {
        precondition(macroStart < macroEnd, "macro band must be non-empty")
        precondition(glyphStart < glyphEnd, "glyph band must be non-empty")
        self.macroStart = macroStart
        self.macroEnd = macroEnd
        self.glyphStart = glyphStart
        self.glyphEnd = glyphEnd
    }

    /// Hermite smoothstep in `[edge0, edge1]`, clamped to `[0, 1]`; matches MSL
    /// `smoothstep`. Non-finite input yields 0.
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard x.isFinite, edge0 < edge1 else { return x >= edge1 ? 1 : 0 }
        let t = Swift.min(Swift.max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Weight of the micro (byte-color) branch, 0 at full macro, 1 once byte
    /// colors are opaque.
    public func microBlend(bytePx: Double) -> Double {
        Self.smoothstep(macroStart, macroEnd, bytePx)
    }

    /// Weight of the macro (metric-field) branch — the complement of `microBlend`.
    public func macroBlend(bytePx: Double) -> Double {
        1 - microBlend(bytePx: bytePx)
    }

    /// Opacity of the opcode glyph overlay, 0 until `glyphStart`, 1 at `glyphEnd`.
    public func glyphBlend(bytePx: Double) -> Double {
        Self.smoothstep(glyphStart, glyphEnd, bytePx)
    }
}
