#if canImport(MetalKit)
import Foundation
import AppKit
import Combine
import Metal
import MetalKit
import BFFMetal
import BFFOracle
import SoupScopeCore
import CSoupRender

/// Main-actor owner of the running soup and all view state. It advances epochs in
/// bounded per-frame batches, publishes the HUD, and holds the pan/zoom camera.
/// Everything simulation-side is confined to the main actor and driven from the
/// MTKView's `draw(in:)`, so command encoding stays serial and understandable and
/// SwiftUI is never blocked for more than one bounded (~10 ms) batch.
@MainActor
final class AppModel: ObservableObject, @unchecked Sendable {
    let options: AppLaunchOptions
    let residentPlan: ResidentAppRunPlan
    private let constructsLegacyCPURunner: Bool
    let config: SoupConfig
    private let residentConfig: ResidentEpochConfig?
    let grid: ProgramGrid
    let lod = LODModel()
    let normalization: MetricNormalization

    var camera = Camera()
    var batcher: AdaptiveBatcher
    /// Resident fast-view selector carried in the existing VizUniforms word:
    /// 0 composite (default), 1 R, 2 G, 3 B.
    var metricChannel: UInt32 = ResidentVizChannel.defaultChannel.rawValue
    var isRunning = true

    @Published private(set) var hud: HUDModel

    /// Bounded entropy-over-time history for the resident visualization overlay.
    /// This is visualization-grade state, intentionally separate from Brotli /
    /// scientific entropy cadence. It remains empty until a future Metal /
    /// close-LOD integration passes real mean-byte-entropy samples through
    /// `receiveResidentVizEntropy(epoch:meanByteEntropy:)`.
    @Published private(set) var vizEntropyHistory = VizEntropyHistory()

    /// Explicit availability for resident visualization entropy. It starts false
    /// because the current resident report type does not expose viz entropy; the
    /// UI must report unavailable rather than inventing zeroes or empty data.
    @Published private(set) var vizEntropyAvailable = false

    /// The LOD readout of the most recently submitted render frame — the exact
    /// `LODReadout` that fed the shader uniforms, surfaced for the HUD so the
    /// displayed zoom/blend values are byte-for-byte what is being rendered. It is
    /// `@Published` (not a computed re-evaluation) so a camera-only zoom/pan, which
    /// never advances an epoch or mutates `hud`, still refreshes the HUD — including
    /// while paused. Updated only from `makeUniforms`, and only when the value
    /// actually changed, so it never spins a redundant SwiftUI update.
    @Published private(set) var lodReadout: LODReadout

    let context: SharedMetalContext?
    private var runner: SoupRunner?
    private var residentDriver: ResidentSimulationDriver?
    /// Monotonically increasing lifecycle generation for the resident driver.
    /// Every resident `onReport`/`onFailure`/`onStop` callback captures the
    /// generation of the driver it belongs to and is inert unless it is still
    /// current — so callbacks queued by an old driver that are still in flight
    /// when `resetInteractiveResidentSimulation` constructs a fresh driver cannot
    /// mutate the new state or emit a stale termination. The launch-time driver
    /// captures generation `0`; each Reset bumps it before stopping the old
    /// driver.
    private var lifecycleGeneration = ResidentLifecycleGeneration()
    private var residentDisplayedEpoch = 0
    private var residentRenderedFrames = 0
    private var residentFinalDiagnosticEmitter = ResidentFinalDiagnosticEmitter()
    private(set) var lastSnapshot: RenderSnapshot?

    // Opt-in per-frame host-stage timing (`--frame-stage-timing`). `nil` (off) unless the
    // launch option requested it, so the default frame path is byte-for-byte unchanged.
    // `stepFrame` stashes the epoch-batch and snapshot-build spans it measures; the
    // renderer folds them together with the frame wall and the Metal-only texture/submit
    // spans into one `AppFrameStageSample`.
    private var frameStages: AppFrameStageAccumulator?
    private var lastEpochBatchSeconds: Double?
    private var lastSnapshotBuildSeconds: Double?
    /// Whether per-frame host-stage timing is active (renderer gate).
    var frameStageTimingEnabled: Bool { frameStages != nil }

