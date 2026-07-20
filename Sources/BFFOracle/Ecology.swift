import Foundation

/// CPU-only oracle for BFF-Ecology v1.
///
/// Normative source: `Docs/Architecture/07-ecological-mode.md`. This engine is
/// deliberately separate from `Simulation`: it reuses `BFFInterpreter` for the
/// grounded per-pair semantics, but owns its own topology, scheduler, RNG wrapper,
/// mutation domains, counters, checkpoints, and replay digest.

// MARK: - Configuration

public struct EcologyConfig: Equatable, Sendable, Codable {
    public static let engineID = "ecology-v1"
    public static let topologyID = "torus-512x256-v1"
    public static let schedulerID = "edge-color-sync-v1"
    public static let rngContractID = "ecology-counter-pcg-v1"

    public var seed: UInt32
    public var stepBudget: Int
    public var mutationP32: UInt32
    public var variant: BFFVariant
    public var bracketMode: BracketMode

    public var evaluatorContractID: String {
        "bff-evaluator-v1:\(variant.rawValue):\(bracketMode.rawValue)"
    }

    public init(seed: UInt32,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                bracketMode: BracketMode = .dynamicScan) {
        precondition(stepBudget > 0, "step budget must be positive")
        self.seed = seed
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.bracketMode = bracketMode
    }

    enum CodingKeys: String, CodingKey {
        case engineID, topologyID, schedulerID, rngContractID
        case seed, stepBudget, mutationP32, variant, bracketMode
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.engineID, forKey: .engineID)
        try c.encode(Self.topologyID, forKey: .topologyID)
        try c.encode(Self.schedulerID, forKey: .schedulerID)
        try c.encode(Self.rngContractID, forKey: .rngContractID)
        try c.encode(seed, forKey: .seed)
        try c.encode(stepBudget, forKey: .stepBudget)
        try c.encode(mutationP32, forKey: .mutationP32)
        try c.encode(variant, forKey: .variant)
        try c.encode(bracketMode, forKey: .bracketMode)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let engine = try c.decode(String.self, forKey: .engineID)
        let topology = try c.decode(String.self, forKey: .topologyID)
        let scheduler = try c.decode(String.self, forKey: .schedulerID)
        let rng = try c.decode(String.self, forKey: .rngContractID)
        guard engine == Self.engineID else { throw EcologyContractError.engineID(engine) }
        guard topology == Self.topologyID else { throw EcologyContractError.topologyID(topology) }
        guard scheduler == Self.schedulerID else { throw EcologyContractError.schedulerID(scheduler) }
        guard rng == Self.rngContractID else { throw EcologyContractError.rngContractID(rng) }

        let budget = try c.decode(Int.self, forKey: .stepBudget)
        guard budget > 0 else { throw EcologyContractError.invalidStepBudget(budget) }
        self.seed = try c.decode(UInt32.self, forKey: .seed)
        self.stepBudget = budget
        self.mutationP32 = try c.decode(UInt32.self, forKey: .mutationP32)
        self.variant = try c.decode(BFFVariant.self, forKey: .variant)
        self.bracketMode = try c.decode(BracketMode.self, forKey: .bracketMode)
    }
}

public enum EcologyContractError: Error, Equatable, CustomStringConvertible {
    case magic(String)
    case schemaVersion(Int)
    case engineID(String)
    case topologyID(String)
    case schedulerID(String)
    case rngContractID(String)
    case evaluatorContractID(String)
    case invalidStepBudget(Int)
    case epochOutOfRange(UInt64)
    case elementOutOfRange(UInt32)
    case corruptSoup(String)

