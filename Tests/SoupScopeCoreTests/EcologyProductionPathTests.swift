import XCTest
import BFFOracle
import BFFMetal
import BFFEcologyMetal
@testable import SoupScopeCore

/// Focused production-path tests for the experimental "SoupScope Spatial
/// Ecology" truthfulness contract. Exercises the production types directly —
/// `HUDModel.record(ecology:)`, `HUDModel.noteEcologyDisplayedLease`/
/// `noteEcologyDisplayUnavailable`, `EcologyHUDDiagnostics`, `EcologyFinalDiagnostic`,
/// and the public `ResidentSnapshotRingState` the ecology path depends on —
/// to prove the three explicitly separated epoch/phase domains stay truthful
/// across the production paths.
///
/// No Metal required: every assertion is against observable behavior of the
/// production types on Linux. No helper-only mirrors: a small factory builds
/// real `EcologyMetalEpochReport` values (production type) from
/// `EcologyEpochCounters` (production type) so the production
/// `HUDModel.record(ecology:)` path is exercised end-to-end.
final class EcologyProductionPathTests: XCTestCase {

    // MARK: - Production report factory (no mirror — builds the real type)

    /// Build a real `EcologyMetalEpochReport` for `epoch` (0-indexed producing
    /// epoch). The counters carry the producing phase; instrumentation carries
    /// minimal truthful values (no GPU times, no readback). This is a
    /// convenience constructor for the production type, not a parallel mirror.
    private func report(epoch: UInt32) -> EcologyMetalEpochReport {
        let counters = EcologyEpochCounters(epoch: epoch,
                                            phase: EcologyMatchingPhase(epoch: epoch))
        let instrumentation = EcologyMetalEpochInstrumentation(
            epochWallSeconds: 0.001,
            mutateKernelSeconds: nil,
            evalKernelSeconds: nil,
            visualizeKernelSeconds: nil,
            counterReadbackSeconds: 0.0,
            soupReadbackSeconds: nil,
            digestSeconds: nil,
            captureReadbackSeconds: nil,
            uploadBytes: 0,
            readbackBytes: 0,
            counterBytes: 0,
            captureBytes: 0)
        return EcologyMetalEpochReport(
            counters: counters,
            digest: nil,
            capturedPairResults: [],
            capturedInputTapes: [],
            capturedFinalTapes: [],
            instrumentation: instrumentation)
    }

    // MARK: 1. No publication — publishedSourceEpoch stays nil

    /// When no successful ring publication has completed, the HUD's
    /// `publishedSourceEpoch`/`publishedPhase` must be `nil`, even after a
    /// simulation report arrives (first-publication absence). The produced
    /// epoch/phase are recorded truthfully; displayed fields are `nil` (no
    /// frame rendered with a valid lease yet).
    func testNoPublicationLeavesPublishedAndDisplayedNil() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        hud.record(ecology: report(epoch: 0),
                   publishedSourceEpoch: nil,  // no publication has completed
                   failureCount: 0)

