import XCTest
import BFFMetal
import BFFOracle
import BFFEcologyMetal
@testable import SoupScopeCore

/// Truthful ecology visualization-channel + availability tests. Channels are
/// soup-derived scalar summaries only; exact spatial metrics remain neutrally
/// unavailable. Pure values; no Metal.
final class EcologyVizChannelsTests: XCTestCase {

    func testFourSoupDerivedChannelsCycleWithoutSpatialClaim() {
        XCTAssertEqual(EcologyVizChannel.allCases.count, 4)
        XCTAssertEqual(EcologyVizChannel.defaultChannel, .composite)

        // The channel labels are the producer's RGB component meanings; none
        // claims energy/death/movement/predation/fitness/reproduction/paper.
        let labels = EcologyVizChannel.allCases.map(\.label)
        XCTAssertTrue(labels.contains("Composite"))
        XCTAssertTrue(labels.contains("Opcode-byte density — R"))
        XCTAssertTrue(labels.contains("Byte mean — G"))
        XCTAssertTrue(labels.contains("Structural XOR fingerprint — B"))
        for label in labels {
            for forbidden in ["energy", "death", "movement", "predation",
                              "fitness", "reproduction", "paper"] {
                XCTAssertFalse(label.lowercased().contains(forbidden),
                               "channel label '\(label)' must not claim \(forbidden)")
            }
        }
    }

    func testCyclingSnapsOutOfRangeBackToDefault() {
        // The selector cycles through exactly the 0...3 selections; an
        // out-of-range current value snaps to default (no accidental legacy
        // shader fallback).
        XCTAssertEqual(EcologyVizChannel.cyclingRawValue(after: 0), 1)
        XCTAssertEqual(EcologyVizChannel.cyclingRawValue(after: 3), 0)
        XCTAssertEqual(EcologyVizChannel.cyclingRawValue(after: 99),
                       EcologyVizChannel.defaultChannel.rawValue)
    }

    func testAvailabilityNeverClaimsSpatialMetrics() {
        // Scalar channels become available after the first epoch; exact
        // spatial metrics are NEVER available from this producer.
        XCTAssertFalse(EcologyVizAvailability.initial.scalarChannelsAvailable)
        XCTAssertFalse(EcologyVizAvailability.initial.spatialMetricsAvailable)
        XCTAssertTrue(EcologyVizAvailability.afterFirstEpoch.scalarChannelsAvailable)
        XCTAssertFalse(EcologyVizAvailability.afterFirstEpoch.spatialMetricsAvailable)
    }

    /// Selector → uniform → Swift-shader-mirror mapping proof (no Metal
    /// required).
    ///
    /// The ecology renderer does NOT have its own colormap: it samples the
    /// producer's RGB overview texel and feeds it through the *resident*
    /// `resident_macro_color` shader branch (see `Renderer` ecology path and
    /// `SoupRender.metal`), selected by the shared `VizUniforms.metricChannel`
    /// word. `ResidentVizMacroColor` is the exact Swift mirror of that shader
    /// function. This test proves the ecology selector is neither inert nor
    /// mislabeled at the mapping level: each `EcologyVizChannel` raw value is
    /// the composite/R/G/B selector word the shader branches on, and the four
    /// channels produce mutually distinct, correctly-component-mapped outputs
    /// for a non-degenerate producer RGB — so selection can visibly differ.
    ///
    /// Scope, truthfully: this exercises the Swift mirror only. It does NOT
    /// execute the native Metal shader or the ecology producer, so native
    /// producer execution is not proven here — that requires the macOS/Metal
    /// validation runs.
    func testEcologySelectorFeedsSharedShaderMirrorWithDistinctChannels() {
        // The ecology channel raw values are exactly the composite/R/G/B
        // selector words, in component order.
        XCTAssertEqual(EcologyVizChannel.allCases.map(\.rawValue),
                       [UInt32(0), 1, 2, 3])
        XCTAssertEqual(EcologyVizChannel.composite.rawValue, 0)
        XCTAssertEqual(EcologyVizChannel.opcodeByteDensity.rawValue, 1)
        XCTAssertEqual(EcologyVizChannel.byteMean.rawValue, 2)
        XCTAssertEqual(EcologyVizChannel.structuralXORFingerprint.rawValue, 3)

        // A non-degenerate producer RGB whose R, G, B components differ, so a
        // component swap can be observed (not 0/1 extremes that collapse).
        let producerRGB = RGB(0.125, 0.5, 0.875)

        let composite = ResidentVizMacroColor.color(residentRGB: producerRGB,
                                                    selectorRawValue:
                                                        EcologyVizChannel.composite.rawValue)
        let rChannel = ResidentVizMacroColor.color(residentRGB: producerRGB,
                                                   selectorRawValue:
                                                       EcologyVizChannel.opcodeByteDensity.rawValue)
        let gChannel = ResidentVizMacroColor.color(residentRGB: producerRGB,
                                                   selectorRawValue:
                                                       EcologyVizChannel.byteMean.rawValue)
        let bChannel = ResidentVizMacroColor.color(residentRGB: producerRGB,
                                                   selectorRawValue:
                                                       EcologyVizChannel.structuralXORFingerprint.rawValue)

        // The ecology channels map to the producer RGB components the labels
        // claim ("— R", "— G", "— B"): the selector is not mislabeled.
        XCTAssertEqual(composite,
                       ResidentVizMacroColor.compositePresentation(residentRGB: producerRGB))
        XCTAssertEqual(rChannel, ResidentScalarPalette.color(for: producerRGB.r))
        XCTAssertEqual(gChannel, ResidentScalarPalette.color(for: producerRGB.g))
        XCTAssertEqual(bChannel, ResidentScalarPalette.color(for: producerRGB.b))

        // The four channels are mutually distinct, so cycling the selector
        // changes the rendered output rather than relabeling an inert signal.
        let outputs = [composite, rChannel, gChannel, bChannel]
        for i in 0..<outputs.count {
            for j in (i + 1)..<outputs.count {
                XCTAssertNotEqual(outputs[i], outputs[j],
                                  "ecology channels \(i) and \(j) must render distinctly")
            }
        }
    }
}