    // Drawable geometry (pixels), set by the renderer on resize.
    private var drawablePxW: Double = 0
    private var drawablePxH: Double = 0
    private var didFit = false

    // Bounded-validation state (the verdict logic lives in the pure
    // `ValidationRun`/`ValidationPolicy` state machine in SoupScopeCore).
    private var validationRun: ValidationRun?
    private var validationStart: Double?
    private var validationTimer: Timer?
    private var completedDraws = 0
    private var lastCommandBuffer: MTLCommandBuffer?
    /// True once a terminal validation verdict is reached; the renderer then stops
    /// submitting new work so no buffer is torn down while an exit is pending.
    private(set) var validationFinished = false
    /// Whether a validation run is active and not yet finished.
    var validationActive: Bool { options.validationSeconds != nil && !validationFinished }

    init(arguments: [String]) {
        // Parse launch options; on error, fall back to interactive defaults and
        // surface the message rather than trapping.
        var startupError: String?
        let parsed: AppLaunchOptions
        do {
            parsed = try AppLaunchOptions.parse(arguments)
        } catch {
            parsed = AppLaunchOptions()
            startupError = "launch args: \(error)"
        }
        self.options = parsed
        let resolvedResidentPlan = parsed.residentRunPlan()
        self.residentPlan = resolvedResidentPlan
        let resolvedConstructsLegacyCPURunner =
            SoupScopeAppLifecycle.constructsLegacyCPURunner(for: resolvedResidentPlan)
        self.constructsLegacyCPURunner = resolvedConstructsLegacyCPURunner

        let resolvedConfig: SoupConfig
        do {
            resolvedConfig = try parsed.soupConfig()
        } catch {
            // A valid, full-capacity default so the app still runs and shows the
            // error. Matches the omitted-argument app default (ProgramGrid.capacity)
            // so a parse failure or a rejected --programs cannot silently fall back
            // to the old 1,024-program modest soup.
            resolvedConfig = (try? SoupConfig(seed: parsed.seed,
                                              programCount: ProgramGrid.capacity))
                ?? (try! SoupConfig(seed: 1, programCount: ProgramGrid.capacity))
            startupError = (startupError.map { $0 + "; " } ?? "") + "config: \(error)"
        }
        self.config = resolvedConfig
        if resolvedResidentPlan.enabled {
            do {
                self.residentConfig = try parsed.residentConfig()
            } catch {
                self.residentConfig = nil
                startupError = (startupError.map { $0 + "; " } ?? "") + "resident config: \(error)"
            }
        } else {
            self.residentConfig = nil
        }
        self.grid = ProgramGrid(programCount: resolvedConfig.programCount)
        self.normalization = MetricNormalization(stepBudget: resolvedConfig.stepBudget)
        // Resident mode does not construct the legacy CPU `SoupRunner`. The
        // non-resident path keeps its existing CPU runner for the per-frame
        // snapshot pipeline.
        self.runner = resolvedConstructsLegacyCPURunner
            ? SoupRunner(config: resolvedConfig)
            : nil
        self.batcher = AdaptiveBatcher()

        var builtContext: SharedMetalContext?
        do {
            builtContext = try SharedMetalContext(colorPixelFormat: .bgra8Unorm)
        } catch {
            startupError = (startupError.map { $0 + "; " } ?? "") + "\(error)"
        }
        self.context = builtContext

        var initialHUD = HUDModel(deviceName: builtContext?.deviceName ?? "no Metal device",
                                  programCount: resolvedConfig.programCount)
        initialHUD.setError(startupError)
        self.hud = initialHUD
        self.lodReadout = LODReadout(camera: camera, lod: lod)

        self.frameStages = parsed.frameStageTiming ? AppFrameStageAccumulator() : nil

        // Initial snapshot routing via the pure production decision: non-resident
        // mode constructed the legacy CPU runner above, so it seeds an epoch-0
        // `RenderSnapshot.initial` from that runner's seeded soup — giving the
        // renderer something deterministic to draw before the first epoch batch.
        // Resident mode routes to `.none` (its soup lives on the GPU), so it must
        // not try to build from an empty CPU soup; `lastSnapshot` stays `nil`
        // until the resident driver produces a frame.
        let resolvedInitialSnapshotSource =
            SoupScopeAppLifecycle.initialSnapshotSource(for: resolvedResidentPlan)
        self.lastSnapshot = resolvedInitialSnapshotSource == .legacyCPURunner
            ? (try? RenderSnapshot.initial(programCount: resolvedConfig.programCount,
                                           soup: runner?.soup ?? []))
            : nil

        // Arm the display-independent validation watchdog (no-op for interactive
        // launch, which omits --validation-seconds).
        beginValidationIfNeeded()
        startResidentIfNeeded()
    }

