import XCTest
import BFFOracle
@testable import BFFMetal

/// Platform-independent tests for the metal-slice soup evolution: config
/// validation, epoch planning/scatter, counter/metric reduction, shadow sampling
/// and comparison, and deterministic replay. These run everywhere (Linux CI
/// included); they inject `CPUPairEvaluator` so a full "epoch" is an honest CPU
/// computation, never a faked GPU run. Actual-GPU coverage lives in
/// `MetalSoupEpochTests` (macOS only).
final class SoupSliceTests: XCTestCase {

    private func config(seed: UInt32 = 42, programs: Int = 16,
                        mutationP32: UInt32 = BFF.defaultMutationP32,
                        budget: Int = 512, shadow: Int? = nil,
                        variant: BFFVariant = .noheads) throws -> SoupConfig {
        try SoupConfig(seed: seed, programCount: programs, stepBudget: budget,
                       mutationP32: mutationP32, variant: variant, shadowSampleCount: shadow)
    }

    // MARK: - Initialization

    func testSeededInitializationMatchesCounterPCG() throws {
        let runner = SoupRunner(config: try config(seed: 7, programs: 8))
        XCTAssertEqual(runner.soup, BFFRandom.initialSoup(programs: 8, seed: 7))
        XCTAssertEqual(runner.epoch, 0)
        XCTAssertEqual(runner.program(at: 3), Array(runner.soup[3 * 64 ..< 4 * 64]))
    }

    // MARK: - Pairing permutation and stable-ID scatter

    func testLiteralPairingPermutationAndPairs() throws {
        // Golden Fisher–Yates vector for count=8, seed=11, epoch=2 (pinned in
        // BFFOracle's RandomTests): [1,0,7,2,4,5,6,3].
        let cfg = try SoupConfig(seed: 11, programCount: 8, stepBudget: 256,
                                 mutationP32: 0, shadowSampleCount: 0)
        let soup = BFFRandom.initialSoup(programs: 8, seed: 11)
        let (_, plan) = SoupPlanner.plan(soup: soup, config: cfg, epoch: 2)
        XCTAssertEqual(plan.permutation, [1, 0, 7, 2, 4, 5, 6, 3])
        XCTAssertEqual(plan.pairs, [
            PairIdentity(a: 1, b: 0), PairIdentity(a: 7, b: 2),
            PairIdentity(a: 4, b: 5), PairIdentity(a: 6, b: 3),
        ])
        // With mutation disabled, each packed tape is exactly the two programs.
        for (p, pair) in plan.pairs.enumerated() {
            let a = Array(soup[Int(pair.a) * 64 ..< (Int(pair.a) + 1) * 64])
            let b = Array(soup[Int(pair.b) * 64 ..< (Int(pair.b) + 1) * 64])
            XCTAssertEqual(plan.inputTapes[p], a + b)
        }
    }

    func testScatterReturnsHalvesToStableProgramIdentities() throws {
        let cfg = try SoupConfig(seed: 11, programCount: 8, stepBudget: 256,
                                 mutationP32: 0, shadowSampleCount: 0)
        let soup = BFFRandom.initialSoup(programs: 8, seed: 11)
        let (mutated, plan) = SoupPlanner.plan(soup: soup, config: cfg, epoch: 2)

        // Synthetic finals: half A all 0xAA, half B all 0xBB — distinguishable.
        let finals = plan.pairs.map { _ in
            [UInt8](repeating: 0xAA, count: 64) + [UInt8](repeating: 0xBB, count: 64)
        }
        var out = mutated
        SoupPlanner.scatter(into: &out, plan: plan, finalTapes: finals)

        for pair in plan.pairs {
            let a = Array(out[Int(pair.a) * 64 ..< (Int(pair.a) + 1) * 64])
            let b = Array(out[Int(pair.b) * 64 ..< (Int(pair.b) + 1) * 64])
            XCTAssertEqual(a, [UInt8](repeating: 0xAA, count: 64),
                           "program \(pair.a) is the A half of its pair")
            XCTAssertEqual(b, [UInt8](repeating: 0xBB, count: 64),
                           "program \(pair.b) is the B half of its pair")
        }
    }