        let ecology = try! XCTUnwrap(hud.ecology)
        XCTAssertEqual(ecology.producedEpoch, 1, "producedEpoch is c.epoch + 1")
        XCTAssertEqual(ecology.producedPhase, "H0",
                       "producedPhase is the producing phase (epoch 0 → H0)")
        XCTAssertNil(ecology.publishedSourceEpoch,
                      "publishedSourceEpoch must be nil when no publication completed")
        XCTAssertNil(ecology.publishedPhase,
                      "publishedPhase must be nil when no publication completed")
        XCTAssertNil(ecology.displayedSourceEpoch,
                      "displayedSourceEpoch must be nil before any valid-lease frame")
        XCTAssertNil(ecology.displayedPhase,
                      "displayedPhase must be nil before any valid-lease frame")
    }

    // MARK: 2. Produced state ahead of published state because publication skipped

    /// When the snapshot ring is exhausted (skipped reservation — no free slot
    /// available), the producer cannot publish, so `publishedSourceEpoch`
    /// stays at its prior value while the produced epoch advances. This
    /// exercises the production `ResidentSnapshotRingState` the ecology path
    /// depends on, then proves the HUD records the truthful lag.
    func testProducedAheadOfPublishedBecausePublicationSkipped() throws {
        let byteCount = EcologyTopology.soupByteCount

        // A 1-slot ring: after one publish, the only slot is published and
        // cannot be reserved again (it would alias the published slot), so
        // the next reservation is skipped.
        var ring = try ResidentSnapshotRingState(slotCount: 1,
                                                  expectedByteCount: byteCount)
        let reservation1 = try XCTUnwrap(ring.reserveForWrite(),
                                         "first reservation must succeed on a fresh ring")
        let token = ring.publish(reservation1, sourceEpoch: 1,
                                 byteCount: byteCount,
                                 blitHostSeconds: nil, blitGPUSeconds: nil)
        XCTAssertNotNil(token)
        XCTAssertEqual(ring.diagnostics.publishedSourceEpoch, 1)

        // Second reservation is skipped (ring exhaustion) — never backpressure.
        XCTAssertNil(ring.reserveForWrite())
        XCTAssertEqual(ring.diagnostics.skippedReservationCount, 1,
                       "skipped reservation must be counted")
        XCTAssertEqual(ring.diagnostics.publishedSourceEpoch, 1,
                       "publishedSourceEpoch unchanged after skipped reservation")

        // The HUD records a second simulation report (epoch 1, producedEpoch 2)
        // with the ring's truthful publishedSourceEpoch = 1 (the publication
        // for epoch 1 was skipped; the previous publication for source epoch 1
        // is still the latest successful one). Produced is now ahead of
        // published truthfully.
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        hud.record(ecology: report(epoch: 0),
                   publishedSourceEpoch: 1, failureCount: 0)
        hud.record(ecology: report(epoch: 1),
                   publishedSourceEpoch: 1,  // unchanged: publication skipped
                   failureCount: 0)

        let ecology = try! XCTUnwrap(hud.ecology)
        XCTAssertEqual(ecology.producedEpoch, 2,
                       "producedEpoch advanced to 2 after the second report")
        XCTAssertEqual(ecology.producedPhase, "H1",
                       "producedPhase is the producing phase for epoch 1 (H1)")
        XCTAssertEqual(ecology.publishedSourceEpoch, 1,
                       "publishedSourceEpoch stays at 1 (publication was skipped)")
        XCTAssertEqual(ecology.publishedPhase, "H0",
                       "publishedPhase derived from publishedSourceEpoch - 1 (H0)")
    }

    // MARK: 3. Published state ahead of displayed state

    /// After a successful publication but before the renderer has submitted a
    /// frame with a valid lease, the published source epoch is set but the
    /// displayed source epoch is still `nil`. The HUD truthfully shows
    /// "published ahead of displayed".
    func testPublishedAheadOfDisplayed() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        // Publication for source epoch 3 completed (after producing epoch 2);
        // no frame has been rendered with a lease yet.
        hud.record(ecology: report(epoch: 2),
                   publishedSourceEpoch: 3,
                   failureCount: 0)

        let ecology = try! XCTUnwrap(hud.ecology)
        XCTAssertEqual(ecology.producedEpoch, 3)
        XCTAssertEqual(ecology.producedPhase, "V0")  // epoch 2 → phase 2 → V0
        XCTAssertEqual(ecology.publishedSourceEpoch, 3,
                       "publishedSourceEpoch reflects the successful publication")
        XCTAssertEqual(ecology.publishedPhase, "V0",
                       "publishedPhase derived from publishedSourceEpoch - 1 (V0)")
        XCTAssertNil(ecology.displayedSourceEpoch,
                      "displayedSourceEpoch nil — no frame rendered with a lease yet")
        XCTAssertNil(ecology.displayedPhase,
                      "displayedPhase nil — no frame rendered with a lease yet")
    }

    // MARK: 4. Displayed update from a valid lease

    /// When the renderer submits a command buffer using a valid immutable
    /// ecology lease, the HUD's displayed source epoch/phase update to the
    /// lease's `sourceEpoch` (and the phase derived from it). The produced
    /// and published fields are unchanged. The neutral fallback path never
    /// calls this and never fabricates these values.
    func testDisplayedUpdateFromValidLease() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        hud.record(ecology: report(epoch: 0),
                   publishedSourceEpoch: 1, failureCount: 0)
        // Before any frame: displayed is nil.
        XCTAssertNil(hud.ecology?.displayedSourceEpoch)

        // The renderer acquires a lease (sourceEpoch = 1) and submits a frame.
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)

        let ecology = try! XCTUnwrap(hud.ecology)
        XCTAssertEqual(ecology.displayedSourceEpoch, 1,
                       "displayedSourceEpoch updates to the lease's sourceEpoch")
        XCTAssertEqual(ecology.displayedPhase, "H0",
                       "displayedPhase derived from sourceEpoch - 1 (epoch 0 → H0)")
        // Produced/published unchanged by the displayed update.
        XCTAssertEqual(ecology.producedEpoch, 1)
        XCTAssertEqual(ecology.producedPhase, "H0")
        XCTAssertEqual(ecology.publishedSourceEpoch, 1)
        XCTAssertEqual(ecology.publishedPhase, "H0")
    }

    /// The neutral fallback path (no valid lease) must NOT fabricate source
    /// epoch/phase. `noteEcologyDisplayUnavailable` leaves the displayed
    /// fields at their prior value — the last valid lease rendered — or `nil`
    /// if no valid lease has ever been rendered. It never resets to 0/"—" or
    /// invents a value.
    func testNeutralFallbackDoesNotFabricateOrResetDisplayed() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        hud.record(ecology: report(epoch: 0),
                   publishedSourceEpoch: 1, failureCount: 0)
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1)
        XCTAssertEqual(hud.ecology?.displayedPhase, "H0")

        // Neutral fallback: displayed must stay at the last valid lease's
        // values — NOT reset to nil, NOT fabricated to 0/"—".
        hud.noteEcologyDisplayUnavailable()
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1,
                       "neutral fallback preserves the last valid lease's sourceEpoch")
        XCTAssertEqual(hud.ecology?.displayedPhase, "H0",
                       "neutral fallback preserves the last valid lease's phase")

        // A fresh HUD with no prior valid lease: neutral fallback leaves
        // displayed nil — no fabrication.
        var fresh = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        fresh.record(ecology: report(epoch: 0),
                     publishedSourceEpoch: nil, failureCount: 0)
        fresh.noteEcologyDisplayUnavailable()
        XCTAssertNil(fresh.ecology?.displayedSourceEpoch,
                      "neutral fallback must not fabricate a source epoch when none exists")
        XCTAssertNil(fresh.ecology?.displayedPhase,
                      "neutral fallback must not fabricate a phase when none exists")
    }

    // MARK: 5. Final diagnostic labels / nullable fields

    /// The ecology final diagnostic carries explicit `producedEpoch`/
    /// `producedPhase`, `publishedSourceEpoch`/`publishedPhase` (nullable),
    /// and `displayedSourceEpoch`/`displayedPhase` (nullable) fields with
    /// truthful names — it must NOT label latest-produced state as texture
    /// source / published / displayed. JSON keys are exactly the truthful
    /// names; nullable fields are absent/unavailable when nil.
    func testFinalDiagnosticExplicitFieldsAndNullableAbsence() throws {
        // Case A: no publication, no display (e.g. reset/stop before any
        // publication landed, or first-publication absence).
        let noPub = EcologyFinalDiagnostic(
            producedEpoch: 1, producedPhase: "H0",
            publishedSourceEpoch: nil, publishedPhase: nil,
            displayedSourceEpoch: nil, displayedPhase: nil,
            frameCount: 0, failures: 0, unknownHalts: 0,
            stopReason: .requested)
        let objA = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(noPub.jsonLine().utf8)) as? [String: Any])
        XCTAssertEqual(objA["kind"] as? String, "ecologyFinalDiagnostic")
        XCTAssertEqual(objA["producedEpoch"] as? Int, 1)
        XCTAssertEqual(objA["producedPhase"] as? String, "H0")
        XCTAssertNil(objA["publishedSourceEpoch"])
        XCTAssertNil(objA["publishedPhase"])
        XCTAssertNil(objA["displayedSourceEpoch"])
        XCTAssertNil(objA["displayedPhase"])
        // The old "textureSourceEpoch" / "simulationEpoch" labels must NOT
        // appear — produced state is not labeled as source/published/displayed.
        XCTAssertNil(objA["textureSourceEpoch"],
                      "ecology diagnostic must not carry the resident 'textureSourceEpoch' label")
        XCTAssertNil(objA["simulationEpoch"],
                      "ecology diagnostic must not carry the resident 'simulationEpoch' label")
        XCTAssertNil(objA["displayedEpoch"],
                      "ecology diagnostic must not carry the resident 'displayedEpoch' label")

        // Case B: produced ahead of published (publication skipped), no
        // display yet. Phase convention: producing epoch e => e mod 4;
        // snapshot sourceEpoch s => (s-1) mod 4. producedEpoch 5 => e=4 =>
        // H0; publishedSourceEpoch 4 => (4-1) mod 4 = 3 => V1.
        let ahead = EcologyFinalDiagnostic(
            producedEpoch: 5, producedPhase: "H0",
            publishedSourceEpoch: 4, publishedPhase: "V1",
            displayedSourceEpoch: nil, displayedPhase: nil,
            frameCount: 0, failures: 1, unknownHalts: 0,
            stopReason: .failure)
        let objB = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(ahead.jsonLine().utf8)) as? [String: Any])
        XCTAssertEqual(objB["producedEpoch"] as? Int, 5)
        XCTAssertEqual(objB["producedPhase"] as? String, "H0")
        XCTAssertEqual(objB["publishedSourceEpoch"] as? Int, 4)
        XCTAssertEqual(objB["publishedPhase"] as? String, "V1")
        XCTAssertNil(objB["displayedSourceEpoch"])
        XCTAssertNil(objB["displayedPhase"])
        XCTAssertEqual(objB["failures"] as? Int, 1)
        XCTAssertEqual(objB["stopReason"] as? String, "failure")
    }

    // MARK: 6. Produced reports never overwrite displayed HUD phase

    /// The blocking truthfulness requirement: a simulation report arriving
    /// after a frame was rendered must NOT overwrite the displayed phase with
    /// the producing phase. The displayed lease's source epoch/phase update
    /// ONLY on a valid-lease render submission. This is the alternation bug
    /// fixed: previously `record(ecology:)` reset `ecology.phase` to the
    /// producing phase on every report, so the visible-state line alternated.
    func testProducedReportsNeverOverwriteDisplayedHUDPhase() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)

        // Report for epoch 0 (producedEpoch 1, producing phase H0).
        hud.record(ecology: report(epoch: 0),
                   publishedSourceEpoch: 1, failureCount: 0)
        // Renderer submits a frame with a valid lease (sourceEpoch 1).
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1)
        XCTAssertEqual(hud.ecology?.displayedPhase, "H0")

        // A new simulation report arrives for epoch 1 (producedEpoch 2,
        // producing phase H1). The displayed phase must NOT alternate to H1.
        hud.record(ecology: report(epoch: 1),
                   publishedSourceEpoch: 2, failureCount: 0)

        XCTAssertEqual(hud.ecology?.producedEpoch, 2,
                       "producedEpoch advanced to 2")
        XCTAssertEqual(hud.ecology?.producedPhase, "H1",
                       "producedPhase is the new producing phase (H1)")
        // The displayed fields are PRESERVED across the report — they reflect
        // the lease the renderer last submitted with, NOT the producing phase.
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1,
                       "displayedSourceEpoch preserved across the report (not overwritten)")
        XCTAssertEqual(hud.ecology?.displayedPhase, "H0",
                       "displayedPhase preserved across the report (not alternated to H1)")

        // The renderer then submits a frame with the newer lease (sourceEpoch 2).
        hud.noteEcologyDisplayedLease(sourceEpoch: 2)
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 2,
                       "displayedSourceEpoch updates on the next valid-lease render")
        XCTAssertEqual(hud.ecology?.displayedPhase, "H1",
                       "displayedPhase updates to the new lease's phase (H1)")

        // Neutral fallback after that: displayed stays at the last valid lease.
        hud.noteEcologyDisplayUnavailable()
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 2,
                       "neutral fallback preserves the last valid lease (sourceEpoch 2)")
        XCTAssertEqual(hud.ecology?.displayedPhase, "H1",
                       "neutral fallback preserves the last valid lease phase (H1)")
    }

    // MARK: - Ring-level truthfulness for published metadata

    /// Published metadata is derived from actual successful ring publication,
    /// not merely attempted production. Exercises the production
    /// `ResidentSnapshotRingState` the ecology path depends on: skipped
    /// reservation, failed blit (cancel), and first-publication absence all
    /// leave `publishedSourceEpoch` truthful. A stale publication (an older
    /// reservation trying to publish after a newer one is already published)
    /// is rejected and does not regress `publishedSourceEpoch`.
    func testPublishedMetadataReflectsActualSuccessfulPublication() throws {
        let byteCount = EcologyTopology.soupByteCount
        // 3 slots so two reservations can be in flight simultaneously for the
        // stale-publication exercise.
        var ring = try ResidentSnapshotRingState(slotCount: 3,
                                                  expectedByteCount: byteCount)

        // First-publication absence: no publish yet → nil.
        XCTAssertNil(ring.diagnostics.publishedSourceEpoch)

        // Failed blit: cancel a reservation (e.g. command buffer failed).
        let r1 = try XCTUnwrap(ring.reserveForWrite())
        ring.cancel(r1)
        XCTAssertEqual(ring.diagnostics.cancelledReservationCount, 1)
        XCTAssertNil(ring.diagnostics.publishedSourceEpoch,
                      "cancelled reservation must not advance publishedSourceEpoch")

        // Successful publication on a fresh reservation.
        let r2 = try XCTUnwrap(ring.reserveForWrite())
        let token = ring.publish(r2, sourceEpoch: 7,
                                 byteCount: byteCount,
                                 blitHostSeconds: nil, blitGPUSeconds: nil)
        XCTAssertNotNil(token)
        XCTAssertEqual(ring.diagnostics.publishedSourceEpoch, 7,
                       "successful publication sets publishedSourceEpoch")
        XCTAssertEqual(ring.diagnostics.publishCount, 1)

        // Stale publication: reserve two slots (rOld generation 3, rNew
        // generation 4). Publish rNew first (sourceEpoch 9), then try to
        // publish rOld (older generation). The stale path rejects rOld and
        // does not regress publishedSourceEpoch.
        let rOld = try XCTUnwrap(ring.reserveForWrite())
        let rNew = try XCTUnwrap(ring.reserveForWrite())
        let newer = ring.publish(rNew, sourceEpoch: 9,
                                 byteCount: byteCount,
                                 blitHostSeconds: nil, blitGPUSeconds: nil)
        XCTAssertNotNil(newer)
        XCTAssertEqual(ring.diagnostics.publishedSourceEpoch, 9)
        let stale = ring.publish(rOld, sourceEpoch: 8,
                                 byteCount: byteCount,
                                 blitHostSeconds: nil, blitGPUSeconds: nil)
        XCTAssertNil(stale, "stale (older-generation) publication must be rejected")
        XCTAssertEqual(ring.diagnostics.stalePublicationCount, 1)
        XCTAssertEqual(ring.diagnostics.publishedSourceEpoch, 9,
                       "stale publication must not regress publishedSourceEpoch")
    }

    // MARK: 7. Zero-completed-epoch produced phase is unavailable

    /// If no ecology epoch has completed (`producedEpoch == 0`), the produced
    /// phase must be `nil` (unavailable) — never fabricated as `H0`. Both the
    /// HUD's `EcologyHUDDiagnostics.producedPhase` and the terminal
    /// `EcologyFinalDiagnostic.producedPhase` preserve this absence truthfully.
    func testZeroCompletedEpochProducedPhaseIsUnavailable() throws {
        // Final diagnostic: producedEpoch 0 => producedPhase nil (JSON null),
        // never "H0".
        let diag = EcologyFinalDiagnostic(
            producedEpoch: 0, producedPhase: nil,
            publishedSourceEpoch: nil, publishedPhase: nil,
            displayedSourceEpoch: nil, displayedPhase: nil,
            frameCount: 0, failures: 0, unknownHalts: 0,
            stopReason: .failure)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(diag.jsonLine().utf8)) as? [String: Any])
        XCTAssertEqual(obj["producedEpoch"] as? Int, 0)
        XCTAssertNil(obj["producedPhase"],
                      "producedPhase must be null (unavailable) when producedEpoch == 0, never fabricated as H0")

        // HUD: a displayed-only state initialized before the first report has
        // producedEpoch 0 and producedPhase nil (not "H0").
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)
        let ecology = try XCTUnwrap(hud.ecology)
        XCTAssertEqual(ecology.producedEpoch, 0,
                       "producedEpoch is 0 before the first report completes")
        XCTAssertNil(ecology.producedPhase,
                      "producedPhase must be nil (unavailable) before the first report, never fabricated as H0")
    }

    // MARK: 8. Valid displayed lease before first report creates only displayed state

    /// `noteEcologyDisplayedLease` must immediately record a valid displayed
    /// lease even when no simulation report exists. It initializes ONLY the
    /// displayed domain; produced (epoch 0, phase nil) and published (nil)
    /// domains remain unavailable.
    func testValidDisplayedLeaseBeforeFirstReportCreatesOnlyDisplayedState() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        // No report has arrived; ecology starts nil.
        XCTAssertNil(hud.ecology)

        // Renderer submits a frame with a valid lease (sourceEpoch 1) before
        // any simulation report. The displayed domain is recorded; produced
        // and published remain unavailable.
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)

        let ecology = try! XCTUnwrap(hud.ecology)
        XCTAssertEqual(ecology.displayedSourceEpoch, 1,
                       "displayedSourceEpoch recorded from the lease")
        XCTAssertEqual(ecology.displayedPhase, "H0",
                       "displayedPhase derived from sourceEpoch - 1 (epoch 0 => H0)")
        // Produced domain unavailable.
        XCTAssertEqual(ecology.producedEpoch, 0,
                       "producedEpoch is 0 (no epoch completed) — only displayed initialized")
        XCTAssertNil(ecology.producedPhase,
                      "producedPhase nil — only displayed initialized")
        // Published domain unavailable.
        XCTAssertNil(ecology.publishedSourceEpoch,
                      "publishedSourceEpoch nil — only displayed initialized")
        XCTAssertNil(ecology.publishedPhase,
                      "publishedPhase nil — only displayed initialized")
    }

    // MARK: 8b. Invalid sourceEpoch zero is inert (no trap, no fabrication)

    /// An invalid `sourceEpoch` of 0 must be rejected safely: it must not
    /// trap on `UInt32(sourceEpoch - 1)` and must not fabricate displayed
    /// metadata. On a fresh HUD (`ecology == nil`) the block stays `nil`; on
    /// a HUD with an existing displayed lease, the prior displayed values are
    /// preserved (the call is inert, mirroring `noteEcologyDisplayUnavailable`).
    func testInvalidSourceEpochZeroIsInert() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        // Fresh HUD: sourceEpoch 0 must not trap and must not fabricate.
        hud.noteEcologyDisplayedLease(sourceEpoch: 0)
        XCTAssertNil(hud.ecology,
                     "sourceEpoch 0 must not fabricate a displayed lease — ecology stays nil")

        // Establish a valid displayed lease, then poke with sourceEpoch 0:
        // the valid lease must be preserved (no overwrite, no trap).
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1)
        XCTAssertEqual(hud.ecology?.displayedPhase, "H0")
        hud.noteEcologyDisplayedLease(sourceEpoch: 0)
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1,
                       "sourceEpoch 0 is inert — prior displayed lease preserved")
        XCTAssertEqual(hud.ecology?.displayedPhase, "H0",
                       "sourceEpoch 0 is inert — prior displayed phase preserved")
    }

    // MARK: 9. Later report preserves pre-report displayed state

    /// A later simulation report adds produced/published state while
    /// preserving the pre-report displayed metadata (the lease the renderer
    /// last submitted with). The displayed phase must NOT alternate to the
    /// producing phase, and produced/published become available.
    func testLaterReportPreservesPreReportDisplayedState() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        // Before any report: renderer submits a lease (sourceEpoch 1).
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1)
        XCTAssertEqual(hud.ecology?.displayedPhase, "H0")
        XCTAssertNil(hud.ecology?.producedPhase)
        XCTAssertNil(hud.ecology?.publishedSourceEpoch)

        // A simulation report arrives for epoch 0 (producedEpoch 1, H0) with a
        // successful publication (publishedSourceEpoch 1). Produced and
        // published become available; displayed is PRESERVED.
        hud.record(ecology: report(epoch: 0),
                   publishedSourceEpoch: 1, failureCount: 0)

        let ecology = try! XCTUnwrap(hud.ecology)
        XCTAssertEqual(ecology.producedEpoch, 1, "producedEpoch now set from the report")
        XCTAssertEqual(ecology.producedPhase, "H0", "producedPhase now set (epoch 0 => H0)")
        XCTAssertEqual(ecology.publishedSourceEpoch, 1, "publishedSourceEpoch now set")
        XCTAssertEqual(ecology.publishedPhase, "H0",
                       "publishedPhase derived from publishedSourceEpoch - 1 (H0)")
        // Displayed metadata PRESERVED across the report — not overwritten by
        // the producing phase, not cleared.
        XCTAssertEqual(ecology.displayedSourceEpoch, 1,
                       "displayedSourceEpoch preserved across the later report")
        XCTAssertEqual(ecology.displayedPhase, "H0",
                       "displayedPhase preserved across the later report")
    }

    // MARK: 10. Reset clears displayed state

    /// Reset clears displayed metadata: the production
    /// `ResidentResetTransition` builds a fresh `HUDModel` whose `ecology`
    /// block is `nil`, so a displayed-only state (initialized before the first
    /// report) is cleared truthfully — produced/published/displayed all
    /// return to unavailable.
    func testResetClearsDisplayedState() {
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)
        hud.noteEcologyDisplayedLease(sourceEpoch: 1)
        XCTAssertEqual(hud.ecology?.displayedSourceEpoch, 1)
        XCTAssertNotNil(hud.ecology)

        // The production reset transition builds a fresh HUD (ecology nil).
        let reset = ResidentResetTransition(deviceName: "TestDevice",
                                             programCount: 131_072,
                                             drawableWidth: 1024,
                                             drawableHeight: 512)
        hud = reset.hud
        XCTAssertNil(hud.ecology,
                     "reset clears displayed metadata — ecology returns to nil (all domains unavailable)")
    }

    // MARK: 11. Phase derivation consistent across H0/H1/V0/V1

    /// Produced/published/displayed phase derivation is consistent across all
    /// four phases. Convention: producing epoch `e` => `e mod 4` = H0,H1,V0,V1;
    /// snapshot sourceEpoch `s >= 1` => `(s - 1) mod 4`. This exercises the
    /// production `record(ecology:)` + `noteEcologyDisplayedLease` path across
    /// epochs 0..<8 (two full phase cycles) and asserts each domain's phase
    /// matches the convention, preventing inconsistent epoch/phase pairs.
    func testPhaseDerivationConsistentAcrossAllFourPhases() {
        let phaseLabels = ["H0", "H1", "V0", "V1"]
        var hud = HUDModel(deviceName: "TestDevice", programCount: 131_072)

        // Producing epochs 0..<8: phase = e mod 4. The published source epoch
        // tracks the produced epoch (e + 1), so publishedPhase = (s - 1) mod 4
        // = e mod 4 — the SAME producing phase. The displayed lease follows the
        // published source epoch one-for-one, so displayedPhase = (s - 1) mod 4
        // as well. All three domains must agree per-epoch and follow the
        // convention.
        for e in 0..<8 {
            let producedEpoch = e + 1
            let publishedSourceEpoch = producedEpoch
            hud.record(ecology: report(epoch: UInt32(e)),
                       publishedSourceEpoch: publishedSourceEpoch,
                       failureCount: 0)
            hud.noteEcologyDisplayedLease(sourceEpoch: publishedSourceEpoch)

            let ecology = try! XCTUnwrap(hud.ecology)
            let expectedPhase = phaseLabels[e % 4]

            // Produced: phase = e mod 4.
            XCTAssertEqual(ecology.producedEpoch, producedEpoch)
            XCTAssertEqual(ecology.producedPhase, expectedPhase,
                           "producedPhase for producing epoch \(e) must be \(expectedPhase) (e mod 4)")

            // Published: phase = (s - 1) mod 4 = e mod 4 (same as produced here).
            XCTAssertEqual(ecology.publishedSourceEpoch, publishedSourceEpoch)
            XCTAssertEqual(ecology.publishedPhase, expectedPhase,
                           "publishedPhase for sourceEpoch \(publishedSourceEpoch) must be \(expectedPhase) ((s-1) mod 4)")

            // Displayed: phase = (s - 1) mod 4.
            XCTAssertEqual(ecology.displayedSourceEpoch, publishedSourceEpoch)
            XCTAssertEqual(ecology.displayedPhase, expectedPhase,
                           "displayedPhase for sourceEpoch \(publishedSourceEpoch) must be \(expectedPhase) ((s-1) mod 4)")

            // Cross-check against the production phase type itself — the
            // canonical convention source.
            XCTAssertEqual(
                EcologyMatchingPhase(epoch: UInt32(e)).label, expectedPhase,
                "EcologyMatchingPhase(epoch: \(e)) must produce \(expectedPhase)")
            XCTAssertEqual(
                EcologyMatchingPhase(epoch: UInt32(publishedSourceEpoch - 1)).label,
                expectedPhase,
                "EcologyMatchingPhase(epoch: sourceEpoch - 1) must produce \(expectedPhase)")
        }
    }
}
