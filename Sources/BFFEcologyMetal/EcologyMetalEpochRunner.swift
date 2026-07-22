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
/// costs are reported separately. The app-safe path also reports the visualize
/// kernel GPU time so the HUD's `visualizationGpuMs` is a real measurement, not
/// a dead field.
public struct EcologyMetalEpochInstrumentation: Equatable, Sendable, Codable {
    public var epochWallSeconds: Double
    public var mutateKernelSeconds: Double?
    public var evalKernelSeconds: Double?
    /// App-safe only: the `bff_ecology_visualize` kernel GPU time. `nil` on the
    /// accepted CLI path, which never runs the visualize kernel.
    public var visualizeKernelSeconds: Double?
    public var counterReadbackSeconds: Double
    public var soupReadbackSeconds: Double?
    public var digestSeconds: Double?
    public var captureReadbackSeconds: Double?
    public var uploadBytes: Int
    public var readbackBytes: Int
    public var counterBytes: Int
    public var captureBytes: Int

    /// Public memberwise initializer so external test modules can construct
    /// production reports for focused production-path tests (no Metal required).
    /// Production callers use the runner's `runEpoch()`/`runEpochAppSafe()`.
    public init(epochWallSeconds: Double,
                mutateKernelSeconds: Double?,
                evalKernelSeconds: Double?,
                visualizeKernelSeconds: Double?,
                counterReadbackSeconds: Double,
                soupReadbackSeconds: Double?,
                digestSeconds: Double?,
                captureReadbackSeconds: Double?,
                uploadBytes: Int,
                readbackBytes: Int,
                counterBytes: Int,
                captureBytes: Int) {
        self.epochWallSeconds = epochWallSeconds
        self.mutateKernelSeconds = mutateKernelSeconds
        self.evalKernelSeconds = evalKernelSeconds
        self.visualizeKernelSeconds = visualizeKernelSeconds
        self.counterReadbackSeconds = counterReadbackSeconds
        self.soupReadbackSeconds = soupReadbackSeconds
        self.digestSeconds = digestSeconds
        self.captureReadbackSeconds = captureReadbackSeconds
        self.uploadBytes = uploadBytes
        self.readbackBytes = readbackBytes
        self.counterBytes = counterBytes
        self.captureBytes = captureBytes
    }
}

public struct EcologyMetalEpochReport: Sendable {
    public var counters: EcologyEpochCounters
    public var digest: UInt64?
    public var capturedPairResults: [BFFEcologyMetalPairResult]
    public var capturedInputTapes: [[UInt8]]
    public var capturedFinalTapes: [[UInt8]]
    public var instrumentation: EcologyMetalEpochInstrumentation

    /// Public memberwise initializer so external test modules can construct
    /// production reports for focused production-path tests (no Metal
    /// required). Production callers use the runner's `runEpoch()`/
    /// `runEpochAppSafe()`, which is the only path that ever produces a real
    /// report.
    public init(counters: EcologyEpochCounters,
                digest: UInt64?,
                capturedPairResults: [BFFEcologyMetalPairResult],
                capturedInputTapes: [[UInt8]],
                capturedFinalTapes: [[UInt8]],
                instrumentation: EcologyMetalEpochInstrumentation) {
        self.counters = counters
        self.digest = digest
        self.capturedPairResults = capturedPairResults
        self.capturedInputTapes = capturedInputTapes
        self.capturedFinalTapes = capturedFinalTapes
        self.instrumentation = instrumentation
    }
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

/// Runtime packaging-contract accessor for the ecology shader resource. The
/// runner loads `BFFEcologyEpoch.metal` via `ShaderResourceLocator` against
/// this module's resource bundle; this accessor exposes the same lookup so the
/// packaging contract ("the ecology shader is a single, provenanced resource
/// the app directly requires") is verifiable at runtime without constructing a
/// runner and without asserting on shader source strings. Declared outside the
/// `#if canImport(Metal)` gate because `ShaderResourceLocator` and
/// `Bundle.module` are platform-independent — the packaging contract is
/// verifiable on every host.
public enum EcologyShaderPackaging {
    /// The bundled `BFFEcologyEpoch.metal` source URL, or `nil` if the
    /// resource is missing from both `Bundle.main` and this module's bundle.
    public static var epochShaderResourceURL: URL? {
        ShaderResourceLocator.url(forResource: "BFFEcologyEpoch",
                                  withExtension: "metal",
                                  moduleBundle: .module)
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
    /// Compiled shader library, retained so the app-safe visualize pipeline can
    /// be built lazily without re-parsing the shader source. The accepted CLI
    /// `runEpoch()` never touches this; it is only consumed by
    /// `prepareAppSafeResources()` / `runEpochAppSafe()`.
    private let library: MTLLibrary

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

    /// App-safe (interactive) execution resources, prepared lazily. `nil`
    /// unless `prepareAppSafeResources()` has been called. The accepted CLI
    /// never prepares these, so its memory footprint and `runEpoch()` behavior
    /// are byte-for-byte unchanged.
    private var appSafeResources: EcologyAppSafeResources?

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
        self.library = library

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
            visualizeKernelSeconds: nil,
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
            instrumentation: instr)
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

