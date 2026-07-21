import BFFOracle
import BFFMetal
import CBFFEcologyShared
import Foundation

#if canImport(Metal)
import Metal
#endif

/// Configuration for the Metal ecology epoch runner.
///
/// This is a separate engine from `ResidentEpochConfig`; it ports the ecology v1
/// contract (fixed 512×256 torus, edge-color scheduler, ecology-counter-pcg RNG)
/// to Metal with byte-exact CPU parity.
///
/// The Metal contract pins `stepBudget` to `1...8192`. The CPU oracle retains its
/// own (already-accepted) budget handling; this constraint is a Metal-runner
/// limitation documented in the thread and surfaced as a clear rejection (never
/// a silent clamp) when loading a checkpoint with `stepBudget > 8192`.
public struct EcologyMetalEpochConfig: Equatable, Sendable {
    public var seed: UInt32
    public var stepBudget: Int
    public var mutationP32: UInt32
    public var variant: BFFVariant
    public var bracketMode: BracketMode
    /// Test-only: capture per-pair input/final tapes and results. Production
    /// CLI never sets this. When enabled, 8 MiB input + 8 MiB final + 1.5 MiB
    /// result buffers are allocated (bounded, explicitly test-only).
    public var capturePairTapes: Bool

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case stepBudgetOutOfRange(Int)
        case stepBudgetExceedsMetalContract(Int)

        public var description: String {
            switch self {
            case .stepBudgetOutOfRange(let n):
                return "step budget \(n) must be in 1...\(BFFEvalLayout.maxStepBudget)"
            case .stepBudgetExceedsMetalContract(let n):
                return "Metal ecology contract pins step budget to 1...8192, got \(n)"
            }
        }
    }

    public init(seed: UInt32,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                bracketMode: BracketMode = .dynamicScan,
                capturePairTapes: Bool = false) throws {
        guard stepBudget > 0, stepBudget <= BFFEvalLayout.maxStepBudget else {
            throw ConfigError.stepBudgetOutOfRange(stepBudget)
        }
        // Metal contract: 1...8192 only. Overflow-safe at this bound.
        guard stepBudget <= 8192 else {
            throw ConfigError.stepBudgetExceedsMetalContract(stepBudget)
        }
        self.seed = seed
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.bracketMode = bracketMode
        self.capturePairTapes = capturePairTapes
    }

    /// Build from an `EcologyConfig` (e.g. from a checkpoint), applying the
    /// Metal contract constraint. Rejects `stepBudget > 8192` clearly.
    public init(fromEcologyConfig config: EcologyConfig,
                capturePairTapes: Bool = false) throws {
        try self.init(seed: config.seed,
                      stepBudget: config.stepBudget,
                      mutationP32: config.mutationP32,
                      variant: config.variant,
                      bracketMode: config.bracketMode,
                      capturePairTapes: capturePairTapes)
    }

    public var topologyID: String { EcologyConfig.topologyID }
    public var schedulerID: String { EcologyConfig.schedulerID }
    public var rngContractID: String { EcologyConfig.rngContractID }
    public var evaluatorContractID: String {
        "bff-evaluator-v1:\(variant.rawValue):\(bracketMode.rawValue)"
    }
}

/// Per-epoch instrumentation. Counter, readback/digest, and optional test-capture
/// costs are reported separately.
public struct EcologyMetalEpochInstrumentation: Equatable, Sendable, Codable {
    public var epochWallSeconds: Double
    public var mutateKernelSeconds: Double?
    public var evalKernelSeconds: Double?
    public var counterReadbackSeconds: Double
    public var soupReadbackSeconds: Double?
    public var digestSeconds: Double?
    public var captureReadbackSeconds: Double?
    public var uploadBytes: Int
    public var readbackBytes: Int
    public var counterBytes: Int
    public var captureBytes: Int
}

