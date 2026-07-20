import XCTest
import BFFMetal
import BFFOracle
@testable import SoupScopeCore

/// Focused production parser/routing regression tests for the narrow
/// launch-default correction: an empty application argument list (after the
/// executable name is stripped, exactly the form `SoupScopeApp` hands to
/// `AppLaunchOptions.parse`) selects resident mode, while every nonempty
/// explicit CLI invocation preserves its prior routing — non-resident unless a
/// `--resident`-family flag flips it. Constants (keyed planner, 131,072
/// `ProgramGrid.capacity` population) are referenced, never duplicated.
final class AppLaunchDefaultRoutingTests: XCTestCase {

    // MARK: 1. Empty GUI args -> resident + keyed + 131K

    /// An empty application argument list must select resident mode with the
    /// existing keyed planner and the 131,072 `ProgramGrid.capacity` population
    /// default. The planner and population are sourced from
    /// `ResidentPairingPlanner.keyed` and `ProgramGrid.capacity` — not
    /// duplicated literals — so a drift in either source is caught here.
    func testEmptyGUIArgsSelectResidentWithKeyedPlannerAndCapacityPopulation() throws {
        let defaults = try AppLaunchOptions.parse([])

        XCTAssertEqual(defaults.simulationMode, .resident)
        XCTAssertTrue(defaults.residentRunPlan().enabled)

        XCTAssertEqual(defaults.residentPlanner, ResidentPairingPlanner.keyed)
        XCTAssertEqual(defaults.residentRunPlan().planner, ResidentPairingPlanner.keyed)

        XCTAssertEqual(defaults.programCount, ProgramGrid.capacity)
        XCTAssertEqual(ProgramGrid.capacity, 131_072)
        XCTAssertEqual(defaults.programCount, 131_072)

        let plan = defaults.residentRunPlan()
        XCTAssertEqual(plan.rendererSource, .residentVisualizationTexture)
        XCTAssertFalse(SoupScopeAppLifecycle.constructsLegacyCPURunner(for: plan))
        XCTAssertEqual(SoupScopeAppLifecycle.initialSnapshotSource(for: plan), .none)

        XCTAssertNoThrow(try defaults.residentConfig())
    }

    // MARK: 2. Representative nonempty explicit invocations preserve prior routing

    /// Representative nonempty explicit invocations that carry no
    /// `--resident`-family flag must keep routing to non-resident mode — the
    /// narrow correction flips only the *empty* launch, so any explicit CLI
    /// (including a single `--programs 8` or a `--help`) retains its prior
    /// implicit non-resident behavior.
    func testNonemptyExplicitInvocationsPreserveNonResidentRouting() throws {
        let invocations: [[String]] = [
            ["--programs", "8"],
            ["--seed", "1"],
            ["--budget", "512"],
            ["--mutation-p32", "0"],
            ["--shadow-sample", "all"],
            ["--variant", "bff"],
            ["--validation-seconds", "1.0"],
            ["--frame-stage-timing"],
            ["--help"],
            ["-h"],
            ["--programs", "131072", "--seed", "42", "--shadow-sample", "all"],
        ]
        for args in invocations {
            let parsed = try AppLaunchOptions.parse(args)
            XCTAssertEqual(parsed.simulationMode, .nonResident,
                           "nonempty invocation \(args) must stay non-resident")
            XCTAssertFalse(parsed.residentRunPlan().enabled,
                           "nonempty invocation \(args) must not enable resident")

            let plan = parsed.residentRunPlan()
            XCTAssertTrue(SoupScopeAppLifecycle.constructsLegacyCPURunner(for: plan),
                          "nonempty invocation \(args) must keep the legacy CPU runner")
            XCTAssertEqual(SoupScopeAppLifecycle.initialSnapshotSource(for: plan),
                           .legacyCPURunner,
                           "nonempty invocation \(args) must seed from the CPU runner")
            XCTAssertEqual(plan.rendererSource, .cpuSnapshot,
                           "nonempty invocation \(args) must render from the CPU snapshot")
        }
    }

    // MARK: 3. Explicit resident behavior remains intact

    /// Every `--resident`-family flag still flips a nonempty explicit
    /// invocation to resident mode with the expected planner/limit/visualization
    /// routing, and the resident error paths still throw.
    func testExplicitResidentFlagsRemainIntact() throws {
        let resident = try AppLaunchOptions.parse(["--resident"])
        let plan = resident.residentRunPlan()
        XCTAssertTrue(plan.enabled)
        XCTAssertEqual(plan.planner, .keyed)
        XCTAssertEqual(plan.rendererSource, .residentVisualizationTexture)
        XCTAssertEqual(plan.limit, .unbounded)
        XCTAssertEqual(plan.checkpointInterval, 0)
        XCTAssertFalse(plan.capturePairTapes)
        XCTAssertEqual(plan.shadowSampleCount, 0)
        XCTAssertFalse(SoupScopeAppLifecycle.constructsLegacyCPURunner(for: plan))
        XCTAssertEqual(SoupScopeAppLifecycle.initialSnapshotSource(for: plan), .none)

        let cpuUpload = try AppLaunchOptions.parse(["--resident-planner", "cpu-upload"])
        XCTAssertTrue(cpuUpload.residentRunPlan().enabled)
        XCTAssertEqual(cpuUpload.residentPlanner, .cpuUpload)

        let epochs = try AppLaunchOptions.parse(["--resident-epochs", "5"])
        XCTAssertTrue(epochs.residentRunPlan().enabled)
        XCTAssertEqual(epochs.residentRunPlan().limit, .epochs(5))

        let seconds = try AppLaunchOptions.parse(["--resident-seconds", "2.5"])
        XCTAssertTrue(seconds.residentRunPlan().enabled)
        XCTAssertEqual(seconds.residentRunPlan().limit, .seconds(2.5))

        let tiny = try AppLaunchOptions.parse(["--resident-tiny-validation"])
        XCTAssertTrue(tiny.residentRunPlan().enabled)
        XCTAssertTrue(tiny.residentRunPlan().tinyValidation)

        let checkpoint = try AppLaunchOptions.parse(["--resident-checkpoint-interval", "3"])
        XCTAssertTrue(checkpoint.residentRunPlan().enabled)
        XCTAssertEqual(checkpoint.residentRunPlan().checkpointInterval, 3)

        let viz = try AppLaunchOptions.parse(["--resident-visualization-width", "256"])
        XCTAssertTrue(viz.residentRunPlan().enabled)
        XCTAssertEqual(viz.residentRunPlan().visualizationWidth, 256)

        XCTAssertThrowsError(try AppLaunchOptions.parse([
            "--resident-epochs", "1", "--resident-seconds", "1",
        ]))
        XCTAssertThrowsError(try AppLaunchOptions.parse(["--resident-planner", "bogus"]))
    }
}