    deinit {
        if residentFinalDiagnosticEmitter.emitted {
            residentDriver?.stop()
        } else {
            residentDriver?.stopAndWait()
        }
    }

    // MARK: - Frame driving

    /// Advance one bounded epoch batch and return the snapshot to render. Called
    /// from the renderer each frame. On failure it stops advancing and leaves the
    /// error visible (never spins/retries). Returns the latest snapshot regardless
    /// so the last good frame stays on screen.
    func stepFrame() -> RenderSnapshot? {
        guard constructsLegacyCPURunner else { return lastSnapshot }
        // Clear this frame's stashed stage spans up front (only when timing), so a frame
        // that does not advance (finished / paused / error) honestly folds `nil` for the
        // epoch-batch and snapshot stages rather than a previous frame's values.
        if frameStages != nil {
            lastEpochBatchSeconds = nil
            lastSnapshotBuildSeconds = nil
        }
        guard validationFinished == false else { return lastSnapshot }
        guard hud.errorState == nil, isRunning, let evaluator = context?.evaluator else {
            return lastSnapshot
        }

        do {
            guard let frameSnapshot = try withStoredCPURunner({ runner -> RenderSnapshot? in
                let epochsToRun = batcher.nextBatchEpochs()
                let t0 = AppMonotonicClock.nowSeconds()
                var reports: [EpochReport] = []
                reports.reserveCapacity(epochsToRun)
                for _ in 0 ..< epochsToRun {
                    reports.append(try runner.runEpoch(using: evaluator))
                }
                let batchMs = (AppMonotonicClock.nowSeconds() - t0) * 1000
                batcher.record(batchMs: batchMs, epochs: reports.count)

                // A shadow mismatch is a hard stop — surface it, do not keep advancing.
                if let bad = reports.first(where: { !$0.shadowMismatches.isEmpty }) {
                    hud.record(batch: reports, epoch: runner.epoch, batchMs: batchMs)
                    hud.setError("CPU-shadow mismatch: "
                                 + (bad.shadowMismatches.first?.summary ?? "divergence"))
                    return lastSnapshot
                }

                hud.record(batch: reports, epoch: runner.epoch, batchMs: batchMs)

                let metrics = reports.last?.metrics
                var snapshotBuildSeconds: Double? = nil
                if let metrics {
                    let s0 = frameStages != nil ? AppMonotonicClock.nowSeconds() : 0
                    lastSnapshot = try? RenderSnapshot.build(epoch: runner.epoch,
                                                             programCount: config.programCount,
                                                             soup: runner.soup,
                                                             metrics: metrics)
                    if frameStages != nil {
                        snapshotBuildSeconds = AppMonotonicClock.nowSeconds() - s0
                    }
                }
                // Stash this frame's app-stage spans for the renderer to fold (only when timing).
                if frameStages != nil {
                    lastEpochBatchSeconds = batchMs / 1000
                    lastSnapshotBuildSeconds = snapshotBuildSeconds
                }
                return lastSnapshot
            }) else {
                return lastSnapshot
            }
            return frameSnapshot
        } catch {
            hud.setError("epoch execution failed: \(error)")
            return lastSnapshot
        }
    }