public struct EcologyMetalEpochReport: Sendable {
    public var counters: EcologyEpochCounters
    public var digest: UInt64?
    public var capturedPairResults: [BFFEcologyMetalPairResult]
    public var capturedInputTapes: [[UInt8]]
    public var capturedFinalTapes: [[UInt8]]
    public var instrumentation: EcologyMetalEpochInstrumentation
}

/// Test-only per-pair result, mirroring `InteractionResult` field semantics.
public struct BFFEcologyMetalPairResult: Equatable, Sendable {
    public var steps: Int
    public var noopSteps: Int
    public var copyWrites: Int
    public var loopOps: Int
    public var remapEvents: Int
    public var halt: HaltReason

    public init(steps: Int, noopSteps: Int, copyWrites: Int,
                loopOps: Int, remapEvents: Int, halt: HaltReason) {
        self.steps = steps
        self.noopSteps = noopSteps
        self.copyWrites = copyWrites
        self.loopOps = loopOps
        self.remapEvents = remapEvents
        self.halt = halt
    }

    public init(fromCStruct s: BFFEcologyPairResult) {
        self.steps = Int(s.steps)
        self.noopSteps = Int(s.noopSteps)
        self.copyWrites = Int(s.copyWrites)
        self.loopOps = Int(s.loopOps)
        self.remapEvents = Int(s.remapEvents)
        self.halt = HaltReason(rawValue: UInt8(s.halt)) ?? .budget
    }
}

/// Layout probe words that `bff_ecology_layout_probe` writes, in order.
/// These must match Swift's `MemoryLayout` of the imported C structs.
///
/// Declared outside the Metal gate because it uses only `MemoryLayout` of the
/// imported C structs — no Metal dependency. This lets the host-side ABI
/// verification test run on all platforms (including Linux CI).
public enum BFFEcologyLayoutProbe {
    public static let wordCount = 18

    public static func hostProbeWords() -> [UInt32] {
        func word(_ value: Int?) -> UInt32 {
            guard let value, let narrowed = UInt32(exactly: value) else {
                fatalError("shared struct field offset unavailable — layout contract broken")
            }
            return narrowed
        }
        return [
            word(MemoryLayout<BFFEcologyEpochParams>.size),
            word(MemoryLayout<BFFEcologyEpochParams>.alignment),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.seed)),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.epoch)),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.stepBudget)),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.mutationP32)),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.variant)),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.bracketMode)),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.capturePairTapes)),
            word(MemoryLayout<BFFEcologyEpochParams>.offset(of: \.reserved0)),
            word(MemoryLayout<BFFEcologyPairResult>.size),
            word(MemoryLayout<BFFEcologyPairResult>.alignment),
            word(MemoryLayout<BFFEcologyPairResult>.offset(of: \.steps)),
            word(MemoryLayout<BFFEcologyPairResult>.offset(of: \.noopSteps)),
            word(MemoryLayout<BFFEcologyPairResult>.offset(of: \.copyWrites)),
            word(MemoryLayout<BFFEcologyPairResult>.offset(of: \.loopOps)),
            word(MemoryLayout<BFFEcologyPairResult>.offset(of: \.remapEvents)),
            word(MemoryLayout<BFFEcologyPairResult>.offset(of: \.halt)),
        ]
    }
}

#if canImport(Metal)

/// Experimental GPU-resident ecology epoch runner.
///
/// This is a separate engine from `ResidentMetalEpochRunner`. It ports the
/// ecology v1 contract to Metal with byte-exact CPU parity against
/// `EcologyOracleRunner`.
public final class EcologyMetalEpochRunner {
    public enum RunnerError: Error, CustomStringConvertible {
        case noDevice
        case commandQueueUnavailable
        case shaderSourceMissing
        case compileFailed(String)
        case kernelMissing(String)
        case bufferAllocationFailed(String)
        case commandEncodingFailed(String)
        case gpuExecutionFailed(String)
        case layoutProbeMismatch(expected: UInt32, actual: UInt32, index: Int)
        case epochOutOfRange(UInt64)
        case unexpectedHalt(UInt32)
        case checkpointStepBudgetExceedsMetalContract(Int)
        case checkpointEpochOutOfRange(UInt64)