/// Reset/generation-fence tests for the ecology path, mirroring the resident
/// contract. The same `ResidentLifecycleGeneration` fence is reused unchanged
/// (a generic UInt64 counter); the ecology reset gate is its own pure decision.
final class EcologyResetGenerationTests: XCTestCase {

    private func plan(enabled: Bool = true,
                      limit: ResidentRunLimit = .unbounded,
                      tinyValidation: Bool = false) -> EcologyAppRunPlan {
        EcologyAppRunPlan(enabled: enabled, seed: 1, stepBudget: 64,
                          mutationP32: 0, variant: .noheads,
                          bracketMode: .dynamicScan, limit: limit,
                          tinyValidation: tinyValidation)
    }

    // MARK: - Reset gate

    func testResetAllowedForInteractiveEcologyMode() {
        let interactive = plan()
        XCTAssertTrue(SoupScopeAppLifecycle.canResetInteractiveEcology(
            plan: interactive, validationActive: false))
    }

    func testResetRejectedForBoundedEcologyRun() {
        let bounded = plan(limit: .epochs(5))
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveEcology(
            plan: bounded, validationActive: false))
        let seconds = plan(limit: .seconds(1))
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveEcology(
            plan: seconds, validationActive: false))
    }

    func testResetRejectedForTinyValidationEcologyRun() {
        let tiny = plan(tinyValidation: true)
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveEcology(
            plan: tiny, validationActive: false))
    }

    func testResetRejectedWhileValidationActive() {
        let interactive = plan()
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveEcology(
            plan: interactive, validationActive: true))
    }

    func testResetRejectedForDisabledEcologyPlan() {
        let disabled = plan(enabled: false)
        XCTAssertFalse(SoupScopeAppLifecycle.canResetInteractiveEcology(
            plan: disabled, validationActive: false))
    }

    // MARK: - Generation fence (the existing lifecycle fence, reused)

    /// Bumping the generation renders every callback that captured the prior
    /// generation inert — stale completions after Reset/stop cannot mutate the
    /// new state or emit a stale termination.
    func testGenerationFenceInertsStaleCallbacks() {
        var gen = ResidentLifecycleGeneration()
        let oldGeneration = gen.current
        XCTAssertTrue(gen.isCurrent(oldGeneration))
        gen.bump()
        XCTAssertFalse(gen.isCurrent(oldGeneration))
        XCTAssertTrue(gen.isCurrent(gen.current))
    }

    /// The generation fence starts at 0 so the launch-time driver's callbacks
    /// are current until the first Reset bumps it — matching the resident
    /// contract the ecology path reuses.
    func testGenerationFenceStartsAtZeroLikeResident() {
        var gen = ResidentLifecycleGeneration()
        XCTAssertEqual(gen.current, 0)
        XCTAssertEqual(gen.bump(), 1)
    }

    // MARK: - Deterministic reconstruction from immutable config

    /// Reset reconstructs the ecology driver from the immutable config/plan;
    /// repeated construction of the accepted runner from the same immutable
    /// config produces the same seeded soup (the deterministic-reconstruction
    /// property).
    func testEcologyConfigIsImmutableAndReconstructable() throws {
        let config = try EcologyMetalEpochConfig(seed: 42, stepBudget: 64,
                                                  mutationP32: 0, variant: .noheads)
        let again = try EcologyMetalEpochConfig(seed: 42, stepBudget: 64,
                                                 mutationP32: 0, variant: .noheads)
        XCTAssertEqual(config, again)
        // The seeded initial soup is a pure function of the immutable seed —
        // the same config always reconstructs the same starting soup.
        let soupA = EcologyRandom.initialSoup(seed: config.seed)
        let soupB = EcologyRandom.initialSoup(seed: again.seed)
        XCTAssertEqual(soupA, soupB)
        XCTAssertEqual(soupA.count, EcologyTopology.soupByteCount)
    }
}

