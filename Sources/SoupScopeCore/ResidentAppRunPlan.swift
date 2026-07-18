import BFFMetal

public enum AppSimulationMode: Equatable, Sendable {
    case nonResident
    case resident
}

public enum ResidentRunLimit: Equatable, Sendable {
    case unbounded
    case epochs(Int)
    case seconds(Double)

    public var isBounded: Bool {
        switch self {
        case .unbounded: return false
        case .epochs, .seconds: return true
        }
    }
}

public struct ResidentAppRunPlan: Equatable, Sendable {
    public var enabled: Bool
    public var planner: ResidentPairingPlanner
    public var limit: ResidentRunLimit
    public var tinyValidation: Bool
    public var checkpointInterval: Int
    public var capturePairTapes: Bool
    public var shadowSampleCount: Int?
    public var visualizationWidth: Int

    public init(enabled: Bool,
                planner: ResidentPairingPlanner = .keyed,
                limit: ResidentRunLimit = .unbounded,
                tinyValidation: Bool = false,
                checkpointInterval: Int = 0,
                capturePairTapes: Bool = false,
                shadowSampleCount: Int? = 0,
                visualizationWidth: Int = ProgramGrid.canonicalWidth) {
        self.enabled = enabled
        self.planner = planner
        self.limit = limit
        self.tinyValidation = tinyValidation
        self.checkpointInterval = checkpointInterval
        self.capturePairTapes = capturePairTapes
        self.shadowSampleCount = shadowSampleCount
        self.visualizationWidth = visualizationWidth
    }

    public var rendererSource: ResidentRenderSource {
        enabled ? .residentVisualizationTexture : .cpuSnapshot
    }

    public var fullSoupCheckpointEnabled: Bool {
        checkpointInterval > 0
    }

    public var normalRunningReadsBackSoup: Bool {
        enabled && !tinyValidation && fullSoupCheckpointEnabled
    }
}

public enum ResidentRenderSource: Equatable, Sendable {
    case cpuSnapshot
    case residentVisualizationTexture
}

public enum ResidentSimulationState: Equatable, Sendable {
    case running
    case paused
    case stopping
    case stopped
}

public struct ResidentSimulationStateMachine: Equatable, Sendable {
    public private(set) var state: ResidentSimulationState

    public init(state: ResidentSimulationState = .running) {
        self.state = state
    }

    public var shouldAdvance: Bool { state == .running }
    public var isTerminal: Bool { state == .stopped }

    public mutating func pause() {
        if state == .running { state = .paused }
    }

    public mutating func resume() {
        if state == .paused { state = .running }
    }

    public mutating func togglePause() {
        switch state {
        case .running: state = .paused
        case .paused: state = .running
        case .stopping, .stopped: break
        }
    }

    public mutating func requestStop() {
        if state != .stopped { state = .stopping }
    }

    public mutating func markStopped() {
        state = .stopped
    }
}

public struct ResidentHUDDiagnostics: Equatable, Sendable {
    public var sourceEpoch: Int
    public var displayedEpoch: Int
    public var plannerCLI: String
    public var plannerModeID: String
    public var plannerProvenance: String
    public var epochWallMs: Double
    public var mutationGpuMs: Double?
    public var plannerGpuMs: Double?
    public var evalGpuMs: Double?
    public var visualizationGpuMs: Double?
    public var checkpointInterval: Int
    public var checkpointBytes: Int
    public var readbackBytes: Int
    public var failureCount: Int
    public var unknownHalts: Int

    public init(sourceEpoch: Int,
                displayedEpoch: Int,
                plannerCLI: String,
                plannerModeID: String,
                plannerProvenance: String,
                epochWallMs: Double,
                mutationGpuMs: Double?,
                plannerGpuMs: Double?,
                evalGpuMs: Double?,
                visualizationGpuMs: Double?,
                checkpointInterval: Int,
                checkpointBytes: Int,
                readbackBytes: Int,
                failureCount: Int,
                unknownHalts: Int) {
        self.sourceEpoch = sourceEpoch
        self.displayedEpoch = displayedEpoch
        self.plannerCLI = plannerCLI
        self.plannerModeID = plannerModeID
        self.plannerProvenance = plannerProvenance
        self.epochWallMs = epochWallMs
        self.mutationGpuMs = mutationGpuMs
        self.plannerGpuMs = plannerGpuMs
        self.evalGpuMs = evalGpuMs
        self.visualizationGpuMs = visualizationGpuMs
        self.checkpointInterval = checkpointInterval
        self.checkpointBytes = checkpointBytes
        self.readbackBytes = readbackBytes
        self.failureCount = failureCount
        self.unknownHalts = unknownHalts
    }
}
