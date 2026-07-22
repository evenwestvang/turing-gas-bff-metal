#if canImport(MetalKit)
import Foundation
import Metal
import MetalKit
import BFFMetal
import BFFOracle
import SoupScopeCore
import CSoupRender

/// MTKView delegate: drives one bounded epoch batch per frame (via `AppModel`),
/// then renders the resulting immutable snapshot. The CPU path allocates fresh
/// per-frame buffers from `RenderSnapshot`; the resident path acquires a generation
/// lease on a persistent GPU snapshot slot and releases it from the render command
/// buffer completion handler. Render command buffers are submitted on the context's
/// shared queue, serial with the evaluator's compute work.
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
        // Once a validation verdict has been reached, stop submitting new work so no
        // buffer is torn down while the pending exit waits on the last one.
        if appModel.validationFinished { return }

        // Opt-in per-frame host-stage timing: measure the frame wall and the Metal-only
        // spans (soup-buffer allocation/copy, metric-texture population/upload, render
        // command encoding after encoder creation + submit) here where they are
        // technically measurable, then fold them with the epoch-batch/snapshot spans
        // `stepFrame` measured. All reads are gated on the flag, so the default frame
        // path takes no clock and is unchanged.
        let timing = appModel.frameStageTimingEnabled
        let frameStart = timing ? AppMonotonicClock.nowSeconds() : 0
        var soupBufferSeconds: Double? = nil
        var metricTextureSeconds: Double? = nil
        var renderSubmitSeconds: Double? = nil

        let snapshot = (appModel.usesResidentRendering || appModel.usesEcologyRendering)
            ? nil : appModel.stepFrame()

        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = context.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        // Encoder creation happened above; by design that setup cost is outside this
        // span and remains in the explicit app-frame unclassified remainder.
        let encodeStart = timing ? AppMonotonicClock.nowSeconds() : 0
        if appModel.usesResidentRendering {
            let sourceEpoch = appModel.latestResidentSourceEpoch
            if let texture = appModel.residentVisualizationTexture {
                var uniforms = appModel.makeUniforms()
                let expectedByteCount = try? ResidentSnapshotLayout.checkedSoupByteCount(
                    programCount: Int(uniforms.programCount))
                if ResidentRenderDecision.requiresSnapshotLease(microBlend: uniforms.microBlend) {
                    let snapshotLease = appModel.acquireResidentSnapshot()
                    let decision = ResidentRenderDecision.decide(
                        expectedByteCount: expectedByteCount,
                        leaseByteCount: snapshotLease?.byteCount,
                        expectedOverviewWidth: texture.width,
                        expectedOverviewHeight: texture.height,
                        leaseOverviewWidth: snapshotLease?.overviewTexture.width,
                        leaseOverviewHeight: snapshotLease?.overviewTexture.height,
                        microBlend: uniforms.microBlend)
                    if decision.usesLeasedSnapshot, let snapshotLease {
                        encoder.setRenderPipelineState(context.residentRenderPipeline)
                        encoder.setFragmentBytes(&uniforms,
                                                 length: MemoryLayout<VizUniforms>.stride,
                                                 index: 0)
                        encoder.setFragmentBuffer(snapshotLease.buffer, offset: 0, index: 1)
                        encoder.setFragmentTexture(snapshotLease.overviewTexture, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        snapshotLease.releaseOnCommandBufferCompletion(commandBuffer)
                        appModel.noteResidentFrameSubmitted(sourceEpoch: snapshotLease.sourceEpoch)
                    } else {
                        snapshotLease?.release()
                        encoder.setRenderPipelineState(context.residentOverviewRenderPipeline)
                        encoder.setFragmentBytes(&uniforms,
                                                 length: MemoryLayout<VizUniforms>.stride,
                                                 index: 0)
                        encoder.setFragmentTexture(texture, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        appModel.noteResidentFrameSubmitted(sourceEpoch: sourceEpoch)
                    }
                } else {
                    encoder.setRenderPipelineState(context.residentOverviewRenderPipeline)
                    encoder.setFragmentBytes(&uniforms,
                                             length: MemoryLayout<VizUniforms>.stride,
                                             index: 0)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    appModel.noteResidentFrameSubmitted(sourceEpoch: sourceEpoch)
                }
            }
        } else if appModel.usesEcologyRendering {
            // Ecology renderer ownership contract:
            //
            // NEVER binds the producer's live mutable soup or its live overview
            // texture. Every frame acquires a published immutable soup+overview
            // snapshot lease — the SAME paired slot the producer published on
            // its blit command buffer's completion. Close LOD (microBlend > 0)
            // binds the lease's soup buffer + overview texture through the
            // resident render pipeline; far-only LOD (microBlend == 0) binds
            // only the lease's overview texture through the overview pipeline.
            // Both paths use the same lease and release it on THIS render
            // command buffer's completion, so the slot cannot be recycled
            // until the renderer is done with it.
            //
            // Before the first publication, or when acquire fails (ring busy /
            // no publication yet), the renderer binds NO producer resource and
            // draws nothing — the cleared neutral background is the unavailable
            // state. The displayed epoch/phase is taken from the lease's
            // `sourceEpoch` (see `noteEcologyFrameSubmitted`), so it always
            // corresponds to the resource actually rendered this frame. No
            // full-soup CPU readback, no CPU digest, no GPU wait on this
            // display thread.
            let expectedByteCount = EcologyTopology.soupByteCount
            let lease = appModel.acquireEcologySnapshot()
            if let lease = lease,
               lease.byteCount == expectedByteCount,
               lease.overviewTexture.width == EcologyTopology.width,
               lease.overviewTexture.height == EcologyTopology.height {
                var uniforms = appModel.makeUniforms()
                if ResidentRenderDecision.requiresSnapshotLease(microBlend: uniforms.microBlend) {
                    encoder.setRenderPipelineState(context.residentRenderPipeline)
                    encoder.setFragmentBytes(&uniforms,
                                             length: MemoryLayout<VizUniforms>.stride,
                                             index: 0)
                    encoder.setFragmentBuffer(lease.buffer, offset: 0, index: 1)
                    encoder.setFragmentTexture(lease.overviewTexture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                } else {
                    encoder.setRenderPipelineState(context.residentOverviewRenderPipeline)
                    encoder.setFragmentBytes(&uniforms,
                                             length: MemoryLayout<VizUniforms>.stride,
                                             index: 0)
                    encoder.setFragmentTexture(lease.overviewTexture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                lease.releaseOnCommandBufferCompletion(commandBuffer)
                appModel.noteEcologyFrameSubmitted(sourceEpoch: lease.sourceEpoch)
            } else {
                lease?.release()
                // Neutral background: no producer resource is bound. The
                // unavailable acquisition preserves the prior displayed
                // ecology source epoch/phase (the last valid lease
                // rendered) rather than reporting a fabricated epoch zero;
                // see `noteEcologyFrameUnavailable`/`noteEcologyDisplayUnavailable`.
                appModel.noteEcologyFrameUnavailable()
            }
        } else if let snapshot {
            let soupStart = timing ? AppMonotonicClock.nowSeconds() : 0
            let soupBuffer = makeSoupBuffer(snapshot)
            if timing { soupBufferSeconds = AppMonotonicClock.nowSeconds() - soupStart }

            let texStart = timing ? AppMonotonicClock.nowSeconds() : 0
            let metricTexture = makeMetricTexture(snapshot)
            if timing { metricTextureSeconds = AppMonotonicClock.nowSeconds() - texStart }
            if let soupBuffer, let metricTexture {
                var uniforms = appModel.makeUniforms()
                encoder.setRenderPipelineState(context.renderPipeline)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VizUniforms>.stride, index: 0)
                encoder.setFragmentBuffer(soupBuffer, offset: 0, index: 1)
                encoder.setFragmentTexture(metricTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        // With no snapshot the pass still clears to the background color.
        encoder.endEncoding()
        commandBuffer.present(drawable)

        // Validation success is counted only from an actually-completed submission,
        // so the run finishes after real render progress — never mid-flight.
        if appModel.validationActive {
            let appModel = self.appModel
            appModel.noteRenderSubmitted(commandBuffer)
            commandBuffer.addCompletedHandler { _ in
                Task { @MainActor in appModel.noteDrawCompleted() }
            }
        }
        commandBuffer.commit()

        if timing {
            // Render encode + submit span: from just after encoder construction through
            // commit, minus soup-buffer and metric-texture work already attributed to
            // their own stages. Encoder creation remains in the explicit app-frame
            // unclassified remainder.
            renderSubmitSeconds = AppMonotonicClock.nowSeconds() - encodeStart
                - (soupBufferSeconds ?? 0) - (metricTextureSeconds ?? 0)
            appModel.recordFrameStages(
                frameSeconds: AppMonotonicClock.nowSeconds() - frameStart,
                soupBufferSeconds: soupBufferSeconds,
                metricTextureSeconds: metricTextureSeconds,
                renderSubmitSeconds: renderSubmitSeconds)
        }
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