    public var description: String {
        switch self {
        case .magic(let s): return "unexpected ecology checkpoint magic '\(s)'"
        case .schemaVersion(let v): return "unsupported ecology schema version \(v)"
        case .engineID(let s): return "unexpected ecology engineID '\(s)'"
        case .topologyID(let s): return "unexpected ecology topologyID '\(s)'"
        case .schedulerID(let s): return "unexpected ecology schedulerID '\(s)'"
        case .rngContractID(let s): return "unexpected ecology rngContractID '\(s)'"
        case .evaluatorContractID(let s): return "unexpected ecology evaluatorContractID '\(s)'"
        case .invalidStepBudget(let n): return "step budget \(n) must be positive"
        case .epochOutOfRange(let e): return "epoch \(e) exceeds ecology UInt32 RNG range"
        case .elementOutOfRange(let i): return "element \(i) exceeds ecology 24-bit range"
        case .corruptSoup(let s): return "corrupt ecology soup: \(s)"
        }
    }
}

// MARK: - Topology and matching

public struct EcologyCoordinate: Equatable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct EcologyPair: Equatable, Sendable, Codable {
    public var index: Int
    public var a: Int
    public var b: Int
    public init(index: Int, a: Int, b: Int) {
        self.index = index
        self.a = a
        self.b = b
    }
}

public enum EcologyMatchingPhase: UInt8, CaseIterable, Equatable, Sendable, Codable {
    case horizontalEven = 0
    case horizontalOdd = 1
    case verticalEven = 2
    case verticalOdd = 3

    public init(epoch: UInt32) {
        self = Self(rawValue: UInt8(epoch & 3))!
    }

    public var label: String {
        switch self {
        case .horizontalEven: return "H0"
        case .horizontalOdd: return "H1"
        case .verticalEven: return "V0"
        case .verticalOdd: return "V1"
        }
    }
}

public enum EcologyTopology {
    public static let width = 512
    public static let height = 256
    public static let siteCount = width * height
    public static let pairCount = siteCount / 2
    public static let soupByteCount = siteCount * BFF.tapeSize
    public static let maxProgramByteElement = UInt32(soupByteCount - 1)
    public static let elementLimit: UInt32 = 1 << 24

    public static func siteID(x: Int, y: Int) -> Int {
        precondition((0..<width).contains(x), "x out of range")
        precondition((0..<height).contains(y), "y out of range")
        return y * width + x
    }

    public static func coordinate(siteID: Int) -> EcologyCoordinate {
        precondition((0..<siteCount).contains(siteID), "siteID out of range")
        return EcologyCoordinate(x: siteID % width, y: siteID / width)
    }

    public static func east(siteID: Int) -> Int {
        let c = coordinate(siteID: siteID)
        return Self.siteID(x: (c.x + 1) & (width - 1), y: c.y)
    }

    public static func south(siteID: Int) -> Int {
        let c = coordinate(siteID: siteID)
        return Self.siteID(x: c.x, y: (c.y + 1) & (height - 1))
    }

    public static func pair(at pairIndex: Int, phase: EcologyMatchingPhase) -> EcologyPair {
        precondition((0..<pairCount).contains(pairIndex), "pair index out of range")
        switch phase {
        case .horizontalEven, .horizontalOdd:
            let parity = phase == .horizontalEven ? 0 : 1
            let ownersPerRow = width / 2
            let y = pairIndex / ownersPerRow
            let ownerSlot = pairIndex % ownersPerRow
            let x = ownerSlot * 2 + parity
            let a = siteID(x: x, y: y)
            return EcologyPair(index: pairIndex, a: a, b: east(siteID: a))

        case .verticalEven, .verticalOdd:
            let parity = phase == .verticalEven ? 0 : 1
            let ownerRow = pairIndex / width
            let x = pairIndex % width
            let y = ownerRow * 2 + parity
            let a = siteID(x: x, y: y)
            return EcologyPair(index: pairIndex, a: a, b: south(siteID: a))
        }
    }

    public static func pairs(for phase: EcologyMatchingPhase) -> [EcologyPair] {
        (0..<pairCount).map { pair(at: $0, phase: phase) }
    }
}

// MARK: - Ecology RNG

public enum EcologyRNGPurpose: UInt8, CaseIterable, Equatable, Sendable, Codable {
    case initBytes = 0x01
    case mutateFlag = 0x02
    case mutateValue = 0x03
    case shadow = 0x04
    case futurePartner = 0x05
    case futureMovement = 0x06
}

