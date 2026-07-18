import BFFOracle
import Dispatch
import Foundation

#if canImport(Metal)
import Metal
#endif

/// Experimental GPU-resident epoch configuration.
///
/// This is deliberately separate from `SoupConfig`: existing small-soup/app/benchmark
/// defaults are untouched, while this type can expose residency-specific knobs such as
/// checkpoint cadence, pair-tape capture, and visualization output.
public struct ResidentEpochConfig: Equatable, Sendable {
    public var seed: UInt32
    public var programCount: Int
    public var stepBudget: Int
    public var mutationP32: UInt32
    public var variant: BFFVariant
    public var initMode: SoupConfig.InitMode
    /// Number of pairs to CPU-shadow per epoch. `nil` means all pairs.
    public var shadowSampleCount: Int?
    /// Read the full soup back every N epochs. `0` disables full checkpoints.
    public var checkpointInterval: Int
    /// Capture pre/post 128-byte pair tapes in reusable GPU buffers. Validation modes
    /// enable this; throughput smoke runs can leave it off.
    public var capturePairTapes: Bool
    /// Emit one approximate RGBA visualization pixel per program into a reusable
    /// texture and byte buffer.
    public var visualizationEnabled: Bool
    public var visualizationWidth: Int

    public var pairCount: Int { programCount / 2 }
    public var soupByteCount: Int { programCount * BFF.tapeSize }
    public var resolvedShadowSampleCount: Int {
        min(shadowSampleCount ?? pairCount, pairCount)
    }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case programCountNotPositiveEven(Int)
        case programCountOverflow(Int)
        case stepBudgetOutOfRange(Int)
        case shadowSampleOutOfRange(Int)
        case checkpointIntervalNegative(Int)
        case visualizationWidthNotPositive(Int)

        public var description: String {
            switch self {
            case .programCountNotPositiveEven(let n):
                return "program count \(n) must be positive and even"
            case .programCountOverflow(let n):
                return "program count \(n) is too large for resident buffer sizing"
            case .stepBudgetOutOfRange(let n):
                return "step budget \(n) must be in 1...\(BFFEvalLayout.maxStepBudget)"
            case .shadowSampleOutOfRange(let n):
                return "shadow sample count \(n) must be non-negative"
            case .checkpointIntervalNegative(let n):
                return "checkpoint interval \(n) must be >= 0"
            case .visualizationWidthNotPositive(let n):
                return "visualization width \(n) must be positive"
            }
        }
    }

    public init(seed: UInt32,
                programCount: Int = BFF.defaultSoupPrograms,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                initMode: SoupConfig.InitMode = .uniform,
                shadowSampleCount: Int? = 0,
                checkpointInterval: Int = 0,
                capturePairTapes: Bool = false,
                visualizationEnabled: Bool = false,
                visualizationWidth: Int = 512) throws {
        guard programCount > 0, programCount % 2 == 0 else {
            throw ConfigError.programCountNotPositiveEven(programCount)
        }
        guard programCount <= Int.max / BFF.tapeSize,
              programCount / 2 <= Int(UInt32.max),
              programCount <= Int(UInt32.max) else {
            throw ConfigError.programCountOverflow(programCount)
        }
        guard stepBudget > 0, stepBudget <= BFFEvalLayout.maxStepBudget else {
            throw ConfigError.stepBudgetOutOfRange(stepBudget)
        }
        if let shadowSampleCount, shadowSampleCount < 0 {
            throw ConfigError.shadowSampleOutOfRange(shadowSampleCount)
        }
        guard checkpointInterval >= 0 else {
            throw ConfigError.checkpointIntervalNegative(checkpointInterval)
        }
        guard visualizationWidth > 0 else {
            throw ConfigError.visualizationWidthNotPositive(visualizationWidth)
        }
        self.seed = seed
        self.programCount = programCount
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.initMode = initMode
        self.shadowSampleCount = shadowSampleCount
        self.checkpointInterval = checkpointInterval
        self.capturePairTapes = capturePairTapes
        self.visualizationEnabled = visualizationEnabled
        self.visualizationWidth = visualizationWidth
    }

    public func initialSoup() -> [UInt8] {
        switch initMode {
        case .uniform:
            return BFFRandom.initialSoup(programs: programCount, seed: seed)
        case .constant:
            return BFFRandom.constantSoup(programs: programCount)
        case .opcode:
            return BFFRandom.opcodeSoup(programs: programCount, seed: seed)
        }
    }
}