/// Bounded ecology final diagnostic labeling. The ecology path emits its
/// final diagnostic as a distinct `EcologyFinalDiagnostic` type (never a
/// `ResidentFinalDiagnostic` overload) — a bounded ecology run is truthfully
/// ecology-labeled and carries explicit produced/published/displayed fields
/// with truthful names. The resident diagnostic schema/default behavior is
/// preserved unchanged.
final class EcologyFinalDiagnosticLabelTests: XCTestCase {

    func testEcologyFinalDiagnosticIsEcologyLabeledWithExplicitFields() throws {
        // Phase convention: producing epoch e => e mod 4; snapshot sourceEpoch
        // s => (s-1) mod 4. producedEpoch 4 => e=3 => V1; publishedSourceEpoch
        // 4 => (4-1) mod 4 = 3 => V1; displayedSourceEpoch 3 => (3-1) mod 4 =
        // 2 => V0.
        let diagnostic = EcologyFinalDiagnostic(
            producedEpoch: 4,
            producedPhase: "V1",
            publishedSourceEpoch: 4,
            publishedPhase: "V1",
            displayedSourceEpoch: 3,
            displayedPhase: "V0",
            frameCount: 12,
            failures: 0,
            unknownHalts: 0,
            stopReason: .epochLimit)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(diagnostic.jsonLine().utf8)) as? [String: Any])
        XCTAssertEqual(obj["kind"] as? String, "ecologyFinalDiagnostic")
        XCTAssertEqual(obj["stopReason"] as? String, "epochLimit")
        // Explicit produced/published/displayed fields with truthful names —
        // not a single texture-source field that conflates domains.
        XCTAssertEqual(obj["producedEpoch"] as? Int, 4)
        XCTAssertEqual(obj["producedPhase"] as? String, "V1")
        XCTAssertEqual(obj["publishedSourceEpoch"] as? Int, 4)
        XCTAssertEqual(obj["publishedPhase"] as? String, "V1")
        XCTAssertEqual(obj["displayedSourceEpoch"] as? Int, 3)
        XCTAssertEqual(obj["displayedPhase"] as? String, "V0")
        XCTAssertEqual(obj["frameCount"] as? Int, 12)
    }

    /// Nullable publication/display fields are emitted as JSON `null` (absent)
    /// when no publication/display has occurred — first-publication absence,
    /// skipped reservation, failed blit, or reset/stop before any
    /// publication landed truthfully leaves them `nil`.
    func testEcologyFinalDiagnosticNullableFieldsWhenNoPublicationOrDisplay() throws {
        let diagnostic = EcologyFinalDiagnostic(
            producedEpoch: 2,
            producedPhase: "H1",
            publishedSourceEpoch: nil,
            publishedPhase: nil,
            displayedSourceEpoch: nil,
            displayedPhase: nil,
            frameCount: 0,
            failures: 0,
            unknownHalts: 0,
            stopReason: .requested)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(diagnostic.jsonLine().utf8)) as? [String: Any])
        XCTAssertEqual(obj["producedEpoch"] as? Int, 2)
        XCTAssertNil(obj["publishedSourceEpoch"],
                      "publishedSourceEpoch must be null when no publication landed")
        XCTAssertNil(obj["publishedPhase"],
                      "publishedPhase must be null when no publication landed")
        XCTAssertNil(obj["displayedSourceEpoch"],
                      "displayedSourceEpoch must be null when no lease was rendered")
        XCTAssertNil(obj["displayedPhase"],
                      "displayedPhase must be null when no lease was rendered")
    }

    /// The ecology diagnostic emitter is one-shot: the first termination wins
    /// and later emits are inert (the same contract as the resident emitter,
    /// but in a distinct type so the resident path's schema is unchanged).
    func testEcologyFinalDiagnosticEmitterIsOneShot() {
        var emitter = EcologyFinalDiagnosticEmitter()
        let diagnostic = EcologyFinalDiagnostic(
            producedEpoch: 1, producedPhase: "H0",
            publishedSourceEpoch: nil, publishedPhase: nil,
            displayedSourceEpoch: nil, displayedPhase: nil,
            frameCount: 0, failures: 0, unknownHalts: 0,
            stopReason: .secondsLimit)
        var lines: [String] = []
        XCTAssertTrue(emitter.emit(diagnostic) { lines.append($0) })
        XCTAssertFalse(emitter.emit(diagnostic) { lines.append($0) })
        XCTAssertEqual(lines.count, 1)
    }

    /// The resident default `kind` is unchanged by the new ecology type, so
    /// the grounded resident termination contract is preserved.
    func testResidentFinalDiagnosticDefaultKindIsUnchanged() throws {
        let diagnostic = ResidentFinalDiagnostic(
            simulationEpoch: 1, displayedEpoch: 0, textureSourceEpoch: 1,
            frameCount: 0, failures: 0, unknownHalts: 0, stopReason: .secondsLimit)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(diagnostic.jsonLine().utf8)) as? [String: Any])
        XCTAssertEqual(obj["kind"] as? String, "residentFinalDiagnostic")
    }
}