public struct EcologyRNGSlot: Hashable, Equatable, Sendable, Codable {
    public var stream: UInt32
    public var index: UInt32
    public init(stream: UInt32, index: UInt32) {
        self.stream = stream
        self.index = index
    }
}

public enum EcologyRandom {
    public static let contractID = EcologyConfig.rngContractID
    public static let seedXor: UInt32 = 0xEC0E_C001

    @inlinable
    public static func ecologySeed(seed: UInt32) -> UInt32 {
        seed ^ seedXor
    }

    public static func encode(purpose: EcologyRNGPurpose,
                              epoch: UInt32,
                              element: UInt32) throws -> EcologyRNGSlot {
        guard element < EcologyTopology.elementLimit else {
            throw EcologyContractError.elementOutOfRange(element)
        }
        let p = UInt32(purpose.rawValue)
        let stream = (p << 24) | (epoch >> 8)
        let index = ((epoch & 0xFF) << 24) | element
        return EcologyRNGSlot(stream: stream, index: index)
    }

    public static func draw(seed: UInt32,
                            purpose: EcologyRNGPurpose,
                            epoch: UInt32,
                            element: UInt32) throws -> UInt32 {
        let slot = try encode(purpose: purpose, epoch: epoch, element: element)
        return BFFRandom.rng3(seed: ecologySeed(seed: seed),
                              stream: slot.stream,
                              index: slot.index)
    }

    public static func initialSoup(seed: UInt32) -> [UInt8] {
        var soup = [UInt8](repeating: 0, count: EcologyTopology.soupByteCount)
        for i in 0..<soup.count {
            let element = UInt32(i)
            soup[i] = UInt8(truncatingIfNeeded: try! draw(
                seed: seed, purpose: .initBytes, epoch: 0, element: element))
        }
        return soup
    }

    @discardableResult
    public static func mutate(soup: inout [UInt8],
                              seed: UInt32,
                              epoch: UInt32,
                              mutationP32: UInt32) -> Int {
        precondition(soup.count <= Int(EcologyTopology.elementLimit),
                     "ecology mutation element field overflow")
        guard mutationP32 > 0 else { return 0 }
        var mutated = 0
        for i in 0..<soup.count {
            let element = UInt32(i)
            let flag = try! draw(seed: seed, purpose: .mutateFlag,
                                 epoch: epoch, element: element)
            if flag < mutationP32 {
                let value = try! draw(seed: seed, purpose: .mutateValue,
                                      epoch: epoch, element: element)
                soup[i] = UInt8(truncatingIfNeeded: value)
                mutated += 1
            }
        }
        return mutated
    }
}

// MARK: - Digest

public enum EcologyDigest {
    public static func digest(_ soup: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for b in soup {
            hash = (hash ^ UInt64(b)) &* prime
        }
        return hash
    }

    public static func hexString(_ digest: UInt64) -> String {
        let s = String(digest, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }
}

// MARK: - Counters and site stats

public struct EcologyEpochCounters: Equatable, Sendable, Codable {
    public var epoch: UInt32
    public var phase: EcologyMatchingPhase
    public var interactions: Int
    public var mutationCount: Int
    public var totalRawSteps: Int
    public var totalNoopSteps: Int
    public var totalCommandSteps: Int
    public var totalLoopOps: Int
    public var totalCopyWrites: Int
    public var totalRemapEvents: Int
    public var haltBudget: Int
    public var haltPCOut: Int
    public var haltUnmatched: Int
    public var writeSites: Int
    public var writeConflicts: Int
    public var digest: UInt64

    public var haltAccounted: Int {
        haltBudget + haltPCOut + haltUnmatched
    }