    private func withStoredCPURunner<Result>(
        _ body: (inout SoupRunner) throws -> Result
    ) rethrows -> Result? {
        guard var storedRunner = runner else { return nil }
        defer { runner = storedRunner }
        return try body(&storedRunner)
    }

    /// Fold one frame's app-stage spans into the accumulator, pairing the renderer's
    /// frame wall + Metal-only spans with the epoch-batch and snapshot-build spans
    /// `stepFrame` measured. No-op unless `--frame-stage-timing` is on.
    func recordFrameStages(frameSeconds: Double, soupBufferSeconds: Double?,
                           metricTextureSeconds: Double?, renderSubmitSeconds: Double?) {
        guard frameStages != nil else { return }
        frameStages?.record(AppFrameStageSample(
            frameSeconds: frameSeconds,
            epochBatchSeconds: lastEpochBatchSeconds,
            snapshotBuildSeconds: lastSnapshotBuildSeconds,
            soupBufferSeconds: soupBufferSeconds,
            metricTextureSeconds: metricTextureSeconds,
            renderSubmitSeconds: renderSubmitSeconds))
    }

    // MARK: - Geometry / camera

    /// Update the drawable size (pixels) from the renderer; frames the whole soup
    /// on first valid size.
    func updateDrawableSize(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        drawablePxW = width
        drawablePxH = height
        if !didFit {
            camera.fitAll(cameraGeometry())
            didFit = true
        } else {
            camera.clamp(cameraGeometry())
        }
    }

    /// Camera geometry frames the *populated* extent (columns `0..<min(N,512)`,
    /// rows `0..<⌈N/512⌉`) even though the coordinates themselves stay canonical —
    /// so fit/reset never centers on the mostly-empty 512×256 canvas.
    func cameraGeometry() -> CameraGeometry {
        CameraGeometry(soupByteWidth: Double(grid.populatedByteWidth),
                       soupByteHeight: Double(grid.populatedByteHeight),
                       viewPxWidth: drawablePxW, viewPxHeight: drawablePxH)
    }

    func zoom(factor: Double, anchorPxX: Double, anchorPxY: Double) {
        camera.zoom(factor: factor, anchorPxX: anchorPxX, anchorPxY: anchorPxY,
                    geometry: cameraGeometry())
    }

    func pan(dxPx: Double, dyPx: Double) {
        camera.pan(dxPx: dxPx, dyPx: dyPx, geometry: cameraGeometry())
    }

    func fitAll() { camera.fitAll(cameraGeometry()) }
    func togglePause() {
        if let residentDriver {
            isRunning = residentDriver.togglePause()
        } else {
            isRunning.toggle()
        }
        objectWillChange.send()          // reflect the paused flag immediately
    }
    func cycleMetricChannel() {
        metricChannel = ResidentVizChannel.cyclingRawValue(after: metricChannel)
        objectWillChange.send()
    }

    /// The resident-path channel the current `metricChannel` selects. Used by
    /// the HUD and entropy overlay to label the active resident signal with its
    /// resident-specific names.
    var residentVizChannel: ResidentVizChannel {
        ResidentVizChannel(rawValue: metricChannel) ?? ResidentVizChannel.defaultChannel
    }

    /// The uniforms for the current frame. Evaluates the frame's `LODReadout` once
    /// (the single source shared with the HUD), publishes it as the observable HUD
    /// readout when it changed since the last frame, and builds the uniforms from that
    /// same readout — so the HUD shows exactly what the shader is blending and a
    /// camera-only change refreshes the HUD even while paused, with no redundant
    /// SwiftUI update when the camera is steady.
    func makeUniforms() -> VizUniforms {
        let frame = LODReadout.forFrame(camera: camera, lod: lod, current: lodReadout)
        if frame.changed { lodReadout = frame.readout }
        return VizLayout.makeUniforms(readout: frame.readout, camera: camera, grid: grid,
                                      metricChannel: metricChannel,
                                      viewPxWidth: drawablePxW, viewPxHeight: drawablePxH)
    }