    // MARK: - App-safe (interactive) execution path
    //
    // A separate API from the accepted CLI `runEpoch()`: it shares the exact
    // mutate+eval kernels and accepted CPU-parity semantics, but performs
    // **no full-soup CPU readback, no CPU digest, and no GPU wait on the
    // display thread**. Instead the producer (this runner, driven from a
    // background simulation queue) schedules an immutable soup+overview blit
    // into a snapshot ring slot and publishes on command-buffer completion.
    // The renderer leases the immutable slot and releases on render
    // command-buffer completion — it never binds the live mutable soup.
    //
    // Resources (visualize pipeline, overview texture + byte buffer, snapshot
    // ring) are prepared lazily so the CLI's footprint and `runEpoch()`
    // behavior are byte-for-byte unchanged.

    /// The fixed ecology overview texture dimensions (512 × 256 = 131,072
    /// sites, sourced from `EcologyTopology` — never duplicated).
    private static let overviewWidth = EcologyTopology.width
    private static let overviewHeight = EcologyTopology.height
    private static let snapshotSlotCount = 3

    /// The immutable, GPU-resident overview texture the producer's visualize
    /// kernel writes and the snapshot blit copies into the immutable ring slots.
    /// `nil` until `prepareAppSafeResources()` has succeeded. The renderer
    /// NEVER binds this live texture — it leases the immutable ring copy. Kept
    /// public so tests and the snapshot blit can confirm the producer resource
    /// exists; it is not a cross-thread epoch source.
    public var residentVisualizationTexture: MTLTexture? {
        appSafeResources?.overviewTexture
    }

    /// Snapshot-ring diagnostics for the app-safe path. Returns the
    /// `ResidentSnapshotRingDiagnostics.unprepared` sentinel (slot count 0,
    /// every counter 0) before preparation so the HUD never fabricates lease
    /// counts for a ring that does not exist yet. Construction is via that
    /// narrow public sentinel (defined in BFFMetal) — this module never
    /// synthesizes a `ResidentSnapshotRingDiagnostics` value itself.
    public var residentSnapshotDiagnostics: ResidentSnapshotRingDiagnostics {
        appSafeResources?.snapshotRing.diagnostics
            ?? .unprepared
    }

    /// Lease an immutable, same-generation soup+overview snapshot for the
    /// current published epoch. Returns `nil` if no slot is published yet or
    /// every slot is busy (renderer backpressure is skipped — the renderer
    /// falls back to the overview-only path). The lease is released on the
    /// render command buffer's completion handler; `deinit` also releases.
    public func acquireResidentSnapshot(expectedByteCount: Int) -> ResidentGPUSnapshotLease? {
        appSafeResources?.snapshotRing.acquire(expectedByteCount: expectedByteCount)
    }