    public init(epoch: UInt32,
                phase: EcologyMatchingPhase,
                interactions: Int = EcologyTopology.pairCount,
                mutationCount: Int = 0,
                totalRawSteps: Int = 0,
                totalNoopSteps: Int = 0,
                totalCommandSteps: Int = 0,
                totalLoopOps: Int = 0,
                totalCopyWrites: Int = 0,
                totalRemapEvents: Int = 0,
                haltBudget: Int = 0,
                haltPCOut: Int = 0,
                haltUnmatched: Int = 0,
                writeSites: Int = 0,
                writeConflicts: Int = 0,
                digest: UInt64 = 0) {
        self.epoch = epoch
        self.phase = phase
        self.interactions = interactions
        self.mutationCount = mutationCount
        self.totalRawSteps = totalRawSteps
        self.totalNoopSteps = totalNoopSteps
        self.totalCommandSteps = totalCommandSteps
        self.totalLoopOps = totalLoopOps
        self.totalCopyWrites = totalCopyWrites
        self.totalRemapEvents = totalRemapEvents
        self.haltBudget = haltBudget
        self.haltPCOut = haltPCOut
        self.haltUnmatched = haltUnmatched
        self.writeSites = writeSites
        self.writeConflicts = writeConflicts
        self.digest = digest
    }
}

public struct EcologySiteStats: Equatable, Sendable, Codable {
    public var siteID: Int
    public var partnerSiteID: Int
    public var pairIndex: Int
    public var epoch: UInt32
    public var phase: EcologyMatchingPhase
    public var rawSteps: Int
    public var noopSteps: Int
    public var commandSteps: Int
    public var halt: HaltReason
    public var copyWrites: Int
    public var loopOps: Int
    public var remapEvents: Int
}

// MARK: - Runner

public struct EcologyOracleRunner: Sendable {
    public let config: EcologyConfig
    public private(set) var soup: [UInt8]
    /// Next epoch to execute. Values above `UInt32.max` cannot be run because the
    /// v1 RNG counter layout carries exactly a 32-bit epoch.
    public private(set) var epoch: UInt64
    public private(set) var lastEpochCounters: EcologyEpochCounters?
    public private(set) var lastSiteStats: [EcologySiteStats]

    public var digest: UInt64 { EcologyDigest.digest(soup) }
    public var digestHex: String { EcologyDigest.hexString(digest) }

    public init(config: EcologyConfig) {
        self.config = config
        self.soup = EcologyRandom.initialSoup(seed: config.seed)
        self.epoch = 0
        self.lastEpochCounters = nil
        self.lastSiteStats = []
    }

    public init(config: EcologyConfig, soup: [UInt8], epoch: UInt64 = 0) throws {
        guard soup.count == EcologyTopology.soupByteCount else {
            throw EcologyContractError.corruptSoup(
                "decoded soup is \(soup.count) bytes, expected \(EcologyTopology.soupByteCount)")
        }
        guard epoch <= UInt64(UInt32.max) else {
            throw EcologyContractError.epochOutOfRange(epoch)
        }
        self.config = config
        self.soup = soup
        self.epoch = epoch
        self.lastEpochCounters = nil
        self.lastSiteStats = []
    }

    public init(checkpoint: EcologyCheckpoint) throws {
        let config = try checkpoint.config()
        let soup = try checkpoint.soupBytes()
        try self.init(config: config, soup: soup, epoch: checkpoint.epoch)
        self.lastEpochCounters = checkpoint.lastEpochCounters
    }

    public func program(at siteID: Int) -> [UInt8] {
        precondition((0..<EcologyTopology.siteCount).contains(siteID),
                     "siteID out of range")
        let start = siteID * BFF.tapeSize
        return Array(soup[start ..< start + BFF.tapeSize])
    }

