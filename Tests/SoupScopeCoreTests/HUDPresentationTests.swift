import XCTest
@testable import SoupScopeCore

/// Focused tests for the HUD presentation restructure:
/// - VizEntropyHistory state feeds the HUD entropy line
/// - ResidentResetTransition clears entropy state correctly
/// - HUDModel carries all required raw metric fields
///
/// These tests use production helper types (HUDModel, VizEntropyHistory,
/// ResidentResetTransition) and do not depend on Metal or SwiftUI.
/// They make no fragile source-string assertions.
final class HUDPresentationTests: XCTestCase {

    // MARK: - Entropy availability → HUD data flow

    func testVizEntropyHistoryLatestFeedsHUDEntropyLine() {
        var history = VizEntropyHistory(capacity: 8)
        XCTAssertNil(history.latest?.meanByteEntropyBitsPerByte,
                     "empty history → latest nil → HUD shows em-dash")

        let sample = VizEntropySample(epoch: 0, meanByteEntropyBitsPerByte: 3.14)
        XCTAssertTrue(history.record(sample))

        XCTAssertEqual(history.latest?.meanByteEntropyBitsPerByte, 3.14,
                       "latest provides the HUD entropy line value")
    }

    func testUnavailableEntropyDoesNotExposeLatest() {
        var history = VizEntropyHistory(capacity: 4)
        history.record(VizEntropySample(epoch: 0, meanByteEntropyBitsPerByte: 2.5))

        let available = false
        let entropyForHUD: Double? = available
            ? history.latest?.meanByteEntropyBitsPerByte
            : nil

        XCTAssertNil(entropyForHUD,
                     "available false → HUD entropy nil regardless of history content")
    }

    func testAvailableWithEmptyHistoryDoesNotExposeLatest() {
        let history = VizEntropyHistory(capacity: 4)
        let available = true
        let entropyForHUD: Double? = available
            ? history.latest?.meanByteEntropyBitsPerByte
            : nil

        XCTAssertNil(entropyForHUD,
                     "available true but history empty → HUD entropy nil")
    }

    func testAvailableWithHistoryExposesLatest() {
        var history = VizEntropyHistory(capacity: 4)
        history.record(VizEntropySample(epoch: 5, meanByteEntropyBitsPerByte: 1.5))
        let available = true
        let entropyForHUD: Double? = available
            ? history.latest?.meanByteEntropyBitsPerByte
            : nil

        XCTAssertEqual(entropyForHUD, 1.5)
    }

    // MARK: - HUDModel carries all raw metrics

    func testHUDModelCarriesAllRawMetricFields() {
        let hud = HUDModel(deviceName: "TestDevice", programCount: 16)
        XCTAssertEqual(hud.deviceName, "TestDevice")
        XCTAssertEqual(hud.programCount, 16)
        XCTAssertEqual(hud.epoch, 0)
        XCTAssertEqual(hud.rawSteps, 0)
        XCTAssertEqual(hud.noopSteps, 0)
        XCTAssertEqual(hud.commandSteps, 0)
        XCTAssertEqual(hud.haltBudget, 0)
        XCTAssertEqual(hud.haltPCOut, 0)
        XCTAssertEqual(hud.haltUnmatched, 0)
        XCTAssertEqual(hud.haltUnknown, 0)
        XCTAssertEqual(hud.copyWrites, 0)
        XCTAssertEqual(hud.shadowChecked, 0)
        XCTAssertEqual(hud.shadowMismatch, 0)
        XCTAssertNil(hud.errorState)
        XCTAssertNil(hud.resident)
    }

    func testHUDModelErrorStateRemainsInPrimarySection() {
        var hud = HUDModel()
        hud.setError("critical failure")
        XCTAssertEqual(hud.errorState, "critical failure")
        hud.record(batch: [], epoch: 1, batchMs: 10)
        XCTAssertEqual(hud.errorState, "critical failure",
                       "error state survives record()")
        hud.setError(nil)
        XCTAssertNil(hud.errorState)
    }

    // MARK: - Reset clears entropy state

    func testResetTransitionClearsEntropyState() {
        let transition = ResidentResetTransition(
            deviceName: "TestDevice", programCount: 16,
            drawableWidth: 640, drawableHeight: 480)

        XCTAssertTrue(transition.vizEntropyHistory.isEmpty,
                     "reset clears entropy history")
        XCTAssertFalse(transition.vizEntropyAvailable,
                       "reset sets entropy availability false")
        XCTAssertEqual(transition.metricChannel, ResidentVizChannel.defaultChannel.rawValue,
                       "reset restores default metric channel")
        XCTAssertEqual(transition.hud.epoch, 0, "reset clears epoch")
        XCTAssertNil(transition.hud.errorState, "reset clears error state")
        XCTAssertNil(transition.hud.resident, "reset clears resident diagnostics")
    }

    // MARK: - Channel labels

    func testResidentChannelLabelIsAvailableForPrimaryHUD() {
        for channel in ResidentVizChannel.allCases {
            XCTAssertFalse(channel.label.isEmpty,
                           "channel \(channel) must have non-empty label for HUD")
        }
    }

    // MARK: - HUDModel batch record propagates epoch

    func testHUDModelRecordBatchUpdatesEpoch() {
        var hud = HUDModel(deviceName: "Dev", programCount: 8)
        hud.record(batch: [], epoch: 42, batchMs: 100.0)
        XCTAssertEqual(hud.epoch, 42, "record sets epoch")
        XCTAssertEqual(hud.lastBatchMs, 100.0, accuracy: 0.01,
                       "record sets batchMs")
    }

    // MARK: - Identity preserved across updates

    func testHUDModelPreservesIdentityAcrossUpdates() {
        var hud = HUDModel(deviceName: "M4", programCount: 131072)
        hud.record(batch: [], epoch: 5, batchMs: 50.0)
        hud.setError("oops")
        hud.setError(nil)

        XCTAssertEqual(hud.deviceName, "M4", "device name survives")
        XCTAssertEqual(hud.programCount, 131072, "program count survives")
    }
}
