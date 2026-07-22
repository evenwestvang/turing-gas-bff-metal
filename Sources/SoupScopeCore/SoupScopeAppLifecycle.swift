import Foundation

/// The SwiftUI scene shape SoupScope composes for a launch plan.
public enum SoupScopeSceneComposition: Equatable, Sendable {
    case sharedWindowGroup(id: String)

    public var windowSceneID: String {
        switch self {
        case let .sharedWindowGroup(id):
            return id
        }
    }
}

/// The initial snapshot source the app shell seeds `lastSnapshot` from at
/// launch, derived from the launch plan. The non-resident path builds the
/// epoch-0 `RenderSnapshot.initial` from the constructed legacy CPU runner's
/// seeded soup; the resident path skips that build (its soup lives on the GPU)
/// and leaves `lastSnapshot` `nil` until the resident driver produces a frame.
public enum InitialSnapshotSource: Equatable, Sendable {
    case legacyCPURunner
    case none
}

/// Portable lifecycle invariants for the SoupScope macOS shell.
///
/// These are pure values (no AppKit/SwiftUI dependency) so the app's
/// lifecycle/configuration contract is testable on Linux, exactly like the
/// other pure models in this module. The SwiftUI shell consumes these
/// constants so the shell and the tests share one source of truth.
public enum SoupScopeAppLifecycle {
    /// The shared `WindowGroup` scene identifier the SwiftUI shell uses.
    ///
    /// SoupScope is a single-window app rendered through one automatically
    /// presented shared `WindowGroup`: SwiftUI presents the one main window at
    /// launch with no explicit `openWindow`/AppKit `NSWindow` wiring. The id is
    /// constant and tested so the shell cannot drift from the contract.
    public static let windowSceneID = "dev.bff.soupscope.window"

    /// The production SwiftUI scene composition for every launch plan. Both
    /// resident and non-resident launches share the same automatically
    /// presented `WindowGroup` plan; routing differences live in
    /// `constructsLegacyCPURunner`/`initialSnapshotSource`, not the scene.
    public static func sceneComposition(for plan: ResidentAppRunPlan) -> SoupScopeSceneComposition {
        _ = plan
        return .sharedWindowGroup(id: windowSceneID)
    }

    /// True iff the legacy CPU `SoupRunner` should be constructed for this plan.
    public static func constructsLegacyCPURunner(for plan: ResidentAppRunPlan) -> Bool {
        !plan.enabled
    }

    /// True iff the legacy CPU `SoupRunner` should be constructed for this
    /// ecology plan. The ecology engine is GPU-resident and shares the
    /// accepted `EcologyMetalEpochRunner`; it constructs neither the legacy
    /// CPU `SoupRunner` nor the grounded `ResidentSimulationDriver`, so this
    /// is always `false`.
    public static func constructsLegacyCPURunner(forEcology plan: EcologyAppRunPlan) -> Bool {
        _ = plan
        return false
    }

    /// The initial snapshot source for this ecology plan. The ecology soup
    /// lives on the GPU; the app never builds an epoch-0 CPU snapshot, so the
    /// source is `.none` exactly like the resident path.
    public static func initialSnapshotSource(forEcology plan: EcologyAppRunPlan) -> InitialSnapshotSource {
        _ = plan
        return .none
    }

    /// The initial snapshot source for this plan: non-resident mode seeds
    /// `lastSnapshot` from the legacy CPU runner's soup; resident mode seeds
    /// nothing (its soup lives on the GPU). Derived from the same
    /// `constructsLegacyCPURunner` invariant so the shell and tests share one
    /// source of truth.
    public static func initialSnapshotSource(for plan: ResidentAppRunPlan) -> InitialSnapshotSource {
        constructsLegacyCPURunner(for: plan) ? .legacyCPURunner : .none
    }

    /// True iff the user-visible Reset gesture is allowed for this launch plan
    /// and current app state.
    ///
    /// Reset reconstructs the resident simulation driver from its immutable
    /// config/plan/shared Metal device+queue, so it is only meaningful for the
    /// *interactive resident well-mixed* mode — i.e. a resident run whose limit
    /// is `unbounded`, with `tinyValidation` off, and no display-independent
    /// bounded native validation armed. It is a truthful no-op otherwise:
    ///
    /// - A bounded resident run (`--resident-epochs` / `--resident-seconds`) or a
    ///   `--resident-tiny-validation` diagnostic run must terminate exactly as
    ///   configured; reset would change bounded termination semantics, so it is
    ///   rejected.
    /// - A `--validation-seconds` bounded native validation run must terminate
    ///   finitely on its own timer/draw verdict; reset would re-open the run, so
    ///   it is rejected.
    /// - The non-resident path has no resident driver to reconstruct, so it is
    ///   rejected (the non-resident behavior is otherwise unchanged).
    ///
    /// Pure value decision so the shell and the tests share one source of truth.
    public static func canResetInteractiveResident(plan: ResidentAppRunPlan,
                                                   validationActive: Bool) -> Bool {
        guard plan.enabled, !plan.limit.isBounded, !plan.tinyValidation else {
            return false
        }
        return !validationActive
    }