    @discardableResult
    public mutating func runEpoch() throws -> EcologyEpochCounters {
        guard epoch <= UInt64(UInt32.max) else {
            throw EcologyContractError.epochOutOfRange(epoch)
        }
        let e = UInt32(epoch)
        let phase = EcologyMatchingPhase(epoch: e)

        var mutated = soup
        let mutationCount = EcologyRandom.mutate(soup: &mutated,
                                                 seed: config.seed,
                                                 epoch: e,
                                                 mutationP32: config.mutationP32)
        var newSoup = mutated
        var counters = EcologyEpochCounters(epoch: e, phase: phase)
        counters.mutationCount = mutationCount

        var stats = [EcologySiteStats]()
        stats.reserveCapacity(EcologyTopology.siteCount)
        var written = [UInt8](repeating: 0, count: EcologyTopology.siteCount)
        var resultCache: [[UInt8]: InteractionResult] = [:]

        for pairIndex in 0..<EcologyTopology.pairCount {
            let pair = EcologyTopology.pair(at: pairIndex, phase: phase)
            let rangeA = pair.a * BFF.tapeSize ..< (pair.a + 1) * BFF.tapeSize
            let rangeB = pair.b * BFF.tapeSize ..< (pair.b + 1) * BFF.tapeSize
            let pairTape = Array(mutated[rangeA]) + Array(mutated[rangeB])
            let result: InteractionResult
            if let cached = resultCache[pairTape] {
                result = cached
            } else {
                let evaluated = BFFInterpreter.run(
                    pairTape: pairTape,
                    variant: config.variant,
                    bracketMode: config.bracketMode,
                    stepBudget: config.stepBudget)
                resultCache[pairTape] = evaluated
                result = evaluated
            }

            newSoup.replaceSubrange(rangeA, with: result.tape[0..<BFF.tapeSize])
            newSoup.replaceSubrange(rangeB, with: result.tape[BFF.tapeSize..<BFF.pairTapeSize])

            written[pair.a] &+= 1
            written[pair.b] &+= 1

            counters.totalRawSteps += result.steps
            counters.totalNoopSteps += result.noopSteps
            counters.totalCommandSteps += result.commandSteps
            counters.totalLoopOps += result.loopOps
            counters.totalCopyWrites += result.copyWrites
            counters.totalRemapEvents += result.remapEvents
            switch result.halt {
            case .budget: counters.haltBudget += 1
            case .pcOut: counters.haltPCOut += 1
            case .unmatched: counters.haltUnmatched += 1
            }

            let commonA = EcologySiteStats(
                siteID: pair.a, partnerSiteID: pair.b, pairIndex: pairIndex,
                epoch: e, phase: phase,
                rawSteps: result.steps, noopSteps: result.noopSteps,
                commandSteps: result.commandSteps, halt: result.halt,
                copyWrites: result.copyWrites, loopOps: result.loopOps,
                remapEvents: result.remapEvents)
            let commonB = EcologySiteStats(
                siteID: pair.b, partnerSiteID: pair.a, pairIndex: pairIndex,
                epoch: e, phase: phase,
                rawSteps: result.steps, noopSteps: result.noopSteps,
                commandSteps: result.commandSteps, halt: result.halt,
                copyWrites: result.copyWrites, loopOps: result.loopOps,
                remapEvents: result.remapEvents)
            stats.append(commonA)
            stats.append(commonB)
        }

        counters.writeSites = written.reduce(0) { $0 + ($1 == 1 ? 1 : 0) }
        counters.writeConflicts = written.reduce(0) { $0 + ($1 > 1 ? 1 : 0) }
        counters.digest = EcologyDigest.digest(newSoup)

        stats.sort { $0.siteID < $1.siteID }
        soup = newSoup
        epoch += 1
        lastEpochCounters = counters
        lastSiteStats = stats
        return counters
    }

    @discardableResult
    public mutating func run(epochs count: Int) throws -> [EcologyEpochCounters] {
        precondition(count >= 0, "epoch count must be non-negative")
        var all: [EcologyEpochCounters] = []
        all.reserveCapacity(count)
        for _ in 0..<count {
            all.append(try runEpoch())
        }
        return all
    }
}

// MARK: - Checkpoint / replay fixture

public struct EcologyCheckpoint: Equatable, Sendable, Codable {
    public static let magicString = "BFFECO1"
    public static let currentSchemaVersion = 1

