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
/// Two structural overlays fade in the same way — both gated on how large a cell is
/// on screen, never present when a cell is subpixel:
///
/// | overlay | gate variable | what shows |
/// |---------|---------------|------------|
/// | program boundaries | program cell px = `8·bytePx` | 8×8-block edges, absent at macro LOD, subtle fade when the blocks are big enough to read |
/// | byte boundaries    | byte cell px = `bytePx`      | per-byte cell edges, low-alpha, only at the closest LOD, drawn *beneath* glyph ink |
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
    /// Program-cell size in px (`8·bytePx`) where 8×8-block boundaries begin to fade in.
    /// Below this the blocks are too small for a grid to help (and are absent entirely
    /// once a program cell is subpixel); 24 px ≈ `bytePx` 3 (03 §3).
    public var programBoundaryStartPx: Double
    /// Program-cell size in px where block boundaries are fully faded in (48 px ≈ `bytePx` 6).
    public var programBoundaryEndPx: Double
    /// `bytePx` (byte-cell px) where per-byte boundaries begin to fade in — deep zoom
    /// only, under the glyph ink (03 §3: byte gridlines from `bytePx ≥ 24`).
    public var byteBoundaryStart: Double
    /// `bytePx` where per-byte boundaries are fully faded in.
    public var byteBoundaryEnd: Double

    public init(macroStart: Double = 0.5, macroEnd: Double = 1.5,
                glyphStart: Double = 12, glyphEnd: Double = 18,
                programBoundaryStartPx: Double = 24, programBoundaryEndPx: Double = 48,
                byteBoundaryStart: Double = 24, byteBoundaryEnd: Double = 32) {
        precondition(macroStart < macroEnd, "macro band must be non-empty")
        precondition(glyphStart < glyphEnd, "glyph band must be non-empty")
        precondition(programBoundaryStartPx < programBoundaryEndPx,
                     "program-boundary band must be non-empty")
        precondition(byteBoundaryStart < byteBoundaryEnd, "byte-boundary band must be non-empty")
        self.macroStart = macroStart
        self.macroEnd = macroEnd
        self.glyphStart = glyphStart
        self.glyphEnd = glyphEnd
        self.programBoundaryStartPx = programBoundaryStartPx
        self.programBoundaryEndPx = programBoundaryEndPx
        self.byteBoundaryStart = byteBoundaryStart
        self.byteBoundaryEnd = byteBoundaryEnd
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

    /// Program-boundary (8×8-block edge) fade, gated on the program-cell size on
    /// screen (`8·bytePx`): 0 while the blocks are small — and in particular 0 at
    /// macro LOD where a program cell is subpixel — rising to 1 once the blocks are
    /// large enough that the grid aids reading. The shader scales this by a subtle
    /// max opacity so the lines never dominate.
    public func programBoundaryBlend(bytePx: Double) -> Double {
        Self.smoothstep(programBoundaryStartPx, programBoundaryEndPx, 8 * bytePx)
    }

    /// Per-byte-boundary fade, gated on the byte-cell size on screen (`bytePx`): 0
    /// except at the closest zoom, where a faint per-cell grid appears *beneath* the
    /// glyph ink. The shader scales this by a low max opacity.
    public func byteBoundaryBlend(bytePx: Double) -> Double {
        Self.smoothstep(byteBoundaryStart, byteBoundaryEnd, bytePx)
    }
}