    // MARK: - Mutation boundaries

    func testZeroMutationCountAndUntouchedSoup() throws {
        let cfg = try config(mutationP32: 0)
        let soup = BFFRandom.initialSoup(programs: 16, seed: 42)
        let (mutated, plan) = SoupPlanner.plan(soup: soup, config: cfg, epoch: 1)
        XCTAssertEqual(plan.mutationCount, 0)
        XCTAssertEqual(mutated, soup)
    }

    func testForcedMutationCountMatchesIndependentPredicate() throws {
        // Recompute the fired-predicate count independently from the public RNG
        // primitives to pin both determinism and the exact definition.
        let seed: UInt32 = 42, epoch: UInt32 = 1
        let p32: UInt32 = 1 << 31 // ~half the bytes fire
        let cfg = try config(mutationP32: p32)
        let soup = BFFRandom.initialSoup(programs: 16, seed: seed)
        let (_, plan) = SoupPlanner.plan(soup: soup, config: cfg, epoch: Int(epoch))

        let stream = BFFRandom.stream(epoch: epoch, pass: .mutate)
        let expected = (0 ..< soup.count).reduce(into: 0) { acc, i in
            if BFFRandom.rng3(seed: seed, stream: stream, index: UInt32(i)) < p32 { acc += 1 }
        }
        XCTAssertEqual(plan.mutationCount, expected)
        XCTAssertGreaterThan(plan.mutationCount, 0)
        XCTAssertLessThan(plan.mutationCount, soup.count)
    }

    // MARK: - Deterministic replay / seed divergence

    func testDeterministicReplayIsBitIdentical() throws {
        let cpu = CPUPairEvaluator()
        var a = SoupRunner(config: try config(shadow: 4))
        var b = SoupRunner(config: try config(shadow: 4))
        let ra = try a.run(epochs: 5, using: cpu)
        let rb = try b.run(epochs: 5, using: cpu)
        XCTAssertEqual(a.soup, b.soup)
        XCTAssertEqual(a.digest, b.digest)
        for (x, y) in zip(ra, rb) {
            XCTAssertEqual(x.counters, y.counters)
            XCTAssertEqual(x.metrics, y.metrics)
            XCTAssertEqual(x.digest, y.digest)
            XCTAssertEqual(x.shadowChecked, y.shadowChecked)
            XCTAssertEqual(x.shadowMismatches, y.shadowMismatches)
        }
    }

    func testDifferentSeedChangesTrajectory() throws {
        let cpu = CPUPairEvaluator()
        var a = SoupRunner(config: try config(seed: 1))
        var b = SoupRunner(config: try config(seed: 2))
        XCTAssertNotEqual(a.digest, b.digest, "initial soups differ by seed")
        try a.run(epochs: 3, using: cpu)
        try b.run(epochs: 3, using: cpu)
        XCTAssertNotEqual(a.digest, b.digest)
    }

    // MARK: - Config validation

    func testConfigRejectsInvalidSettings() {
        XCTAssertThrowsError(try SoupConfig(seed: 0, programCount: 15)) // odd
        XCTAssertThrowsError(try SoupConfig(seed: 0, programCount: 0))  // zero
        XCTAssertThrowsError(try SoupConfig(seed: 0, programCount: 8, stepBudget: 0))
        XCTAssertThrowsError(try SoupConfig(seed: 0, programCount: 8,
                                            stepBudget: Int(UInt32.max) + 1))
        XCTAssertThrowsError(try SoupConfig(seed: 0, programCount: 8, shadowSampleCount: -1))
        XCTAssertThrowsError(try SoupConfig(seed: 0, programCount: 8, shadowSampleCount: 5))
        // Valid boundaries: full shadow, zero shadow, zero mutation, max budget.
        XCTAssertNoThrow(try SoupConfig(seed: 0, programCount: 8, shadowSampleCount: 4))
        XCTAssertNoThrow(try SoupConfig(seed: 0, programCount: 8, shadowSampleCount: 0))
        XCTAssertNoThrow(try SoupConfig(seed: 0, programCount: 8, mutationP32: 0))
        XCTAssertNoThrow(try SoupConfig(seed: 0, programCount: 8,
                                        stepBudget: Int(UInt32.max)))
    }

