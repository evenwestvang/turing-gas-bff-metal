import XCTest
import BFFOracle
@testable import BFFMetal

/// Direct cross-implementation equivalence: the metal-slice CPU epoch path
/// (`SoupRunner` + `CPUPairEvaluator`) against the legacy scalar
/// `BFFOracle.Simulation`.
///
/// These are two independently written orchestrations. They share only the RNG
/// (`BFFRandom`) and the interpreter (`BFFInterpreter`); they keep separate config
/// and counter types, and even scatter results differently — `Simulation` writes
/// each pair's halves back in place as it iterates, while `SoupRunner` packs from a
/// mutated copy and scatters into a fresh soup. If either had silently forked the
/// evolution semantics (a different mutation order, a different pairing, a stale
/// read), the soups would diverge. Holding them byte-identical after every epoch —
/// under real mutation and pairing, not a zero-mutation trivial path — plus
/// matching every counter the two designs have in common, pins that they are the
/// same walk computed two ways.
///
/// The only intentionally NON-common observables are:
///   * `EpochStats.totalRemapEvents` — `Simulation`-only D1 instrumentation. In
///     `.dynamicScan` (the only semantics the slice implements) a remap is counted
///     but never alters execution, so it must not perturb the soup; the test proves
///     that by requiring identical soups even across epochs where remaps occur.
///   * `EpochCounters.haltUnknown` / `noopSteps` / `commandSteps` — slice-only
///     accounting the oracle does not compute. `haltUnknown` is normatively zero
///     here and is asserted so.
final class SliceOracleEquivalenceTests: XCTestCase {

    // Shared deterministic, bounded parameters. `mutationP32 = 1 << 24` (≈1/256 per
    // byte) guarantees several real mutations every epoch on a 32×64 = 2048-byte
    // soup, so mutation is genuinely exercised, not disabled.
    private let seed: UInt32 = 1234
    private let programs = 32
    private let budget = 8192
    private let mutationP32: UInt32 = 1 << 24
    private let variant: BFFVariant = .noheads
    private let epochs = 8

    private func makeSoupConfig() throws -> SoupConfig {
        // Shadow disabled: the shadow is the slice re-running the CPU against
        // itself, which would trivially match and is irrelevant to this oracle
        // comparison. The CPU evaluator always runs `.dynamicScan`.
        try SoupConfig(seed: seed, programCount: programs, stepBudget: budget,
                       mutationP32: mutationP32, variant: variant, shadowSampleCount: 0)
    }

    private func makeSimConfig() -> SimulationConfig {
        // Same seed/size/budget/mutation/variant, with the matching bracket mode.
        SimulationConfig(seed: seed, populationSize: programs, stepBudget: budget,
                         mutationP32: mutationP32, variant: variant,
                         bracketMode: .dynamicScan)
    }

    func testSliceMatchesOracleEpochByEpoch() throws {
        var runner = SoupRunner(config: try makeSoupConfig())
        var sim = Simulation(config: makeSimConfig())

        // Sanity: identical starting soup and size before any epoch runs.
        XCTAssertEqual(runner.soup, sim.soup, "seeded initial soups must match")
        XCTAssertEqual(runner.soup.count, programs * BFF.tapeSize)

        let cpu = CPUPairEvaluator()

        var totalMutations = 0
        var totalRawSteps = 0
        var totalCommandSteps = 0
        var totalRemapEvents = 0
        var sawRemap = false

        for e in 0 ..< epochs {
            let report = try runner.runEpoch(using: cpu)
            let stats = sim.runEpoch()

            // Full soup bytes agree after every epoch — the authoritative check.
            XCTAssertEqual(runner.soup, sim.soup, "soup diverged at epoch \(e)")
            // Digest is a pure function of the soup; assert it too as a cheap,
            // location-independent fingerprint of that agreement.
            XCTAssertEqual(runner.digest, SoupDigest.digest(sim.soup),
                           "digest diverged at epoch \(e)")

            // Every counter the two designs have in common.
            let c = report.counters
            XCTAssertEqual(c.epoch, stats.epoch, "epoch \(e)")
            XCTAssertEqual(c.interactions, stats.interactions, "epoch \(e)")
            XCTAssertEqual(c.totalRawSteps, stats.totalSteps,
                           "raw step total (slice) vs totalSteps (oracle), epoch \(e)")
            XCTAssertEqual(c.haltBudget, stats.haltBudget, "epoch \(e)")
            XCTAssertEqual(c.haltPCOut, stats.haltPCOut, "epoch \(e)")
            XCTAssertEqual(c.haltUnmatched, stats.haltUnmatched, "epoch \(e)")
            XCTAssertEqual(c.totalCopyWrites, stats.totalCopyWrites, "epoch \(e)")
            XCTAssertEqual(c.totalLoopOps, stats.totalLoopOps, "epoch \(e)")
            // Oracle's derived mean is exactly the shared raw-step total / interactions.
            XCTAssertEqual(stats.meanSteps,
                           Double(c.totalRawSteps) / Double(c.interactions),
                           accuracy: 1e-9, "epoch \(e)")

            // Slice-only bucket: normatively zero for the real CPU evaluator, and
            // the four-bucket invariant still closes.
            XCTAssertEqual(c.haltUnknown, 0, "epoch \(e)")
            XCTAssertEqual(c.haltAccounted, c.interactions, "epoch \(e)")

            totalMutations += c.mutationCount
            totalRawSteps += c.totalRawSteps
            totalCommandSteps += c.totalCommandSteps
            totalRemapEvents += stats.totalRemapEvents
            if stats.totalRemapEvents > 0 { sawRemap = true }
        }

        // Mutation and pairing were genuinely exercised (not a trivial path).
        XCTAssertGreaterThan(totalMutations, 0, "mutation must have fired")
        XCTAssertGreaterThan(totalCommandSteps, 0, "programs must have executed ops")

        // The remap-instrumentation path was actually crossed: at least one taken
        // bracket's live-scan match differed from the frozen table during these
        // epochs. That is `Simulation`-only bookkeeping and does NOT change
        // `.dynamicScan` execution — proven by the byte-identical soups above even
        // though a remap occurred. Pinned so this coverage cannot silently vanish.
        XCTAssertTrue(sawRemap, "expected the remap-event path to be exercised")
        XCTAssertEqual(totalRemapEvents, 1, "golden remap-event total (oracle-only)")

        // Golden evidence. These literals were captured from the shared
        // RNG+interpreter substrate; they make this a regression anchor, not merely
        // two calls to the same orchestration agreeing with each other. A change to
        // `BFFRandom`, `BFFInterpreter`, or either orchestration would move them.
        XCTAssertEqual(SoupDigest.hexString(runner.digest), "0e5d7f125243d332",
                       "golden final soup digest after \(epochs) epochs")
        XCTAssertEqual(totalMutations, 65, "golden fired-mutation total")
        XCTAssertEqual(totalRawSteps, 24937, "golden raw-step total")
        XCTAssertEqual(totalCommandSteps, 1044, "golden command-step total")
    }
}