    var usesResidentRendering: Bool {
        residentDriver != nil
    }

    var residentVisualizationTexture: MTLTexture? {
        residentDriver?.texture
    }

    var residentSnapshotDiagnostics: ResidentSnapshotRingDiagnostics? {
        residentDriver?.snapshotDiagnostics
    }

    func acquireResidentSnapshot() -> ResidentGPUSnapshotLease? {
        guard let residentConfig else { return nil }
        return residentDriver?.acquireSnapshot(expectedByteCount: residentConfig.soupByteCount)
    }

    var latestResidentSourceEpoch: Int {
        residentDriver?.latestCompletedEpoch ?? 0
    }

    func noteResidentDisplayedEpoch(_ epoch: Int) {
        residentDisplayedEpoch = epoch
        if var resident = hud.resident {
            resident.displayedEpoch = epoch
            hud.resident = resident
        }
    }

    func noteResidentFrameSubmitted(sourceEpoch: Int) {
        residentRenderedFrames += 1
        noteResidentDisplayedEpoch(sourceEpoch)
    }

    private func startResidentIfNeeded() {
        guard residentPlan.enabled else { return }
        guard let context else {
            hud.setError((hud.errorState.map { $0 + "; " } ?? "")
                         + "resident mode requires Metal")
            if residentPlan.limit.isBounded || residentPlan.tinyValidation {
                emitResidentFinalDiagnosticAndTerminate(
                    reason: .failure,
                    snapshot: ResidentProgressSnapshot(simulationEpoch: 0,
                                                       textureSourceEpoch: 0,
                                                       failures: 1,
                                                       unknownHalts: 0))
            }
            return
        }
        guard let residentConfig else {
            if residentPlan.limit.isBounded || residentPlan.tinyValidation {
                emitResidentFinalDiagnosticAndTerminate(
                    reason: .failure,
                    snapshot: ResidentProgressSnapshot(simulationEpoch: 0,
                                                       textureSourceEpoch: 0,
                                                       failures: 1,
                                                       unknownHalts: 0))
            }
            return
        }
        do {
            let driver = try makeResidentDriver(context: context, residentConfig: residentConfig)
            residentDriver = driver
            isRunning = true
            driver.start()
        } catch {
            hud.setError((hud.errorState.map { $0 + "; " } ?? "")
                         + "resident start failed: \(error)")
            if residentPlan.limit.isBounded || residentPlan.tinyValidation {
                emitResidentFinalDiagnosticAndTerminate(
                    reason: .failure,
                    snapshot: ResidentProgressSnapshot(simulationEpoch: 0,
                                                       textureSourceEpoch: 0,
                                                       failures: 1,
                                                       unknownHalts: 0))
            }
        }
    }

    /// Construct a `ResidentSimulationDriver` from the immutable
    /// `residentConfig`/`residentPlan` and the shared Metal device+queue, whose
    /// `onReport`/`onFailure`/`onStop` callbacks capture the current lifecycle
    /// generation and are inert unless it is still current — so callbacks queued
    /// by an old driver that are still in flight after Reset cannot mutate the
    /// new state or emit a stale termination.
    private func makeResidentDriver(context: SharedMetalContext,
                                   residentConfig: ResidentEpochConfig
    ) throws -> ResidentSimulationDriver {
        let generation = lifecycleGeneration.current
        return try ResidentSimulationDriver(
            config: residentConfig,
            plan: residentPlan,
            device: context.device,
            commandQueue: context.queue,
            onReport: { [weak self] report, failures in
                guard let self, self.lifecycleGeneration.isCurrent(generation) else { return }
                self.receiveResidentReport(report, failureCount: failures)
            },
            onFailure: { [weak self] message in
                guard let self, self.lifecycleGeneration.isCurrent(generation) else { return }
                self.hud.setError(message)
            },
            onStop: { [weak self] reason, snapshot in
                guard let self, self.lifecycleGeneration.isCurrent(generation) else { return }
                self.residentDidStop(reason: reason, snapshot: snapshot)
            })
    }