    /// Prepare the app-safe resources (visualize pipeline, overview texture +
    /// byte buffer, snapshot ring). Idempotent; safe to call more than once.
    /// Throws on pipeline/texture/buffer/ring allocation failure. The CLI
    /// never calls this.
    public func prepareAppSafeResources() throws {
        if appSafeResources != nil { return }
        guard let fn = library.makeFunction(name: "bff_ecology_visualize") else {
            throw RunnerError.kernelMissing("bff_ecology_visualize")
        }
        let visualizePipeline: MTLComputePipelineState
        do {
            visualizePipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            throw RunnerError.compileFailed("pipeline bff_ecology_visualize: \(error)")
        }

        let overviewDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Self.overviewWidth,
            height: Self.overviewHeight,
            mipmapped: false)
        overviewDesc.usage = [.shaderWrite, .shaderRead]
        guard let overviewTexture = device.makeTexture(descriptor: overviewDesc) else {
            throw RunnerError.bufferAllocationFailed("ecology.overviewTexture")
        }
        overviewTexture.label = "ecology.overviewTexture"

        let ring: ResidentGPUSnapshotRing
        do {
            ring = try ResidentGPUSnapshotRing(
                device: device,
                slotCount: Self.snapshotSlotCount,
                byteCount: soupByteCount,
                overviewWidth: Self.overviewWidth,
                overviewHeight: Self.overviewHeight)
        } catch let ResidentMetalEpochRunner.RunnerError.bufferAllocationFailed(label) {
            throw RunnerError.bufferAllocationFailed(label)
        }
        self.appSafeResources = EcologyAppSafeResources(
            visualizePipeline: visualizePipeline,
            overviewTexture: overviewTexture,
            snapshotRing: ring)
    }

