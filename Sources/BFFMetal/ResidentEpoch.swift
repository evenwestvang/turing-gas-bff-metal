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
    /// Experimental resident pairing planner. Defaults to the existing keyed GPU
    /// bijection so prior invocations keep their behavior unless explicitly changed.
    public var planner: ResidentPairingPlanner
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
    /// Opt-in CPU-side pairing distribution diagnostics. These require reading or
    /// retaining the permutation and are deliberately off for throughput runs.
    public var pairingDiagnosticsEnabled: Bool

    /// Resident planner/pairing mode. This experimental path is not Fisher-Yates
    /// trajectory-compatible with `Simulation` or `SoupRunner` unless the
    /// `cpu-upload-fisher-yates-v1` counterfactual planner is selected.
    public var pairingModeID: String { planner.identifier }
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
                planner: ResidentPairingPlanner = .keyed,
                shadowSampleCount: Int? = 0,
                checkpointInterval: Int = 0,
                capturePairTapes: Bool = false,
                visualizationEnabled: Bool = false,
                visualizationWidth: Int = 512,
                pairingDiagnosticsEnabled: Bool = false) throws {
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
        self.planner = planner
        self.shadowSampleCount = shadowSampleCount
        self.checkpointInterval = checkpointInterval
        self.capturePairTapes = capturePairTapes
        self.visualizationEnabled = visualizationEnabled
        self.visualizationWidth = visualizationWidth
        self.pairingDiagnosticsEnabled = pairingDiagnosticsEnabled
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

public enum ResidentSnapshotLayout {
    public enum LayoutError: Error, Equatable, CustomStringConvertible {
        case programCountNotPositive(Int)
        case programCountOverflow(Int)
        case programIDOutOfRange(Int, programCount: Int)
        case byteIndexOutOfRange(Int)

        public var description: String {
            switch self {
            case .programCountNotPositive(let n):
                return "program count \(n) must be positive"
            case .programCountOverflow(let n):
                return "program count \(n) overflows resident snapshot byte count"
            case .programIDOutOfRange(let id, let programCount):
                return "program id \(id) out of range 0..<\(programCount)"
            case .byteIndexOutOfRange(let byte):
                return "byte index \(byte) out of range 0..<\(BFF.tapeSize)"
            }
        }
    }

    public static let programByteCount = BFF.tapeSize

    public static func checkedSoupByteCount(programCount: Int) throws -> Int {
        guard programCount > 0 else {
            throw LayoutError.programCountNotPositive(programCount)
        }
        guard programCount <= Int.max / programByteCount else {
            throw LayoutError.programCountOverflow(programCount)
        }
        return programCount * programByteCount
    }

    public static func byteOffset(programID: Int, byteIndex: Int,
                                  programCount: Int) throws -> Int {
        _ = try checkedSoupByteCount(programCount: programCount)
        guard programID >= 0 && programID < programCount else {
            throw LayoutError.programIDOutOfRange(programID, programCount: programCount)
        }
        guard byteIndex >= 0 && byteIndex < programByteCount else {
            throw LayoutError.byteIndexOutOfRange(byteIndex)
        }
        return programID * programByteCount + byteIndex
    }
}

public struct ResidentSnapshotReservation: Equatable, Sendable, Codable {
    public var slot: Int
    public var generation: UInt64

    public init(slot: Int, generation: UInt64) {
        self.slot = slot
        self.generation = generation
    }
}

public struct ResidentSnapshotToken: Equatable, Sendable, Codable {
    public var slot: Int
    public var generation: UInt64
    public var sourceEpoch: Int
    public var byteCount: Int

    public init(slot: Int, generation: UInt64, sourceEpoch: Int, byteCount: Int) {
        self.slot = slot
        self.generation = generation
        self.sourceEpoch = sourceEpoch
        self.byteCount = byteCount
    }
}

public struct ResidentSnapshotSlotDiagnostics: Equatable, Sendable, Codable {
    public var slot: Int
    public var generation: UInt64?
    public var sourceEpoch: Int?
    public var byteCount: Int?
    public var isWriting: Bool
    public var isPublished: Bool
    public var activeLeases: Int
}

public struct ResidentSnapshotRingDiagnostics: Equatable, Sendable, Codable {
    public var slotCount: Int
    public var expectedByteCount: Int
    public var nextGeneration: UInt64
    public var publishedSlot: Int?
    public var publishedGeneration: UInt64?
    public var publishedSourceEpoch: Int?
    public var activeLeaseCount: Int
    public var writingSlotCount: Int
    public var reservationCount: Int
    public var publishCount: Int
    public var skippedReservationCount: Int
    public var cancelledReservationCount: Int
    public var stalePublicationCount: Int
    public var failedAcquireCount: Int
    public var staleReleaseCount: Int
    public var generationExhaustedReservationCount: Int
    public var lastBlitHostSeconds: Double?
    public var lastBlitGPUSeconds: Double?
    public var slots: [ResidentSnapshotSlotDiagnostics]
}

public struct ResidentSnapshotRingState: Sendable {
    private struct Slot: Sendable {
        var generation: UInt64?
        var sourceEpoch: Int?
        var byteCount: Int?
        var isWriting = false
        var activeLeases = 0
    }

    public enum StateError: Error, Equatable, CustomStringConvertible {
        case invalidSlotCount(Int)
        case invalidExpectedByteCount(Int)

        public var description: String {
            switch self {
            case .invalidSlotCount(let n):
                return "snapshot ring slot count \(n) must be positive"
            case .invalidExpectedByteCount(let n):
                return "snapshot ring byte count \(n) must be positive"
            }
        }
    }

    private var slots: [Slot]
    private var publishedSlot: Int?
    public let expectedByteCount: Int
    public private(set) var nextGeneration: UInt64 = 1
    private var reservationCount = 0
    private var publishCount = 0
    private var skippedReservationCount = 0
    private var cancelledReservationCount = 0
    private var stalePublicationCount = 0
    private var failedAcquireCount = 0
    private var staleReleaseCount = 0
    private var generationExhaustedReservationCount = 0
    private var lastBlitHostSeconds: Double?
    private var lastBlitGPUSeconds: Double?

    public init(slotCount: Int, expectedByteCount: Int) throws {
        try self.init(slotCount: slotCount,
                      expectedByteCount: expectedByteCount,
                      initialNextGeneration: 1)
    }

    init(slotCount: Int, expectedByteCount: Int,
         initialNextGeneration: UInt64) throws {
        guard slotCount > 0 else { throw StateError.invalidSlotCount(slotCount) }
        guard expectedByteCount > 0 else {
            throw StateError.invalidExpectedByteCount(expectedByteCount)
        }
        self.slots = [Slot](repeating: Slot(), count: slotCount)
        self.expectedByteCount = expectedByteCount
        self.nextGeneration = initialNextGeneration
    }

    public mutating func reserveForWrite() -> ResidentSnapshotReservation? {
        guard nextGeneration < UInt64.max else {
            skippedReservationCount += 1
            generationExhaustedReservationCount += 1
            return nil
        }
        guard let slot = slots.indices.first(where: { index in
            index != publishedSlot && !slots[index].isWriting && slots[index].activeLeases == 0
        }) else {
            skippedReservationCount += 1
            return nil
        }
        let generation = nextGeneration
        nextGeneration += 1
        slots[slot].generation = generation
        slots[slot].sourceEpoch = nil
        slots[slot].byteCount = nil
        slots[slot].isWriting = true
        reservationCount += 1
        return ResidentSnapshotReservation(slot: slot, generation: generation)
    }

    @discardableResult
    public mutating func publish(_ reservation: ResidentSnapshotReservation,
                                 sourceEpoch: Int,
                                 byteCount: Int,
                                 blitHostSeconds: Double?,
                                 blitGPUSeconds: Double?) -> ResidentSnapshotToken? {
        guard slots.indices.contains(reservation.slot),
              slots[reservation.slot].isWriting,
              slots[reservation.slot].generation == reservation.generation,
              byteCount == expectedByteCount else {
            cancel(reservation)
            return nil
        }
        if let publishedSlot,
           let publishedGeneration = slots[publishedSlot].generation,
           publishedGeneration > reservation.generation {
            slots[reservation.slot].isWriting = false
            slots[reservation.slot].sourceEpoch = nil
            slots[reservation.slot].byteCount = nil
            stalePublicationCount += 1
            return nil
        }
        slots[reservation.slot].isWriting = false
        slots[reservation.slot].sourceEpoch = sourceEpoch
        slots[reservation.slot].byteCount = byteCount
        publishedSlot = reservation.slot
        publishCount += 1
        lastBlitHostSeconds = blitHostSeconds
        lastBlitGPUSeconds = blitGPUSeconds
        return ResidentSnapshotToken(slot: reservation.slot,
                                     generation: reservation.generation,
                                     sourceEpoch: sourceEpoch,
                                     byteCount: byteCount)
    }

    public mutating func cancel(_ reservation: ResidentSnapshotReservation) {
        guard slots.indices.contains(reservation.slot),
              slots[reservation.slot].isWriting,
              slots[reservation.slot].generation == reservation.generation else {
            return
        }
        slots[reservation.slot].isWriting = false
        slots[reservation.slot].sourceEpoch = nil
        slots[reservation.slot].byteCount = nil
        cancelledReservationCount += 1
    }

    public mutating func acquire(expectedByteCount: Int) -> ResidentSnapshotToken? {
        guard expectedByteCount == self.expectedByteCount,
              let slot = publishedSlot,
              slots.indices.contains(slot),
              !slots[slot].isWriting,
              slots[slot].byteCount == expectedByteCount,
              let generation = slots[slot].generation,
              let sourceEpoch = slots[slot].sourceEpoch else {
            failedAcquireCount += 1
            return nil
        }
        slots[slot].activeLeases += 1
        return ResidentSnapshotToken(slot: slot,
                                     generation: generation,
                                     sourceEpoch: sourceEpoch,
                                     byteCount: expectedByteCount)
    }

    public mutating func release(_ token: ResidentSnapshotToken) {
        guard slots.indices.contains(token.slot),
              slots[token.slot].generation == token.generation,
              slots[token.slot].activeLeases > 0 else {
            staleReleaseCount += 1
            return
        }
        slots[token.slot].activeLeases -= 1
    }

    public var diagnostics: ResidentSnapshotRingDiagnostics {
        let activeLeaseCount = slots.reduce(0) { $0 + $1.activeLeases }
        let writingSlotCount = slots.filter(\.isWriting).count
        let publishedGeneration = publishedSlot.flatMap { slots[$0].generation }
        let publishedSourceEpoch = publishedSlot.flatMap { slots[$0].sourceEpoch }
        return ResidentSnapshotRingDiagnostics(
            slotCount: slots.count,
            expectedByteCount: expectedByteCount,
            nextGeneration: nextGeneration,
            publishedSlot: publishedSlot,
            publishedGeneration: publishedGeneration,
            publishedSourceEpoch: publishedSourceEpoch,
            activeLeaseCount: activeLeaseCount,
            writingSlotCount: writingSlotCount,
            reservationCount: reservationCount,
            publishCount: publishCount,
            skippedReservationCount: skippedReservationCount,
            cancelledReservationCount: cancelledReservationCount,
            stalePublicationCount: stalePublicationCount,
            failedAcquireCount: failedAcquireCount,
            staleReleaseCount: staleReleaseCount,
            generationExhaustedReservationCount: generationExhaustedReservationCount,
            lastBlitHostSeconds: lastBlitHostSeconds,
            lastBlitGPUSeconds: lastBlitGPUSeconds,
            slots: slots.enumerated().map { index, slot in
                ResidentSnapshotSlotDiagnostics(
                    slot: index,
                    generation: slot.generation,
                    sourceEpoch: slot.sourceEpoch,
                    byteCount: slot.byteCount,
                    isWriting: slot.isWriting,
                    isPublished: index == publishedSlot,
                    activeLeases: slot.activeLeases)
            })
    }
}

public enum ResidentRenderFallbackReason: Equatable, Sendable, Codable {
    case unavailable
    case invalidExpectedByteCount
    case wrongByteCount(expected: Int, actual: Int)
    case invalidExpectedOverviewSize(width: Int, height: Int)
    case wrongOverviewSize(expectedWidth: Int, expectedHeight: Int,
                           actualWidth: Int, actualHeight: Int)
    case farLOD(microBlend: Float)
}

public struct ResidentRenderDecision: Equatable, Sendable, Codable {
    public enum Source: Equatable, Sendable, Codable {
        case leasedSnapshot
        case liveOverview
    }

    public var source: Source
    public var fallbackReason: ResidentRenderFallbackReason?

    public var usesLeasedSnapshot: Bool { source == .leasedSnapshot }
    public var usesCloseLOD: Bool { usesLeasedSnapshot }

    public init(source: Source,
                fallbackReason: ResidentRenderFallbackReason?) {
        self.source = source
        self.fallbackReason = fallbackReason
    }

    public static func requiresSnapshotLease(microBlend: Float) -> Bool {
        microBlend > 0
    }

    public static func decide(expectedByteCount: Int?,
                              leaseByteCount: Int?,
                              expectedOverviewWidth: Int,
                              expectedOverviewHeight: Int,
                              leaseOverviewWidth: Int?,
                              leaseOverviewHeight: Int?,
                              microBlend: Float) -> ResidentRenderDecision {
        guard requiresSnapshotLease(microBlend: microBlend) else {
            return ResidentRenderDecision(source: .liveOverview,
                                          fallbackReason: .farLOD(microBlend: microBlend))
        }
        guard let expectedByteCount, expectedByteCount > 0 else {
            return ResidentRenderDecision(source: .liveOverview,
                                          fallbackReason: .invalidExpectedByteCount)
        }
        guard expectedOverviewWidth > 0, expectedOverviewHeight > 0 else {
            return ResidentRenderDecision(
                source: .liveOverview,
                fallbackReason: .invalidExpectedOverviewSize(width: expectedOverviewWidth,
                                                             height: expectedOverviewHeight))
        }
        guard let leaseByteCount else {
            return ResidentRenderDecision(source: .liveOverview,
                                          fallbackReason: .unavailable)
        }
        guard leaseByteCount == expectedByteCount else {
            return ResidentRenderDecision(
                source: .liveOverview,
                fallbackReason: .wrongByteCount(expected: expectedByteCount,
                                                actual: leaseByteCount))
        }
        guard let leaseOverviewWidth, let leaseOverviewHeight else {
            return ResidentRenderDecision(source: .liveOverview,
                                          fallbackReason: .unavailable)
        }
        guard leaseOverviewWidth == expectedOverviewWidth,
              leaseOverviewHeight == expectedOverviewHeight else {
            return ResidentRenderDecision(
                source: .liveOverview,
                fallbackReason: .wrongOverviewSize(expectedWidth: expectedOverviewWidth,
                                                   expectedHeight: expectedOverviewHeight,
                                                   actualWidth: leaseOverviewWidth,
                                                   actualHeight: leaseOverviewHeight))
        }
        return ResidentRenderDecision(source: .leasedSnapshot, fallbackReason: nil)
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
    public var plannerCPUGenerationSeconds: Double
    public var permutationUploadSeconds: Double
    public var permutationUploadBytes: Int
    public var plannerGPUSeconds: Double?
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
    public var permutationFingerprint: UInt64?
    public var pairingDiagnostics: PairingDistributionDiagnostics?
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
        let plannerStart = ResidentClock.now()
        let perm = config.planner.permutation(count: config.programCount,
                                              seed: config.seed, epoch: e)
        let plannerCPUSeconds = ResidentClock.now() - plannerStart

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
        let shouldFingerprintPermutation = config.capturePairTapes
            || config.pairingDiagnosticsEnabled
        let permutationFingerprint = shouldFingerprintPermutation
            ? PermutationDigest.digest(perm)
            : nil
        let pairingDiagnostics = config.pairingDiagnosticsEnabled
            ? PairingDistributionDiagnostics.analyze(permutation: perm)
            : nil
        epoch += 1

        let wall = ResidentClock.now() - start
        let sizes = ResidentEpochBufferSizer.sizes(config: config)
        let instr = ResidentEpochInstrumentation(
            epochWallSeconds: wall,
            checkpointSeconds: checkpointEnabled ? 0 : nil,
            plannerCPUGenerationSeconds: plannerCPUSeconds,
            permutationUploadSeconds: 0,
            permutationUploadBytes: 0,
            plannerGPUSeconds: nil,
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
                                   permutationFingerprint: permutationFingerprint,
                                   pairingDiagnostics: pairingDiagnostics,
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
public final class ResidentGPUSnapshotLease: @unchecked Sendable {
    public let buffer: MTLBuffer
    public let overviewTexture: MTLTexture
    public let slot: Int
    public let generation: UInt64
    public let sourceEpoch: Int
    public let byteCount: Int

    private let lock = NSLock()
    private var hasReleased = false
    private let releaseBody: @Sendable (ResidentSnapshotToken) -> Void

    fileprivate init(buffer: MTLBuffer,
                     overviewTexture: MTLTexture,
                     token: ResidentSnapshotToken,
                     release: @escaping @Sendable (ResidentSnapshotToken) -> Void) {
        self.buffer = buffer
        self.overviewTexture = overviewTexture
        self.slot = token.slot
        self.generation = token.generation
        self.sourceEpoch = token.sourceEpoch
        self.byteCount = token.byteCount
        self.releaseBody = release
    }

    public func release() {
        let token: ResidentSnapshotToken?
        lock.lock()
        if hasReleased {
            token = nil
        } else {
            hasReleased = true
            token = ResidentSnapshotToken(slot: slot,
                                          generation: generation,
                                          sourceEpoch: sourceEpoch,
                                          byteCount: byteCount)
        }
        lock.unlock()
        if let token {
            releaseBody(token)
        }
    }

    public func releaseOnCommandBufferCompletion(_ commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [self] _ in
            release()
        }
    }

    deinit {
        release()
    }
}

private final class ResidentGPUSnapshotRing: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ResidentSnapshotRingState
    private let buffers: [MTLBuffer]
    private let overviewTextures: [MTLTexture]

    init(device: MTLDevice, slotCount: Int, byteCount: Int,
         overviewWidth: Int, overviewHeight: Int) throws {
        self.state = try ResidentSnapshotRingState(slotCount: slotCount,
                                                   expectedByteCount: byteCount)
        var builtBuffers: [MTLBuffer] = []
        var builtTextures: [MTLTexture] = []
        builtBuffers.reserveCapacity(slotCount)
        builtTextures.reserveCapacity(slotCount)
        let overviewDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: overviewWidth,
            height: max(1, overviewHeight),
            mipmapped: false)
        overviewDesc.usage = .shaderRead
        overviewDesc.storageMode = .private
        for slot in 0..<slotCount {
            guard let buffer = device.makeBuffer(length: byteCount,
                                                 options: .storageModePrivate) else {
                throw ResidentMetalEpochRunner.RunnerError
                    .bufferAllocationFailed("resident.snapshot[\(slot)]")
            }
            buffer.label = "resident.snapshot[\(slot)]"
            guard let texture = device.makeTexture(descriptor: overviewDesc) else {
                throw ResidentMetalEpochRunner.RunnerError
                    .bufferAllocationFailed("resident.snapshotOverview[\(slot)]")
            }
            texture.label = "resident.snapshotOverview[\(slot)]"
            builtBuffers.append(buffer)
            builtTextures.append(texture)
        }
        self.buffers = builtBuffers
        self.overviewTextures = builtTextures
    }

    func reserveForWrite() -> (ResidentSnapshotReservation, MTLBuffer, MTLTexture)? {
        lock.lock()
        let reservation = state.reserveForWrite()
        lock.unlock()
        guard let reservation else { return nil }
        return (reservation, buffers[reservation.slot], overviewTextures[reservation.slot])
    }

    func publish(_ reservation: ResidentSnapshotReservation,
                 sourceEpoch: Int,
                 byteCount: Int,
                 blitHostSeconds: Double?,
                 blitGPUSeconds: Double?) {
        lock.lock()
        _ = state.publish(reservation,
                          sourceEpoch: sourceEpoch,
                          byteCount: byteCount,
                          blitHostSeconds: blitHostSeconds,
                          blitGPUSeconds: blitGPUSeconds)
        lock.unlock()
    }

    func cancel(_ reservation: ResidentSnapshotReservation) {
        lock.lock()
        state.cancel(reservation)
        lock.unlock()
    }

    func acquire(expectedByteCount: Int) -> ResidentGPUSnapshotLease? {
        lock.lock()
        let token = state.acquire(expectedByteCount: expectedByteCount)
        lock.unlock()
        guard let token else { return nil }
        return ResidentGPUSnapshotLease(buffer: buffers[token.slot],
                                        overviewTexture: overviewTextures[token.slot],
                                        token: token) { [weak self] token in
            self?.release(token)
        }
    }

    var diagnostics: ResidentSnapshotRingDiagnostics {
        lock.lock()
        let snapshot = state.diagnostics
        lock.unlock()
        return snapshot
    }

    private func release(_ token: ResidentSnapshotToken) {
        lock.lock()
        state.release(token)
        lock.unlock()
    }
}

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
    private let snapshotRing: ResidentGPUSnapshotRing
    private let bufferSizes: ResidentBufferSizes

    public var deviceName: String { device.name }
    public var residentVisualizationTexture: MTLTexture? { visualizationTexture }
    public var residentSnapshotDiagnostics: ResidentSnapshotRingDiagnostics {
        snapshotRing.diagnostics
    }

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
        let visualizationHeight = (config.programCount + config.visualizationWidth - 1)
            / config.visualizationWidth
        self.snapshotRing = try ResidentGPUSnapshotRing(device: device,
                                                        slotCount: 3,
                                                        byteCount: bufferSizes.soupBytes,
                                                        overviewWidth: config.visualizationWidth,
                                                        overviewHeight: visualizationHeight)

        if config.visualizationEnabled {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: config.visualizationWidth,
                height: max(1, visualizationHeight),
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

    public func acquireResidentSnapshot(expectedByteCount: Int) -> ResidentGPUSnapshotLease? {
        snapshotRing.acquire(expectedByteCount: expectedByteCount)
    }

    @discardableResult
    public func runEpoch() throws -> ResidentEpochReport {
        let epochStart = ResidentClock.now()
        var timings: [ResidentKernelTiming] = []
        var readbackBytes = 0
        var parameterBytes = 0
        var plannerCPUGenerationSeconds = 0.0
        var permutationUploadSeconds = 0.0
        var permutationUploadBytes = 0
        var plannerGPUSeconds: Double?

        try runMutate(into: &timings, parameterBytes: &parameterBytes)
        switch config.planner {
        case .keyed:
            try runPlan(into: &timings, parameterBytes: &parameterBytes)
            if let planTiming = timings.last, planTiming.name == "plan" {
                plannerGPUSeconds = planTiming.gpuSeconds
            }
        case .cpuUpload:
            let upload = uploadCPUFisherYatesPermutation()
            plannerCPUGenerationSeconds = upload.generationSeconds
            permutationUploadSeconds = upload.copySeconds
            permutationUploadBytes = upload.byteCount
        }
        try runEvalScatter(into: &timings, parameterBytes: &parameterBytes)
        if config.visualizationEnabled {
            try runVisualize(into: &timings, parameterBytes: &parameterBytes)
        }
        scheduleSnapshotPublication(sourceEpoch: epoch + 1)

        let counterWords = readCounterWords()
        readbackBytes += bufferSizes.countersBytes
        let counters = ResidentEpochCounters(epoch: epoch, interactions: config.pairCount,
                                             words: counterWords)

        var captures: [ResidentPairCapture] = []
        captures.reserveCapacity(config.capturePairTapes ? config.pairCount : 0)
        var permutationSnapshot: [UInt32]?
        if config.capturePairTapes || config.pairingDiagnosticsEnabled {
            permutationSnapshot = readPermutation()
            readbackBytes += bufferSizes.permutationBytes
        }
        if config.capturePairTapes, let permutationSnapshot {
            captures = readPairCaptures(permutation: permutationSnapshot)
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
        let permutationFingerprint = permutationSnapshot.map(PermutationDigest.digest)
        let pairingDiagnostics = config.pairingDiagnosticsEnabled
            ? permutationSnapshot.map { PairingDistributionDiagnostics.analyze(permutation: $0) }
            : nil

        epoch += 1
        let wall = ResidentClock.now() - epochStart
        let initialUploadBytes = epoch == 1 ? config.soupByteCount : 0
        let instr = ResidentEpochInstrumentation(
            epochWallSeconds: wall,
            checkpointSeconds: checkpointSeconds,
            plannerCPUGenerationSeconds: plannerCPUGenerationSeconds,
            permutationUploadSeconds: permutationUploadSeconds,
            permutationUploadBytes: permutationUploadBytes,
            plannerGPUSeconds: plannerGPUSeconds,
            epochsPerSecond: wall > 0 ? 1.0 / wall : 0,
            uploadBytes: initialUploadBytes + permutationUploadBytes,
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
                                   permutationFingerprint: permutationFingerprint,
                                   pairingDiagnostics: pairingDiagnostics,
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
            blit.fill(buffer: self.countersBuffer, range: 0..<self.bufferSizes.countersBytes, value: 0)
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
            dispatchThreads(count: config.programCount, pipeline: planPipeline, encoder: enc)
        }
    }

    private func uploadCPUFisherYatesPermutation()
        -> (generationSeconds: Double, copySeconds: Double, byteCount: Int) {
        let generationStart = ResidentClock.now()
        let perm = BFFRandom.pairingPermutation(count: config.programCount,
                                                seed: config.seed,
                                                epoch: UInt32(epoch))
        let generationSeconds = ResidentClock.now() - generationStart

        let byteCount = perm.count * MemoryLayout<UInt32>.stride
        let copyStart = ResidentClock.now()
        perm.withUnsafeBufferPointer { buf in
            permutationBuffer.contents().copyMemory(from: buf.baseAddress!,
                                                    byteCount: byteCount)
        }
        permutationBuffer.didModifyRange(0..<byteCount)
        let copySeconds = ResidentClock.now() - copyStart
        return (generationSeconds, copySeconds, byteCount)
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
            blit.fill(buffer: self.activityBuffer, range: 0..<self.bufferSizes.programActivityBytes, value: 0)
            blit.fill(buffer: self.resultBuffer, range: 0..<self.bufferSizes.pairResultBytes, value: 0)
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

    private func scheduleSnapshotPublication(sourceEpoch: Int) {
        guard let (reservation, snapshotBuffer, snapshotOverviewTexture) = snapshotRing.reserveForWrite() else {
            return
        }
        guard let visualizationTexture else {
            snapshotRing.cancel(reservation)
            return
        }
        guard visualizationTexture.width == snapshotOverviewTexture.width,
              visualizationTexture.height == snapshotOverviewTexture.height else {
            snapshotRing.cancel(reservation)
            return
        }
        guard let cb = commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            snapshotRing.cancel(reservation)
            return
        }
        cb.label = "resident.snapshot.blit"
        let byteCount = bufferSizes.soupBytes
        let start = ResidentClock.now()
        blit.copy(from: soupBuffer, sourceOffset: 0,
                  to: snapshotBuffer, destinationOffset: 0,
                  size: byteCount)
        let overviewSize = MTLSize(width: visualizationTexture.width,
                                   height: visualizationTexture.height,
                                   depth: 1)
        blit.copy(from: visualizationTexture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: overviewSize,
                  to: snapshotOverviewTexture,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.addCompletedHandler { [snapshotRing] completed in
            let hostSeconds = ResidentClock.now() - start
            guard completed.status == .completed, completed.error == nil else {
                snapshotRing.cancel(reservation)
                return
            }
            let gpuSpan = completed.gpuEndTime - completed.gpuStartTime
            let gpuSeconds = (completed.gpuStartTime > 0 && gpuSpan > 0) ? gpuSpan : nil
            snapshotRing.publish(reservation,
                                 sourceEpoch: sourceEpoch,
                                 byteCount: byteCount,
                                 blitHostSeconds: hostSeconds,
                                 blitGPUSeconds: gpuSeconds)
        }
        cb.commit()
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

    private func readPermutation() -> [UInt32] {
        (0..<config.programCount).map { i in
            permutationBuffer.contents()
                .load(fromByteOffset: i * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }
    }

    private func readPairCaptures(permutation: [UInt32]) -> [ResidentPairCapture] {
        var out: [ResidentPairCapture] = []
        out.reserveCapacity(config.pairCount)
        let resultStride = 5 * MemoryLayout<UInt32>.stride
        for pairIndex in 0..<config.pairCount {
            let a = permutation[2 * pairIndex]
            let b = permutation[2 * pairIndex + 1]
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
