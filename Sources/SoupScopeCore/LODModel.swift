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
/// Two structural overlays fade in on different bands — not both on close
/// byte-cell zoom:
///
/// - the program perimeter fades with the macro→micro byte-color transition
///   at `bytePx` 0.5…1.5;
/// - the interior byte seams remain gated on close byte-cell zoom at
///   `bytePx` 24…32.
///
/// | overlay | gate variable | what shows |
/// |---------|---------------|------------|
/// | program boundaries | program cell px = `8·bytePx` | 8×8-block outer edges, fading in with the macro→micro crossfade (bytePx 0.5…1.5), slightly stronger than byte edges |
/// | byte boundaries    | byte cell px = `bytePx`      | per-byte cell edges, low-alpha, only at the closest LOD, drawn *beneath* glyph ink |
///
/// All thresholds are constants here (the one shared source of truth; the shader
/// receives the *evaluated* blend factors, not the thresholds, so this Swift model
/// is the tested definition and the shader cannot drift from it).
public struct LODModel: Equatable, Sendable {
    public enum GridEdgeClassification: Equatable, Sendable {
        case program
        case interiorByte
        case none
    }

    /// Maximum alpha applied to program perimeter pixels.
    public static let programBoundaryAlpha = 0.80
    /// Maximum alpha applied to interior byte-boundary pixels.
    public static let byteBoundaryAlpha = 0.18

    /// `bytePx` where the macro→micro crossfade begins.
    public var macroStart: Double
    /// `bytePx` where micro (byte colors) is fully opaque.
    public var macroEnd: Double
    /// `bytePx` where opcode glyph marks begin to appear.
    public var glyphStart: Double
    /// `bytePx` where opcode glyph marks are fully opaque.
    public var glyphEnd: Double
    /// Program-cell size in px (`8·bytePx`) where 8×8-block boundaries begin to
    /// fade in. The default 4 px is `bytePx` 0.5, so the program perimeter fade
    /// begins exactly at the macro→micro crossfade start.
    public var programBoundaryStartPx: Double
    /// Program-cell size in px where block boundaries are fully faded in (12 px
    /// = `bytePx` 1.5), matching the macro→micro crossfade end.
    public var programBoundaryEndPx: Double
    /// `bytePx` (byte-cell px) where per-byte boundaries begin to fade in — true
    /// close zoom only, under the glyph ink.
    public var byteBoundaryStart: Double
    /// `bytePx` where per-byte boundaries are fully faded in.
    public var byteBoundaryEnd: Double

    public init(macroStart: Double = 0.5, macroEnd: Double = 1.5,
                glyphStart: Double = 12, glyphEnd: Double = 18,
                programBoundaryStartPx: Double = 4, programBoundaryEndPx: Double = 12,
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

    /// Line half-width in byte-cell UV units. Mirrors the shader's 0.5-pixel
    /// edge width and clamps to half a cell so pathological zoom values cannot
    /// classify the whole cell as an edge.
    public static func gridLineFraction(bytePx: Double) -> Double {
        guard bytePx.isFinite, bytePx > 0 else { return 0.5 }
        return Swift.min(0.5 / Swift.max(bytePx, 1e-4), 0.5)
    }

    /// Classify the structural grid edge for a byte-cell pixel. The decision is
    /// intentionally mutually exclusive: program perimeter wins first, interior
    /// byte boundaries second, and all remaining pixels are ungridded.
    public static func gridEdgeClassification(inBlockX: Int, inBlockY: Int,
                                              cellU: Double, cellV: Double,
                                              bytePx: Double) -> GridEdgeClassification {
        let u = cellU.isFinite ? Swift.min(Swift.max(cellU, 0), 1) : 0
        let v = cellV.isFinite ? Swift.min(Swift.max(cellV, 0), 1) : 0
        let line = gridLineFraction(bytePx: bytePx)

        let onProgramEdge =
            (inBlockX == 0 && u < line)
            || (inBlockY == 0 && v < line)
            || (inBlockX == 7 && u >= 1 - line)
            || (inBlockY == 7 && v >= 1 - line)
        if onProgramEdge { return .program }

        let onInteriorByteEdge =
            (inBlockX > 0 && u < line)
            || (inBlockY > 0 && v < line)
            || (inBlockX < 7 && u >= 1 - line)
            || (inBlockY < 7 && v >= 1 - line)
        return onInteriorByteEdge ? .interiorByte : .none
    }

    /// Mutually exclusive alpha policy for a classified structural edge. Program
    /// perimeter pixels never accumulate the byte-boundary alpha.
    public static func gridEdgeAlpha(_ classification: GridEdgeClassification,
                                     programBoundaryBlend: Double,
                                     byteBoundaryBlend: Double) -> Double {
        func clamped(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return Swift.min(Swift.max(value, 0), 1)
        }

        switch classification {
        case .program:
            return programBoundaryAlpha * clamped(programBoundaryBlend)
        case .interiorByte:
            return byteBoundaryAlpha * clamped(byteBoundaryBlend)
        case .none:
            return 0
        }
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
    /// screen (`8·bytePx`): 0 below the macro→micro crossfade, rising to 1 across
    /// the same `bytePx` band as `microBlend` (0.5…1.5), so the program perimeter
    /// appears together with the byte colors and never at overview/mid LOD. The
    /// shader scales this by a subtle max opacity so the lines never dominate.
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
