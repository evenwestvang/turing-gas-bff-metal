import CSoupRender

/// Platform-independent view of the render uniform ABI (`SoupRenderShared.h`),
/// mirroring `BFFEvalLayout`. The host words are derived from Swift's
/// `MemoryLayout` of the C-imported `VizUniforms`; the renderer's `viz_layout_probe`
/// must report the identical words before any draw (defensive validation for the
/// new GPU structure). Tested on Linux against the documented literals.
public enum VizLayout {

    /// Words `viz_layout_probe` writes, in order:
    ///
    ///     [0] sizeof   [1] alignof
    ///     [2] viewportPxX [3] viewportPxY [4] originByteX [5] originByteY
    ///     [6] bytePx   [7] microBlend  [8] glyphBlend
    ///     [9] gridWidth [10] gridHeight [11] programCount [12] metricChannel [13] flags
    public static func hostProbeWords() -> [UInt32] {
        func word(_ value: Int?) -> UInt32 {
            guard let value, let narrowed = UInt32(exactly: value) else {
                fatalError("VizUniforms field offset unavailable — layout contract broken")
            }
            return narrowed
        }
        return [
            word(MemoryLayout<VizUniforms>.size),
            word(MemoryLayout<VizUniforms>.alignment),
            word(MemoryLayout<VizUniforms>.offset(of: \.viewportPxX)),
            word(MemoryLayout<VizUniforms>.offset(of: \.viewportPxY)),
            word(MemoryLayout<VizUniforms>.offset(of: \.originByteX)),
            word(MemoryLayout<VizUniforms>.offset(of: \.originByteY)),
            word(MemoryLayout<VizUniforms>.offset(of: \.bytePx)),
            word(MemoryLayout<VizUniforms>.offset(of: \.microBlend)),
            word(MemoryLayout<VizUniforms>.offset(of: \.glyphBlend)),
            word(MemoryLayout<VizUniforms>.offset(of: \.gridWidth)),
            word(MemoryLayout<VizUniforms>.offset(of: \.gridHeight)),
            word(MemoryLayout<VizUniforms>.offset(of: \.programCount)),
            word(MemoryLayout<VizUniforms>.offset(of: \.metricChannel)),
            word(MemoryLayout<VizUniforms>.offset(of: \.flags)),
        ]
    }

    /// Number of `uint32` words the probe writes.
    public static var probeWordCount: Int { 14 }

    /// Build the per-frame uniforms from the current transform and layout. The LOD
    /// blend factors are evaluated here (from the shared `LODModel`) so the shader
    /// receives the tested values rather than re-deriving thresholds.
    public static func makeUniforms(camera: Camera, grid: ProgramGrid, lod: LODModel,
                                    metricChannel: UInt32,
                                    viewPxWidth: Double, viewPxHeight: Double) -> VizUniforms {
        VizUniforms(
            viewportPxX: Float(viewPxWidth),
            viewportPxY: Float(viewPxHeight),
            originByteX: Float(camera.originByteX),
            originByteY: Float(camera.originByteY),
            bytePx: Float(camera.bytePx),
            microBlend: Float(lod.microBlend(bytePx: camera.bytePx)),
            glyphBlend: Float(lod.glyphBlend(bytePx: camera.bytePx)),
            gridWidth: UInt32(grid.width),
            gridHeight: UInt32(grid.height),
            programCount: UInt32(grid.programCount),
            metricChannel: metricChannel,
            flags: 0)
    }
}
