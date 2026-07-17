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

    /// Evaluate the readout from the same camera transform and LOD model a frame
    /// renders with — the blend factors come from `LODModel`'s tested methods, not a
    /// re-derivation of its thresholds.
    public init(camera: Camera, lod: LODModel) {
        let px = camera.bytePx
        self.bytePx = px
        self.macroBlend = lod.macroBlend(bytePx: px)
        self.microBlend = lod.microBlend(bytePx: px)
        self.glyphBlend = lod.glyphBlend(bytePx: px)
    }
}
