import XCTest
import BFFMetal
import BFFOracle
import BFFEcologyMetal
@testable import SoupScopeCore

/// Focused production tests for the experimental "SoupScope Spatial Ecology"
/// app integration — parser, run-plan, persistent label/channel, lifecycle
/// routing, snapshot-ownership reuse, and the reset/generation fence.
///
/// Pure SoupScopeCore/BFFOracle/BFFEcologyMetal/BFFMetal values only — no
/// AppKit/Metal — so the whole ecology contract is testable on any host
/// (including Linux CI). No source-string assertions are used as execution
/// proof: every assertion is against observable behavior.
final class EcologyAppLaunchTests: XCTestCase {

    // MARK: 1. Plain/empty launch stays the grounded resident route

    /// An empty application argument list must keep the existing grounded
    /// resident routing (keyed planner, 131,072 ProgramGrid.capacity). Ecology
    /// must never be selected implicitly.
    func testEmptyLaunchStaysResidentNotEcology() throws {
        let plain = try AppLaunchOptions.parse([])
        XCTAssertEqual(plain.simulationMode, .resident)
        XCTAssertFalse(plain.ecologyPlan.enabled)
        XCTAssertTrue(plain.residentRunPlan().enabled)
        XCTAssertEqual(plain.residentPlanner, .keyed)
        XCTAssertEqual(plain.programCount, ProgramGrid.capacity)
        XCTAssertEqual(plain.programCount, 131_072)
    }

    // MARK: 2. Explicit --ecology route + persistent label

    /// `--ecology` selects the ecology engine, constructs neither the legacy
    /// CPU runner nor the grounded resident driver, and pins the topology to
    /// the fixed 512×256 ecology canvas.
    func testEcologyFlagRoutesToEcologyEngineWithoutLegacyRunner() throws {
        let opts = try AppLaunchOptions.parse(["--ecology"])
        XCTAssertEqual(opts.simulationMode, .ecology)
        XCTAssertTrue(opts.ecologyPlan.enabled)

        // Exactly one engine per app run: ecology constructs neither the
        // legacy SoupRunner nor the grounded ResidentSimulationDriver.
        XCTAssertFalse(SoupScopeAppLifecycle.constructsLegacyCPURunner(
            forEcology: opts.ecologyPlan))
        XCTAssertEqual(SoupScopeAppLifecycle.initialSnapshotSource(
            forEcology: opts.ecologyPlan), .none)

        // The topology is fixed by the ecology contract, not configurable.
        XCTAssertEqual(EcologyAppRunPlan.siteCount, EcologyTopology.siteCount)
        XCTAssertEqual(EcologyAppRunPlan.siteCount, 131_072)
        XCTAssertEqual(EcologyAppRunPlan.siteCount, ProgramGrid.capacity)

        // The persistent label is exactly the headless-CLI string.
        XCTAssertEqual(EcologyAppRunPlan.label, "Experimental Spatial Ecology")
    }

    /// `--ecology` with a nonempty explicit CLI keeps ecology routing and
    /// forwards the accepted-CLI config knobs (seed/budget/mutation-p32/
    /// variant/brackets) into the immutable plan.
    func testEcologyForwardsAcceptedCLIConfigKnobs() throws {
        let opts = try AppLaunchOptions.parse([
            "--ecology", "--seed", "12345", "--budget", "4096",
            "--mutation-p32", "1000", "--variant", "bff",
            "--ecology-brackets", "jumpTable",
        ])
        XCTAssertEqual(opts.simulationMode, .ecology)
        XCTAssertEqual(opts.ecologyPlan.seed, 12345)
        XCTAssertEqual(opts.ecologyPlan.stepBudget, 4096)
        XCTAssertEqual(opts.ecologyPlan.mutationP32, 1000)
        XCTAssertEqual(opts.ecologyPlan.variant, .seededHeads)
        XCTAssertEqual(opts.ecologyPlan.bracketMode, .jumpTable)
        // The ecology evaluator contract token matches the headless CLI form.
        XCTAssertEqual(opts.ecologyPlan.evaluatorContractID,
                       "bff-evaluator-v1:bff:jumpTable")
    }

    /// The Metal contract pins ecology stepBudget to 1...8192; over-budget is
    /// rejected clearly, never clamped (parity with the headless CLI).
    func testEcologyOverBudgetIsRejectedNeverClamped() {
        XCTAssertThrowsError(try AppLaunchOptions.parse(["--ecology", "--budget", "8193"])) {
            error in
            guard case AppLaunchOptions.ParseError.ecologyBudgetExceedsMetalContract(8193) = error
            else { return XCTFail("expected metal-contract rejection, got \(error)") }
        }
    }

    /// At most one of --ecology-epochs / --ecology-seconds.
    func testEcologyConflictingLimitsRejected() {
        XCTAssertThrowsError(try AppLaunchOptions.parse([
            "--ecology", "--ecology-epochs", "1", "--ecology-seconds", "1",
        ])) { error in
            guard case AppLaunchOptions.ParseError.conflictingEcologyLimits = error
            else { return XCTFail("expected conflicting-ecology-limits, got \(error)") }
        }
    }