    private func receiveResidentReport(_ report: ResidentEpochReport, failureCount: Int) {
        guard let residentConfig else { return }
        hud.record(resident: report,
                   planner: residentPlan.planner,
                   checkpointInterval: residentConfig.checkpointInterval,
                   displayedEpoch: residentDisplayedEpoch,
                   failureCount: failureCount)
        if report.shadowMismatches.isEmpty == false {
            hud.setError("resident CPU-shadow mismatch: "
                         + (report.shadowMismatches.first?.summary ?? "divergence"))
        }
        objectWillChange.send()
    }

    /// Future Metal / close-LOD integration seam. `ResidentEpochReport` on this
    /// bounded non-Metal slice intentionally lacks `vizMeanByteEntropy`, so resident
    /// reports do not call this yet. When real samples are added, nil or non-finite
    /// input means the signal is unavailable and records nothing.
    func receiveResidentVizEntropy(epoch: Int, meanByteEntropy: Double?) {
        guard let meanByteEntropy, meanByteEntropy.isFinite,
              let sample = VizEntropySampleDecoder.sample(epoch: epoch,
                                                          meanByteEntropy: meanByteEntropy)
        else {
            vizEntropyAvailable = false
            return
        }
        vizEntropyAvailable = true
        vizEntropyHistory.record(sample)
    }

    private func residentDidStop(reason: ResidentDriverStopReason,
                                 snapshot: ResidentProgressSnapshot) {
        isRunning = false
        objectWillChange.send()
        guard residentPlan.limit.isBounded || residentPlan.tinyValidation || reason == .failure else {
            return
        }
        emitResidentFinalDiagnosticAndTerminate(reason: reason, snapshot: snapshot)
    }

    private func emitResidentFinalDiagnosticAndTerminate(
        reason: ResidentDriverStopReason,
        snapshot: ResidentProgressSnapshot
    ) {
        let diagnostic = ResidentFinalDiagnostic(
            simulationEpoch: snapshot.simulationEpoch,
            displayedEpoch: residentDisplayedEpoch,
            textureSourceEpoch: snapshot.textureSourceEpoch,
            frameCount: residentRenderedFrames,
            failures: snapshot.failures,
            unknownHalts: snapshot.unknownHalts,
            stopReason: reason)
        guard residentFinalDiagnosticEmitter.emit(diagnostic, write: { print($0) }) else {
            return
        }
        let exitCode = ResidentTerminationPolicy.exitCode(
            reason: reason,
            metalAvailable: context != nil,
            hasError: hud.errorState != nil)
        if exitCode == 0 {
            NSApplication.shared.terminate(nil)
        } else {
            exit(exitCode)
        }
    }

    func stopResidentSimulation() {
        residentDriver?.stopAndWait()
    }

    // MARK: - Interactive resident Reset

