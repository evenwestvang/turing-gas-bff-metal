#if canImport(MetalKit)
import Foundation
import Metal
import MetalKit
import BFFMetal
import SoupScopeCore
import CSoupRender

/// The single explicit owner of the shared GPU context (REQUIRED 1): one
/// `MTLDevice`, one `MTLCommandQueue`, the immutable soup evaluator, and the
/// immutable render pipeline. The soup evaluator and the renderer use the **same**
/// device and the **same** queue — all command encoding is serial on that one
/// queue, so there is no hidden multi-queue work and hazard tracking orders the
/// render pass against compute automatically.
final class SharedMetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let evaluator: MetalBFFEvaluator
    let renderPipeline: MTLRenderPipelineState

    var deviceName: String { device.name }

    enum ContextError: Error, CustomStringConvertible {
        case noDevice
        case queueCreationFailed
        case shaderSourceMissing
        case compileFailed(String)
        case functionMissing(String)
        case pipelineFailed(String)
        case vizLayoutMismatch(String)

        var description: String {
            switch self {
            case .noDevice: return "no Metal device available"
            case .queueCreationFailed: return "could not create the shared command queue"
            case .shaderSourceMissing: return "SoupRender.metal not found in the app bundle or the SoupScope resource bundle"
            case .compileFailed(let d): return "render shader compile failed: \(d)"
            case .functionMissing(let n): return "render function '\(n)' not found"
            case .pipelineFailed(let d): return "render pipeline creation failed: \(d)"
            case .vizLayoutMismatch(let d): return "VizUniforms GPU/host layout mismatch: \(d)"
            }
        }
    }

    init(colorPixelFormat: MTLPixelFormat) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ContextError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw ContextError.queueCreationFailed
        }
        self.device = device
        self.queue = queue

        // The evaluator shares this exact device and queue.
        self.evaluator = try MetalBFFEvaluator(device: device, queue: queue)

        guard let url = ShaderResourceLocator.url(forResource: "SoupRender",
                                                  withExtension: "metal",
                                                  moduleBundle: .module) else {
            throw ContextError.shaderSourceMissing
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw ContextError.compileFailed("\(error)")
        }
        guard let vertexFn = library.makeFunction(name: "soup_vertex") else {
            throw ContextError.functionMissing("soup_vertex")
        }
        guard let fragmentFn = library.makeFunction(name: "soup_fragment") else {
            throw ContextError.functionMissing("soup_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        do {
            self.renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw ContextError.pipelineFailed("\(error)")
        }

        try Self.verifyVizLayout(device: device, queue: queue, library: library)
    }

    /// Defensive validation of the new GPU structure: run `viz_layout_probe` and
    /// require every reported sizeof/alignof/offset to equal the host layout before
    /// any frame is drawn.
    private static func verifyVizLayout(device: MTLDevice, queue: MTLCommandQueue,
                                        library: MTLLibrary) throws {
        guard let probeFn = library.makeFunction(name: "viz_layout_probe") else {
            throw ContextError.functionMissing("viz_layout_probe")
        }
        let probe: MTLComputePipelineState
        do {
            probe = try device.makeComputePipelineState(function: probeFn)
        } catch {
            throw ContextError.pipelineFailed("viz_layout_probe: \(error)")
        }

        let wordCount = VizLayout.probeWordCount
        let length = wordCount * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw ContextError.vizLayoutMismatch("probe buffer allocation failed")
        }
        memset(buffer.contents(), 0xFF, length)

        guard let cb = queue.makeCommandBuffer(),
              let encoder = cb.makeComputeCommandEncoder() else {
            throw ContextError.vizLayoutMismatch("could not encode probe")
        }
        encoder.setComputePipelineState(probe)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw ContextError.vizLayoutMismatch("probe execution: \(error)")
        }

        var gpu = [UInt32](repeating: 0, count: wordCount)
        for i in 0..<wordCount {
            gpu[i] = buffer.contents().load(fromByteOffset: i * MemoryLayout<UInt32>.stride,
                                            as: UInt32.self)
        }
        let host = VizLayout.hostProbeWords()
        if gpu != host {
            let first = (0..<wordCount).first { gpu[$0] != host[$0] } ?? 0
            throw ContextError.vizLayoutMismatch(
                "probe word \(first): gpu \(gpu[first]) vs host \(host[first]) "
                + "(gpu \(gpu), host \(host))")
        }
    }
}
#endif
