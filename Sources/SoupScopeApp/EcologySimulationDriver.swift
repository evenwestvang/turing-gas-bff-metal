#if canImport(MetalKit)
import Foundation
import Metal
import MetalKit
import BFFMetal
import BFFEcologyMetal
import BFFOracle
import SoupScopeCore

/// Background simulation driver for the experimental "SoupScope Spatial
/// Ecology" mode. A **separate engine** from `ResidentSimulationDriver`: it
/// wraps the accepted `EcologyMetalEpochRunner` and drives its **app-safe**
/// `runEpochAppSafe()` path (no full-soup CPU readback, no CPU digest, no GPU
/// wait on the display thread), publishing immutable same-generation
/// soup+overview resources the renderer leases.
///
/// Ownership/synchronization exactly mirrors the grounded resident driver:
/// the producer (this driver, on a serial simulation queue) owns the live
/// mutable soup through the runner; the renderer never binds it. Every
/// `onReport`/`onFailure`/`onStop` callback captures the driver's lifecycle
/// generation and is inert unless it is still current, so stale completions
/// queued by an old driver after Reset/stop cannot mutate the new state or
/// emit a stale termination.
final class EcologySimulationDriver: @unchecked Sendable {
    typealias ReportHandler = @MainActor @Sendable (EcologyMetalEpochReport, Int) -> Void
    typealias FailureHandler = @MainActor @Sendable (String) -> Void
    typealias StopHandler = @MainActor @Sendable (ResidentDriverStopReason,
                                                   ResidentProgressSnapshot) -> Void

    private enum LoopAction {
        case advance
        case sleep
        case stop(ResidentDriverStopReason)
    }

    private let runner: EcologyMetalEpochRunner
    private let plan: EcologyAppRunPlan
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var state = ResidentSimulationStateMachine()
    private var deadlineTimer: ResidentDeadlineTimer?
    private var cpuReference: EcologyOracleRunner?
    private var hasStarted = false
    private var hasFinished = false
    private var stopReasonValue: ResidentDriverStopReason?
    private var startedAt = 0.0
    private var latestEpochValue = 0
    private var failureCountValue = 0
    private var latestUnknownHaltsValue = 0

    private let onReport: ReportHandler
    private let onFailure: FailureHandler
    private let onStop: StopHandler

    init(config: EcologyMetalEpochConfig,
         plan: EcologyAppRunPlan,
         device: MTLDevice,
         commandQueue: MTLCommandQueue,
         onReport: @escaping ReportHandler,
         onFailure: @escaping FailureHandler,
         onStop: @escaping StopHandler) throws {
        self.runner = try EcologyMetalEpochRunner(
            config: config, device: device, commandQueue: commandQueue)
        // Prepare the app-safe resources (visualize pipeline, overview
        // texture, snapshot ring) once at construction so the renderer has a
        // stable overview texture to sample from the first frame, and
        // runEpochAppSafe() never blocks on lazy preparation.
        try runner.prepareAppSafeResources()
        self.plan = plan
        self.queue = DispatchQueue(label: "dev.bff.soupscope.ecology-simulation")
        // CPU parity reference for tiny-validation only. The interactive
        // (unbounded) path never constructs one — it shares the accepted
        // semantics without readback.
        self.cpuReference = plan.tinyValidation
            ? EcologyOracleRunner(config: EcologyConfig(seed: plan.seed,
                                                       stepBudget: plan.stepBudget,
                                                       mutationP32: plan.mutationP32,
                                                       variant: plan.variant,
                                                       bracketMode: plan.bracketMode))
            : nil
        self.onReport = onReport
        self.onFailure = onFailure
        self.onStop = onStop
        queue.setSpecific(key: queueKey, value: 1)
        if case .seconds(let seconds) = plan.limit {
            self.deadlineTimer = ResidentDeadlineTimer(seconds: seconds) { [weak self] in
                self?.finish(reason: .secondsLimit)
            }
        }
    }

    deinit { stopAndWait() }

    var snapshotDiagnostics: ResidentSnapshotRingDiagnostics {
        runner.residentSnapshotDiagnostics
    }

    func acquireSnapshot(expectedByteCount: Int) -> ResidentGPUSnapshotLease? {
        runner.acquireResidentSnapshot(expectedByteCount: expectedByteCount)
    }

    var latestCompletedEpoch: Int { locked { latestEpochValue } }
    var failureCount: Int { locked { failureCountValue } }

    var diagnosticSnapshot: ResidentProgressSnapshot {
        locked { snapshotLocked() }
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
        deadlineTimer?.start()
        queue.async { [self] in
            runLoop()
            group.leave()
        }
    }

    func setPaused(_ paused: Bool) {
        locked { paused ? state.pause() : state.resume() }
    }

    func togglePause() -> Bool {
        locked { state.togglePause(); return state.shouldAdvance }
    }

    func stop() { requestStop(reason: .requested) }

    func stopAndWait() {
        stop()
        if DispatchQueue.getSpecific(key: queueKey) == nil { group.wait() }
    }