    // MARK: - Counters and halt histogram

    func testEpochCountersAggregateAndHaltHistogramSumsToPairs() throws {
        var runner = SoupRunner(config: try config())
        let report = try runner.runEpoch(using: CPUPairEvaluator())
        let c = report.counters
        XCTAssertEqual(c.interactions, 8)
        XCTAssertEqual(c.haltBudget + c.haltPCOut + c.haltUnmatched, 8,
                       "every interaction halts with exactly one reason")
        // The normative CPU evaluator never emits an out-of-contract halt code, so
        // the unknown bucket is empty and the full four-bucket invariant reduces to
        // the three-bucket one here.
        XCTAssertEqual(c.haltUnknown, 0)
        XCTAssertEqual(c.haltAccounted, c.interactions,
                       "known + unknown halt counts equal interactions")
        XCTAssertEqual(c.totalCommandSteps, c.totalRawSteps - c.totalNoopSteps)
        XCTAssertGreaterThan(c.totalRawSteps, 0)
    }

    // MARK: - Unknown halt codes are surfaced globally

    /// A `PairEvaluator` that returns structurally valid outcomes but stamps a
    /// chosen out-of-contract raw halt code on every interaction. It echoes each
    /// input tape unchanged so scatter stays well-formed; only the halt byte is
    /// off-contract. This models an evaluator emitting a halt code the host does
    /// not recognize, without touching the real GPU/shared ABI.
    private struct UnknownHaltEvaluator: PairEvaluator {
        let haltCode: UInt32
        func evaluate(pairTapes: [[UInt8]], variant: BFFVariant,
                      stepBudget: Int) -> [GPUPairOutcome] {
            pairTapes.map { tape in
                GPUPairOutcome(finalTape: tape, steps: 1, noopSteps: 0,
                               copyWrites: 0, loopOps: 0, halt: haltCode)
            }
        }
    }

    func testUnknownHaltCodesAreCountedInReductionAndInvariantHolds() {
        let tape = [UInt8](repeating: 0, count: BFF.pairTapeSize)
        func outcome(_ halt: UInt32) -> GPUPairOutcome {
            GPUPairOutcome(finalTape: tape, steps: 1, noopSteps: 0,
                           copyWrites: 0, loopOps: 0, halt: halt)
        }
        // Two known reasons and two DISTINCT out-of-contract codes: 0 (the reserved
        // "never used" value) and 99 (arbitrary garbage). Both must land in unknown.
        let outcomes = [
            outcome(UInt32(HaltReason.budget.rawValue)),
            outcome(UInt32(HaltReason.unmatched.rawValue)),
            outcome(0),
            outcome(99),
        ]
        let c = EpochCounters.reduce(epoch: 5, mutationCount: 0, outcomes: outcomes)
        XCTAssertEqual(c.haltBudget, 1)
        XCTAssertEqual(c.haltPCOut, 0)
        XCTAssertEqual(c.haltUnmatched, 1)
        XCTAssertEqual(c.haltUnknown, 2, "codes 0 and 99 are both out-of-contract")
        XCTAssertEqual(c.haltAccounted, 4)
        XCTAssertEqual(c.haltAccounted, c.interactions,
                       "known + unknown halt counts equal interactions")
    }