    /// User-visible Reset (the `r` key): reconstruct the resident simulation
    /// driver from its immutable `residentConfig`/`residentPlan` and the shared
    /// Metal device+queue, restoring the seeded soup, epoch zero, the snapshot
    /// ring/resources/generations, and all displayed/visualization/HUD/error
    /// state, then re-fit the camera with the current drawable geometry and
    /// restart.
    ///
    /// Allowed only for the interactive resident well-mixed mode — a resident
    /// run with an `unbounded` limit, `tinyValidation` off, and no
    /// display-independent bounded native validation armed. It is a truthful
    /// no-op otherwise, so bounded validation and finite resident diagnostic
    /// runs terminate exactly as configured (their termination semantics do not
    /// change). The non-resident path is unchanged.
    ///
    /// Generation fence: the generation is bumped *before* the old driver is
    /// stopped, so every `onReport`/`onFailure`/`onStop` callback the old driver
    /// still has queued on the main queue is inert by the time it fires — it can
    /// neither mutate the freshly reset state nor emit a stale termination. The
    /// fresh driver's callbacks capture the new generation.
    ///
    /// Failure semantics: the cleared state is applied before fresh driver
    /// construction. If construction throws after the old driver was torn down,
    /// the app applies `ResidentResetTransition.failureRollback` — `isRunning`
    /// becomes `false`, no driver is left installed, and an explicit error is
    /// set on the HUD — so the app truthfully remains stopped rather than
    /// silently presenting `isRunning == true` with no driver.
    @discardableResult
    func resetInteractiveResidentSimulation() -> Bool {
        guard usesResidentRendering,
              SoupScopeAppLifecycle.canResetInteractiveResident(
                  plan: residentPlan, validationActive: validationActive),
              let context,
              let residentConfig else {
            return false
        }
        // Bump the lifecycle generation first so any callback the old driver
        // still has queued on the main queue is inert by the time it fires.
        lifecycleGeneration.bump()
        // Stop and join the old driver before constructing the fresh one. Its
        // run loop exits and schedules its onStop on the main queue; that
        // onStop captures the old generation and is inert under the fence.
        residentDriver?.stopAndWait()
        residentDriver = nil

        // Build the production reset-state transition for the current run
        // identity and drawable geometry. It clears HUD/error/counters,
        // displayed/source epoch, rendered frames, viz entropy
        // history/availability, and the metric channel, and carries the
        // camera-refit decision and running-state intent — one transaction the
        // shell and the tests share, instead of hand-reconstructed state.
        //
        // `residentFinalDiagnosticEmitter` is *not* part of the transition: it
        // is a one-shot termination guard for bounded runs, and Reset is only
        // allowed in the unbounded interactive mode where it has never
        // emitted, so leaving it preserves bounded termination semantics.
        let reset = ResidentResetTransition(deviceName: hud.deviceName,
                                            programCount: hud.programCount,
                                            drawableWidth: drawablePxW,
                                            drawableHeight: drawablePxH)
        residentDisplayedEpoch = reset.displayedEpoch
        residentRenderedFrames = reset.renderedFrames
        lastSnapshot = nil
        hud = reset.hud
        vizEntropyHistory = reset.vizEntropyHistory
        vizEntropyAvailable = reset.vizEntropyAvailable
        metricChannel = reset.metricChannel
        isRunning = reset.intendsToRun
        if frameStages != nil {
            frameStages = AppFrameStageAccumulator()
            lastEpochBatchSeconds = nil
            lastSnapshotBuildSeconds = nil
        }

        // Apply the camera refit and publish the HUD LOD readout through one
        // transition method that owns the ordering — refit first (when the
        // drawable is usable), then read the LOD from the *post-refit* camera —
        // so the published HUD LOD matches the post-reset camera, never the
        // pre-refit camera the user just panned/zoomed. When no drawable has
        // arrived yet, the transition leaves the camera untouched and returns
        // `didFit == false` so the next `updateDrawableSize` performs the first
        // fit — exactly like launch.
        let refitResult = reset.applyRefitAndBuildLODReadout(
            camera: &camera, geometry: cameraGeometry(), lod: lod)
        didFit = refitResult.didFit
        lodReadout = refitResult.lodReadout

        // Construct the fresh driver from the unchanged immutable
        // config/plan/shared device+queue. Its callbacks capture the new
        // generation; no in-place reset is added to ResidentMetalEpochRunner.
        do {
            let driver = try makeResidentDriver(context: context, residentConfig: residentConfig)
            residentDriver = driver
            driver.start()
            objectWillChange.send()
            return true
        } catch {
            // Fresh construction failed after the old driver was torn down.
            // Truthfully remain stopped: no driver (already `nil`), `isRunning`
            // set to the failure rollback's `false`, and an explicit error on
            // the HUD — never silently "running" with no driver.
            let rollback = ResidentResetTransition.failureRollback
            isRunning = rollback.isRunning
            hud.setError((hud.errorState.map { $0 + "; " } ?? "")
                         + "resident reset failed: \(error)")
            objectWillChange.send()
            return false
        }
    }

    // MARK: - Bounded native validation
    //
    // `--validation-seconds` must terminate finitely even if the MTKView never gets
    // a drawable or a display callback. Two display-independent inputs drive the pure
    // `ValidationRun`: completed render submissions (the success path, from the
    // command buffer's completion handler) and a one-shot main-run-loop watchdog (the
    // finite backstop). Neither advances epochs. The run latches its first terminal
    // verdict, so `finishValidation` runs exactly once even under a race.

