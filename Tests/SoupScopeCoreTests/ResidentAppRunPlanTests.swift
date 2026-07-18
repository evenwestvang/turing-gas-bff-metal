import XCTest
import Foundation
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

    func testResidentDeadlineTimerStopsDriverStateWithoutDisplayProgress() {
        let stopped = expectation(description: "resident seconds deadline stopped driver")
        let lock = NSLock()
        var machine = ResidentSimulationStateMachine()
        let timer = ResidentDeadlineTimer(seconds: 0.02) {
            lock.lock()
            machine.requestStop()
            lock.unlock()
            stopped.fulfill()
        }
        timer.start()
        wait(for: [stopped], timeout: 1.0)
        timer.cancel()
        lock.lock()
        let state = machine.state
        lock.unlock()
        XCTAssertEqual(state, .stopping)
    }

    func testResidentFinalDiagnosticIsCompleteWithNoDrawableCallbacks() throws {
        let diagnostic = ResidentFinalDiagnostic(
            simulationEpoch: 17,
            displayedEpoch: 0,
            textureSourceEpoch: 17,
            frameCount: 0,
            failures: 0,
            unknownHalts: 2,
            stopReason: .secondsLimit)
        let line = diagnostic.jsonLine()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8))
            as? [String: Any])

        XCTAssertEqual(obj["kind"] as? String, "residentFinalDiagnostic")
        XCTAssertEqual(obj["simulationEpoch"] as? Int, 17)
        XCTAssertEqual(obj["displayedEpoch"] as? Int, 0)
        XCTAssertEqual(obj["textureSourceEpoch"] as? Int, 17)
        XCTAssertEqual(obj["frameCount"] as? Int, 0)
        XCTAssertEqual(obj["failures"] as? Int, 0)
        XCTAssertEqual(obj["unknownHalts"] as? Int, 2)
        XCTAssertEqual(obj["stopReason"] as? String, "secondsLimit")
    }

    func testResidentFinalDiagnosticEmitterCompletesExactlyOnce() {
        var emitter = ResidentFinalDiagnosticEmitter()
        let diagnostic = ResidentFinalDiagnostic(
            simulationEpoch: 3,
            displayedEpoch: 0,
            textureSourceEpoch: 3,
            frameCount: 0,
            failures: 0,
            unknownHalts: 0,
            stopReason: .secondsLimit)
        var lines: [String] = []

        XCTAssertTrue(emitter.emit(diagnostic) { lines.append($0) })
        XCTAssertFalse(emitter.emit(diagnostic) { lines.append($0) })
        XCTAssertEqual(lines.count, 1)
    }

    func testResidentTerminationExitCodePolicy() {
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .epochLimit,
                                                          metalAvailable: true,
                                                          hasError: false),
                       0)
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .secondsLimit,
                                                          metalAvailable: true,
                                                          hasError: false),
                       0)
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .requested,
                                                          metalAvailable: true,
                                                          hasError: false),
                       0)
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .failure,
                                                          metalAvailable: true,
                                                          hasError: false),
                       1)
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .epochLimit,
                                                          metalAvailable: true,
                                                          hasError: true),
                       1)
        XCTAssertEqual(ResidentTerminationPolicy.exitCode(reason: .failure,
                                                          metalAvailable: false,
                                                          hasError: true),
                       2)
    }
}
