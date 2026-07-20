import XCTest
import BFFMetal
import BFFOracle
@testable import SoupScopeCore

/// Behavioral tests for the user-visible resident Reset feature.
///
/// Reset is an AppModel (macOS) behavior, but its contract is expressed through
/// pure SoupScopeCore helpers — the gate decision, the lifecycle generation
/// fence, the reset-state transition (`ResidentResetTransition`), the
/// failure-rollback contract (`ResidentResetTransition.failureRollback`), and
/// the deterministic-reconstruction property of the resident config — so the
/// whole contract is testable on any host without AppKit/Metal. These tests
/// prove:
///
/// - the generation fence (old queued callbacks are inert after a bump);
/// - deterministic reconstruction / repeated trajectory from fresh construction
///   of the resident runner with unchanged immutable config;
/// - the production reset-state transition clears HUD/error/counters,
///   displayed/source epoch, rendered frames, entropy history/availability,
///   the default channel, and carries the LOD/camera-refit decision and
///   running-state intent;
/// - the LOD readout is published from the *post-refit* camera (the contract
///   that catches blocker 1: HUD LOD must match the post-reset camera);
/// - the failure-rollback contract for a failed fresh driver construction
///   (the contract that catches blocker 2: the app remains stopped with an
///   explicit error, never silently "running" with no driver);
/// - the camera-refit contract (refit now when the drawable is usable, defer
///   to the next resize otherwise);
/// - bounded-validation / finite-plan rejection (Reset is a truthful no-op
///   outside interactive resident well-mixed mode).
///
/// No source-string tests: every assertion is against observable behavior.
final class ResidentResetTests: XCTestCase {

    // MARK: - Reset gate

    private func plan(enabled: Bool = true,
                      limit: ResidentRunLimit = .unbounded,
                      tinyValidation: Bool = false) -> ResidentAppRunPlan {
        ResidentAppRunPlan(enabled: enabled,
                           planner: .keyed,
                           limit: limit,
                           tinyValidation: tinyValidation)
    }

    func testResetAllowedForInteractiveResidentWellMixedMode() {
        let interactive = plan(enabled: true, limit: .unbounded, tinyValidation: false)
        XCTAssertTrue(SoupScopeAppLifecycle.canResetInteractiveResident(
            plan: interactive, validationActive: false),
            "interactive resident unbounded mode must allow Reset")
    }