    /// The whole point of the global bucket: unknown halt codes are counted even
    /// when CPU-shadow sampling is disabled, so the divergence is never invisible.
    func testUnknownHaltCountedGloballyEvenWithShadowDisabled() throws {
        let cfg = try config(shadow: 0) // shadow sampling explicitly off
        var runner = SoupRunner(config: cfg)
        // Every interaction gets halt code 0, which is out-of-contract.
        let report = try runner.runEpoch(using: UnknownHaltEvaluator(haltCode: 0))
        XCTAssertEqual(report.shadowChecked, 0, "no pair was shadow-checked")
        XCTAssertEqual(report.shadowMismatches, [], "the shadow saw nothing")
        let c = report.counters
        XCTAssertEqual(c.interactions, 8)
        XCTAssertEqual(c.haltBudget, 0)
        XCTAssertEqual(c.haltPCOut, 0)
        XCTAssertEqual(c.haltUnmatched, 0)
        XCTAssertEqual(c.haltUnknown, 8,
                       "all interactions counted as unknown despite no shadowing")
        XCTAssertEqual(c.haltAccounted, c.interactions)
    }

    func testCounterReductionOverSyntheticOutcomes() {
        let tape = [UInt8](repeating: 0, count: BFF.pairTapeSize)
        let outcomes = [
            GPUPairOutcome(finalTape: tape, steps: 10, noopSteps: 3, copyWrites: 1,
                           loopOps: 2, halt: UInt32(HaltReason.budget.rawValue)),
            GPUPairOutcome(finalTape: tape, steps: 5, noopSteps: 5, copyWrites: 0,
                           loopOps: 0, halt: UInt32(HaltReason.pcOut.rawValue)),
            GPUPairOutcome(finalTape: tape, steps: 7, noopSteps: 1, copyWrites: 4,
                           loopOps: 3, halt: UInt32(HaltReason.unmatched.rawValue)),
        ]
        let c = EpochCounters.reduce(epoch: 2, mutationCount: 9, outcomes: outcomes)
        XCTAssertEqual(c.epoch, 2)
        XCTAssertEqual(c.mutationCount, 9)
        XCTAssertEqual(c.interactions, 3)
        XCTAssertEqual(c.totalRawSteps, 22)
        XCTAssertEqual(c.totalNoopSteps, 9)
        XCTAssertEqual(c.totalCommandSteps, 13)
        XCTAssertEqual(c.totalLoopOps, 5)
        XCTAssertEqual(c.totalCopyWrites, 5)
        XCTAssertEqual(c.haltBudget, 1)
        XCTAssertEqual(c.haltPCOut, 1)
        XCTAssertEqual(c.haltUnmatched, 1)
    }

    // MARK: - Entropy definition

    func testEntropyOfRepeatedByteIsZero() {
        let prog = [UInt8](repeating: 0x41, count: 64)
        XCTAssertEqual(SoupMetrics.entropyBitsPerByte(prog), 0.0, accuracy: 1e-12)
    }

    func testEntropyOf64DistinctBytesIsSixBits() {
        let prog = (0 ..< 64).map { UInt8($0) }
        XCTAssertEqual(SoupMetrics.entropyBitsPerByte(prog), 6.0, accuracy: 1e-12)
    }

    // MARK: - Activity attribution

    func testActivityIsCommandStepsAttributedToBothPartners() throws {
        let cfg = try config()
        var runner = SoupRunner(config: cfg)
        // Re-derive the plan/outcomes exactly as runEpoch does for epoch 0.
        let (mutated, plan) = SoupPlanner.plan(soup: runner.soup, config: cfg, epoch: 0)
        let outcomes = CPUPairEvaluator().evaluate(pairTapes: plan.inputTapes,
                                                   variant: cfg.variant,
                                                   stepBudget: cfg.stepBudget)
        var newSoup = mutated
        SoupPlanner.scatter(into: &newSoup, plan: plan,
                            finalTapes: outcomes.map(\.finalTape))
        let metrics = SoupMetrics.programMetrics(soup: newSoup, plan: plan,
                                                 outcomes: outcomes,
                                                 programCount: cfg.programCount)
        for (p, pair) in plan.pairs.enumerated() {
            let expected = outcomes[p].commandSteps
            XCTAssertEqual(metrics[Int(pair.a)].activity, expected)
            XCTAssertEqual(metrics[Int(pair.b)].activity, expected,
                           "both partners share the pair-level activity")
        }
        // Sanity: runEpoch produces the same metrics.
        let report = try runner.runEpoch(using: CPUPairEvaluator())
        XCTAssertEqual(report.metrics, metrics)
    }

