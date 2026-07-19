import XCTest
@testable import SoupScopeCore

/// Focused lifecycle tests for the production-used resident/non-resident
/// app-shell decisions.
final class ResidentAppLifecycleTests: XCTestCase {

    func testResidentPlanComposesSharedWindowGroupAndSkipsLegacyCPURunner() {
        let resident = try! AppLaunchOptions.parse(["--resident"]).residentRunPlan()

        XCTAssertEqual(SoupScopeAppLifecycle.sceneComposition(for: resident),
                       .sharedWindowGroup(id: SoupScopeAppLifecycle.windowSceneID))
        XCTAssertFalse(SoupScopeAppLifecycle.constructsLegacyCPURunner(for: resident),
                       "resident mode must not construct the legacy CPU SoupRunner")
    }

    func testNonResidentPlanComposesSharedWindowGroupAndConstructsLegacyCPURunner() {
        let nonResident = try! AppLaunchOptions.parse([]).residentRunPlan()

        XCTAssertEqual(SoupScopeAppLifecycle.sceneComposition(for: nonResident),
                       .sharedWindowGroup(id: SoupScopeAppLifecycle.windowSceneID))
        XCTAssertTrue(SoupScopeAppLifecycle.constructsLegacyCPURunner(for: nonResident),
                      "non-resident mode must keep constructing the legacy CPU SoupRunner")
    }

    /// Regression for the initial snapshot routing: the pure production decision
    /// `SoupScopeAppLifecycle.initialSnapshotSource(for:)` must route non-resident
    /// mode to `.legacyCPURunner` (so `AppModel.init` seeds `lastSnapshot` from
    /// the constructed CPU runner's seeded soup) and resident mode to `.none`
    /// (so `lastSnapshot` stays `nil` and never builds from an empty CPU soup).
    /// This exercises the same production routing `AppModel.init` consumes
    /// rather than independently reconstructing `SoupRunner` + `RenderSnapshot.initial`.
    func testInitialSnapshotSourceRoutesByPlan() {
        let resident = try! AppLaunchOptions.parse(["--resident"]).residentRunPlan()
        XCTAssertEqual(SoupScopeAppLifecycle.initialSnapshotSource(for: resident),
                       .none,
                       "resident mode must not seed lastSnapshot from a CPU runner")

        let nonResident = try! AppLaunchOptions.parse([]).residentRunPlan()
        XCTAssertEqual(SoupScopeAppLifecycle.initialSnapshotSource(for: nonResident),
                       .legacyCPURunner,
                       "non-resident mode must seed lastSnapshot from the legacy CPU runner")
    }
}
