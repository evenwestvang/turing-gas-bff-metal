#if canImport(MetalKit)
import Foundation
import Metal
import MetalKit
import BFFMetal
import SoupScopeCore

enum ResidentDriverStopReason: Equatable, Sendable {
    case requested
    case epochLimit
    case secondsLimit
    case failure
}

final class ResidentSimulationDriver: @unchecked Sendable {
    typealias ReportHandler = @MainActor @Sendable (ResidentEpochReport, Int) -> Void
    typealias FailureHandler = @MainActor @Sendable (String) -> Void
    typealias StopHandler = @MainActor @Sendable (ResidentDriverStopReason, Int) -> Void

    private enum LoopAction {
        case advance
        case sleep
        case stop(ResidentDriverStopReason)
    }

    private let runner: ResidentMetalEpochRunner
    private let plan: ResidentAppRunPlan
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var state = ResidentSimulationStateMachine()
    private var cpuReference: ResidentCPUReferenceRunner?
    private var hasStarted = false
    private var startedAt = 0.0
    private var latestEpochValue = 0
    private var failureCountValue = 0

    private let onReport: ReportHandler
    private let onFailure: FailureHandler
    private let onStop: StopHandler

    init(config: ResidentEpochConfig,
         plan: ResidentAppRunPlan,
         device: MTLDevice,
         commandQueue: MTLCommandQueue,
         onReport: @escaping ReportHandler,
         onFailure: @escaping FailureHandler,
         onStop: @escaping StopHandler) throws {
        self.runner = try ResidentMetalEpochRunner(config: config,
                                                   device: device,
                                                   commandQueue: commandQueue)
        self.plan = plan
        self.queue = DispatchQueue(label: "dev.bff.soupscope.resident-simulation")
        self.cpuReference = plan.tinyValidation ? ResidentCPUReferenceRunner(config: config) : nil
        self.onReport = onReport
        self.onFailure = onFailure
        self.onStop = onStop
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stopAndWait()
    }

    var texture: MTLTexture? {
        runner.residentVisualizationTexture
    }

    var latestCompletedEpoch: Int {
        locked { latestEpochValue }
    }

    var failureCount: Int {
        locked { failureCountValue }
    }

    func start() {
        let shouldStart = locked { () -> Bool in
            guard !hasStarted else { return false }
            hasStarted = true
            startedAt = Self.now()
            return true
        }
        guard shouldStart else { return }
        group.enter()
        queue.async { [self] in
            runLoop()
            group.leave()
        }
    }

    func setPaused(_ paused: Bool) {
        locked {
            if paused {
                state.pause()
            } else {
                state.resume()
            }
        }
    }

    func togglePause() -> Bool {
        locked {
            state.togglePause()
            return state.shouldAdvance
        }
    }

    func stop() {
        locked { state.requestStop() }
    }

    func stopAndWait() {
        stop()
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            group.wait()
        }
    }

    private func runLoop() {
        var stopReason: ResidentDriverStopReason = .requested
        loop:
        while true {
            switch nextAction() {
            case .advance:
                do {
                    let report = try runner.runEpoch()
                    let failures = validate(report)
                    let count = locked { () -> Int in
                        latestEpochValue = report.counters.epoch + 1
                        failureCountValue += failures.count
                        if !failures.isEmpty { state.requestStop() }
                        return failureCountValue
                    }
                    DispatchQueue.main.async { [onReport] in
                        MainActor.assumeIsolated {
                            onReport(report, count)
                        }
                    }
                    if let first = failures.first {
                        DispatchQueue.main.async { [onFailure] in
                            MainActor.assumeIsolated {
                                onFailure(first)
                            }
                        }
                    }
                } catch {
                    let count = locked { () -> Int in
                        failureCountValue += 1
                        state.requestStop()
                        return failureCountValue
                    }
                    DispatchQueue.main.async { [onFailure] in
                        MainActor.assumeIsolated {
                            onFailure("resident epoch failed after \(count) failure(s): \(error)")
                        }
                    }
                }
            case .sleep:
                Thread.sleep(forTimeInterval: 0.005)
            case .stop(let reason):
                stopReason = reason
                break loop
            }
            if locked({ state.state == .stopping }) {
                stopReason = failureCountValue > 0 ? .failure : .requested
                break loop
            }
        }
        let finalEpoch = locked { () -> Int in
            state.markStopped()
            return latestEpochValue
        }
        DispatchQueue.main.async { [onStop] in
            MainActor.assumeIsolated {
                onStop(stopReason, finalEpoch)
            }
        }
    }

    private func nextAction() -> LoopAction {
        locked {
            switch state.state {
            case .stopping, .stopped:
                return .stop(failureCountValue > 0 ? .failure : .requested)
            case .paused:
                return .sleep
            case .running:
                switch plan.limit {
                case .unbounded:
                    return .advance
                case .epochs(let maxEpochs):
                    return latestEpochValue >= max(0, maxEpochs) ? .stop(.epochLimit) : .advance
                case .seconds(let seconds):
                    let elapsed = Self.now() - startedAt
                    return elapsed >= max(0, seconds) ? .stop(.secondsLimit) : .advance
                }
            }
        }
    }

    private func validate(_ gpu: ResidentEpochReport) -> [String] {
        var failures = gpu.shadowMismatches.map { "resident shadow mismatch: \($0.summary)" }
        guard var cpu = cpuReference else { return failures }
        let reference = cpu.runEpoch()
        cpuReference = cpu

        if gpu.counters != reference.counters {
            failures.append("resident CPU parity mismatch epoch=\(gpu.counters.epoch) counters")
        }
        if gpu.checkpointSoup != reference.checkpointSoup {
            failures.append("resident CPU parity mismatch epoch=\(gpu.counters.epoch) checkpoint")
        }
        if gpu.permutationFingerprint != reference.permutationFingerprint {
            failures.append("resident CPU parity mismatch epoch=\(gpu.counters.epoch) permutation")
        }
        if gpu.capturedPairs != reference.capturedPairs {
            failures.append("resident CPU parity mismatch epoch=\(gpu.counters.epoch) captures")
        }
        if reference.shadowMismatches.isEmpty == false {
            failures.append("CPU reference shadow mismatch epoch=\(gpu.counters.epoch)")
        }
        return failures
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
#endif
