import XCTest
import BFFOracle
import BFFMetal
@testable import SoupScopeCore

/// HUD counter/halt/shadow propagation and the invariant that per-frame batching
/// never changes the deterministic soup trajectory. Uses the platform-independent
/// `CPUPairEvaluator` so these run everywhere (no Metal).
final class HUDAndTrajectoryTests: XCTestCase {

    private func config(programs: Int = 16, shadow: Int? = nil) throws -> SoupConfig {
        try SoupConfig(seed: 42, programCount: programs, stepBudget: 512,
                       mutationP32: BFF.defaultMutationP32, shadowSampleCount: shadow)
    }

    // MARK: - HUD propagation

    func testHUDRecordsLatestEpochCountersAndAccumulatesShadow() throws {
        var runner = SoupRunner(config: try config(programs: 16, shadow: 8))
        let reports = try runner.run(epochs: 5, using: CPUPairEvaluator())

        var hud = HUDModel(deviceName: "TestDevice", programCount: 16)
        hud.record(batch: reports, epoch: runner.epoch, batchMs: 12.5)

        XCTAssertEqual(hud.epoch, runner.epoch)
        XCTAssertEqual(hud.lastBatchEpochs, reports.count)
        XCTAssertEqual(hud.lastBatchMs, 12.5)
        XCTAssertEqual(hud.msPerEpoch, 12.5 / Double(reports.count), accuracy: 1e-12)

        // Latest-epoch counters mirror the last report exactly.
        let last = reports.last!.counters
        XCTAssertEqual(hud.rawSteps, last.totalRawSteps)
        XCTAssertEqual(hud.noopSteps, last.totalNoopSteps)
        XCTAssertEqual(hud.commandSteps, last.totalCommandSteps)
        XCTAssertEqual(hud.haltBudget, last.haltBudget)
        XCTAssertEqual(hud.haltPCOut, last.haltPCOut)
        XCTAssertEqual(hud.haltUnmatched, last.haltUnmatched)
        XCTAssertEqual(hud.haltUnknown, last.haltUnknown)
        XCTAssertEqual(hud.copyWrites, last.totalCopyWrites)

        // Shadow counts accumulate across every report in the batch.
        XCTAssertEqual(hud.shadowChecked, reports.reduce(0) { $0 + $1.shadowChecked })
        XCTAssertEqual(hud.shadowMismatch, reports.reduce(0) { $0 + $1.shadowMismatches.count })
        XCTAssertEqual(hud.shadowMismatch, 0, "CPU reference never diverges from itself")
        XCTAssertNil(hud.errorState)
    }

    func testHUDErrorStateIsVisibleAndSticksAcrossRecords() throws {
        var runner = SoupRunner(config: try config())
        let reports = try runner.run(epochs: 2, using: CPUPairEvaluator())
        var hud = HUDModel()
        hud.setError("boom")
        hud.record(batch: reports, epoch: runner.epoch, batchMs: 1)
        XCTAssertEqual(hud.errorState, "boom")   // record does not clear a set error
        hud.setError(nil)
        XCTAssertNil(hud.errorState)
    }

    // MARK: - Trajectory independence from batching cadence

    func testTrajectoryIsIndependentOfBatchPartition() throws {
        let cpu = CPUPairEvaluator()
        // Run A: one batch of 12 epochs. Run B: partitions 1 + 4 + 7.
        var a = SoupRunner(config: try config(shadow: 4))
        var b = SoupRunner(config: try config(shadow: 4))

        let repsA = try a.run(epochs: 12, using: cpu)
        var repsB: [EpochReport] = []
        for count in [1, 4, 7] {
            repsB.append(contentsOf: try b.run(epochs: count, using: cpu))
        }

        XCTAssertEqual(a.soup, b.soup, "final soup independent of batch partition")
        XCTAssertEqual(a.digest, b.digest)
        XCTAssertEqual(repsA.count, repsB.count)
        for (x, y) in zip(repsA, repsB) {
            XCTAssertEqual(x.digest, y.digest)
            XCTAssertEqual(x.counters, y.counters)
        }
    }

    // MARK: - Snapshot built from a real epoch keeps stable-ID ordering

    func testSnapshotFromRunnerMatchesSoupAndMetricLengths() throws {
        let cfg = try config(programs: 16)
        var runner = SoupRunner(config: cfg)
        let report = try runner.runEpoch(using: CPUPairEvaluator())
        let snap = try RenderSnapshot.build(epoch: runner.epoch,
                                            programCount: cfg.programCount,
                                            soup: runner.soup, metrics: report.metrics)
        XCTAssertEqual(snap.programCount, cfg.programCount)
        XCTAssertEqual(snap.programBytes.count, cfg.programCount * BFF.tapeSize)
        XCTAssertEqual(snap.activity.count, cfg.programCount)
        XCTAssertEqual(snap.entropy.count, cfg.programCount)
        // Record i is program i: snapshot bytes equal the runner's soup slice.
        for id in 0 ..< cfg.programCount {
            XCTAssertEqual(snap.programByteSlice(id), runner.program(at: id))
            XCTAssertEqual(snap.activity[id], report.metrics[id].activity)
            XCTAssertEqual(snap.entropy[id], report.metrics[id].entropyBitsPerByte)
        }
    }

    func testInitialSnapshotHasZeroActivityAndComputedEntropy() throws {
        let cfg = try config(programs: 8)
        let runner = SoupRunner(config: cfg)
        let snap = try RenderSnapshot.initial(programCount: cfg.programCount, soup: runner.soup)
        XCTAssertEqual(snap.epoch, 0)
        XCTAssertTrue(snap.activity.allSatisfy { $0 == 0 })
        XCTAssertEqual(snap.entropy.count, cfg.programCount)
        // Entropy is the per-program byte entropy of the seeded soup.
        XCTAssertEqual(snap.entropy[0],
                       SoupMetrics.entropyBitsPerByte(runner.program(at: 0)))
    }
}
