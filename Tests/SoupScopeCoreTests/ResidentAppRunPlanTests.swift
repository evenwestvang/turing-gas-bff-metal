import XCTest
import BFFMetal
@testable import SoupScopeCore

final class ResidentAppRunPlanTests: XCTestCase {
    func testResidentModeIsOptInAndDefaultsDoNotReadBackSoup() throws {
        let defaults = try AppLaunchOptions.parse([])
        XCTAssertEqual(defaults.simulationMode, .nonResident)
        XCTAssertFalse(defaults.residentRunPlan().enabled)
        XCTAssertEqual(defaults.residentRunPlan().rendererSource, .cpuSnapshot)

        let resident = try AppLaunchOptions.parse(["--resident"])
        let plan = resident.residentRunPlan()
        XCTAssertTrue(plan.enabled)
        XCTAssertEqual(plan.rendererSource, .residentVisualizationTexture)
        XCTAssertEqual(plan.planner, .keyed)
        XCTAssertEqual(plan.checkpointInterval, 0)
        XCTAssertFalse(plan.capturePairTapes)
        XCTAssertEqual(plan.shadowSampleCount, 0)
        XCTAssertFalse(plan.normalRunningReadsBackSoup)

        let config = try resident.residentConfig()
        XCTAssertTrue(config.visualizationEnabled)
        XCTAssertEqual(config.checkpointInterval, 0)
        XCTAssertFalse(config.capturePairTapes)
        XCTAssertEqual(config.shadowSampleCount, 0)
    }

    func testResidentLaunchParsesPlannerBoundsAndValidation() throws {
        let parsed = try AppLaunchOptions.parse([
            "--resident-planner", "cpu-upload",
            "--resident-epochs", "7",
            "--programs", "64",
            "--resident-visualization-width", "16",
        ])
        XCTAssertEqual(parsed.simulationMode, .resident)
        XCTAssertEqual(parsed.residentPlanner, .cpuUpload)
        XCTAssertEqual(parsed.residentRunPlan().limit, .epochs(7))
        XCTAssertEqual(parsed.residentRunPlan().visualizationWidth, 16)

        let tiny = try AppLaunchOptions.parse(["--resident-tiny-validation", "--programs", "8"])
        let plan = tiny.residentRunPlan()
        XCTAssertEqual(plan.limit, .epochs(1))
        XCTAssertEqual(plan.checkpointInterval, 1)
        XCTAssertTrue(plan.capturePairTapes)
        XCTAssertNil(plan.shadowSampleCount)
        let config = try tiny.residentConfig()
        XCTAssertEqual(config.checkpointInterval, 1)
        XCTAssertTrue(config.capturePairTapes)
        XCTAssertNil(config.shadowSampleCount)

        let seconds = try AppLaunchOptions.parse(["--resident-seconds", "2.5"])
        XCTAssertEqual(seconds.residentRunPlan().limit, .seconds(2.5))
        XCTAssertThrowsError(try AppLaunchOptions.parse([
            "--resident-epochs", "1", "--resident-seconds", "1",
        ]))
        XCTAssertThrowsError(try AppLaunchOptions.parse(["--resident-planner", "bogus"]))
    }

    func testResidentPlannerLabelsPreserveModeAndProvenance() {
        XCTAssertEqual(ResidentPairingPlanner.keyed.cliValue, "keyed")
        XCTAssertEqual(ResidentPairingPlanner.keyed.identifier, "parallel-swap-or-not-v1")
        XCTAssertEqual(ResidentPairingPlanner.keyed.provenanceLabel,
                       "statistical-random-looking-not-fisher-yates-identical")

        XCTAssertEqual(ResidentPairingPlanner.cpuUpload.cliValue, "cpu-upload")
        XCTAssertEqual(ResidentPairingPlanner.cpuUpload.identifier,
                       "cpu-upload-fisher-yates-v1")
        XCTAssertEqual(ResidentPairingPlanner.cpuUpload.provenanceLabel,
                       "canonical-fisher-yates-trajectory")
    }

    func testResidentPauseResumeStateMachineIsRaceTolerantAtBoundaries() {
        var machine = ResidentSimulationStateMachine()
        XCTAssertEqual(machine.state, .running)
        XCTAssertTrue(machine.shouldAdvance)

        machine.pause()
        XCTAssertEqual(machine.state, .paused)
        XCTAssertFalse(machine.shouldAdvance)
        machine.pause()
        XCTAssertEqual(machine.state, .paused)

        machine.resume()
        XCTAssertEqual(machine.state, .running)
        machine.togglePause()
        XCTAssertEqual(machine.state, .paused)
        machine.togglePause()
        XCTAssertEqual(machine.state, .running)

        machine.requestStop()
        XCTAssertEqual(machine.state, .stopping)
        machine.pause()
        machine.resume()
        machine.togglePause()
        XCTAssertEqual(machine.state, .stopping)
        machine.markStopped()
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertTrue(machine.isTerminal)
    }
}
