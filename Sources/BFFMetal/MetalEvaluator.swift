import BFFOracle
import CBFFShared
import Foundation

#if canImport(Metal)
import Metal

/// macOS Metal host for the normative dynamic-scan evaluator
/// (`Shaders/BFFEvaluate.metal`).
///
/// Buffer ownership is per call and explicit: `evaluate` allocates fresh
/// `.storageModeShared` buffers, uploads the input tapes, dispatches, blocks on
/// command-buffer completion, and reads the finals back — the GPU mutates the
/// tape buffer in place and is the sole writer of the result buffer. Nothing is
/// pooled or reused; this is the correctness slice, not the performance one.
///
/// `init` refuses to hand out an evaluator unless the `bff_layout_probe` kernel
/// reports byte-for-byte the same struct layout Swift sees for the imported
/// `CBFFShared` structs (layer 3 of the contract in BFFShared.h).
public final class MetalBFFEvaluator {

    public enum EvaluatorError: Error, CustomStringConvertible {
        case noDevice
        case shaderSourceMissing
        case compileFailed(String)
        case kernelMissing(String)
        case layoutMismatch(String)
        case bufferAllocationFailed
        case gpuExecutionFailed(String)
        case invalidInput(String)

        public var description: String {
            switch self {
            case .noDevice:
                return "no Metal device available"
            case .shaderSourceMissing:
                return "BFFEvaluate.metal missing from the BFFMetal resource bundle"
            case .compileFailed(let detail):
                return "Metal shader compile failed: \(detail)"
            case .kernelMissing(let name):
                return "kernel '\(name)' not found in compiled library"
            case .layoutMismatch(let detail):
                return "GPU/host shared-struct layout mismatch: \(detail)"
            case .bufferAllocationFailed:
                return "MTLBuffer allocation failed"
            case .gpuExecutionFailed(let detail):
                return "GPU execution failed: \(detail)"
            case .invalidInput(let detail):
                return "invalid input: \(detail)"
            }
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let evaluatePipeline: MTLComputePipelineState

    public var deviceName: String { device.name }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EvaluatorError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw EvaluatorError.gpuExecutionFailed("could not create command queue")
        }
        self.device = device
        self.queue = queue