public struct ResidentBufferSizes: Equatable, Sendable, Codable {
    public var soupBytes: Int
    public var permutationBytes: Int
    public var pairResultBytes: Int
    public var pairInputCaptureBytes: Int
    public var pairFinalCaptureBytes: Int
    public var countersBytes: Int
    public var programActivityBytes: Int
    public var visualizationBytes: Int

    public var totalPersistentBytes: Int {
        soupBytes + permutationBytes + pairResultBytes + pairInputCaptureBytes
            + pairFinalCaptureBytes + countersBytes + programActivityBytes
            + visualizationBytes
    }
}

public struct ResidentKernelTiming: Equatable, Sendable, Codable {
    public var name: String
    public var hostSeconds: Double
    public var gpuSeconds: Double?

    public init(name: String, hostSeconds: Double, gpuSeconds: Double?) {
        self.name = name
        self.hostSeconds = hostSeconds
        self.gpuSeconds = gpuSeconds
    }
}

public struct ResidentEpochInstrumentation: Equatable, Sendable, Codable {
    public var epochWallSeconds: Double
    public var checkpointSeconds: Double?
    public var epochsPerSecond: Double
    public var uploadBytes: Int
    public var readbackBytes: Int
    public var parameterBytes: Int
    public var bufferSizes: ResidentBufferSizes
    public var kernelTimings: [ResidentKernelTiming]
}

public struct ResidentEpochCounters: Equatable, Sendable, Codable {
    public var epoch: Int
    public var interactions: Int
    public var mutationCount: Int
    public var totalRawSteps: Int
    public var totalNoopSteps: Int
    public var totalCommandSteps: Int
    public var totalLoopOps: Int
    public var totalCopyWrites: Int
    public var haltBudget: Int
    public var haltPCOut: Int
    public var haltUnmatched: Int
    public var haltUnknown: Int

    public init(epoch: Int, interactions: Int, mutationCount: Int,
                totalRawSteps: Int, totalNoopSteps: Int, totalLoopOps: Int,
                totalCopyWrites: Int, haltBudget: Int, haltPCOut: Int,
                haltUnmatched: Int, haltUnknown: Int) {
        self.epoch = epoch
        self.interactions = interactions
        self.mutationCount = mutationCount
        self.totalRawSteps = totalRawSteps
        self.totalNoopSteps = totalNoopSteps
        self.totalCommandSteps = totalRawSteps - totalNoopSteps
        self.totalLoopOps = totalLoopOps
        self.totalCopyWrites = totalCopyWrites
        self.haltBudget = haltBudget
        self.haltPCOut = haltPCOut
        self.haltUnmatched = haltUnmatched
        self.haltUnknown = haltUnknown
    }

    public init(epoch: Int, interactions: Int, words: [UInt32]) {
        precondition(words.count >= ResidentCounterLayout.wordCount)
        self.init(epoch: epoch,
                  interactions: interactions,
                  mutationCount: Int(words[ResidentCounterLayout.mutationCount]),
                  totalRawSteps: Int(words[ResidentCounterLayout.totalRawSteps]),
                  totalNoopSteps: Int(words[ResidentCounterLayout.totalNoopSteps]),
                  totalLoopOps: Int(words[ResidentCounterLayout.totalLoopOps]),
                  totalCopyWrites: Int(words[ResidentCounterLayout.totalCopyWrites]),
                  haltBudget: Int(words[ResidentCounterLayout.haltBudget]),
                  haltPCOut: Int(words[ResidentCounterLayout.haltPCOut]),
                  haltUnmatched: Int(words[ResidentCounterLayout.haltUnmatched]),
                  haltUnknown: Int(words[ResidentCounterLayout.haltUnknown]))
    }

    public var haltAccounted: Int {
        haltBudget + haltPCOut + haltUnmatched + haltUnknown
    }
}