    /// True iff the user-visible Reset gesture is allowed for this ecology
    /// launch plan and current app state.
    ///
    /// Ecology Reset mirrors the resident contract: it reconstructs the
    /// `EcologySimulationDriver` from the **immutable** `EcologyAppRunPlan`
    /// and the shared Metal device+queue, so it is only meaningful for the
    /// *interactive* ecology mode — an ecology run whose limit is `unbounded`,
    /// with `tinyValidation` off, and no display-independent bounded native
    /// validation armed. It is a truthful no-op otherwise, so bounded /
    /// tiny-validation / validation-seconds runs terminate exactly as
    /// configured. The non-ecology paths are unchanged.
    ///
    /// Pure value decision so the shell and tests share one source of truth.
    public static func canResetInteractiveEcology(plan: EcologyAppRunPlan,
                                                  validationActive: Bool) -> Bool {
        guard plan.enabled, !plan.limit.isBounded, !plan.tinyValidation else {
            return false
        }
        return !validationActive
    }

    /// The camera-refit decision Reset applies, derived from the current
    /// drawable geometry (pixels, already backing-scaled). When the drawable is
    /// usable, Reset frames the whole populated soup right away and keeps the
    /// "already fitted" latch set so a later resize clamps instead of re-fitting.
    /// When no drawable has arrived yet, Reset clears the latch so the next
    /// `updateDrawableSize` performs the first fit — exactly like launch.
    ///
    /// Pure value decision so the camera-refit contract is unit-testable on any
    /// host (no AppKit, no Metal), matching the rest of the lifecycle invariants.
    public static func resetCameraRefitDecision(drawableWidth: Double,
                                                drawableHeight: Double
    ) -> ResidentResetRefitDecision {
        let usable = drawableWidth > 0 && drawableHeight > 0
        return ResidentResetRefitDecision(shouldRefitNow: usable, didFit: usable)
    }
}

/// Monotonically increasing lifecycle generation for the resident simulation
/// driver. Every `onReport` / `onFailure` / `onStop` callback captures the
/// generation of the driver it belongs to and is inert unless it is still
/// current, so callbacks queued by an old driver that are still in flight when
/// Reset constructs a fresh driver cannot mutate the new state or emit a stale
/// termination.
///
/// Pure value type: the shell holds one instance and bumps it before stopping
/// the old driver; the test suite proves the fence without any AppKit/Metal.
public struct ResidentLifecycleGeneration: Equatable, Sendable {
    /// The current generation. Starts at `0` so the first (launch-time) driver's
    /// callbacks — which capture `0` — are current until the first Reset bumps
    /// it to `1`.
    public private(set) var current: UInt64

    public init(current: UInt64 = 0) {
        self.current = current
    }

    /// Advance the generation and return the new current value, which the
    /// freshly constructed driver captures in its callbacks. Uses wrapping add
    /// so a long-running interactive session never traps on overflow.
    @discardableResult
    public mutating func bump() -> UInt64 {
        current &+= 1
        return current
    }

    /// True iff `generation` is the current generation, i.e. the callback that
    /// captured it still belongs to the live driver.
    public func isCurrent(_ generation: UInt64) -> Bool {
        generation == current
    }
}

/// The camera-refit action Reset takes for the current drawable geometry.
public struct ResidentResetRefitDecision: Equatable, Sendable {
    /// True iff `Camera.fitAll` should be called now against the current
    /// `CameraGeometry` (the drawable is usable).
    public var shouldRefitNow: Bool
    /// The value to assign the "already fitted" latch after Reset: `true` when
    /// the camera was just fitted, `false` when there is no drawable yet so the
    /// next `updateDrawableSize` performs the first fit.
    public var didFit: Bool

    public init(shouldRefitNow: Bool, didFit: Bool) {
        self.shouldRefitNow = shouldRefitNow
        self.didFit = didFit
    }
}

