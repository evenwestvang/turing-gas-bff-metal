import XCTest
import BFFOracle
@testable import BFFMetal

/// Pins the epoch ordering contract the benchmark relies on and documents
/// (blocker 7): each epoch mutates the soup BEFORE pairing/packing/evaluation, using
/// the fixed `counter-pcg-v1` streams (mutate = `epoch*4+0`, pairing = `epoch*4+1`).
final class EpochOrderingTests: XCTestCase {

    func testMutationHappensBeforePairingAndPacking() throws {
        // Force every byte's mutation predicate to fire so mutation is unmissable.
        let config = try SoupConfig(seed: 777, programCount: 8,
                                    mutationP32: .max, initMode: .opcode)
        let runner = SoupRunner(config: config)
        let original = runner.soup

        let epoch = 3
        let (mutatedSoup, plan) = SoupPlanner.plan(soup: original, config: config,
                                                   epoch: epoch)

        // 1. Mutation ran and matches the standalone mutate routine on the mutate
        //    stream `epoch*4+0`, computed independently (deterministic, exact).
        var expectedMutated = original
        let firedCount = BFFRandom.mutate(soup: &expectedMutated, seed: config.seed,
                                          epoch: UInt32(epoch), mutationP32: .max)
        XCTAssertEqual(mutatedSoup, expectedMutated)
        XCTAssertEqual(plan.mutationCount, firedCount)
        XCTAssertNotEqual(mutatedSoup, original, "the soup was actually mutated")

        // 2. Pairing uses the pairing stream `epoch*4+1`, independent of mutation.
        let expectedPerm = BFFRandom.pairingPermutation(count: config.programCount,
                                                        seed: config.seed,
                                                        epoch: UInt32(epoch))
        XCTAssertEqual(plan.permutation, expectedPerm)

        // 3. The tapes fed to evaluation are packed from the MUTATED soup, not the
        //    original — the concrete proof that mutation precedes pairing/packing.
        //    (If packing preceded mutation, these would equal the pre-mutation slices,
        //    which differ since `mutatedSoup != original`.)
        for (p, pair) in plan.pairs.enumerated() {
            let ra = Int(pair.a) * BFF.tapeSize
            let rb = Int(pair.b) * BFF.tapeSize
            let expectedTape = Array(mutatedSoup[ra ..< ra + BFF.tapeSize])
                + Array(mutatedSoup[rb ..< rb + BFF.tapeSize])
            XCTAssertEqual(plan.inputTapes[p], expectedTape,
                           "pair \(p) tape must come from the post-mutation soup")
        }
    }
}