    /// Arm the one-shot, display-independent watchdog on the main run loop. Called
    /// once at launch. If Metal never came up there is nothing to validate, so the
    /// deadline is immediate; otherwise it is the grace deadline — the backstop for a
    /// run that produces no drawable within `requestedSeconds + grace`.
    private func beginValidationIfNeeded() {
        guard let seconds = options.validationSeconds, validationRun == nil else { return }
        let policy = ValidationPolicy(requestedSeconds: seconds, metalAvailable: context != nil)
        validationRun = ValidationRun(policy: policy)
        validationStart = AppMonotonicClock.nowSeconds()
        let deadline = policy.metalAvailable ? policy.graceDeadline : 0
        let timer = Timer(timeInterval: max(0, deadline), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateValidation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        validationTimer = timer
    }

    /// Record the frame's submitted command buffer so a pending exit can wait on it.
    func noteRenderSubmitted(_ buffer: MTLCommandBuffer) {
        guard validationActive else { return }
        lastCommandBuffer = buffer
    }

    /// One completed render submission (from the command buffer's completion handler)
    /// — the success path, so a run finishes only after a real render has landed.
    func noteDrawCompleted() {
        guard validationActive else { return }
        completedDraws += 1
        evaluateValidation()
    }

    /// Feed the current display-independent facts to the run's state machine and, if
    /// it reaches a terminal verdict, finish exactly once.
    private func evaluateValidation() {
        guard let start = validationStart, validationRun != nil, !validationFinished else { return }
        let inputs = ValidationInputs(
            elapsedSeconds: AppMonotonicClock.nowSeconds() - start,
            completedDraws: completedDraws,
            hasError: hud.errorState != nil,
            shadowMismatch: hud.shadowMismatch)
        if let outcome = validationRun!.step(inputs) {
            finishValidation(outcome)
        }
    }

    /// Print exactly one deterministic diagnostic line and terminate — the single
    /// termination path, guarded by `validationFinished` and the run's latch. Before
    /// exiting it waits on the last submitted buffer so we never tear down a render
    /// command buffer that is still in flight (in the completion-handler path that
    /// buffer is already done, so the wait returns immediately).
    private func finishValidation(_ outcome: ValidationOutcome) {
        guard !validationFinished else { return }
        validationFinished = true
        validationTimer?.invalidate()
        validationTimer = nil

        if let cb = lastCommandBuffer, cb.status != .completed {
            cb.waitUntilCompleted()
        }

        let h = hud
        let line = "validation outcome=\(outcome.statusToken) "
            + "requestedSeconds=\(options.validationSeconds ?? 0) "
            + "completedDraws=\(completedDraws) epochs=\(h.epoch) "
            + "lastBatchEpochs=\(h.lastBatchEpochs) "
            + String(format: "lastBatchMs=%.3f msPerEpoch=%.4f ", h.lastBatchMs, h.msPerEpoch)
            + "halt[budget=\(h.haltBudget),pcOut=\(h.haltPCOut),"
            + "unmatched=\(h.haltUnmatched),unknown=\(h.haltUnknown)] "
            + "copyWrites=\(h.copyWrites) "
            + "shadowChecked=\(h.shadowChecked) shadowMismatch=\(h.shadowMismatch) "
            + "programs=\(h.programCount) device=\"\(h.deviceName)\" "
            + "error=\(h.errorState ?? "none")"
        // Append the opt-in per-frame host-stage attribution when enabled and any frame
        // was folded; absent otherwise so the default diagnostic line is unchanged.
        let stageLine = frameStages?.summary().map { " frameStages[\($0.summaryLine)]" }
        print(line + (stageLine ?? ""))
        // C `exit` flushes stdio: 0 success, 1 error/mismatch/no-progress, 2 no Metal.
        exit(outcome.exitCode)
    }
}
#endif