    /// Ecology bounded/tiny-validation plans populate their limit correctly.
    func testEcologyBoundedAndTinyPlans() throws {
        let epochs = try AppLaunchOptions.parse(["--ecology", "--ecology-epochs", "3"])
        XCTAssertEqual(epochs.ecologyPlan.limit, .epochs(3))

        let seconds = try AppLaunchOptions.parse(["--ecology", "--ecology-seconds", "2.5"])
        XCTAssertEqual(seconds.ecologyPlan.limit, .seconds(2.5))

        let tiny = try AppLaunchOptions.parse(["--ecology", "--ecology-tiny-validation"])
        XCTAssertTrue(tiny.ecologyPlan.tinyValidation)
        XCTAssertEqual(tiny.ecologyPlan.limit, .epochs(1))
    }

    /// Nonempty explicit invocations without --ecology keep their existing
    /// (non-resident) routing — the ecology route is opt-in only.
    func testNonEcologyInvocationsDoNotRouteToEcology() throws {
        for args in [["--programs", "8"], ["--seed", "1"], ["--resident"], ["--help"]] {
            let parsed = try AppLaunchOptions.parse(args)
            XCTAssertNotEqual(parsed.simulationMode, .ecology,
                              "invocation \(args) must not route to ecology")
            XCTAssertFalse(parsed.ecologyPlan.enabled,
                           "invocation \(args) must not enable the ecology plan")
        }
    }

    // MARK: Fixed topology routing — --ecology rejects an explicit --programs

    /// The ecology topology is fixed by contract (512×256 = 131,072 sites),
    /// so `--ecology` combined with an explicit `--programs` is a parse error
    /// (never silently ignored, never silently honored) — no false HUD/config
    /// state is emitted.
    func testEcologyWithExplicitProgramsIsRejected() {
        for count in [4096, 64, 131_072, 262_144] {
            XCTAssertThrowsError(
                try AppLaunchOptions.parse(["--ecology", "--programs", "\(count)"])
            ) { error in
                guard case AppLaunchOptions.ParseError.ecologyTopologyNotConfigurable(
                        explicitProgramCount: let n) = error,
                      n == count else {
                    return XCTFail(
                        "expected ecologyTopologyNotConfigurable(\(count)), got \(error)")
                }
            }
        }
    }

    /// `--programs` may appear before or after `--ecology`; the rejection is
    /// order-independent (the parse gate fires after the whole list is consumed).
    func testEcologyProgramsRejectionIsOrderIndependent() {
        XCTAssertThrowsError(
            try AppLaunchOptions.parse(["--programs", "2048", "--ecology"])
        ) { error in
            guard case AppLaunchOptions.ParseError.ecologyTopologyNotConfigurable(
                    explicitProgramCount: 2048) = error else {
                return XCTFail("expected ecologyTopologyNotConfigurable, got \(error)")
            }
        }
    }

    /// Without an explicit `--programs`, the ecology route keeps the fixed app
    /// grid/HUD at 131,072 = EcologyTopology.siteCount = ProgramGrid.capacity.
    func testEcologyWithoutExplicitProgramsKeepsFixed131072Topology() throws {
        let opts = try AppLaunchOptions.parse(["--ecology"])
        XCTAssertEqual(opts.programCount, ProgramGrid.capacity)
        XCTAssertEqual(opts.programCount, 131_072)
        XCTAssertEqual(EcologyAppRunPlan.siteCount, 131_072)
        // The fixed topology matches the canonical canvas capacity, so the
        // grid/HUD is exactly 131072 with no false config state.
        XCTAssertEqual(EcologyAppRunPlan.siteCount, opts.programCount)
    }

    /// The fixed-topology gate is specific to the combination: a bare
    /// `--programs` (no --ecology) still parses and forwards its count, and a
    /// bare `--ecology` (no --programs) still routes to ecology.
    func testProgramsAloneAndEcologyAloneBothParse() throws {
        let p = try AppLaunchOptions.parse(["--programs", "8192"])
        XCTAssertEqual(p.programCount, 8192)
        XCTAssertNotEqual(p.simulationMode, .ecology)

        let e = try AppLaunchOptions.parse(["--ecology"])
        XCTAssertEqual(e.simulationMode, .ecology)
        XCTAssertEqual(e.programCount, ProgramGrid.capacity)
    }

    /// The immutable EcologyMetalEpochConfig is reconstructable from the
    /// parsed launch options (the input to deterministic Reset).
    func testEcologyConfigReconstructableFromLaunchOptions() throws {
        let opts = try AppLaunchOptions.parse([
            "--ecology", "--seed", "7", "--budget", "1024", "--mutation-p32", "5",
        ])
        let config = try opts.ecologyConfig()
        XCTAssertEqual(config.seed, 7)
        XCTAssertEqual(config.stepBudget, 1024)
        XCTAssertEqual(config.mutationP32, 5)
        XCTAssertEqual(config.variant, .noheads)
        XCTAssertEqual(config.bracketMode, .dynamicScan)
        // The config's topology/scheduler/rng contract IDs match the ecology v1
        // contract (sourced from EcologyConfig — no duplication).
        XCTAssertEqual(config.topologyID, EcologyConfig.topologyID)
        XCTAssertEqual(config.schedulerID, EcologyConfig.schedulerID)
        XCTAssertEqual(config.rngContractID, EcologyConfig.rngContractID)
    }
}
