/// The camera/LOD-derived values that drive one rendered frame: the zoom variable
/// `bytePx` and the LOD blend factors evaluated from the shared `LODModel` at that
/// zoom. Built once from a `Camera` + `LODModel` and consumed by *both* the render
/// uniforms (`VizLayout.makeUniforms`) and the diagnostic HUD, so the on-screen
/// readout can never drift from the factors the shader is actually blending — there
/// is a single evaluation of the thresholds, never a HUD copy of them.
public struct LODReadout: Equatable, Sendable {
    /// Screen pixels per byte cell — the single LOD variable, straight from the camera.
    public let bytePx: Double
    /// Weight of the macro (metric-field) branch; the complement of `microBlend`.
    public let macroBlend: Double
    /// Weight of the micro (byte-color) branch.
    public let microBlend: Double
    /// Opacity of the opcode glyph overlay.
    public let glyphBlend: Double
    /// Program-boundary (8×8-block edge) fade, gated on `8·bytePx`.
    public let programBoundaryBlend: Double
    /// Per-byte-boundary fade, close LOD only, drawn beneath the glyph ink.
    public let byteBoundaryBlend: Double

    /// Evaluate the readout from the same camera transform and LOD model a frame
    /// renders with — the blend factors come from `LODModel`'s tested methods, not a
    /// re-derivation of its thresholds.
    public init(camera: Camera, lod: LODModel) {
        let px = camera.bytePx
        self.bytePx = px
        self.macroBlend = lod.macroBlend(bytePx: px)
        self.microBlend = lod.microBlend(bytePx: px)
        self.glyphBlend = lod.glyphBlend(bytePx: px)
        self.programBoundaryBlend = lod.programBoundaryBlend(bytePx: px)
        self.byteBoundaryBlend = lod.byteBoundaryBlend(bytePx: px)
    }

    /// The readout for the frame currently being submitted, paired with whether it
    /// differs from `current` — the readout the HUD is already showing.
    ///
    /// The render path calls this exactly once per frame: the returned `readout`
    /// feeds the uniforms (`VizLayout.makeUniforms`) *and*, when `changed`, becomes
    /// the new observable HUD readout. Because it is a single evaluation, the HUD and
    /// the shader consume the same value and cannot drift. A camera-only zoom/pan —
    /// which never advances the epoch or touches the published HUD model, e.g. while
    /// paused — still reports `changed`, so the HUD refreshes; a steady camera reports
    /// `changed == false`, so the caller publishes nothing and cannot spin a SwiftUI
    /// update loop.
    public static func forFrame(camera: Camera, lod: LODModel, current: LODReadout)
        -> (readout: LODReadout, changed: Bool) {
        let readout = LODReadout(camera: camera, lod: lod)
        return (readout, readout != current)
    }
}