enum ResidentCounterLayout {
    static let mutationCount = 0
    static let totalRawSteps = 1
    static let totalNoopSteps = 2
    static let totalLoopOps = 3
    static let totalCopyWrites = 4
    static let haltBudget = 5
    static let haltPCOut = 6
    static let haltUnmatched = 7
    static let haltUnknown = 8
    static let wordCount = 9
}

public struct ResidentPairCapture: Equatable, Sendable {
    public var pairIndex: Int
    public var programA: UInt32
    public var programB: UInt32
    public var inputTape: [UInt8]
    public var finalTape: [UInt8]
    public var outcome: GPUPairOutcome
}

public struct ResidentEpochReport: Sendable {
    public var counters: ResidentEpochCounters
    public var digest: UInt64?
    public var checkpointSoup: [UInt8]?
    public var capturedPairs: [ResidentPairCapture]
    public var shadowChecked: Int
    public var shadowMismatches: [ShadowMismatch]
    public var instrumentation: ResidentEpochInstrumentation
}

/// Platform-independent reference for the experimental resident epoch path.
///
/// It uses the same state shape as the Metal runner, but executes on the scalar oracle.
/// Tests use it to validate tails/sizing/parity on Linux; mismatch diagnostics use its
/// pair captures as the CPU anchor.
public struct ResidentCPUReferenceRunner: Sendable {
    public let config: ResidentEpochConfig
    public private(set) var soup: [UInt8]
    public private(set) var epoch: Int

    public init(config: ResidentEpochConfig) {
        self.config = config
        self.soup = config.initialSoup()
        self.epoch = 0
    }

    @discardableResult
    public mutating func runEpoch() -> ResidentEpochReport {
        let start = ResidentClock.now()
        let e = UInt32(epoch)
        let mutationCount = BFFRandom.mutate(soup: &soup, seed: config.seed,
                                             epoch: e, mutationP32: config.mutationP32)
        let perm = BFFRandom.pairingPermutation(count: config.programCount,
                                                seed: config.seed, epoch: e)

        var words = [UInt32](repeating: 0, count: ResidentCounterLayout.wordCount)
        words[ResidentCounterLayout.mutationCount] = UInt32(mutationCount)
        var captures: [ResidentPairCapture] = []
        captures.reserveCapacity(config.capturePairTapes ? config.pairCount : 0)

        for pairIndex in 0..<config.pairCount {
            let a = perm[2 * pairIndex]
            let b = perm[2 * pairIndex + 1]
            let aStart = Int(a) * BFF.tapeSize
            let bStart = Int(b) * BFF.tapeSize
            let input = Array(soup[aStart..<aStart + BFF.tapeSize])
                + Array(soup[bStart..<bStart + BFF.tapeSize])
            let r = BFFInterpreter.run(pairTape: input, variant: config.variant,
                                       bracketMode: .dynamicScan,
                                       stepBudget: config.stepBudget)
            soup.replaceSubrange(aStart..<aStart + BFF.tapeSize,
                                 with: r.tape[0..<BFF.tapeSize])
            soup.replaceSubrange(bStart..<bStart + BFF.tapeSize,
                                 with: r.tape[BFF.tapeSize..<BFF.pairTapeSize])

            words[ResidentCounterLayout.totalRawSteps] &+= UInt32(r.steps)
            words[ResidentCounterLayout.totalNoopSteps] &+= UInt32(r.noopSteps)
            words[ResidentCounterLayout.totalLoopOps] &+= UInt32(r.loopOps)
            words[ResidentCounterLayout.totalCopyWrites] &+= UInt32(r.copyWrites)
            switch r.halt {
            case .budget: words[ResidentCounterLayout.haltBudget] &+= 1
            case .pcOut: words[ResidentCounterLayout.haltPCOut] &+= 1
            case .unmatched: words[ResidentCounterLayout.haltUnmatched] &+= 1
            }

            if config.capturePairTapes {
                let outcome = GPUPairOutcome(finalTape: r.tape,
                                             steps: UInt32(r.steps),
                                             noopSteps: UInt32(r.noopSteps),
                                             copyWrites: UInt32(r.copyWrites),
                                             loopOps: UInt32(r.loopOps),
                                             halt: UInt32(r.halt.rawValue))
                captures.append(ResidentPairCapture(pairIndex: pairIndex,
                                                    programA: a, programB: b,
                                                    inputTape: input,
                                                    finalTape: r.tape,
                                                    outcome: outcome))
            }
        }

        let counters = ResidentEpochCounters(epoch: epoch, interactions: config.pairCount,
                                             words: words)
        let shadowCount = config.capturePairTapes ? config.resolvedShadowSampleCount : 0
        let shadowSample = ShadowSampler.sampleIndices(
            pairCount: config.pairCount,
            sampleCount: shadowCount,
            seed: config.seed,
            epoch: epoch)
        var mismatches: [ShadowMismatch] = []
        if config.capturePairTapes {
            for idx in shadowSample {
                let c = captures[idx]
                if let mm = ShadowComparator.check(epoch: epoch, pairIndex: idx,
                                                   programA: c.programA,
                                                   programB: c.programB,
                                                   input: c.inputTape,
                                                   variant: config.variant,
                                                   stepBudget: config.stepBudget,
                                                   gpu: c.outcome) {
                    mismatches.append(mm)
                }
            }
        }

        let checkpointEnabled = config.checkpointInterval > 0
            && ((epoch + 1) % config.checkpointInterval == 0)
        let checkpoint = checkpointEnabled ? soup : nil
        let digest = checkpoint.map(SoupDigest.digest)
        epoch += 1

        let wall = ResidentClock.now() - start
        let sizes = ResidentEpochBufferSizer.sizes(config: config)
        let instr = ResidentEpochInstrumentation(
            epochWallSeconds: wall,
            checkpointSeconds: checkpointEnabled ? 0 : nil,
            epochsPerSecond: wall > 0 ? 1.0 / wall : 0,
            uploadBytes: epoch == 1 ? config.soupByteCount : 0,
            readbackBytes: (checkpoint?.count ?? 0)
                + ResidentCounterLayout.wordCount * MemoryLayout<UInt32>.stride
                + captures.count * (BFF.pairTapeSize * 2 + 5 * MemoryLayout<UInt32>.stride),
            parameterBytes: 0,
            bufferSizes: sizes,
            kernelTimings: [])

        return ResidentEpochReport(counters: counters,
                                   digest: digest,
                                   checkpointSoup: checkpoint,
                                   capturedPairs: captures,
                                   shadowChecked: shadowSample.count,
                                   shadowMismatches: mismatches,
                                   instrumentation: instr)
    }
}