/// Snapshot-ownership reuse tests: the ecology engine reuses the public
/// `ResidentGPUSnapshotRing` + `ResidentGPUSnapshotLease` + the pure
/// `ResidentSnapshotRingState` value type so its producer-publishes/
/// renderer-leases contract is defined and tested in one place. These tests
/// exercise the pure state machine (no Metal) on the contract the ecology
/// path depends on: ring exhaustion skips publication without backpressure,
/// and stale releases are inert.
final class EcologySnapshotOwnershipTests: XCTestCase {

    private static let byteCount = EcologyTopology.soupByteCount

    func testRingExhaustionSkipsPublicationWithoutBackpressure() throws {
        // A single-slot ring that already has one published slot cannot
        // reserve another (it would alias the published slot) — exhaustion
        // returns nil, which the producer treats as "skip publication", never
        // as backpressure that would stall the simulation.
        var state = try ResidentSnapshotRingState(slotCount: 1,
                                                  expectedByteCount: Self.byteCount)
        guard let reservation = state.reserveForWrite() else {
            return XCTFail("first reservation must succeed on a fresh ring")
        }
        let token = state.publish(reservation, sourceEpoch: 1,
                                  byteCount: Self.byteCount,
                                  blitHostSeconds: nil, blitGPUSeconds: nil)
        XCTAssertNotNil(token)
        // Now the only slot is published and leased; a further reservation
        // must be skipped (nil) — never block.
        XCTAssertNil(state.reserveForWrite())
        XCTAssertEqual(state.diagnostics.skippedReservationCount, 1)
    }

    func testLeasedSlotReleasesAndBecomesReservableAgain() throws {
        var state = try ResidentSnapshotRingState(slotCount: 2,
                                                  expectedByteCount: Self.byteCount)
        let r1 = try XCTUnwrap(state.reserveForWrite())
        _ = state.publish(r1, sourceEpoch: 1, byteCount: Self.byteCount,
                          blitHostSeconds: nil, blitGPUSeconds: nil)
        let lease = try XCTUnwrap(state.acquire(expectedByteCount: Self.byteCount))
        XCTAssertEqual(lease.sourceEpoch, 1)
        XCTAssertEqual(state.diagnostics.activeLeaseCount, 1)

        // While the lease is held, the leased slot cannot be reserved again
        // (the renderer holds the immutable resource; the producer must use a
        // different slot).
        XCTAssertNotNil(state.reserveForWrite())  // the second slot is free

        // Releasing the lease returns the slot to the pool.
        state.release(lease)
        XCTAssertEqual(state.diagnostics.activeLeaseCount, 0)
    }

    func testStaleReleaseAfterGenerationBumpIsInert() throws {
        // Simulate a generation bump / reset: a fresh ring state is created.
        // A stale release against the OLD token on the NEW state must be
        // counted as stale and never corrupt the new state (no spurious lease
        // decrement, no active-lease growth).
        var state = try ResidentSnapshotRingState(slotCount: 2,
                                                  expectedByteCount: Self.byteCount)
        let r = try XCTUnwrap(state.reserveForWrite())
        _ = state.publish(r, sourceEpoch: 1, byteCount: Self.byteCount,
                          blitHostSeconds: nil, blitGPUSeconds: nil)
        let lease = try XCTUnwrap(state.acquire(expectedByteCount: Self.byteCount))

        // A brand-new ring state stands in for the post-reset state. Releasing
        // a token acquired on the OLD state against the NEW state is stale:
        // the new state has no matching generation/lease, so it is counted and
        // otherwise inert.
        var newState = try ResidentSnapshotRingState(slotCount: 2,
                                                      expectedByteCount: Self.byteCount)
        XCTAssertEqual(newState.diagnostics.activeLeaseCount, 0)
        newState.release(lease)  // stale token against the new state
        XCTAssertEqual(newState.diagnostics.staleReleaseCount, 1)
        XCTAssertEqual(newState.diagnostics.activeLeaseCount, 0)
    }
}
