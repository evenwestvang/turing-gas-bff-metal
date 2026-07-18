import XCTest
@testable import SoupScopeCore

/// Pure, platform-independent coverage for the app-frame host-stage timing model. No
/// Metal, no clock: the reconciliation math and the "available only when present on every
/// frame" rule are exercised on synthetic spans, exactly the way the benchmark's
/// `HostStageAttribution` math is unit-tested off-Metal.
final class AppFrameStageTimingTests: XCTestCase {

    func testEmptyAccumulatorHasNoSummary() {
        let acc = AppFrameStageAccumulator()
        XCTAssertEqual(acc.frameCount, 0)
        XCTAssertNil(acc.summary(), "no frames -> no summary")
    }

    /// All stages present on every frame: means reconcile, remainder is the frame wall
    /// minus the classified sum, and the classified fraction is exact.
    func testFullyPopulatedFramesReconcile() throws {
        var acc = AppFrameStageAccumulator()
        // Two identical frames: wall 10 ms, classified 4+2+1+2 = 9 ms, remainder 1 ms.
        let sample = AppFrameStageSample(
            frameSeconds: 0.010, epochBatchSeconds: 0.004, snapshotBuildSeconds: 0.002,
            metricTextureSeconds: 0.001, renderSubmitSeconds: 0.002)
        acc.record(sample)
        acc.record(sample)

        let s = try XCTUnwrap(acc.summary())
        XCTAssertEqual(s.frameCount, 2)
        XCTAssertEqual(s.meanFrameMs, 10, accuracy: 1e-9)
        XCTAssertEqual(s.epochBatchMsPerFrame!, 4, accuracy: 1e-9)
        XCTAssertEqual(s.snapshotBuildMsPerFrame!, 2, accuracy: 1e-9)
        XCTAssertEqual(s.metricTextureMsPerFrame!, 1, accuracy: 1e-9)
        XCTAssertEqual(s.renderSubmitMsPerFrame!, 2, accuracy: 1e-9)
        XCTAssertEqual(s.unclassifiedMsPerFrame, 1, accuracy: 1e-9)
        XCTAssertEqual(s.classifiedFrameFraction, 0.9, accuracy: 1e-9)

        // Reconciliation: available stage means + remainder == mean frame wall.
        let sum = s.epochBatchMsPerFrame! + s.snapshotBuildMsPerFrame!
            + s.metricTextureMsPerFrame! + s.renderSubmitMsPerFrame!
        XCTAssertEqual(sum + s.unclassifiedMsPerFrame, s.meanFrameMs, accuracy: 1e-9)
    }

    /// A stage measured on only some frames (the Metal-only spans on a host that skipped
    /// them) is reported as `nil`, and its time stays in the remainder so the total still
    /// reconciles.
    func testPartiallyPresentStageIsNilAndFoldsIntoRemainder() throws {
        var acc = AppFrameStageAccumulator()
        // Frame 1 has the Metal spans; frame 2 does not (e.g. no drawable that frame).
        acc.record(AppFrameStageSample(
            frameSeconds: 0.010, epochBatchSeconds: 0.004, snapshotBuildSeconds: 0.002,
            metricTextureSeconds: 0.001, renderSubmitSeconds: 0.002))
        acc.record(AppFrameStageSample(
            frameSeconds: 0.010, epochBatchSeconds: 0.004, snapshotBuildSeconds: 0.002,
            metricTextureSeconds: nil, renderSubmitSeconds: nil))

        let s = try XCTUnwrap(acc.summary())
        // epoch + snapshot present on both frames -> available.
        XCTAssertEqual(s.epochBatchMsPerFrame!, 4, accuracy: 1e-9)
        XCTAssertEqual(s.snapshotBuildMsPerFrame!, 2, accuracy: 1e-9)
        // Metal spans present on only one frame -> nil.
        XCTAssertNil(s.metricTextureMsPerFrame)
        XCTAssertNil(s.renderSubmitMsPerFrame)
        // Classified = epoch+snapshot only (6 ms/frame); remainder = 10 - 6 = 4.
        XCTAssertEqual(s.unclassifiedMsPerFrame, 4, accuracy: 1e-9)
        XCTAssertEqual(s.classifiedFrameFraction, 0.6, accuracy: 1e-9)
    }

    /// The remainder never goes negative even if the recorded spans exceed the frame wall.
    func testRemainderClampsAtZero() throws {
        var acc = AppFrameStageAccumulator()
        acc.record(AppFrameStageSample(
            frameSeconds: 0.001, epochBatchSeconds: 0.002, snapshotBuildSeconds: 0.002))
        let s = try XCTUnwrap(acc.summary())
        XCTAssertEqual(s.unclassifiedMsPerFrame, 0, "never negative")
    }

    /// The one-line summary is deterministic and prints unmeasured stages as `null`.
    func testSummaryLinePrintsNullForUnmeasuredStages() throws {
        var acc = AppFrameStageAccumulator()
        acc.record(AppFrameStageSample(frameSeconds: 0.010, epochBatchSeconds: 0.004,
                                       snapshotBuildSeconds: 0.002))
        let line = try XCTUnwrap(acc.summary()).summaryLine
        XCTAssertTrue(line.contains("frames=1"))
        XCTAssertTrue(line.contains("metricTextureMs=null"))
        XCTAssertTrue(line.contains("renderSubmitMs=null"))
        XCTAssertTrue(line.contains("epochBatchMs=4.0000"), line)   // 0.004 s -> 4 ms
    }

    /// The launch flag defaults off and parses on.
    func testLaunchOptionParsesFrameStageTiming() throws {
        XCTAssertFalse(AppLaunchOptions().frameStageTiming, "off by default")
        let on = try AppLaunchOptions.parse(["--frame-stage-timing"])
        XCTAssertTrue(on.frameStageTiming)
    }
}