    func testResetRejectedForNonResidentPlan() {
        let nonResident = plan(enabled: false, limit: .unbounded, tinyValidation: false)
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveResident(
            plan: nonResident, validationActive: false),
            "non-resident mode must not Reset a resident driver")
    }

    func testResetRejectedForBoundedEpochLimit() {
        let bounded = plan(enabled: true, limit: .epochs(100), tinyValidation: false)
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveResident(
            plan: bounded, validationActive: false),
            "bounded --resident-epochs runs must terminate exactly as configured")
    }

    func testResetRejectedForBoundedSecondsLimit() {
        let bounded = plan(enabled: true, limit: .seconds(30), tinyValidation: false)
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveResident(
            plan: bounded, validationActive: false),
            "bounded --resident-seconds runs must terminate exactly as configured")
    }

    func testResetRejectedForTinyValidation() {
        let tiny = plan(enabled: true, limit: .unbounded, tinyValidation: true)
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveResident(
            plan: tiny, validationActive: false),
            "--resident-tiny-validation diagnostic runs must not be Reset")
    }

    func testResetRejectedWhileBoundedNativeValidationActive() {
        let interactive = plan(enabled: true, limit: .unbounded, tinyValidation: false)
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveResident(
            plan: interactive, validationActive: true),
            "--validation-seconds bounded native validation must not be Reset")
    }

    // MARK: - Generation fence

    func testLifecycleGenerationStartsAtZeroAndCurrent() {
        var gen = ResidentLifecycleGeneration()
        XCTAssertEqual(gen.current, 0)
        XCTAssertTrue(gen.isCurrent(0), "launch-time driver captures 0 and is current")
    }

    func testLifecycleGenerationBumpAdvancesAndFencesOldCallbacks() {
        var gen = ResidentLifecycleGeneration()
        let launchGeneration = gen.current

        let resetGeneration = gen.bump()
        XCTAssertEqual(resetGeneration, 1)
        XCTAssertEqual(gen.current, 1)
        XCTAssertFalse(gen.isCurrent(launchGeneration),
            "old callbacks (captured at launch) are inert after the first Reset")
        XCTAssertTrue(gen.isCurrent(resetGeneration),
            "the fresh driver's callbacks (captured at the new generation) are current")
    }

    func testLifecycleGenerationRepeatedBumpsFenceEveryPriorGeneration() {
        var gen = ResidentLifecycleGeneration()
        var captured: [UInt64] = [gen.current]
        for _ in 0..<3 {
            captured.append(gen.bump())
        }
        XCTAssertEqual(captured, [0, 1, 2, 3])
        // Only the very latest generation is current; every prior one is fenced.
        for g in captured.dropLast() {
            XCTAssertFalse(gen.isCurrent(g),
                "generation \(g) must be fenced after subsequent bumps")
        }
        XCTAssertTrue(gen.isCurrent(gen.current))
    }

    /// Simulate the end-to-end fence: an old driver's onStop is queued on the
    /// main queue; Reset bumps the generation before it fires; the old callback
    /// observes it is no longer current and must not mutate state or emit a
    /// termination. This is the behavioral contract the AppModel callback
    /// closures rely on, exercised purely against the helper.
    func testLifecycleGenerationFencesOldQueuedOnStopCallback() {
        var gen = ResidentLifecycleGeneration()
        var didFire = false
        var didTerminate = false

        // Launch-time driver captures generation 0.
        let oldGeneration = gen.current
        let oldOnStop: (ResidentDriverStopReason, ResidentProgressSnapshot) -> Void = { _, _ in
            guard gen.isCurrent(oldGeneration) else { return }
            didFire = true
            didTerminate = true
        }

        // Reset bumps the generation before the queued onStop fires.
        gen.bump()

        // The queued old onStop now fires on the main queue after Reset.
        oldOnStop(.requested, ResidentProgressSnapshot(simulationEpoch: 7,
                                                       textureSourceEpoch: 7,
                                                       failures: 0,
                                                       unknownHalts: 0))
        XCTAssertFalse(didFire, "old onStop must be inert under the generation fence")
        XCTAssertFalse(didTerminate,
            "old onStop must not emit a stale termination after Reset")
    }

    /// The fresh driver's callbacks, captured at the new generation, do fire and
    /// mutate state — proving the fence is generation-scoped, not a blanket
    /// suppression.
    func testLifecycleGenerationAllowsFreshCallbackToFire() {
        var gen = ResidentLifecycleGeneration()
        let oldGeneration = gen.current
        let newGeneration = gen.bump()

        var fired: UInt64? = nil
        let report = makeReferenceReport()
        let newOnReport: (ResidentEpochReport, Int) -> Void = { _, _ in
            guard gen.isCurrent(newGeneration) else { return }
            fired = newGeneration
        }
        newOnReport(report, 0)
        XCTAssertEqual(fired, newGeneration,
            "fresh callback captured at the current generation fires")
        XCTAssertNotEqual(newGeneration, oldGeneration)
    }

    // MARK: - Deterministic reconstruction / repeated trajectory

    /// Fresh construction from the unchanged immutable resident config restores
    /// the seeded soup and reproduces the exact same trajectory — the
    /// production guarantee Reset relies on. Uses the platform-independent
    /// `ResidentCPUReferenceRunner` (the same scalar oracle the resident Metal
    /// path is parity-checked against), so the trajectory test runs everywhere.
    func testFreshConstructionReproducesTrajectory() throws {
        let config = try ResidentEpochConfig(seed: 0xB00F,
                                             programCount: 16,
                                             stepBudget: 512,
                                             checkpointInterval: 1)

        var a = ResidentCPUReferenceRunner(config: config)
        var b = ResidentCPUReferenceRunner(config: config)

        // Both freshly constructed runners start from the same seeded soup.
        XCTAssertEqual(a.soup, b.soup,
            "fresh construction restores the seeded soup")
        XCTAssertEqual(a.epoch, 0)
        XCTAssertEqual(b.epoch, 0)

        // Running the same number of epochs reproduces the trajectory byte
        // for byte and report for report.
        let epochs = 5
        var reportsA: [ResidentEpochReport] = []
        var reportsB: [ResidentEpochReport] = []
        for _ in 0..<epochs {
            reportsA.append(a.runEpoch())
            reportsB.append(b.runEpoch())
        }

        XCTAssertEqual(a.soup, b.soup,
            "fresh construction from unchanged config reproduces the soup trajectory")
        XCTAssertEqual(a.epoch, epochs)
        XCTAssertEqual(b.epoch, epochs)
        XCTAssertEqual(reportsA.count, reportsB.count)
        for (x, y) in zip(reportsA, reportsB) {
            XCTAssertEqual(x.counters, y.counters,
                "fresh construction reproduces per-epoch counters")
            XCTAssertEqual(x.checkpointSoup, y.checkpointSoup,
                "fresh construction reproduces per-epoch checkpoints")
            XCTAssertEqual(x.permutationFingerprint, y.permutationFingerprint,
                "fresh construction reproduces the planner/RNG permutation fingerprint")
        }
    }

    /// A second fresh runner constructed *after* a first has advanced still
    /// reproduces the first's trajectory from epoch zero — proving Reset's
    /// reconstruction is independent of the prior driver's history (the old
    /// driver's state is not consulted).
    func testFreshConstructionAfterAdvanceStillReproducesTrajectory() throws {
        let config = try ResidentEpochConfig(seed: 1234,
                                             programCount: 8,
                                             stepBudget: 256)
        var first = ResidentCPUReferenceRunner(config: config)
        for _ in 0..<4 { _ = first.runEpoch() }
        XCTAssertGreaterThan(first.epoch, 0)

        // Fresh construction after the first advanced — independent of it.
        var fresh = ResidentCPUReferenceRunner(config: config)
        XCTAssertEqual(fresh.epoch, 0, "fresh construction restores epoch zero")
        XCTAssertEqual(fresh.soup, config.initialSoup(),
            "fresh construction restores the seeded soup, not the advanced soup")

        // Re-run the same trajectory from the fresh runner and compare against
        // a reference built the same way.
        var reference = ResidentCPUReferenceRunner(config: config)
        for _ in 0..<3 {
            let r = fresh.runEpoch()
            let s = reference.runEpoch()
            XCTAssertEqual(r.counters, s.counters)
        }
        XCTAssertEqual(fresh.soup, reference.soup,
            "fresh reconstruction repeats the deterministic trajectory")
    }

    // MARK: - Reset-state transition (production helper)

    /// The production `ResidentResetTransition` clears every app-visible field
    /// Reset touches and preserves only run identity (device name + program
    /// count). Exercises the same transaction the AppModel reset path calls,
    /// not a hand-reconstructed copy of its state.
    func testResetTransitionClearsHUDAndPreservesRunIdentity() {
        // A HUD advanced past launch — epoch, counters, an error, resident diag.
        var advanced = HUDModel(deviceName: "GPU", programCount: 16)
        advanced.epoch = 42
        advanced.rawSteps = 1000
        advanced.commandSteps = 600
        advanced.haltBudget = 5
        advanced.shadowChecked = 200
        advanced.shadowMismatch = 1
        advanced.setError("transient failure")
        let report = makeReferenceReport()
        advanced.record(resident: report,
                        planner: .keyed,
                        checkpointInterval: 1,
                        displayedEpoch: 40,
                        failureCount: 3)
        XCTAssertNotNil(advanced.errorState)
        XCTAssertNotNil(advanced.resident)

        let transition = ResidentResetTransition(deviceName: advanced.deviceName,
                                                 programCount: advanced.programCount,
                                                 drawableWidth: 1280,
                                                 drawableHeight: 720)
        let cleared = transition.hud
        // Run identity is preserved.
        XCTAssertEqual(cleared.deviceName, "GPU")
        XCTAssertEqual(cleared.programCount, 16)
        // Simulation/counter/error/resident state is cleared.
        XCTAssertEqual(cleared.epoch, 0, "fresh HUD resets epoch to zero")
        XCTAssertEqual(cleared.rawSteps, 0)
        XCTAssertEqual(cleared.commandSteps, 0)
        XCTAssertEqual(cleared.haltBudget, 0)
        XCTAssertEqual(cleared.shadowChecked, 0)
        XCTAssertEqual(cleared.shadowMismatch, 0)
        XCTAssertNil(cleared.errorState, "fresh HUD clears the error state")
        XCTAssertNil(cleared.resident, "fresh HUD clears the resident diagnostics")
    }

    func testResetTransitionClearsDisplayedAndSourceEpochAndRenderedFrames() {
        let transition = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                 drawableWidth: 1280, drawableHeight: 720)
        XCTAssertEqual(transition.displayedEpoch, 0,
            "reset zeroes the displayed/source epoch")
        XCTAssertEqual(transition.renderedFrames, 0,
            "reset zeroes the rendered-frame count")
    }

    func testResetTransitionClearsEntropyHistoryAndAvailability() {
        // Populate a history the way receiveResidentVizEntropy would.
        var populated = VizEntropyHistory()
        for epoch in 0..<8 {
            populated.record(VizEntropySample(epoch: epoch,
                                             meanByteEntropyBitsPerByte: 2.5))
        }
        XCTAssertFalse(populated.isEmpty)
        XCTAssertEqual(populated.count, 8)

        let transition = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                 drawableWidth: 1280, drawableHeight: 720)
        let cleared = transition.vizEntropyHistory
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(cleared.count, 0)
        XCTAssertEqual(cleared.capacity, VizEntropyHistory.defaultCapacity,
            "fresh history keeps the default capacity")
        XCTAssertFalse(transition.vizEntropyAvailable,
            "entropy availability must be reset to false")
    }

    func testResetTransitionResetsMetricChannelToDefault() {
        let transition = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                 drawableWidth: 1280, drawableHeight: 720)
        XCTAssertEqual(transition.metricChannel, ResidentVizChannel.defaultChannel.rawValue)
        XCTAssertEqual(transition.metricChannel, ResidentVizChannel.composite.rawValue)
    }

    func testResetTransitionCarriesCameraRefitDecision() {
        let usable = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                             drawableWidth: 1280, drawableHeight: 720)
        XCTAssertTrue(usable.refit.shouldRefitNow)
        XCTAssertTrue(usable.refit.didFit)

        let deferred = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                drawableWidth: 0, drawableHeight: 0)
        XCTAssertFalse(deferred.refit.shouldRefitNow)
        XCTAssertFalse(deferred.refit.didFit)
    }

    func testResetTransitionRunningStateIntentIsTrueOnSuccess() {
        let transition = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                 drawableWidth: 1280, drawableHeight: 720)
        XCTAssertTrue(transition.intendsToRun,
            "a successful reset intends to run the fresh driver")
    }

    // MARK: - LOD readout is published from the post-refit camera (blocker 1)

    /// The published HUD LOD readout must match the *post-refit* camera, not the
    /// pre-refit camera the user just panned/zoomed. The transition's
    /// `applyRefitAndBuildLODReadout` is the single production method the
    /// AppModel calls; it owns the refit→readout ordering, so the shell cannot
    /// get it wrong. This test would catch a regression that published the
    /// readout before the refit.
    func testResetTransitionAppliesRefitThenBuildsLODReadoutFromPostRefitCamera() {
        let geometry = CameraGeometry(soupByteWidth: 64, soupByteHeight: 32,
                                       viewPxWidth: 1280, viewPxHeight: 720)
        var camera = Camera()
        // Pan/zoom the camera away from the launch fit, like a user session.
        camera.zoom(factor: 4.0, anchorPxX: 640, anchorPxY: 360, geometry: geometry)
        camera.pan(dxPx: 200, dyPx: 120, geometry: geometry)
        let zoomedCamera = camera
        XCTAssertNotEqual(zoomedCamera.bytePx, Camera().bytePx,
            "sanity: the camera moved away from the launch fit")

        let lod = LODModel()
        let transition = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                 drawableWidth: geometry.viewPxWidth,
                                                 drawableHeight: geometry.viewPxHeight)
        XCTAssertTrue(transition.refit.shouldRefitNow)

        // The production seam: one call refits the camera and builds the
        // readout from the post-refit camera, in that order.
        let result = transition.applyRefitAndBuildLODReadout(camera: &camera,
                                                             geometry: geometry,
                                                             lod: lod)

        // The published readout must match a readout built from the post-refit
        // camera — the contract blocker 1 fixed.
        let expectedPostRefit = LODReadout(camera: camera, lod: lod)
        XCTAssertEqual(result.lodReadout, expectedPostRefit,
            "HUD LOD readout must match the post-refit camera")
        XCTAssertTrue(result.didFit,
            "a usable drawable leaves the already-fitted latch set")

        // And it must NOT match a readout built from the pre-refit (zoomed/
        // panned) camera — this is the assertion that would have caught
        // blocker 1.
        let fromZoomedPreRefit = LODReadout(camera: zoomedCamera, lod: lod)
        XCTAssertNotEqual(result.lodReadout, fromZoomedPreRefit,
            "HUD LOD readout must not be the pre-refit camera's readout")
    }

    /// When no drawable has arrived yet, the refit decision is deferred: the
    /// transition leaves the camera untouched and builds the readout from the
    /// launch-time (un-refit) camera — exactly like launch. Keeps the post-
    /// refit contract honest on the deferred path too.
    func testResetTransitionDeferredRefitLeavesCameraAndReturnsLaunchReadout() {
        let geometry = CameraGeometry(soupByteWidth: 64, soupByteHeight: 32,
                                       viewPxWidth: 0, viewPxHeight: 0)
        var camera = Camera()
        let beforeCamera = camera
        let lod = LODModel()
        let transition = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                 drawableWidth: 0, drawableHeight: 0)
        XCTAssertFalse(transition.refit.shouldRefitNow)

        let result = transition.applyRefitAndBuildLODReadout(camera: &camera,
                                                             geometry: geometry,
                                                             lod: lod)
        XCTAssertEqual(camera, beforeCamera,
            "deferred refit must not mutate the camera")
        XCTAssertEqual(result.lodReadout, LODReadout(camera: beforeCamera, lod: lod),
            "deferred refit builds the readout from the launch-time camera")
        XCTAssertFalse(result.didFit,
            "deferred refit clears the already-fitted latch so the next resize fits")
    }

    /// The transition's `lodReadout(afterRefit:)` convenience reads exactly the
    /// camera the caller passes (post-refit by contract); a pre-refit camera
    /// would show through verbatim. Pins the value-semantics snapshot contract.
    func testResetTransitionLODReadoutAfterRefitIsSnapshotOfInputCamera() {
        let lod = LODModel()
        var camera = Camera()
        let transition = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                                 drawableWidth: 1280, drawableHeight: 720)
        let snapshot = transition.lodReadout(afterRefit: camera, lod: lod)
        // Mutating the camera after asking for the readout must not change the
        // already-captured readout (value semantics).
        camera.zoom(factor: 4.0, anchorPxX: 640, anchorPxY: 360,
                    geometry: CameraGeometry(soupByteWidth: 64, soupByteHeight: 32,
                                               viewPxWidth: 1280, viewPxHeight: 720))
        XCTAssertEqual(snapshot.bytePx, LODReadout(camera: Camera(), lod: lod).bytePx,
            "the returned readout is a snapshot, not a live view")
    }

    // MARK: - Failure rollback semantics (blocker 2)

    /// If fresh driver construction fails after the old driver was torn down,
    /// the app must truthfully remain stopped — `isRunning = false` with an
    /// explicit error, never silently "running" with no driver. The
    /// `ResidentResetTransition.failureRollback` is the production contract the
    /// AppModel catch path applies; this test would catch a regression that
    /// left `isRunning == true` after a failed reconstruction.
    func testResetTransitionFailureRollbackLeavesAppStoppedWithExplicitError() {
        let rollback = ResidentResetTransition.failureRollback
        XCTAssertFalse(rollback.isRunning,
            "a failed reconstruction must leave isRunning == false — no driver exists")
        XCTAssertTrue(rollback.requiresExplicitError,
            "a failed reconstruction must surface an explicit error, not silent stop")
        // The failure rollback is distinct from the success intent: a successful
        // reset intends to run, a failed one must not.
        let success = ResidentResetTransition(deviceName: "GPU", programCount: 16,
                                              drawableWidth: 1280, drawableHeight: 720)
        XCTAssertNotEqual(success.intendsToRun, rollback.isRunning,
            "success intent (true) and failure rollback (false) must disagree on isRunning")
    }

    /// The failure rollback is a constant contract: every Reset that fails must
    /// apply the same stopped-with-error semantics, never a partial recovery.
    func testResetTransitionFailureRollbackIsStableContract() {
        let a = ResidentResetTransition.failureRollback
        let b = ResidentResetTransition.failureRollback
        XCTAssertEqual(a, b, "failure rollback is a single stable contract value")
        XCTAssertEqual(a.isRunning, false)
        XCTAssertEqual(a.requiresExplicitError, true)
    }

    // MARK: - Camera-refit contract

    func testResetRefitsNowWhenDrawableIsUsable() {
        let decision = SoupScopeAppLifecycle.resetCameraRefitDecision(
            drawableWidth: 1280, drawableHeight: 720)
        XCTAssertTrue(decision.shouldRefitNow,
            "Reset must refit the camera when the drawable geometry is usable")
        XCTAssertTrue(decision.didFit,
            "Reset must keep the already-fitted latch set when it just fitted")
    }

    func testResetDefersRefitWhenNoDrawableYet() {
        let decision = SoupScopeAppLifecycle.resetCameraRefitDecision(
            drawableWidth: 0, drawableHeight: 0)
        XCTAssertFalse(decision.shouldRefitNow,
            "Reset must not fit against an unusable geometry")
        XCTAssertFalse(decision.didFit,
            "Reset must clear the already-fitted latch so the next resize fits")
    }

    /// The refit decision composed with `Camera.fitAll` re-establishes the
    /// camera invariant from a panned/zoomed camera — the contract the AppModel
    /// reset relies on for the usable-drawable path.
    func testResetRefitDecisionComposesWithFitAllToRestoreInvariant() {
        let geometry = CameraGeometry(soupByteWidth: 64, soupByteHeight: 32,
                                       viewPxWidth: 1280, viewPxHeight: 720)
        var camera = Camera()
        // Pan/zoom the camera away from the launch fit, like a user session.
        camera.zoom(factor: 4.0, anchorPxX: 640, anchorPxY: 360, geometry: geometry)
        camera.pan(dxPx: 200, dyPx: 120, geometry: geometry)
        XCTAssertNotEqual(camera.bytePx, Camera().bytePx,
            "sanity: the camera moved away from the default")

        let decision = SoupScopeAppLifecycle.resetCameraRefitDecision(
            drawableWidth: geometry.viewPxWidth, drawableHeight: geometry.viewPxHeight)
        XCTAssertTrue(decision.shouldRefitNow)
        if decision.shouldRefitNow {
            camera.fitAll(geometry)
        }
        // The camera invariant: bytePx inside [minBytePx, maxBytePx].
        XCTAssertGreaterThanOrEqual(camera.bytePx, camera.minBytePx(geometry) - 1e-9)
        XCTAssertLessThanOrEqual(camera.bytePx, geometry.maxBytePx + 1e-9)
        // Content larger than the viewport on either axis fully covers it; on an
        // undersized axis it is centered. With this geometry the soup is smaller
        // than the viewport on both axes, so both origins must be centered.
        let visW = geometry.viewPxWidth / camera.bytePx
        let visH = geometry.viewPxHeight / camera.bytePx
        XCTAssertEqual(camera.originByteX, (geometry.soupByteWidth - visW) / 2, accuracy: 1e-6,
            "x axis centered after reset refit")
        XCTAssertEqual(camera.originByteY, (geometry.soupByteHeight - visH) / 2, accuracy: 1e-6,
            "y axis centered after reset refit")
    }

    // MARK: - Bounded termination is preserved

    /// Reset must not change bounded termination semantics: a bounded or
    /// tiny-validation plan is rejected by the gate, so its bounded exit
    /// diagnostic / exit-code policy is unchanged. Exercised via the pure
    /// `ResidentTerminationPolicy` the bounded runs emit through.
    func testResetDoesNotChangeBoundedTerminationExitCodes() {
        // A bounded seconds-limit normal stop exits 0 (no error).
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .secondsLimit,
                                                          metalAvailable: true,
                                                          hasError: false), 0)
        // An epoch-limit stop with an error exits 1.
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .epochLimit,
                                                          metalAvailable: true,
                                                          hasError: true), 1)
        // A failure always exits 1.
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .failure,
                                                          metalAvailable: true,
                                                          hasError: false), 1)
        // No Metal always exits 2.
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .requested,
                                                          metalAvailable: false,
                                                          hasError: false), 2)
    }

    // MARK: - Helpers

    /// Produce a real `ResidentEpochReport` from the platform-independent
    /// `ResidentCPUReferenceRunner`, since the report/instrumentation structs
    /// have no public cross-module memberwise init.
    private func makeReferenceReport() -> ResidentEpochReport {
        var runner = ResidentCPUReferenceRunner(config: try! ResidentEpochConfig(
            seed: 1, programCount: 4, stepBudget: 64))
        return runner.runEpoch()
    }
}