    // MARK: - Shadow sampling

    func testShadowSampleIsDeterministicWithoutDuplicates() {
        let a = ShadowSampler.sampleIndices(pairCount: 64, sampleCount: 10, seed: 3, epoch: 1)
        let b = ShadowSampler.sampleIndices(pairCount: 64, sampleCount: 10, seed: 3, epoch: 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 10)
        XCTAssertEqual(Set(a).count, 10, "no duplicates")
        XCTAssertEqual(a, a.sorted())
        XCTAssertTrue(a.allSatisfy { $0 >= 0 && $0 < 64 })
    }

    func testShadowSampleBoundariesAndDomainSeparation() {
        // Zero disables.
        XCTAssertEqual(ShadowSampler.sampleIndices(pairCount: 8, sampleCount: 0,
                                                   seed: 1, epoch: 0), [])
        // Full sample covers every pair.
        XCTAssertEqual(ShadowSampler.sampleIndices(pairCount: 8, sampleCount: 8,
                                                   seed: 1, epoch: 0), Array(0 ..< 8))
        // Different epochs (typically) select differently — proves epoch feeds it.
        let e0 = ShadowSampler.sampleIndices(pairCount: 128, sampleCount: 8, seed: 1, epoch: 0)
        let e1 = ShadowSampler.sampleIndices(pairCount: 128, sampleCount: 8, seed: 1, epoch: 1)
        XCTAssertNotEqual(e0, e1)
    }

    func testZeroShadowSampleDisablesComparison() throws {
        var runner = SoupRunner(config: try config(shadow: 0))
        let report = try runner.runEpoch(using: CPUPairEvaluator())
        XCTAssertEqual(report.shadowChecked, 0)
        XCTAssertEqual(report.shadowMismatches, [])
    }

    // MARK: - Shadow comparator

    private func matchingOutcome(for input: [UInt8], variant: BFFVariant,
                                 budget: Int) -> GPUPairOutcome {
        let r = BFFInterpreter.run(pairTape: input, variant: variant,
                                   bracketMode: .dynamicScan, stepBudget: budget)
        return GPUPairOutcome(finalTape: r.tape, steps: UInt32(r.steps),
                              noopSteps: UInt32(r.noopSteps), copyWrites: UInt32(r.copyWrites),
                              loopOps: UInt32(r.loopOps), halt: UInt32(r.halt.rawValue))
    }

    private func sampleInput() -> [UInt8] {
        var tape = [UInt8](repeating: 0, count: BFF.pairTapeSize)
        tape[0] = BFFOp.head0Right
        tape[1] = BFFOp.inc
        tape[2] = BFFOp.inc
        tape[3] = BFFOp.loopOpen
        tape[4] = BFFOp.dec
        tape[5] = BFFOp.loopClose
        return tape
    }

    func testShadowComparatorPassesOnMatchingOutcome() {
        let input = sampleInput()
        let gpu = matchingOutcome(for: input, variant: .noheads, budget: 8192)
        XCTAssertNil(ShadowComparator.check(epoch: 0, pairIndex: 2, programA: 5, programB: 9,
                                            input: input, variant: .noheads,
                                            stepBudget: 8192, gpu: gpu))
    }

