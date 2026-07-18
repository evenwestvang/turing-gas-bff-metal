import Dispatch
import Foundation

public enum ResidentDriverStopReason: String, Codable, Equatable, Sendable {
    case requested
    case epochLimit
    case secondsLimit
    case failure
}

public struct ResidentProgressSnapshot: Equatable, Sendable {
    public var simulationEpoch: Int
    public var textureSourceEpoch: Int
    public var failures: Int
    public var unknownHalts: Int

    public init(simulationEpoch: Int,
                textureSourceEpoch: Int,
                failures: Int,
                unknownHalts: Int) {
        self.simulationEpoch = simulationEpoch
        self.textureSourceEpoch = textureSourceEpoch
        self.failures = failures
        self.unknownHalts = unknownHalts
    }
}

public struct ResidentFinalDiagnostic: Codable, Equatable, Sendable {
    public var kind: String
    public var simulationEpoch: Int
    public var displayedEpoch: Int
    public var textureSourceEpoch: Int
    public var frameCount: Int
    public var failures: Int
    public var unknownHalts: Int
    public var stopReason: ResidentDriverStopReason

    public init(simulationEpoch: Int,
                displayedEpoch: Int,
                textureSourceEpoch: Int,
                frameCount: Int,
                failures: Int,
                unknownHalts: Int,
                stopReason: ResidentDriverStopReason) {
        self.kind = "residentFinalDiagnostic"
        self.simulationEpoch = simulationEpoch
        self.displayedEpoch = displayedEpoch
        self.textureSourceEpoch = textureSourceEpoch
        self.frameCount = frameCount
        self.failures = failures
        self.unknownHalts = unknownHalts
        self.stopReason = stopReason
    }

    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            preconditionFailure("resident final diagnostic must be JSON-encodable")
        }
        return line
    }
}

public struct ResidentFinalDiagnosticEmitter: Sendable {
    public private(set) var emitted = false

    public init() {}

    @discardableResult
    public mutating func emit(_ diagnostic: ResidentFinalDiagnostic,
                              write: (String) -> Void) -> Bool {
        guard !emitted else { return false }
        emitted = true
        write(diagnostic.jsonLine())
        return true
    }
}

public final class ResidentDeadlineTimer: @unchecked Sendable {
    private let seconds: Double
    private let queue: DispatchQueue
    private let onDeadline: () -> Void
    private let lock = NSLock()
    private var source: DispatchSourceTimer?
    private var started = false
    private var completed = false

    public init(seconds: Double,
                queue: DispatchQueue = DispatchQueue(label: "dev.bff.soupscope.resident-deadline"),
                onDeadline: @escaping () -> Void) {
        self.seconds = max(0, seconds)
        self.queue = queue
        self.onDeadline = onDeadline
    }

    deinit {
        cancel()
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.fire()
        }
        let maxSeconds = Double(Int.max) / 1_000_000_000
        let nanoseconds = seconds >= maxSeconds
            ? Int.max
            : Int((seconds * 1_000_000_000).rounded(.up))
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds),
                       leeway: .milliseconds(10))
        let shouldStart = locked { () -> Bool in
            guard !started, !completed else { return false }
            started = true
            source = timer
            timer.resume()
            return true
        }
        if !shouldStart {
            timer.resume()
            timer.cancel()
        }
    }

    public func cancel() {
        let timer = locked { () -> DispatchSourceTimer? in
            guard !completed else { return nil }
            completed = true
            let timer = source
            source = nil
            return timer
        }
        timer?.cancel()
    }

    private func fire() {
        let shouldFire = locked { () -> Bool in
            guard !completed else { return false }
            completed = true
            source = nil
            return true
        }
        guard shouldFire else { return }
        onDeadline()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
