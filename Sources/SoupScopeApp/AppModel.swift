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

    let context: SharedMetalContext?
    private var runner: SoupRunner
    private(set) var lastSnapshot: RenderSnapshot?

    // Drawable geometry (pixels), set by the renderer on resize.
    private var drawablePxW: Double = 0
    private var drawablePxH: Double = 0
    private var didFit = false

    // Bounded-validation state.
    private var validationStart: CFAbsoluteTime?
    private var validationFinished = false

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

        self.lastSnapshot = try? RenderSnapshot.initial(programCount: resolvedConfig.programCount,
                                                        soup: runner.soup)
    }

    // MARK: - Frame driving

    /// Advance one bounded epoch batch and return the snapshot to render. Called
    /// from the renderer each frame. On failure it stops advancing and leaves the
    /// error visible (never spins/retries). Returns the latest snapshot regardless
    /// so the last good frame stays on screen.
    func stepFrame() -> RenderSnapshot? {
        maybeFinishValidation()
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
        if let metrics {
            lastSnapshot = try? RenderSnapshot.build(epoch: runner.epoch,
                                                     programCount: config.programCount,
                                                     soup: runner.soup, metrics: metrics)
        }
        return lastSnapshot
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

    func cameraGeometry() -> CameraGeometry {
        CameraGeometry(soupByteWidth: Double(grid.byteWidth),
                       soupByteHeight: Double(grid.byteHeight),
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

    /// The uniforms for the current frame.
    func makeUniforms() -> VizUniforms {
        VizLayout.makeUniforms(camera: camera, grid: grid, lod: lod,
                               metricChannel: metricChannel,
                               viewPxWidth: drawablePxW, viewPxHeight: drawablePxH)
    }

    // MARK: - Bounded native validation

    private func maybeFinishValidation() {
        guard let seconds = options.validationSeconds, !validationFinished else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if validationStart == nil {
            validationStart = now
            // If Metal never came up, there is nothing to validate — report and exit.
            if context == nil { finishValidation(seconds: seconds); }
            return
        }
        if now - validationStart! >= seconds {
            finishValidation(seconds: seconds)
        }
    }

    private func finishValidation(seconds: Double) {
        guard !validationFinished else { return }
        validationFinished = true
        let h = hud
        let mismatch = h.shadowMismatch
        let hasError = h.errorState != nil
        let line = "validation seconds=\(seconds) epochs=\(h.epoch) "
            + "lastBatchEpochs=\(h.lastBatchEpochs) "
            + String(format: "lastBatchMs=%.3f msPerEpoch=%.4f ", h.lastBatchMs, h.msPerEpoch)
            + "halt[budget=\(h.haltBudget),pcOut=\(h.haltPCOut),"
            + "unmatched=\(h.haltUnmatched),unknown=\(h.haltUnknown)] "
            + "copyWrites=\(h.copyWrites) "
            + "shadowChecked=\(h.shadowChecked) shadowMismatch=\(mismatch) "
            + "programs=\(h.programCount) device=\"\(h.deviceName)\" "
            + "error=\(h.errorState ?? "none")"
        print(line)
        // Clean termination (C `exit` flushes stdio): 0 on success, 1 on any
        // mismatch/error, 2 if Metal never came up.
        let code: Int32 = context == nil ? 2 : ((mismatch > 0 || hasError) ? 1 : 0)
        exit(code)
    }
}
#endif