    private func runLoop() {
        loop: while true {
            switch nextAction() {
            case .advance:
                do {
                    let report = try runner.runEpochAppSafe()
                    let failures = validate(report)
                    let count = locked { () -> Int in
                        // The report's epoch is the producing epoch e (UInt32,
                        // domain-guaranteed by the runner's epochOutOfRange
                        // check). The number of completed epochs is e + 1,
                        // narrowed to Int for the renderer/HUD.
                        latestEpochValue = Int(report.counters.epoch) + 1
                        // `EcologyEpochCounters` has no `haltUnknown` field by
                        // contract: the ecology evaluator only produces the
                        // three in-contract halt reasons. The runner's
                        // `runEpochAppSafe()` reads the GPU `haltUnknown`
                        // counter and throws `unexpectedHalt` if it is nonzero,
                        // so a successful report provably has zero unknown
                        // halts — represent it as 0 here without weakening the
                        // hard-error path (which already threw above).
                        latestUnknownHaltsValue = 0
                        failureCountValue += failures.count
                        if !failures.isEmpty { requestStopLocked(reason: .failure) }
                        return failureCountValue
                    }
                    DispatchQueue.main.async { [onReport] in
                        MainActor.assumeIsolated { onReport(report, count) }
                    }
                    if let first = failures.first {
                        DispatchQueue.main.async { [onFailure] in
                            MainActor.assumeIsolated { onFailure(first) }
                        }
                    }
                } catch {
                    let count = locked { () -> Int in
                        failureCountValue += 1
                        requestStopLocked(reason: .failure)
                        return failureCountValue
                    }
                    DispatchQueue.main.async { [onFailure] in
                        MainActor.assumeIsolated {
                            onFailure("ecology epoch failed after \(count) failure(s): \(error)")
                        }
                    }
                }
            case .sleep:
                Thread.sleep(forTimeInterval: 0.005)
            case .stop(let reason):
                finish(reason: reason)
                break loop
            }
            if locked({ state.state == .stopping }) {
                finish(reason: stopReasonValue
                       ?? (failureCountValue > 0 ? .failure : .requested))
                break loop
            }
        }
    }

    private func nextAction() -> LoopAction {
        locked {
            switch state.state {
            case .stopping, .stopped:
                return .stop(stopReasonValue
                             ?? (failureCountValue > 0 ? .failure : .requested))
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

    private func requestStop(reason: ResidentDriverStopReason) {
        locked { requestStopLocked(reason: reason) }
    }

    private func requestStopLocked(reason: ResidentDriverStopReason) {
        if stopReasonValue == nil || reason == .failure {
            stopReasonValue = reason
        }
        state.requestStop()
    }

    @discardableResult
    private func finish(reason: ResidentDriverStopReason) -> Bool {
        let finished = locked { () -> (ResidentDriverStopReason, ResidentProgressSnapshot)? in
            guard !hasFinished else { return nil }
            hasFinished = true
            requestStopLocked(reason: reason)
            let finalReason = stopReasonValue ?? reason
            state.markStopped()
            return (finalReason, snapshotLocked())
        }
        guard let (finalReason, snapshot) = finished else { return false }
        deadlineTimer?.cancel()
        DispatchQueue.main.async { [onStop] in
            MainActor.assumeIsolated { onStop(finalReason, snapshot) }
        }
        return true
    }

    private func snapshotLocked() -> ResidentProgressSnapshot {
        ResidentProgressSnapshot(simulationEpoch: latestEpochValue,
                                 textureSourceEpoch: latestEpochValue,
                                 failures: failureCountValue,
                                 unknownHalts: latestUnknownHaltsValue)
    }

    /// Tiny-validation CPU parity check (off for the interactive path). The
    /// app-safe report carries no digest and no captured pairs, so parity is
    /// established on the **counters** — the same counters the accepted CLI
    /// asserts against the CPU oracle. The interactive (unbounded) path
    /// returns no failures (it does not construct a CPU reference).
    ///
    /// The CPU oracle's `runEpoch()` is `throws` (it rejects epochs outside
    /// the UInt32 RNG domain). A throw here is a real validation failure: it
    /// is reported truthfully as a parity failure string and never swallowed,
    /// so the run stops with an explicit reason instead of silently advancing.
    private func validate(_ gpu: EcologyMetalEpochReport) -> [String] {
        guard var cpu = cpuReference else { return [] }
        var failures: [String] = []
        let reference: EcologyEpochCounters
        do {
            reference = try cpu.runEpoch()
        } catch {
            failures.append("ecology CPU oracle runEpoch failed for "
                            + "gpu epoch \(gpu.counters.epoch): \(error)")
            cpuReference = cpu
            return failures
        }
        cpuReference = cpu
        if gpu.counters.epoch != reference.epoch {
            failures.append("ecology CPU parity mismatch epoch"
                            + " gpu=\(gpu.counters.epoch) cpu=\(reference.epoch)")
        }
        if gpu.counters.mutationCount != reference.mutationCount
            || gpu.counters.totalRawSteps != reference.totalRawSteps
            || gpu.counters.totalNoopSteps != reference.totalNoopSteps
            || gpu.counters.totalLoopOps != reference.totalLoopOps
            || gpu.counters.totalCopyWrites != reference.totalCopyWrites
            || gpu.counters.totalRemapEvents != reference.totalRemapEvents
            || gpu.counters.haltBudget != reference.haltBudget
            || gpu.counters.haltPCOut != reference.haltPCOut
            || gpu.counters.haltUnmatched != reference.haltUnmatched {
            failures.append("ecology CPU parity mismatch epoch=\(gpu.counters.epoch) counters")
        }
        return failures
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    private static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
#endif
