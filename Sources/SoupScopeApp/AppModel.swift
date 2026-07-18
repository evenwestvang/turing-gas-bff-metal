#if canImport(MetalKit)
import Foundation
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
final class AppModel: ObservableObject {
    let options: AppLaunchOptions
    let config: SoupConfig
    let grid: ProgramGrid
    let lod = LODModel()
    let normalization: MetricNormalization

    var camera = Camera()
    var batcher: AdaptiveBatcher
    /// 0 activity, 1 entropy, 2 life composite (default).
    var metricChannel: UInt32 = 2
    var isRunning = true

    @Published private(set) var hud: HUDModel

    /// The LOD readout of the most recently submitted render frame — the exact
    /// `LODReadout` that fed the shader uniforms, surfaced for the HUD so the
    /// displayed zoom/blend values are byte-for-byte what is being rendered. It is
    /// `@Published` (not a computed re-evaluation) so a camera-only zoom/pan, which
    /// never advances an epoch or mutates `hud`, still refreshes the HUD — including
    /// while paused. Updated only from `makeUniforms`, and only when the value
    /// actually changed, so it never spins a redundant SwiftUI update.
    @Published private(set) var lodReadout: LODReadout

    let context: SharedMetalContext?
    private var runner: SoupRunner
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
    private var validationStart: CFAbsoluteTime?
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

        let resolvedConfig: SoupConfig
        do {
            resolvedConfig = try parsed.soupConfig()
        } catch {
            // A valid, modest default so the app still runs and shows the error.
            resolvedConfig = (try? SoupConfig(seed: parsed.seed, programCount: 1024))
                ?? (try! SoupConfig(seed: 1, programCount: 1024))
            startupError = (startupError.map { $0 + "; " } ?? "") + "config: \(error)"
        }
        self.config = resolvedConfig
        self.grid = ProgramGrid(programCount: resolvedConfig.programCount)
        self.normalization = MetricNormalization(stepBudget: resolvedConfig.stepBudget)
        self.runner = SoupRunner(config: resolvedConfig)
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

        self.lastSnapshot = try? RenderSnapshot.initial(programCount: resolvedConfig.programCount,
                                                        soup: runner.soup)

        // Arm the display-independent validation watchdog (no-op for interactive
        // launch, which omits --validation-seconds).
        beginValidationIfNeeded()
    }

    // MARK: - Frame driving

    /// Advance one bounded epoch batch and return the snapshot to render. Called
    /// from the renderer each frame. On failure it stops advancing and leaves the
    /// error visible (never spins/retries). Returns the latest snapshot regardless
    /// so the last good frame stays on screen.
    func stepFrame() -> RenderSnapshot? {
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

        let epochsToRun = batcher.nextBatchEpochs()
        let t0 = CFAbsoluteTimeGetCurrent()
        var reports: [EpochReport] = []
        reports.reserveCapacity(epochsToRun)
        do {
            for _ in 0 ..< epochsToRun {
                reports.append(try runner.runEpoch(using: evaluator))
            }
        } catch {
            hud.setError("epoch execution failed: \(error)")
            return lastSnapshot
        }
        let batchMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
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
            let s0 = frameStages != nil ? CFAbsoluteTimeGetCurrent() : 0
            lastSnapshot = try? RenderSnapshot.build(epoch: runner.epoch,
                                                     programCount: config.programCount,
                                                     soup: runner.soup, metrics: metrics)
            if frameStages != nil { snapshotBuildSeconds = CFAbsoluteTimeGetCurrent() - s0 }
        }
        // Stash this frame's app-stage spans for the renderer to fold (only when timing).
        if frameStages != nil {
            lastEpochBatchSeconds = batchMs / 1000
            lastSnapshotBuildSeconds = snapshotBuildSeconds
        }
        return lastSnapshot
    }

    /// Fold one frame's app-stage spans into the accumulator, pairing the renderer's
    /// frame wall + Metal-only spans with the epoch-batch and snapshot-build spans
    /// `stepFrame` measured. No-op unless `--frame-stage-timing` is on.
    func recordFrameStages(frameSeconds: Double, metricTextureSeconds: Double?,
                           renderSubmitSeconds: Double?) {
        guard frameStages != nil else { return }
        frameStages?.record(AppFrameStageSample(
            frameSeconds: frameSeconds,
            epochBatchSeconds: lastEpochBatchSeconds,
            snapshotBuildSeconds: lastSnapshotBuildSeconds,
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
        isRunning.toggle()
        objectWillChange.send()          // reflect the paused flag immediately
    }
    func cycleMetricChannel() {
        metricChannel = (metricChannel + 1) % 3
        objectWillChange.send()
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
        validationStart = CFAbsoluteTimeGetCurrent()
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
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - start,
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