public enum ResidentEpochBufferSizer {
    public static func sizes(config: ResidentEpochConfig) -> ResidentBufferSizes {
        let pairTapeBytes = config.pairCount * BFF.pairTapeSize
        let vizHeight = (config.programCount + config.visualizationWidth - 1)
            / config.visualizationWidth
        let vizBytes = config.visualizationEnabled
            ? config.visualizationWidth * vizHeight * 4
            : 0
        return ResidentBufferSizes(
            soupBytes: config.soupByteCount,
            permutationBytes: config.programCount * MemoryLayout<UInt32>.stride,
            pairResultBytes: config.pairCount * 5 * MemoryLayout<UInt32>.stride,
            pairInputCaptureBytes: config.capturePairTapes ? pairTapeBytes : 0,
            pairFinalCaptureBytes: config.capturePairTapes ? pairTapeBytes : 0,
            countersBytes: ResidentCounterLayout.wordCount * MemoryLayout<UInt32>.stride,
            programActivityBytes: config.programCount * MemoryLayout<UInt32>.stride,
            visualizationBytes: vizBytes)
    }
}

enum ResidentClock {
    static func now() -> Double {
        #if canImport(Darwin)
        return ProcessInfo.processInfo.systemUptime
        #else
        return DispatchTime.now().uptimeNanoseconds.doubleSeconds
        #endif
    }
}

private extension UInt64 {
    var doubleSeconds: Double { Double(self) / 1_000_000_000.0 }
}

#if canImport(Metal)
public final class ResidentMetalEpochRunner {
    public enum RunnerError: Error, CustomStringConvertible {
        case noDevice
        case commandQueueUnavailable
        case shaderSourceMissing
        case compileFailed(String)
        case kernelMissing(String)
        case bufferAllocationFailed(String)
        case commandEncodingFailed(String)
        case gpuExecutionFailed(String)
        case checkpointRequiredForDigest