        public var description: String {
            switch self {
            case .noDevice: return "no Metal device available"
            case .commandQueueUnavailable: return "could not create Metal command queue"
            case .shaderSourceMissing: return "BFFEcologyEpoch.metal not found"
            case .compileFailed(let detail): return "ecology shader compile failed: \(detail)"
            case .kernelMissing(let name): return "ecology kernel '\(name)' not found"
            case .bufferAllocationFailed(let detail): return "buffer allocation failed: \(detail)"
            case .commandEncodingFailed(let detail): return "command encoding failed: \(detail)"
            case .gpuExecutionFailed(let detail): return "GPU execution failed: \(detail)"
            case .layoutProbeMismatch(let expected, let actual, let index):
                return "layout probe mismatch at word \(index): expected \(expected), got \(actual)"
            case .epochOutOfRange(let e):
                return "epoch \(e) exceeds ecology UInt32 RNG range"
            case .unexpectedHalt(let count):
                return "GPU produced \(count) unknown halt values — must be zero"
            case .checkpointStepBudgetExceedsMetalContract(let n):
                return "checkpoint stepBudget \(n) exceeds Metal contract (1...8192)"
            case .checkpointEpochOutOfRange(let e):
                return "checkpoint epoch \(e) exceeds ecology UInt32 RNG range"
            }
        }
    }

    public let config: EcologyMetalEpochConfig
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public private(set) var epoch: UInt64 = 0
    public private(set) var lastEpochCounters: EcologyEpochCounters?

    /// Snapshot of the soup buffer (8 MiB readback). Used by the CLI for
    /// header/final digest emission and checkpoint save.
    public var soupSnapshot: [UInt8] {
        [UInt8](UnsafeRawBufferPointer(start: soupBuffer.contents(),
                                        count: soupByteCount))
    }

    // Pipelines
    private let mutatePipeline: MTLComputePipelineState
    private let evalPipeline: MTLComputePipelineState
    private let layoutProbePipeline: MTLComputePipelineState
    private let rngProbePipeline: MTLComputePipelineState
    private let pairProbePipeline: MTLComputePipelineState

    // Buffers
    private let soupBuffer: MTLBuffer
    private let countersBuffer: MTLBuffer
    private let pairResultBuffer: MTLBuffer
    private let inputCaptureBuffer: MTLBuffer
    private let finalCaptureBuffer: MTLBuffer

    // Sizes
    private let soupByteCount = EcologyTopology.soupByteCount
    private let counterByteCount = Int(BFF_ECO_COUNTER_WORD_COUNT) * MemoryLayout<UInt32>.stride
    private let pairResultByteCount: Int
    private let pairTapeCaptureBytes: Int

    public var deviceName: String { device.name }