    /// App-safe epoch execution. Runs the same mutate+eval kernels as the
    /// accepted `runEpoch()`, then runs `bff_ecology_visualize`, reads back
    /// ONLY the small counters buffer, asserts `haltUnknown == 0`, and
    /// schedules an immutable soup+overview snapshot publication (a blit into
    /// a ring slot, published on command-buffer completion). It does **not**
    /// read back the full soup, compute a CPU digest, or wait on the GPU from
    /// the display thread. The `digest` fields of the returned report are
    /// `nil`/`0` (sentinel: not computed) and must not be presented as a real
    /// measurement. Stale completions after `stop`/reset are inert under the
    /// driver's lifecycle-generation fence.
    @discardableResult
    public func runEpochAppSafe() throws -> EcologyMetalEpochReport {
        guard epoch <= UInt64(UInt32.max) else {
            throw RunnerError.epochOutOfRange(epoch)
        }
        let resources = try preparedAppSafeResources()
        let e = UInt32(epoch)
        let phase = EcologyMatchingPhase(epoch: e)
        let epochStart = ResidentClock.now()
        var readbackBytes = 0
        let counterBytes = counterByteCount

        var params = BFFEcologyEpochParams(
            seed: config.seed,
            epoch: e,
            stepBudget: UInt32(config.stepBudget),
            mutationP32: config.mutationP32,
            variant: BFFEcologyEvalLayout.variantCode(config.variant),
            bracketMode: config.bracketMode == .dynamicScan
                ? UInt32(BFF_ECO_BRACKET_DYNAMIC_SCAN)
                : UInt32(BFF_ECO_BRACKET_JUMP_TABLE),
            capturePairTapes: 0,
            reserved0: 0)

        // --- Mutate kernel (same kernel + params as runEpoch) ---
        let mutateTiming = try encodeTimed(name: "mutate", pipeline: mutatePipeline) { cb in
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
            self.dispatchThreads(count: self.soupByteCount, pipeline: mutatePipeline, encoder: enc)
        }

        // --- Eval scatter kernel (same kernel + params as runEpoch) ---
        let evalTiming = try encodeTimed(name: "eval-scatter", pipeline: evalPipeline) { enc in
            enc.setComputePipelineState(evalPipeline)
            enc.setBuffer(soupBuffer, offset: 0, index: 0)
            enc.setBuffer(countersBuffer, offset: 0, index: 1)
            enc.setBytes(&params, length: MemoryLayout<BFFEcologyEpochParams>.stride, index: 2)
            enc.setBuffer(self.pairResultBuffer, offset: 0, index: 3)
            enc.setBuffer(self.inputCaptureBuffer, offset: 0, index: 4)
            enc.setBuffer(self.finalCaptureBuffer, offset: 0, index: 5)
            self.dispatchThreads(count: EcologyTopology.pairCount,
                            pipeline: evalPipeline, encoder: enc)
        }

        // --- Visualize kernel (app-safe only; writes the live overview
        // texture that the snapshot blit copies into the immutable ring slot).
        // The renderer never binds this live texture — it leases the immutable
        // copy. The visualize kernel writes ONLY the texture; there is no
        // host-readable overview byte buffer on this path (it would be written
        // and never read). ---
        let visualizeTiming = try encodeTimed(
            name: "visualize", pipeline: resources.visualizePipeline) { enc in
            enc.setComputePipelineState(resources.visualizePipeline)
            enc.setBuffer(soupBuffer, offset: 0, index: 0)
            enc.setTexture(resources.overviewTexture, index: 0)
            self.dispatchThreads(count: EcologyTopology.siteCount,
                            pipeline: resources.visualizePipeline, encoder: enc)
        }

        // --- Read back ONLY the small counters buffer (no full-soup readback) ---
        let counterReadbackStart = ResidentClock.now()
        let counterWords = readCounterWords()
        let counterReadbackSeconds = ResidentClock.now() - counterReadbackStart
        readbackBytes += counterBytes

        let haltUnknown = counterWords[Int(BFF_ECO_COUNTER_HALT_UNKNOWN)]
        if haltUnknown != 0 {
            throw RunnerError.unexpectedHalt(haltUnknown)
        }

        let mutationCount = Int(counterWords[Int(BFF_ECO_COUNTER_MUTATION_COUNT)])
        let totalRawSteps = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_RAW_STEPS)])
        let totalNoopSteps = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_NOOP_STEPS)])
        let totalLoopOps = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_LOOP_OPS)])
        let totalCopyWrites = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_COPY_WRITES)])
        let totalRemapEvents = Int(counterWords[Int(BFF_ECO_COUNTER_TOTAL_REMAP_EVENTS)])
        let haltBudget = Int(counterWords[Int(BFF_ECO_COUNTER_HALT_BUDGET)])
        let haltPCOut = Int(counterWords[Int(BFF_ECO_COUNTER_HALT_PC_OUT)])
        let haltUnmatched = Int(counterWords[Int(BFF_ECO_COUNTER_HALT_UNMATCHED)])

        // App-safe path does NOT compute a soup digest. The `digest` field is
        // the sentinel `0` ("not computed"); the report's top-level `digest`
        // is `nil`. Neither must be presented as a real measurement.
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
            digest: 0)

        // --- Schedule immutable soup+overview publication (async blit). ---
        // Ring exhaustion skips publication and never backpressures simulation.
        // `sourceEpoch` is the completed-epoch count (e + 1) the snapshot
        // represents; the renderer derives the displayed phase from it via the
        // documented convention (see `noteEcologyFrameSubmitted` in AppModel),
        // so phase is not carried as a separate field here.
        let nextEpoch = Int(e) + 1
        scheduleAppSafeSnapshotPublication(resources: resources,
                                          sourceEpoch: nextEpoch)

        self.lastEpochCounters = counters
        epoch += 1
        let wall = ResidentClock.now() - epochStart

        let instr = EcologyMetalEpochInstrumentation(
            epochWallSeconds: wall,
            mutateKernelSeconds: mutateTiming.gpuSeconds ?? mutateTiming.hostSeconds,
            evalKernelSeconds: evalTiming.gpuSeconds ?? evalTiming.hostSeconds,
            visualizeKernelSeconds: visualizeTiming.gpuSeconds ?? visualizeTiming.hostSeconds,
            counterReadbackSeconds: counterReadbackSeconds,
            soupReadbackSeconds: nil,
            digestSeconds: nil,
            captureReadbackSeconds: nil,
            uploadBytes: 0,
            readbackBytes: readbackBytes,
            counterBytes: counterBytes,
            captureBytes: 0)

        return EcologyMetalEpochReport(
            counters: counters,
            digest: nil,
            capturedPairResults: [],
            capturedInputTapes: [],
            capturedFinalTapes: [],
            instrumentation: instr)
    }

    /// Returns the prepared app-safe resources, preparing them on demand.
    /// Called by `runEpochAppSafe()` so a caller that goes straight to
    /// app-safe execution (the app driver) does not need a separate prepare
    /// step. The CLI never reaches this path.
    private func preparedAppSafeResources() throws -> EcologyAppSafeResources {
        if appSafeResources == nil { try prepareAppSafeResources() }
        return appSafeResources!
    }

    /// Schedule an immutable soup+overview snapshot publication: reserve a
    /// ring slot, blit the live soup + overview texture into it, and publish
    /// on the blit command buffer's completion handler. If no slot is free
    /// (ring exhaustion), skip publication silently — never backpressure the
    /// simulation.
    ///
    /// Phase convention (defined explicitly to remove off-by-one ambiguity):
    /// this is called immediately after the producer completed producing
    /// ecology epoch `e`, so the snapshot carries `sourceEpoch = e + 1`
    /// (completed epochs) and the phase for the producing epoch `e`
    /// (`EcologyMatchingPhase(epoch: e) = e & 3`). The phase is a pure,
    /// unambiguous function of `sourceEpoch` here — `sourceEpoch >= 1` always
    /// (the first publication follows epoch 0), so the displayed phase is
    /// `EcologyMatchingPhase(epoch: sourceEpoch - 1)`. It is therefore NOT
    /// carried as a separate field; the renderer/HUD derive it from
    /// `sourceEpoch` via that single rule (see `noteEcologyFrameSubmitted`).
    private func scheduleAppSafeSnapshotPublication(
        resources: EcologyAppSafeResources,
        sourceEpoch: Int
    ) {
        guard let (reservation, snapshotBuffer, snapshotOverviewTexture) =
                resources.snapshotRing.reserveForWrite() else {
            return
        }
        guard let cb = commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            resources.snapshotRing.cancel(reservation)
            return
        }
        cb.label = "ecology.snapshot.blit"
        let start = ResidentClock.now()
        blit.copy(from: soupBuffer, sourceOffset: 0,
                  to: snapshotBuffer, destinationOffset: 0,
                  size: soupByteCount)
        let overviewSize = MTLSize(width: resources.overviewTexture.width,
                                   height: resources.overviewTexture.height,
                                   depth: 1)
        blit.copy(from: resources.overviewTexture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: overviewSize,
                  to: snapshotOverviewTexture,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let ring = resources.snapshotRing
        let byteCount = soupByteCount
        cb.addCompletedHandler { completed in
            let hostSeconds = ResidentClock.now() - start
            guard completed.status == .completed, completed.error == nil else {
                ring.cancel(reservation)
                return
            }
            let gpuSpan = completed.gpuEndTime - completed.gpuStartTime
            let gpuSeconds = (completed.gpuStartTime > 0 && gpuSpan > 0) ? gpuSpan : nil
            ring.publish(reservation,
                         sourceEpoch: sourceEpoch,
                         byteCount: byteCount,
                         blitHostSeconds: hostSeconds,
                         blitGPUSeconds: gpuSeconds)
        }
        cb.commit()
    }
}

/// Owning container for the ecology app-safe (interactive) GPU resources.
/// Private to this file; the runner exposes them through accessors.
private final class EcologyAppSafeResources: @unchecked Sendable {
    let visualizePipeline: MTLComputePipelineState
    let overviewTexture: MTLTexture
    let snapshotRing: ResidentGPUSnapshotRing

    init(visualizePipeline: MTLComputePipelineState,
         overviewTexture: MTLTexture,
         snapshotRing: ResidentGPUSnapshotRing) {
        self.visualizePipeline = visualizePipeline
        self.overviewTexture = overviewTexture
        self.snapshotRing = snapshotRing
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
