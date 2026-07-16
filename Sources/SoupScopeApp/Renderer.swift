#if canImport(MetalKit)
import Foundation
import Metal
import MetalKit
import SoupScopeCore
import CSoupRender

/// MTKView delegate: drives one bounded epoch batch per frame (via `AppModel`),
/// then renders the resulting immutable snapshot. Every GPU resource it touches is
/// allocated fresh per frame from the snapshot, so there is no CPU/GPU race on the
/// evolving soup — the render command buffer retains its buffers until completion,
/// and the next frame builds new ones. Render command buffers are submitted on the
/// context's shared queue, serial with the evaluator's compute work.
///
/// The delegate methods are left non-isolated (so the conformance holds regardless
/// of how the SDK annotates `MTKViewDelegate`'s isolation) and hop to the main
/// actor via `assumeIsolated` — MTKView always calls them on the main thread — to
/// drive the main-actor `AppModel`.
final class Renderer: NSObject, MTKViewDelegate {
    private let appModel: AppModel
    private let context: SharedMetalContext

    init(appModel: AppModel, context: SharedMetalContext) {
        self.appModel = appModel
        self.context = context
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            appModel.updateDrawableSize(width: Double(size.width),
                                        height: Double(size.height))
        }
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            renderFrame(in: view)
        }
    }

    @MainActor
    private func renderFrame(in view: MTKView) {
        let snapshot = appModel.stepFrame()

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        if let snapshot, let soupBuffer = makeSoupBuffer(snapshot),
           let metricTexture = makeMetricTexture(snapshot) {
            var uniforms = appModel.makeUniforms()
            encoder.setRenderPipelineState(context.renderPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VizUniforms>.stride, index: 0)
            encoder.setFragmentBuffer(soupBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(metricTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        // With no snapshot the pass still clears to the background color.
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Fresh shared buffer holding the snapshot's soup bytes (stable-ID order).
    @MainActor
    private func makeSoupBuffer(_ snapshot: RenderSnapshot) -> MTLBuffer? {
        let byteCount = snapshot.programBytes.count
        guard byteCount > 0 else { return nil }
        return snapshot.programBytes.withUnsafeBytes { raw in
            context.device.makeBuffer(bytes: raw.baseAddress!, length: byteCount,
                                      options: .storageModeShared)
        }
    }

    /// Fresh aggregate metric texture: one texel per program cell, R = normalized
    /// activity, G = normalized entropy (fixed bounds — replay-stable). Padded
    /// cells stay zero and are never sampled (the shader guards `programCount`).
    @MainActor
    private func makeMetricTexture(_ snapshot: RenderSnapshot) -> MTLTexture? {
        let grid = appModel.grid
        let w = grid.width, h = grid.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }

        let norm = appModel.normalization
        var texels = [Float](repeating: 0, count: w * h * 4)
        for id in 0 ..< snapshot.programCount {
            let a = norm.normalizedActivity(snapshot.activity[id])
            let e = norm.normalizedEntropy(snapshot.entropy[id])
            let cell = grid.cell(of: id)
            let base = (cell.row * w + cell.col) * 4
            texels[base] = Float(a)
            texels[base + 1] = Float(e)
            texels[base + 2] = 0
            texels[base + 3] = 1
        }
        texels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: w * 4 * MemoryLayout<Float>.stride)
        }
        return texture
    }
}
#endif
