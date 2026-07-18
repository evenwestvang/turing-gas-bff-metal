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
                return "BFFEvaluate.metal not found in the app bundle or the BFFMetal resource bundle"
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

    /// GPU-side execution time of the LAST `evaluate` command buffer, in seconds, or
    /// `nil` if the hardware did not report usable timestamps for it.
    ///
    /// This is `MTLCommandBuffer.gpuEndTime - gpuStartTime`: the interval the command
    /// buffer was actually executing on the GPU. It is *command-buffer time*, honestly
    /// labeled — not a per-kernel or per-encoder breakdown, and not a CPU profile.
    /// `evaluate` sets it after `waitUntilCompleted`; it never influences the returned
    /// outcomes, so deterministic outputs are unaffected. One epoch dispatches exactly
    /// one command buffer, so a caller can read this immediately after `SoupRunner`
    /// runs an epoch to attribute that epoch's GPU time.
    public private(set) var lastGPUCommandBufferSeconds: Double?

    public var deviceName: String { device.name }

    /// The device and command queue this evaluator uses — exposed so a host can
    /// build ONE shared Metal context (device + queue) and hand the same queue to
    /// both the evaluator and a renderer (REQUIRED 1). Serial command encoding on
    /// one queue keeps ownership understandable and avoids hidden multi-queue work.
    public var metalDevice: MTLDevice { device }
    public var commandQueue: MTLCommandQueue { queue }

    /// Convenience: create a fresh system-default device and its own queue. Used by
    /// the headless CLIs and existing tests; the deterministic evaluate path is
    /// unchanged.
    public convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EvaluatorError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw EvaluatorError.gpuExecutionFailed("could not create command queue")
        }
        try self.init(device: device, queue: queue)
    }

    /// Designated init against an injected device and command queue, so the soup
    /// evaluator and the app renderer share one `MTLDevice` and one queue.
    public init(device: MTLDevice, queue: MTLCommandQueue) throws {
        self.device = device
        self.queue = queue

        guard let sourceURL = ShaderResourceLocator.url(forResource: "BFFEvaluate",
                                                        withExtension: "metal",
                                                        moduleBundle: .module) else {
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
        // The default path passes no clock, so `evaluateCore` takes no timing marks and
        // runs byte-for-byte as before (the profile it returns is discarded).
        try evaluateCore(pairTapes: pairTapes, variant: variant,
                         stepBudget: stepBudget, clock: nil).outcomes
    }

    /// Shared evaluate implementation. When `clock` is non-nil it records host-side
    /// substage timings into an `EvaluatorStageProfile`; when nil it takes no marks and
    /// the returned profile is all-nil. The GPU command-buffer timestamp is read and
    /// stored regardless (it is the existing honest GPU time), and is retained in the
    /// profile *separately* from the CPU submit+wait span — never subtracted from it.
    private func evaluateCore(pairTapes: [[UInt8]], variant: BFFVariant, stepBudget: Int,
                              clock: (() -> Double)?)
        throws -> (outcomes: [GPUPairOutcome], profile: EvaluatorStageProfile) {
        func mark() -> Double? { clock?() }

        guard !pairTapes.isEmpty else { return ([], EvaluatorStageProfile()) }
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

        // --- Buffer allocation ---
        let b0 = mark()
        guard let tapeBuffer = device.makeBuffer(length: count * BFF.pairTapeSize,
                                                 options: .storageModeShared),
              let resultBuffer = device.makeBuffer(length: count * resultStride,
                                                   options: .storageModeShared) else {
            throw EvaluatorError.bufferAllocationFailed
        }
        let b1 = mark()

        // --- Upload / marshalling ---
        for (i, tape) in pairTapes.enumerated() {
            tape.withUnsafeBytes { raw in
                tapeBuffer.contents()
                    .advanced(by: i * BFF.pairTapeSize)
                    .copyMemory(from: raw.baseAddress!, byteCount: BFF.pairTapeSize)
            }
        }
        memset(resultBuffer.contents(), 0, count * resultStride)
        let b2 = mark()

        // --- Command encoding ---
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
        let b3 = mark()

        // --- Submit + synchronous wait (CPU-observed) ---
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let b4 = mark()
        if let error = commandBuffer.error {
            throw EvaluatorError.gpuExecutionFailed("\(error)")
        }

        // Honest command-buffer GPU time. `gpuStartTime`/`gpuEndTime` are valid only
        // after completion; treat a non-positive or non-increasing interval as "no
        // usable timestamp" (nil) rather than reporting a bogus 0, so the benchmark
        // harness can fail clearly instead of silently trusting a fake number. This is
        // retained SEPARATELY from the submit+wait CPU span above; the two are never
        // combined (no wait-minus-GPU is ever computed).
        let gpuSpan = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        let gpuSeconds = (commandBuffer.gpuStartTime > 0 && gpuSpan > 0) ? gpuSpan : nil
        lastGPUCommandBufferSeconds = gpuSeconds

        // --- Readback / materialization ---
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
        let b5 = mark()

        func span(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return b - a
        }
        let profile = EvaluatorStageProfile(
            bufferAllocSeconds: span(b0, b1),
            uploadSeconds: span(b1, b2),
            encodeSeconds: span(b2, b3),
            submitWaitSeconds: span(b3, b4),
            readbackSeconds: span(b4, b5),
            gpuCommandBufferSeconds: gpuSeconds)
        return (outcomes, profile)
    }
}

/// The Metal host can decompose its own evaluate span into host substages, so it is a
/// `StageProfilingEvaluator`. This is opt-in: the runner only calls `evaluateProfiled`
/// when stage instrumentation is requested; the default `evaluate` path is unchanged.
extension MetalBFFEvaluator: StageProfilingEvaluator {
    public func evaluateProfiled(pairTapes: [[UInt8]], variant: BFFVariant,
                                 stepBudget: Int, clock: @escaping () -> Double)
        throws -> (outcomes: [GPUPairOutcome], profile: EvaluatorStageProfile) {
        try evaluateCore(pairTapes: pairTapes, variant: variant,
                         stepBudget: stepBudget, clock: clock)
    }
}

/// The Metal host already exposes exactly the `PairEvaluator` signature, so the
/// GPU is a drop-in evaluator for `SoupRunner` (empty conformance).
extension MetalBFFEvaluator: PairEvaluator {}
#endif