    public convenience init(config: EcologyMetalEpochConfig) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RunnerError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RunnerError.commandQueueUnavailable
        }
        try self.init(config: config, device: device, commandQueue: queue)
    }

    public init(config: EcologyMetalEpochConfig,
                device: MTLDevice,
                commandQueue: MTLCommandQueue) throws {
        self.config = config
        self.device = device
        self.commandQueue = commandQueue

        // Load and compile shader
        guard let sourceURL = ShaderResourceLocator.url(
            forResource: "BFFEcologyEpoch",
            withExtension: "metal",
            moduleBundle: .module) else {
            throw RunnerError.shaderSourceMissing
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw RunnerError.compileFailed("\(error)")
        }

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw RunnerError.kernelMissing(name)
            }
            do { return try device.makeComputePipelineState(function: fn) }
            catch { throw RunnerError.compileFailed("pipeline \(name): \(error)") }
        }

        self.mutatePipeline = try pipeline("bff_ecology_mutate")
        self.evalPipeline = try pipeline("bff_ecology_eval_scatter")
        self.layoutProbePipeline = try pipeline("bff_ecology_layout_probe")
        self.rngProbePipeline = try pipeline("bff_ecology_rng_probe")
        self.pairProbePipeline = try pipeline("bff_ecology_pair_probe")

        // Allocate buffers
        let captureOn = config.capturePairTapes
        self.pairResultByteCount = captureOn
            ? EcologyTopology.pairCount * MemoryLayout<BFFEcologyPairResult>.stride
            : 1
        self.pairTapeCaptureBytes = captureOn
            ? EcologyTopology.pairCount * BFF.pairTapeSize
            : 1

        func buffer(length: Int, label: String) throws -> MTLBuffer {
            let actualLength = max(1, length)
            guard let b = device.makeBuffer(length: actualLength,
                                            options: .storageModeShared) else {
                throw RunnerError.bufferAllocationFailed(label)
            }
            b.label = label
            return b
        }

        self.soupBuffer = try buffer(length: soupByteCount, label: "ecology.soup")
        self.countersBuffer = try buffer(length: counterByteCount, label: "ecology.counters")
        self.pairResultBuffer = try buffer(length: pairResultByteCount, label: "ecology.pairResults")
        self.inputCaptureBuffer = try buffer(length: pairTapeCaptureBytes, label: "ecology.inputCapture")
        self.finalCaptureBuffer = try buffer(length: pairTapeCaptureBytes, label: "ecology.finalCapture")

        // Verify layout probe
        try verifyLayoutProbe()

        // Upload initial soup
        let initialSoup = EcologyRandom.initialSoup(seed: config.seed)
        initialSoup.withUnsafeBytes { raw in
            soupBuffer.contents().copyMemory(from: raw.baseAddress!,
                                             byteCount: initialSoup.count)
        }
    }

    /// Initialize from a checkpoint (cross-load from CPU CLI).
    public convenience init(checkpoint: EcologyCheckpoint,
                            capturePairTapes: Bool = false,
                            device: MTLDevice? = nil,
                            commandQueue: MTLCommandQueue? = nil) throws {
        // Validate checkpoint epoch before anything else
        guard checkpoint.epoch <= UInt64(UInt32.max) else {
            throw RunnerError.checkpointEpochOutOfRange(checkpoint.epoch)
        }
        let ecoConfig = try checkpoint.config()
        // Apply Metal contract: reject stepBudget > 8192 clearly, never clamp
        let metalConfig: EcologyMetalEpochConfig
        do {
            metalConfig = try EcologyMetalEpochConfig(
                fromEcologyConfig: ecoConfig,
                capturePairTapes: capturePairTapes)
        } catch EcologyMetalEpochConfig.ConfigError.stepBudgetExceedsMetalContract(let n) {
            throw RunnerError.checkpointStepBudgetExceedsMetalContract(n)
        }

        let dev = device ?? MTLCreateSystemDefaultDevice()
        guard let dev else { throw RunnerError.noDevice }
        let queue = commandQueue ?? dev.makeCommandQueue()
        guard let queue else { throw RunnerError.commandQueueUnavailable }

        try self.init(config: metalConfig, device: dev, commandQueue: queue)

        // Load soup from checkpoint
        let soup = try checkpoint.soupBytes()
        soup.withUnsafeBytes { raw in
            self.soupBuffer.contents().copyMemory(from: raw.baseAddress!,
                                                   byteCount: soup.count)
        }
        self.epoch = checkpoint.epoch
        self.lastEpochCounters = checkpoint.lastEpochCounters
    }

    // MARK: - Layout probe

    private func verifyLayoutProbe() throws {
        guard let probeBuffer = device.makeBuffer(
            length: BFFEcologyLayoutProbe.wordCount * MemoryLayout<UInt32>.stride,
            options: .storageModeShared) else {
            throw RunnerError.bufferAllocationFailed("ecology.layoutProbe")
        }
        probeBuffer.label = "ecology.layoutProbe"

        guard let cb = commandQueue.makeCommandBuffer() else {
            throw RunnerError.commandEncodingFailed("layout probe command buffer")
        }
        guard let enc = cb.makeComputeCommandEncoder() else {
            throw RunnerError.commandEncodingFailed("layout probe encoder")
        }
        enc.setComputePipelineState(layoutProbePipeline)
        enc.setBuffer(probeBuffer, offset: 0, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw RunnerError.gpuExecutionFailed("layout probe: \(error)")
        }

        let expected = BFFEcologyLayoutProbe.hostProbeWords()
        let ptr = probeBuffer.contents().bindMemory(to: UInt32.self,
                                                     capacity: BFFEcologyLayoutProbe.wordCount)
        for i in 0..<BFFEcologyLayoutProbe.wordCount {
            let actual = ptr[i]
            if actual != expected[i] {
                throw RunnerError.layoutProbeMismatch(expected: expected[i],
                                                      actual: actual,
                                                      index: i)
            }
        }
    }

    // MARK: - Epoch execution

    @discardableResult
    public func runEpoch() throws -> EcologyMetalEpochReport {
        // epochOutOfRange check — same as oracle
        guard epoch <= UInt64(UInt32.max) else {
            throw RunnerError.epochOutOfRange(epoch)
        }
        let e = UInt32(epoch)
        let phase = EcologyMatchingPhase(epoch: e)

        let epochStart = ResidentClock.now()
        var readbackBytes = 0
        let counterBytes = counterByteCount
        var captureBytes = 0

        // Build params
        var params = BFFEcologyEpochParams(
            seed: config.seed,
            epoch: e,
            stepBudget: UInt32(config.stepBudget),
            mutationP32: config.mutationP32,
            variant: BFFEcologyEvalLayout.variantCode(config.variant),
            bracketMode: config.bracketMode == .dynamicScan
                ? UInt32(BFF_ECO_BRACKET_DYNAMIC_SCAN)
                : UInt32(BFF_ECO_BRACKET_JUMP_TABLE),
            capturePairTapes: config.capturePairTapes ? 1 : 0,
            reserved0: 0
        )

        // --- Mutate kernel ---
        let mutateTiming = try encodeTimed(name: "mutate", pipeline: mutatePipeline) { cb in
            // Zero counters
            guard let blit = cb.makeBlitCommandEncoder() else {
                throw RunnerError.commandEncodingFailed("mutate counter fill")
            }
            blit.fill(buffer: self.countersBuffer,
                      range: 0..<self.counterByteCount, value: 0)
            blit.endEncoding()
        } encode: { enc in
            enc.setComputePipelineState(mutatePipeline)
            enc.setBuffer(soupBuffer, offset: 0, index: 0)
            enc.setBuffer(countersBuffer, offset: 0, index: 1)
            enc.setBytes(&params, length: MemoryLayout<BFFEcologyEpochParams>.stride, index: 2)
            dispatchThreads(count: soupByteCount, pipeline: mutatePipeline, encoder: enc)
        }

        // --- Eval scatter kernel ---
        let evalTiming = try encodeTimed(name: "eval-scatter", pipeline: evalPipeline) { enc in
            enc.setComputePipelineState(evalPipeline)
            enc.setBuffer(soupBuffer, offset: 0, index: 0)
            enc.setBuffer(countersBuffer, offset: 0, index: 1)
            enc.setBytes(&params, length: MemoryLayout<BFFEcologyEpochParams>.stride, index: 2)
            enc.setBuffer(pairResultBuffer, offset: 0, index: 3)
            enc.setBuffer(inputCaptureBuffer, offset: 0, index: 4)
            enc.setBuffer(finalCaptureBuffer, offset: 0, index: 5)
            dispatchThreads(count: EcologyTopology.pairCount,
                            pipeline: evalPipeline, encoder: enc)
        }

        // --- Readback counters ---
        let counterReadbackStart = ResidentClock.now()
        let counterWords = readCounterWords()
        let counterReadbackSeconds = ResidentClock.now() - counterReadbackStart
        readbackBytes += counterByteCount

        // Assert haltUnknown == 0
        let haltUnknown = counterWords[Int(BFF_ECO_COUNTER_HALT_UNKNOWN)]
        if haltUnknown != 0 {
            throw RunnerError.unexpectedHalt(haltUnknown)
        }

        // Build EcologyEpochCounters
        let mutationCount = Int(counterWords[Int(BFF_ECO_COUNTER_MUTATION_COUNT)])
        let totalRawSteps = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_RAW_STEPS)])
        let totalNoopSteps = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_NOOP_STEPS)])
        let totalLoopOps = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_LOOP_OPS)])
        let totalCopyWrites = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_COPY_WRITES)])
        let totalRemapEvents = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_REMAP_EVENTS)])
        let haltBudget = Int(counterWords[Int(BFF_ECO_COUNTER_HALT_BUDGET)])
        let haltPCOut = Int(counterWords[Int(BFF_ECO_COUNTER_HALT_PC_OUT)])
        let haltUnmatched = Int(counterWords[Int(BFF_ECO_COUNTER_HALT_UNMATCHED)])

        // Digest: CPU readback + host FNV-1a
        let soupReadbackStart = ResidentClock.now()
        let soupCopy = readSoupCheckpoint()
        let soupReadbackSeconds = ResidentClock.now() - soupReadbackStart
        readbackBytes += soupByteCount

        let digestStart = ResidentClock.now()
        let digest = EcologyDigest.digest(soupCopy)
        let digestSeconds = ResidentClock.now() - digestStart

        let counters = EcologyEpochCounters(
            epoch: e,
            phase: phase,
            interactions: EcologyTopology.pairCount,
            mutationCount: mutationCount,
            totalRawSteps: totalRawSteps,
            totalNoopSteps: totalNoopSteps,
            totalCommandSteps: totalRawSteps - totalNoopSteps,
            totalLoopOps: totalLoopOps,
            totalCopyWrites: totalCopyWrites,
            totalRemapEvents: totalRemapEvents,
            haltBudget: haltBudget,
            haltPCOut: haltPCOut,
            haltUnmatched: haltUnmatched,
            writeSites: EcologyTopology.siteCount,
            writeConflicts: 0,
            digest: digest
        )

        // Capture readback (test-only)
        var capturedPairResults: [BFFEcologyMetalPairResult] = []
        var capturedInputTapes: [[UInt8]] = []
        var capturedFinalTapes: [[UInt8]] = []
        var captureReadbackSeconds: Double? = nil

        if config.capturePairTapes {
            let captureStart = ResidentClock.now()
            capturedPairResults = readPairResults()
            capturedInputTapes = readPairTapes(from: inputCaptureBuffer)
            capturedFinalTapes = readPairTapes(from: finalCaptureBuffer)
            captureReadbackSeconds = ResidentClock.now() - captureStart
            captureBytes = pairResultByteCount + 2 * pairTapeCaptureBytes
            readbackBytes += captureBytes
        }

        self.lastEpochCounters = counters
        epoch += 1
        let wall = ResidentClock.now() - epochStart

        let instr = EcologyMetalEpochInstrumentation(
            epochWallSeconds: wall,
            mutateKernelSeconds: mutateTiming.gpuSeconds ?? mutateTiming.hostSeconds,
            evalKernelSeconds: evalTiming.gpuSeconds ?? evalTiming.hostSeconds,
            counterReadbackSeconds: counterReadbackSeconds,
            soupReadbackSeconds: soupReadbackSeconds,
            digestSeconds: digestSeconds,
            captureReadbackSeconds: captureReadbackSeconds,
            uploadBytes: 0,
            readbackBytes: readbackBytes,
            counterBytes: counterBytes,
            captureBytes: captureBytes
        )

        return EcologyMetalEpochReport(
            counters: counters,
            digest: digest,
            capturedPairResults: capturedPairResults,
            capturedInputTapes: capturedInputTapes,
            capturedFinalTapes: capturedFinalTapes,
            instrumentation: instr
        )
    }

    // MARK: - Test-only probe dispatch

    /// Run the RNG probe kernel for test-only boundary vector verification.
    public func runRNGProbe(inputs: [(seed: UInt32, purpose: UInt32,
                                       epoch: UInt32, element: UInt32)]) throws -> [UInt32] {
        let count = inputs.count
        let inputBytes = count * 4 * MemoryLayout<UInt32>.stride
        let outputBytes = count * MemoryLayout<UInt32>.stride

        guard let inputBuf = device.makeBuffer(length: max(1, inputBytes),
                                                options: .storageModeShared),
              let outputBuf = device.makeBuffer(length: max(1, outputBytes),
                                                 options: .storageModeShared) else {
            throw RunnerError.bufferAllocationFailed("rng probe buffers")
        }

        let inputPtr = inputBuf.contents().bindMemory(to: UInt32.self, capacity: count * 4)
        for (i, quad) in inputs.enumerated() {
            inputPtr[i * 4] = quad.seed
            inputPtr[i * 4 + 1] = quad.purpose
            inputPtr[i * 4 + 2] = quad.epoch
            inputPtr[i * 4 + 3] = quad.element
        }

        var countWord = UInt32(count)
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw RunnerError.commandEncodingFailed("rng probe command buffer")
        }
        guard let enc = cb.makeComputeCommandEncoder() else {
            throw RunnerError.commandEncodingFailed("rng probe encoder")
        }
        enc.setComputePipelineState(rngProbePipeline)
        enc.setBuffer(inputBuf, offset: 0, index: 0)
        enc.setBuffer(outputBuf, offset: 0, index: 1)
        enc.setBytes(&countWord, length: MemoryLayout<UInt32>.stride, index: 2)
        dispatchThreads(count: count, pipeline: rngProbePipeline, encoder: enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw RunnerError.gpuExecutionFailed("rng probe: \(error)")
        }

        let outputPtr = outputBuf.contents().bindMemory(to: UInt32.self, capacity: count)
        return (0..<count).map { outputPtr[$0] }
    }

    /// Run the pair-probe kernel for test-only topology verification.
    public func runPairProbe(epoch: UInt32) throws -> [(a: UInt32, b: UInt32)] {
        let outputBytes = EcologyTopology.pairCount * 2 * MemoryLayout<UInt32>.stride
        guard let outputBuf = device.makeBuffer(length: outputBytes,
                                                 options: .storageModeShared) else {
            throw RunnerError.bufferAllocationFailed("pair probe buffer")
        }
        outputBuf.label = "ecology.pairProbe"

        var params = BFFEcologyEpochParams(
            seed: 0, epoch: epoch, stepBudget: 1, mutationP32: 0,
            variant: 0, bracketMode: 0,
            capturePairTapes: 0, reserved0: 0
        )

        guard let cb = commandQueue.makeCommandBuffer() else {
            throw RunnerError.commandEncodingFailed("pair probe command buffer")
        }
        guard let enc = cb.makeComputeCommandEncoder() else {
            throw RunnerError.commandEncodingFailed("pair probe encoder")
        }
        enc.setComputePipelineState(pairProbePipeline)
        enc.setBuffer(outputBuf, offset: 0, index: 0)
        enc.setBytes(&params, length: MemoryLayout<BFFEcologyEpochParams>.stride, index: 1)
        dispatchThreads(count: EcologyTopology.pairCount,
                        pipeline: pairProbePipeline, encoder: enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw RunnerError.gpuExecutionFailed("pair probe: \(error)")
        }

        let ptr = outputBuf.contents().bindMemory(to: UInt32.self,
                                                    capacity: EcologyTopology.pairCount * 2)
        return (0..<EcologyTopology.pairCount).map { i in
            (a: ptr[i * 2], b: ptr[i * 2 + 1])
        }
    }

    // MARK: - Internal helpers

    private func dispatchThreads(count: Int, pipeline: MTLComputePipelineState,
                                  encoder: MTLComputeCommandEncoder) {
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let groups = (count + width - 1) / width
        encoder.dispatchThreadgroups(
            MTLSize(width: max(1, groups), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    private struct KernelTiming {
        let hostSeconds: Double
        let gpuSeconds: Double?
    }

    private func encodeTimed(name: String,
                             pipeline: MTLComputePipelineState,
                             _ precompute: ((MTLCommandBuffer) throws -> Void)? = nil,
                             encode: (MTLComputeCommandEncoder) throws -> Void) throws -> KernelTiming {
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw RunnerError.commandEncodingFailed("\(name) command buffer")
        }
        cb.label = "ecology.\(name)"
        try precompute?(cb)
        guard let enc = cb.makeComputeCommandEncoder() else {
            throw RunnerError.commandEncodingFailed("\(name) compute encoder")
        }
        let start = ResidentClock.now()
        try encode(enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let host = ResidentClock.now() - start
        if let error = cb.error {
            throw RunnerError.gpuExecutionFailed("\(name): \(error)")
        }
        let gpuSpan = cb.gpuEndTime - cb.gpuStartTime
        let gpu = (cb.gpuStartTime > 0 && gpuSpan > 0) ? gpuSpan : nil
        return KernelTiming(hostSeconds: host, gpuSeconds: gpu)
    }

    private func readCounterWords() -> [UInt32] {
        (0..<Int(BFF_ECO_COUNTER_WORD_COUNT)).map { i in
            countersBuffer.contents()
                .load(fromByteOffset: i * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
    }

    private func readSoupCheckpoint() -> [UInt8] {
        [UInt8](UnsafeRawBufferPointer(start: soupBuffer.contents(),
                                        count: soupByteCount))
    }

    private func readPairResults() -> [BFFEcologyMetalPairResult] {
        let stride = MemoryLayout<BFFEcologyPairResult>.stride
        var out: [BFFEcologyMetalPairResult] = []
        out.reserveCapacity(EcologyTopology.pairCount)
        for i in 0..<EcologyTopology.pairCount {
            let raw = pairResultBuffer.contents()
                .advanced(by: i * stride)
                .load(as: BFFEcologyPairResult.self)
            out.append(BFFEcologyMetalPairResult(fromCStruct: raw))
        }
        return out
    }

    private func readPairTapes(from buffer: MTLBuffer) -> [[UInt8]] {
        var out: [[UInt8]] = []
        out.reserveCapacity(EcologyTopology.pairCount)
        for i in 0..<EcologyTopology.pairCount {
            let offset = i * BFF.pairTapeSize
            let tape = [UInt8](UnsafeRawBufferPointer(
                start: buffer.contents().advanced(by: offset),
                count: BFF.pairTapeSize))
            out.append(tape)
        }
        return out
    }
}

/// Variant code mapping (mirrors BFFEvalLayout.variantCode).
public enum BFFEcologyEvalLayout {
    public static func variantCode(_ variant: BFFVariant) -> UInt32 {
        switch variant {
        case .noheads: return UInt32(BFF_ECO_VARIANT_NOHEADS)
        case .seededHeads: return UInt32(BFF_ECO_VARIANT_SEEDED_HEADS)
        }
    }
}

/// Clock helper (mirrors ResidentClock from BFFMetal).
enum ResidentClock {
    static func now() -> Double {
        #if canImport(Darwin)
        return ProcessInfo.processInfo.systemUptime
        #else
        return Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
        #endif
    }
}

#else
// Linux stub — the runner is unavailable; the CLI exits 2 on non-Metal hosts.
public enum EcologyMetalEpochRunner {
    public enum RunnerError: Error {
        case metalUnavailable
    }
}
#endif