        public var description: String {
            switch self {
            case .noDevice: return "no Metal device available"
            case .commandQueueUnavailable: return "could not create Metal command queue"
            case .shaderSourceMissing: return "BFFResidentEpoch.metal not found"
            case .compileFailed(let detail): return "resident shader compile failed: \(detail)"
            case .kernelMissing(let name): return "resident kernel '\(name)' not found"
            case .bufferAllocationFailed(let detail): return "buffer allocation failed: \(detail)"
            case .commandEncodingFailed(let detail): return "command encoding failed: \(detail)"
            case .gpuExecutionFailed(let detail): return "GPU execution failed: \(detail)"
            case .checkpointRequiredForDigest:
                return "digest requested without a checkpointed soup readback"
            }
        }
    }

    public let config: ResidentEpochConfig
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public private(set) var epoch: Int = 0

    private let mutatePipeline: MTLComputePipelineState
    private let planPipeline: MTLComputePipelineState
    private let evalScatterPipeline: MTLComputePipelineState
    private let visualizePipeline: MTLComputePipelineState

    private let soupBuffer: MTLBuffer
    private let permutationBuffer: MTLBuffer
    private let resultBuffer: MTLBuffer
    private let countersBuffer: MTLBuffer
    private let inputCaptureBuffer: MTLBuffer
    private let finalCaptureBuffer: MTLBuffer
    private let activityBuffer: MTLBuffer
    private let visualizationBuffer: MTLBuffer
    private let visualizationTexture: MTLTexture?
    private let bufferSizes: ResidentBufferSizes

    public var deviceName: String { device.name }