    public var magic: String
    public var schemaVersion: Int
    public var engineID: String
    public var topologyID: String
    public var schedulerID: String
    public var rngContractID: String
    public var evaluatorContractID: String
    public var seed: UInt32
    /// Next epoch to execute.
    public var epoch: UInt64
    public var mutationP32: UInt32
    public var stepBudget: Int
    public var variant: BFFVariant
    public var bracketMode: BracketMode
    public var soupBase64: String
    public var lastEpochCounters: EcologyEpochCounters?

    public init(capturing runner: EcologyOracleRunner) {
        self.magic = Self.magicString
        self.schemaVersion = Self.currentSchemaVersion
        self.engineID = EcologyConfig.engineID
        self.topologyID = EcologyConfig.topologyID
        self.schedulerID = EcologyConfig.schedulerID
        self.rngContractID = EcologyConfig.rngContractID
        self.evaluatorContractID = runner.config.evaluatorContractID
        self.seed = runner.config.seed
        self.epoch = runner.epoch
        self.mutationP32 = runner.config.mutationP32
        self.stepBudget = runner.config.stepBudget
        self.variant = runner.config.variant
        self.bracketMode = runner.config.bracketMode
        self.soupBase64 = Data(runner.soup).base64EncodedString()
        self.lastEpochCounters = runner.lastEpochCounters
    }

    public func config() throws -> EcologyConfig {
        try validateMetadata()
        return EcologyConfig(seed: seed, stepBudget: stepBudget,
                             mutationP32: mutationP32, variant: variant,
                             bracketMode: bracketMode)
    }

    public func soupBytes() throws -> [UInt8] {
        guard let data = Data(base64Encoded: soupBase64) else {
            throw EcologyContractError.corruptSoup("soupBase64 is not valid base64")
        }
        guard data.count == EcologyTopology.soupByteCount else {
            throw EcologyContractError.corruptSoup(
                "decoded soup is \(data.count) bytes, expected \(EcologyTopology.soupByteCount)")
        }
        return [UInt8](data)
    }

    public func validateMetadata() throws {
        guard magic == Self.magicString else { throw EcologyContractError.magic(magic) }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EcologyContractError.schemaVersion(schemaVersion)
        }
        guard engineID == EcologyConfig.engineID else {
            throw EcologyContractError.engineID(engineID)
        }
        guard topologyID == EcologyConfig.topologyID else {
            throw EcologyContractError.topologyID(topologyID)
        }
        guard schedulerID == EcologyConfig.schedulerID else {
            throw EcologyContractError.schedulerID(schedulerID)
        }
        guard rngContractID == EcologyConfig.rngContractID else {
            throw EcologyContractError.rngContractID(rngContractID)
        }
        // stepBudget must be rejected as a clean EcologyContractError before any
        // EcologyConfig initializer can run: the preconditioned initializer would
        // trap on stepBudget <= 0, turning a malformed-checkpoint rejection into a
        // process crash. This guard also covers the equivalent decode/json path
        // (jsonData/decode/config all route through validateMetadata), which is the
        // only malformed-input trap in this file — see EcologyConfig.init(from:) for
        // the decoder path that already validates budget > 0 before assignment.
        guard stepBudget > 0 else { throw EcologyContractError.invalidStepBudget(stepBudget) }
        let expectedEvaluator = EcologyConfig(seed: seed, stepBudget: stepBudget,
                                              mutationP32: mutationP32, variant: variant,
                                              bracketMode: bracketMode)
            .evaluatorContractID
        guard evaluatorContractID == expectedEvaluator else {
            throw EcologyContractError.evaluatorContractID(evaluatorContractID)
        }
        guard epoch <= UInt64(UInt32.max) else {
            throw EcologyContractError.epochOutOfRange(epoch)
        }
    }

    public func jsonData() throws -> Data {
        try validateMetadata()
        _ = try soupBytes()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> EcologyCheckpoint {
        let checkpoint = try JSONDecoder().decode(EcologyCheckpoint.self, from: data)
        try checkpoint.validateMetadata()
        _ = try checkpoint.soupBytes()
        return checkpoint
    }
}