/// The app-visible reset-state transition: a pure value the AppModel builds
/// from the run identity (HUD device name + program count) and the current
/// drawable geometry, then applies to its published state. It is the single
/// production transaction for the user-visible resident Reset, so the cleared
/// HUD/error/counters, displayed/source epoch, rendered frames, entropy
/// history/availability, default channel, LOD/camera-refit decision, and
/// running-state intent are all defined and tested in one place — not
/// reconstructed by hand in tests or in the shell.
///
/// `lodReadout(afterRefit:lod:)` is deliberately a function of the *post-refit*
/// `Camera`: the shell applies `refit` to its `Camera` first, then asks the
/// transition for the HUD LOD readout, so the published readout matches the
/// post-reset camera instead of the pre-refit camera the user just panned/
/// zoomed. When no drawable has arrived yet, `refit.shouldRefitNow` is `false`
/// and the readout is built from the un-refit (launch-time) camera, exactly
/// like launch.
///
/// `intendsToRun` is the running-state intent on a *successful* reset (the fresh
/// driver is about to start). When fresh driver construction fails after the
/// old driver was torn down, the shell applies `failureRollback` instead, so the
/// app truthfully remains stopped — `isRunning = false`, no driver, an explicit
/// error — never silently "running" with no driver.
///
/// Pure value type: no AppKit, no Metal, fully testable on any host.
public struct ResidentResetTransition: Equatable, Sendable {
    /// Cleared HUD. Preserves run identity (device name + program count) and
    /// clears simulation/counter/error/resident-diagnostic state.
    public let hud: HUDModel
    /// Reset resident displayed/source epoch (0).
    public let displayedEpoch: Int
    /// Reset rendered-frame count (0).
    public let renderedFrames: Int
    /// Fresh entropy-over-time history (cleared, default capacity).
    public let vizEntropyHistory: VizEntropyHistory
    /// Reset entropy-availability flag (false — no samples yet).
    public let vizEntropyAvailable: Bool
    /// Reset metric channel — the default resident fast view (Composite).
    public let metricChannel: UInt32
    /// The camera-refit decision for the current drawable geometry.
    public let refit: ResidentResetRefitDecision
    /// Running-state intent on a successful reset. The shell sets `isRunning`
    /// to this on success; on construction failure it applies
    /// `failureRollback` instead.
    public let intendsToRun: Bool

    /// Build the transition from the run identity and the current drawable
    /// geometry (pixels, already backing-scaled). All cleared fields are
    /// derived from the same launch-time contract the app applied at startup.
    public init(deviceName: String, programCount: Int,
                drawableWidth: Double, drawableHeight: Double) {
        self.hud = HUDModel(deviceName: deviceName, programCount: programCount)
        self.displayedEpoch = 0
        self.renderedFrames = 0
        self.vizEntropyHistory = VizEntropyHistory()
        self.vizEntropyAvailable = false
        self.metricChannel = ResidentVizChannel.defaultChannel.rawValue
        self.refit = SoupScopeAppLifecycle.resetCameraRefitDecision(
            drawableWidth: drawableWidth, drawableHeight: drawableHeight)
        self.intendsToRun = true
    }

    /// Apply the camera refit and build the HUD LOD readout in the correct
    /// order — refit first (when `refit.shouldRefitNow`), then read the LOD
    /// from the *post-refit* camera — so the published HUD LOD matches the
    /// post-reset camera, never the pre-refit camera the user just panned/
    /// zoomed. Returns the readout and the post-refit "already fitted" latch
    /// value to assign. The shell calls this single method instead of applying
    /// the refit and reading the LOD separately, so the ordering cannot drift.
    ///
    /// When `refit.shouldRefitNow` is `false` (no drawable yet), the camera is
    /// left untouched and the readout is built from the launch-time camera,
    /// exactly like launch; the returned `didFit` is `false` so the next
    /// `updateDrawableSize` performs the first fit.
    public func applyRefitAndBuildLODReadout(camera: inout Camera,
                                             geometry: CameraGeometry,
                                             lod: LODModel
    ) -> (lodReadout: LODReadout, didFit: Bool) {
        if refit.shouldRefitNow {
            camera.fitAll(geometry)
        }
        return (LODReadout(camera: camera, lod: lod), refit.didFit)
    }

    /// Build the HUD LOD readout from a camera the caller has already refit.
    /// Prefer `applyRefitAndBuildLODReadout` so the refit/readout ordering is
    /// owned by the transition; this is kept for callers that must refit
    /// outside the transition (e.g. tests that pin the post-refit camera).
    public func lodReadout(afterRefit camera: Camera, lod: LODModel) -> LODReadout {
        LODReadout(camera: camera, lod: lod)
    }

    /// The running-state + error contract Reset applies when fresh driver
    /// construction fails after the old driver was torn down. The app must
    /// truthfully remain stopped — `isRunning = false`, no driver — with an
    /// explicit error, never silently "running" with no driver.
    public static let failureRollback = ResidentResetFailureRollback()
}

/// The running-state + error contract for the reset failure path. The app
/// applies this when fresh `ResidentSimulationDriver` construction throws after
/// the old driver was torn down, so the app truthfully remains stopped rather
/// than silently presenting `isRunning == true` with no driver.
///
/// Pure value type so the failure contract is unit-testable on any host.
public struct ResidentResetFailureRollback: Equatable, Sendable {
    /// The value to assign `isRunning` on construction failure. Always `false`:
    /// there is no driver to advance the simulation, so the app must not claim
    /// it is running.
    public let isRunning: Bool
    /// True iff the shell must set an explicit, non-nil error on the HUD before
    /// returning from Reset. The app must never silently report "stopped with no
    /// error" after a failed reconstruction.
    public let requiresExplicitError: Bool

    public init() {
        self.isRunning = false
        self.requiresExplicitError = true
    }
}