    public convenience init(config: ResidentEpochConfig) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RunnerError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RunnerError.commandQueueUnavailable
        }
        try self.init(config: config, device: device, commandQueue: queue)
    }

    public init(config: ResidentEpochConfig,
                device: MTLDevice,
                commandQueue: MTLCommandQueue) throws {
        self.config = config
        self.device = device
        self.commandQueue = commandQueue
        self.bufferSizes = ResidentEpochBufferSizer.sizes(config: config)

        guard let sourceURL = ShaderResourceLocator.url(forResource: "BFFResidentEpoch",
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
        self.mutatePipeline = try pipeline("bff_resident_mutate")
        self.planPipeline = try pipeline("bff_resident_plan_pairs")
        self.evalScatterPipeline = try pipeline("bff_resident_eval_scatter")
        self.visualizePipeline = try pipeline("bff_resident_visualize")

        func buffer(length: Int, label: String) throws -> MTLBuffer {
            let actualLength = max(1, length)
            guard let b = device.makeBuffer(length: actualLength,
                                            options: .storageModeShared) else {
                throw RunnerError.bufferAllocationFailed(label)
            }
            b.label = label
            return b
        }

        self.soupBuffer = try buffer(length: bufferSizes.soupBytes, label: "resident.soup")
        self.permutationBuffer = try buffer(length: bufferSizes.permutationBytes,
                                            label: "resident.permutation")
        self.resultBuffer = try buffer(length: bufferSizes.pairResultBytes,
                                       label: "resident.pairResults")
        self.countersBuffer = try buffer(length: bufferSizes.countersBytes,
                                         label: "resident.counters")
        self.inputCaptureBuffer = try buffer(length: max(bufferSizes.pairInputCaptureBytes, 1),
                                             label: "resident.inputCapture")
        self.finalCaptureBuffer = try buffer(length: max(bufferSizes.pairFinalCaptureBytes, 1),
                                             label: "resident.finalCapture")
        self.activityBuffer = try buffer(length: bufferSizes.programActivityBytes,
                                         label: "resident.activity")
        self.visualizationBuffer = try buffer(length: max(bufferSizes.visualizationBytes, 1),
                                              label: "resident.visualizationRGBA")

        if config.visualizationEnabled {
            let height = (config.programCount + config.visualizationWidth - 1)
                / config.visualizationWidth
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: config.visualizationWidth,
                height: max(1, height),
                mipmapped: false)
            desc.usage = [.shaderWrite, .shaderRead]
            guard let texture = device.makeTexture(descriptor: desc) else {
                throw RunnerError.bufferAllocationFailed("resident.visualizationTexture")
            }
            texture.label = "resident.visualizationTexture"
            self.visualizationTexture = texture
        } else {
            self.visualizationTexture = nil
        }

        let initial = config.initialSoup()
        initial.withUnsafeBytes { raw in
            soupBuffer.contents().copyMemory(from: raw.baseAddress!,
                                             byteCount: initial.count)
        }
    }

    @discardableResult
    public func runEpoch() throws -> ResidentEpochReport {
        let epochStart = ResidentClock.now()
        var timings: [ResidentKernelTiming] = []
        var readbackBytes = 0
        var parameterBytes = 0

        try runMutate(into: &timings, parameterBytes: &parameterBytes)
        try runPlan(into: &timings, parameterBytes: &parameterBytes)
        try runEvalScatter(into: &timings, parameterBytes: &parameterBytes)
        if config.visualizationEnabled {
            try runVisualize(into: &timings, parameterBytes: &parameterBytes)
        }

        let counterWords = readCounterWords()
        readbackBytes += bufferSizes.countersBytes
        let counters = ResidentEpochCounters(epoch: epoch, interactions: config.pairCount,
                                             words: counterWords)

        var captures: [ResidentPairCapture] = []
        captures.reserveCapacity(config.capturePairTapes ? config.pairCount : 0)
        if config.capturePairTapes {
            captures = readPairCaptures()
            readbackBytes += bufferSizes.pairInputCaptureBytes
                + bufferSizes.pairFinalCaptureBytes
                + bufferSizes.pairResultBytes
        }

        let checkpointNow = config.checkpointInterval > 0
            && ((epoch + 1) % config.checkpointInterval == 0)
        let checkpointStart = checkpointNow ? ResidentClock.now() : nil
        let checkpoint = checkpointNow ? readSoupCheckpoint() : nil
        let checkpointSeconds = checkpointStart.map { ResidentClock.now() - $0 }
        if let checkpoint { readbackBytes += checkpoint.count }
        let digest = checkpoint.map(SoupDigest.digest)

        let shadowCount = config.capturePairTapes ? config.resolvedShadowSampleCount : 0
        let shadowSample = ShadowSampler.sampleIndices(pairCount: config.pairCount,
                                                       sampleCount: shadowCount,
                                                       seed: config.seed,
                                                       epoch: epoch)
        var mismatches: [ShadowMismatch] = []
        if config.capturePairTapes {
            for idx in shadowSample {
                let c = captures[idx]
                if let mm = ShadowComparator.check(epoch: epoch, pairIndex: idx,
                                                   programA: c.programA,
                                                   programB: c.programB,
                                                   input: c.inputTape,
                                                   variant: config.variant,
                                                   stepBudget: config.stepBudget,
                                                   gpu: c.outcome) {
                    mismatches.append(mm)
                }
            }
        }

        epoch += 1
        let wall = ResidentClock.now() - epochStart
        let instr = ResidentEpochInstrumentation(
            epochWallSeconds: wall,
            checkpointSeconds: checkpointSeconds,
            epochsPerSecond: wall > 0 ? 1.0 / wall : 0,
            uploadBytes: epoch == 1 ? config.soupByteCount : 0,
            readbackBytes: readbackBytes,
            parameterBytes: parameterBytes,
            bufferSizes: bufferSizes,
            kernelTimings: timings)

        return ResidentEpochReport(counters: counters,
                                   digest: digest,
                                   checkpointSoup: checkpoint,
                                   capturedPairs: captures,
                                   shadowChecked: shadowSample.count,
                                   shadowMismatches: mismatches,
                                   instrumentation: instr)
    }

    private func runMutate(into timings: inout [ResidentKernelTiming],
                           parameterBytes: inout Int) throws {
        var params = ResidentEpochParams(seed: config.seed,
                                         epoch: UInt32(epoch),
                                         programCount: UInt32(config.programCount),
                                         pairCount: UInt32(config.pairCount),
                                         stepBudget: UInt32(config.stepBudget),
                                         mutationP32: config.mutationP32,
                                         variant: BFFEvalLayout.variantCode(config.variant),
                                         capturePairTapes: config.capturePairTapes ? 1 : 0,
                                         visualizationWidth: UInt32(config.visualizationWidth),
                                         reserved0: 0,
                                         reserved1: 0,
                                         reserved2: 0)
        parameterBytes += MemoryLayout<ResidentEpochParams>.stride
        try encodeTimed(name: "mutate", pipeline: mutatePipeline, timings: &timings) { cb in
            guard let blit = cb.makeBlitCommandEncoder() else {
                throw RunnerError.commandEncodingFailed("mutate counter fill")
            }
            blit.fill(buffer: countersBuffer, range: 0..<bufferSizes.countersBytes, value: 0)
            blit.endEncoding()
        } encode: { enc in
            enc.setComputePipelineState(mutatePipeline)
            enc.setBuffer(soupBuffer, offset: 0, index: 0)
            enc.setBuffer(countersBuffer, offset: 0, index: 1)
            enc.setBytes(&params, length: MemoryLayout<ResidentEpochParams>.stride, index: 2)
            dispatchThreads(count: config.soupByteCount, pipeline: mutatePipeline, encoder: enc)
        }
    }

    private func runPlan(into timings: inout [ResidentKernelTiming],
                         parameterBytes: inout Int) throws {
        var params = residentParams()
        parameterBytes += MemoryLayout<ResidentEpochParams>.stride
        try encodeTimed(name: "plan", pipeline: planPipeline, timings: &timings) { enc in
            enc.setComputePipelineState(planPipeline)
            enc.setBuffer(permutationBuffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<ResidentEpochParams>.stride, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
    }

    private func runEvalScatter(into timings: inout [ResidentKernelTiming],
                                parameterBytes: inout Int) throws {
        var params = residentParams()
        parameterBytes += MemoryLayout<ResidentEpochParams>.stride
        try encodeTimed(name: "eval-scatter", pipeline: evalScatterPipeline,
                        timings: &timings) { cb in
            guard let blit = cb.makeBlitCommandEncoder() else {
                throw RunnerError.commandEncodingFailed("eval activity fill")
            }
            blit.fill(buffer: activityBuffer, range: 0..<bufferSizes.programActivityBytes, value: 0)
            blit.fill(buffer: resultBuffer, range: 0..<bufferSizes.pairResultBytes, value: 0)
            blit.endEncoding()
        } encode: { enc in
            enc.setComputePipelineState(evalScatterPipeline)
            enc.setBuffer(soupBuffer, offset: 0, index: 0)
            enc.setBuffer(permutationBuffer, offset: 0, index: 1)
            enc.setBuffer(resultBuffer, offset: 0, index: 2)
            enc.setBuffer(countersBuffer, offset: 0, index: 3)
            enc.setBuffer(inputCaptureBuffer, offset: 0, index: 4)
            enc.setBuffer(finalCaptureBuffer, offset: 0, index: 5)
            enc.setBuffer(activityBuffer, offset: 0, index: 6)
            enc.setBytes(&params, length: MemoryLayout<ResidentEpochParams>.stride, index: 7)
            dispatchThreads(count: config.pairCount, pipeline: evalScatterPipeline, encoder: enc)
        }
    }

    private func runVisualize(into timings: inout [ResidentKernelTiming],
                              parameterBytes: inout Int) throws {
        var params = residentParams()
        parameterBytes += MemoryLayout<ResidentEpochParams>.stride
        try encodeTimed(name: "visualize", pipeline: visualizePipeline, timings: &timings) { enc in
            enc.setComputePipelineState(visualizePipeline)
            enc.setBuffer(soupBuffer, offset: 0, index: 0)
            enc.setBuffer(activityBuffer, offset: 0, index: 1)
            enc.setBuffer(visualizationBuffer, offset: 0, index: 2)
            enc.setBytes(&params, length: MemoryLayout<ResidentEpochParams>.stride, index: 3)
            if let texture = visualizationTexture {
                enc.setTexture(texture, index: 0)
            }
            dispatchThreads(count: config.programCount, pipeline: visualizePipeline, encoder: enc)
        }
    }

    private func encodeTimed(name: String,
                             pipeline: MTLComputePipelineState,
                             timings: inout [ResidentKernelTiming],
                             _ encode: (MTLComputeCommandEncoder) throws -> Void)
        throws {
        try encodeTimed(name: name, pipeline: pipeline, timings: &timings,
                        precompute: nil, encode: encode)
    }

    private func encodeTimed(name: String,
                             pipeline: MTLComputePipelineState,
                             timings: inout [ResidentKernelTiming],
                             precompute: ((MTLCommandBuffer) throws -> Void)?,
                             encode: (MTLComputeCommandEncoder) throws -> Void)
        throws {
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw RunnerError.commandEncodingFailed("\(name) command buffer")
        }
        cb.label = "resident.\(name)"
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
        timings.append(ResidentKernelTiming(name: name, hostSeconds: host, gpuSeconds: gpu))
        _ = pipeline
    }

    private func dispatchThreads(count: Int, pipeline: MTLComputePipelineState,
                                 encoder: MTLComputeCommandEncoder) {
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let groups = (count + width - 1) / width
        encoder.dispatchThreadgroups(MTLSize(width: max(1, groups), height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    private func residentParams() -> ResidentEpochParams {
        ResidentEpochParams(seed: config.seed,
                            epoch: UInt32(epoch),
                            programCount: UInt32(config.programCount),
                            pairCount: UInt32(config.pairCount),
                            stepBudget: UInt32(config.stepBudget),
                            mutationP32: config.mutationP32,
                            variant: BFFEvalLayout.variantCode(config.variant),
                            capturePairTapes: config.capturePairTapes ? 1 : 0,
                            visualizationWidth: UInt32(config.visualizationWidth),
                            reserved0: 0,
                            reserved1: 0,
                            reserved2: 0)
    }

    private func readCounterWords() -> [UInt32] {
        (0..<ResidentCounterLayout.wordCount).map { i in
            countersBuffer.contents()
                .load(fromByteOffset: i * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
    }

    private func readSoupCheckpoint() -> [UInt8] {
        [UInt8](UnsafeRawBufferPointer(start: soupBuffer.contents(),
                                       count: config.soupByteCount))
    }

    private func readPairCaptures() -> [ResidentPairCapture] {
        var out: [ResidentPairCapture] = []
        out.reserveCapacity(config.pairCount)
        let resultStride = 5 * MemoryLayout<UInt32>.stride
        for pairIndex in 0..<config.pairCount {
            let a = permutationBuffer.contents()
                .load(fromByteOffset: (2 * pairIndex) * MemoryLayout<UInt32>.stride,
                      as: UInt32.self)
            let b = permutationBuffer.contents()
                .load(fromByteOffset: (2 * pairIndex + 1) * MemoryLayout<UInt32>.stride,
                      as: UInt32.self)
            let tapeOffset = pairIndex * BFF.pairTapeSize
            let input = [UInt8](UnsafeRawBufferPointer(
                start: inputCaptureBuffer.contents().advanced(by: tapeOffset),
                count: BFF.pairTapeSize))
            let final = [UInt8](UnsafeRawBufferPointer(
                start: finalCaptureBuffer.contents().advanced(by: tapeOffset),
                count: BFF.pairTapeSize))
            let resultBase = pairIndex * resultStride
            let words = (0..<5).map { i in
                resultBuffer.contents()
                    .load(fromByteOffset: resultBase + i * MemoryLayout<UInt32>.stride,
                          as: UInt32.self)
            }
            let outcome = GPUPairOutcome(finalTape: final, steps: words[0],
                                         noopSteps: words[1],
                                         copyWrites: words[2],
                                         loopOps: words[3],
                                         halt: words[4])
            out.append(ResidentPairCapture(pairIndex: pairIndex,
                                           programA: a, programB: b,
                                           inputTape: input,
                                           finalTape: final,
                                           outcome: outcome))
        }
        return out
    }
}

private struct ResidentEpochParams {
    var seed: UInt32
    var epoch: UInt32
    var programCount: UInt32
    var pairCount: UInt32
    var stepBudget: UInt32
    var mutationP32: UInt32
    var variant: UInt32
    var capturePairTapes: UInt32
    var visualizationWidth: UInt32
    var reserved0: UInt32
    var reserved1: UInt32
    var reserved2: UInt32
}
#endif