        guard let sourceURL = Bundle.module.url(forResource: "BFFEvaluate",
                                                withExtension: "metal") else {
            throw EvaluatorError.shaderSourceMissing
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw EvaluatorError.compileFailed("\(error)")
        }

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw EvaluatorError.kernelMissing(name)
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw EvaluatorError.compileFailed("pipeline '\(name)': \(error)")
            }
        }

        let probePipeline = try pipeline("bff_layout_probe")
        self.evaluatePipeline = try pipeline("bff_evaluate_pairs")

        try Self.verifyLayout(device: device, queue: queue, probe: probePipeline)
    }

    /// Run the layout probe and compare every word against the host layout.
    private static func verifyLayout(device: MTLDevice, queue: MTLCommandQueue,
                                     probe: MTLComputePipelineState) throws {
        let wordCount = BFFEvalLayout.probeWordCount
        let length = wordCount * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: length,
                                             options: .storageModeShared) else {
            throw EvaluatorError.bufferAllocationFailed
        }
        memset(buffer.contents(), 0xFF, length)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw EvaluatorError.gpuExecutionFailed("could not encode layout probe")
        }
        encoder.setComputePipelineState(probe)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw EvaluatorError.gpuExecutionFailed("layout probe: \(error)")
        }

        var gpuWords = [UInt32](repeating: 0, count: wordCount)
        for i in 0..<wordCount {
            gpuWords[i] = buffer.contents()
                .load(fromByteOffset: i * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
        let hostWords = BFFEvalLayout.hostProbeWords()
        if gpuWords != hostWords {
            let first = (0..<wordCount).first { gpuWords[$0] != hostWords[$0] }!
            throw EvaluatorError.layoutMismatch(
                "probe word \(first): gpu \(gpuWords[first]) vs host \(hostWords[first]) "
                + "(gpu \(gpuWords), host \(hostWords))")
        }
    }

    /// Evaluate one interaction per input tape on the GPU and return the final
    /// tapes plus the shared accounting, in input order.
    ///
    /// All tapes in one call share `variant` and `stepBudget` because
    /// `BFFEvalParams` is dispatch-wide (`EvaluatorFixturePlanner` groups mixed
    /// fixture files accordingly).
    public func evaluate(pairTapes: [[UInt8]],
                         variant: BFFVariant,
                         stepBudget: Int) throws -> [GPUPairOutcome] {
        guard !pairTapes.isEmpty else { return [] }
        for (i, tape) in pairTapes.enumerated() where tape.count != BFF.pairTapeSize {
            throw EvaluatorError.invalidInput(
                "tape \(i) is \(tape.count) bytes, expected \(BFF.pairTapeSize)")
        }
        guard stepBudget > 0, stepBudget <= BFFEvalLayout.maxStepBudget else {
            throw EvaluatorError.invalidInput(
                "step budget \(stepBudget) not representable in the shared uint32 field")
        }

        let count = pairTapes.count
        let resultStride = MemoryLayout<BFFEvalResult>.stride
        guard let tapeBuffer = device.makeBuffer(length: count * BFF.pairTapeSize,
                                                 options: .storageModeShared),
              let resultBuffer = device.makeBuffer(length: count * resultStride,
                                                   options: .storageModeShared) else {
            throw EvaluatorError.bufferAllocationFailed
        }

        for (i, tape) in pairTapes.enumerated() {
            tape.withUnsafeBytes { raw in
                tapeBuffer.contents()
                    .advanced(by: i * BFF.pairTapeSize)
                    .copyMemory(from: raw.baseAddress!, byteCount: BFF.pairTapeSize)
            }
        }
        memset(resultBuffer.contents(), 0, count * resultStride)

        var params = BFFEvalParams(pairCount: UInt32(count),
                                   stepBudget: UInt32(stepBudget),
                                   variant: BFFEvalLayout.variantCode(variant),
                                   reserved: 0)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw EvaluatorError.gpuExecutionFailed("could not encode evaluate dispatch")
        }
        encoder.setComputePipelineState(evaluatePipeline)
        encoder.setBuffer(tapeBuffer, offset: 0, index: 0)
        encoder.setBuffer(resultBuffer, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<BFFEvalParams>.stride, index: 2)

        // Fixed threadgroup width with a ceil-divided group count; the kernel's
        // `gid >= pairCount` guard absorbs the overhang, so no non-uniform
        // threadgroup support is assumed.
        let width = min(evaluatePipeline.maxTotalThreadsPerThreadgroup, 64)
        let groups = (count + width - 1) / width
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw EvaluatorError.gpuExecutionFailed("\(error)")
        }

        var outcomes: [GPUPairOutcome] = []
        outcomes.reserveCapacity(count)
        for i in 0..<count {
            let record = resultBuffer.contents()
                .load(fromByteOffset: i * resultStride, as: BFFEvalResult.self)
            let tapeStart = tapeBuffer.contents().advanced(by: i * BFF.pairTapeSize)
            let finalTape = [UInt8](UnsafeRawBufferPointer(start: tapeStart,
                                                           count: BFF.pairTapeSize))
            outcomes.append(GPUPairOutcome(finalTape: finalTape,
                                           steps: record.steps,
                                           noopSteps: record.noopSteps,
                                           copyWrites: record.copyWrites,
                                           loopOps: record.loopOps,
                                           halt: record.halt))
        }
        return outcomes
    }
}

/// The Metal host already exposes exactly the `PairEvaluator` signature, so the
/// GPU is a drop-in evaluator for `SoupRunner` (empty conformance).
extension MetalBFFEvaluator: PairEvaluator {}
#endif