    func testShadowComparatorDiagnosesTapeMismatchWithFirstByteAndIdentity() {
        let input = sampleInput()
        var gpu = matchingOutcome(for: input, variant: .noheads, budget: 8192)
        gpu.finalTape[7] ^= 0xFF
        let mm = ShadowComparator.check(epoch: 3, pairIndex: 4, programA: 11, programB: 2,
                                        input: input, variant: .noheads,
                                        stepBudget: 8192, gpu: gpu)
        let m = try! XCTUnwrap(mm)
        XCTAssertEqual(m.epoch, 3)
        XCTAssertEqual(m.pairIndex, 4)
        XCTAssertEqual(m.programA, 11)
        XCTAssertEqual(m.programB, 2)
        XCTAssertEqual(m.firstTapeDivergence, 7)
        XCTAssertTrue(m.lines.contains { $0.contains("byte 7") })
    }

    func testShadowComparatorDiagnosesCounterAndHaltMismatches() {
        let input = sampleInput()
        var gpu = matchingOutcome(for: input, variant: .noheads, budget: 8192)
        let realHalt = gpu.halt
        gpu.steps &+= 1
        gpu.loopOps &+= 3
        // Force a halt code that differs from whatever the oracle actually produced.
        gpu.halt = realHalt == UInt32(HaltReason.budget.rawValue)
            ? UInt32(HaltReason.pcOut.rawValue)
            : UInt32(HaltReason.budget.rawValue)
        let m = try! XCTUnwrap(ShadowComparator.check(epoch: 1, pairIndex: 0,
                                                      programA: 0, programB: 1,
                                                      input: input, variant: .noheads,
                                                      stepBudget: 8192, gpu: gpu))
        XCTAssertNil(m.firstTapeDivergence, "tape still matches")
        XCTAssertTrue(m.lines.contains { $0.contains("steps diverge") })
        XCTAssertTrue(m.lines.contains { $0.contains("loopOps diverge") })
        XCTAssertTrue(m.lines.contains { $0.contains("halt reason diverges") })
    }

    // MARK: - Digest

    func testDigestIsStableAndSeedSensitive() {
        let s1 = BFFRandom.initialSoup(programs: 8, seed: 1)
        let s1b = BFFRandom.initialSoup(programs: 8, seed: 1)
        let s2 = BFFRandom.initialSoup(programs: 8, seed: 2)
        XCTAssertEqual(SoupDigest.digest(s1), SoupDigest.digest(s1b))
        XCTAssertNotEqual(SoupDigest.digest(s1), SoupDigest.digest(s2))
        XCTAssertEqual(SoupDigest.hexString(s1).count, 16)
    }
}

/// Guards the additive `@discardableResult` mutation-count return added to
/// `BFFRandom.mutate` — it must equal the number of fired predicates and preserve
/// the existing in-place mutation behavior bit-for-bit.
final class MutationCountTests: XCTestCase {
    func testMutationCountEqualsFiredPredicateCount() {
        let seed: UInt32 = 5, epoch: UInt32 = 3
        let p32: UInt32 = 1 << 28
        var soup = BFFRandom.initialSoup(programs: 8, seed: 1)
        let before = soup
        let count = BFFRandom.mutate(soup: &soup, seed: seed, epoch: epoch, mutationP32: p32)

        let stream = BFFRandom.stream(epoch: epoch, pass: .mutate)
        let expected = (0 ..< before.count).reduce(into: 0) { acc, i in
            if BFFRandom.rng3(seed: seed, stream: stream, index: UInt32(i)) < p32 { acc += 1 }
        }
        XCTAssertEqual(count, expected)
        XCTAssertGreaterThan(count, 0)
    }

    func testZeroProbabilityCountsZeroAndLeavesSoupUntouched() {
        var soup = BFFRandom.initialSoup(programs: 4, seed: 2)
        let before = soup
        let count = BFFRandom.mutate(soup: &soup, seed: 9, epoch: 0, mutationP32: 0)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(soup, before)
    }
}
