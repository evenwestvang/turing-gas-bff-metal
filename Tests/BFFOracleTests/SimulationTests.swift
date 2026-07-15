import XCTest
@testable import BFFOracle

final class RandomTests: XCTestCase {

    func testPcgHashIsDeterministicAndMixes() {
        XCTAssertEqual(BFFRandom.pcgHash(0), BFFRandom.pcgHash(0))
        XCTAssertEqual(BFFRandom.pcgHash(12345), BFFRandom.pcgHash(12345))
        XCTAssertNotEqual(BFFRandom.pcgHash(0), BFFRandom.pcgHash(1))
        // Verbatim re-derivation of the 02 §4 formula, guarding the constants.
        func reference(_ input: UInt32) -> UInt32 {
            let x = input &* 747796405 &+ 2891336453
            let w = ((x >> ((x >> 28) &+ 4)) ^ x) &* 277803737
            return (w >> 22) ^ w
        }
        for v: UInt32 in [0, 1, 0xDEADBEEF, .max] {
            XCTAssertEqual(BFFRandom.pcgHash(v), reference(v))
        }
    }

    func testRng3StreamAndIndexSeparation() {
        let a = BFFRandom.rng3(seed: 7, stream: 0, index: 0)
        XCTAssertEqual(a, BFFRandom.rng3(seed: 7, stream: 0, index: 0))
        XCTAssertNotEqual(a, BFFRandom.rng3(seed: 7, stream: 1, index: 0))
        XCTAssertNotEqual(a, BFFRandom.rng3(seed: 7, stream: 0, index: 1))
        XCTAssertNotEqual(a, BFFRandom.rng3(seed: 8, stream: 0, index: 0))
    }

    // Literal golden contract for `counter-pcg-v1`: these values were computed once
    // from the documented PCG algorithm (02 §4) via an independent reimplementation
    // and are hard-coded here on purpose. If any of them changes, the RNG contract
    // is broken — every existing fixture is invalidated and `BFFRandom.contractID`
    // must be bumped.
    func testRng3GoldenValues() {
        XCTAssertEqual(BFFRandom.rng3(seed: 0, stream: 0, index: 0), 0x30BE_035E)
        XCTAssertEqual(BFFRandom.rng3(seed: 1, stream: 0, index: 0), 0xE92A_518A)
        XCTAssertEqual(BFFRandom.rng3(seed: 0xDEAD_BEEF, stream: 5, index: 12345), 0x2111_A1D3)
        XCTAssertEqual(BFFRandom.rng3(seed: 42, stream: 9, index: 0xFFFF_FFFF), 0xACCE_0DE5)
    }

    func testSoupInitIsDeterministic() {
        let a = BFFRandom.initialSoup(programs: 4, seed: 99)
        let b = BFFRandom.initialSoup(programs: 4, seed: 99)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 4 * BFF.tapeSize)
        XCTAssertNotEqual(a, BFFRandom.initialSoup(programs: 4, seed: 100))
    }

    func testMutationIsDeterministic() {
        let original = BFFRandom.initialSoup(programs: 8, seed: 1)
        var a = original
        var b = original
        // 1<<28 ≈ 1/16 per byte: dense enough to certainly mutate something in 512 bytes.
        BFFRandom.mutate(soup: &a, seed: 5, epoch: 3, mutationP32: 1 << 28)
        BFFRandom.mutate(soup: &b, seed: 5, epoch: 3, mutationP32: 1 << 28)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, original, "some byte must have mutated at p ≈ 1/16")

        var c = original
        BFFRandom.mutate(soup: &c, seed: 5, epoch: 4, mutationP32: 1 << 28)
        XCTAssertNotEqual(a, c, "different epochs draw from different streams")
    }

    func testZeroMutationLeavesSoupUntouched() {
        let original = BFFRandom.initialSoup(programs: 8, seed: 1)
        var soup = original
        BFFRandom.mutate(soup: &soup, seed: 5, epoch: 3, mutationP32: 0)
        XCTAssertEqual(soup, original)
    }

    func testPairingIsAPermutationWithDisjointPairs() {
        let n = 64
        let perm = BFFRandom.pairingPermutation(count: n, seed: 11, epoch: 2)
        XCTAssertEqual(perm.count, n)
        XCTAssertEqual(perm.sorted(), Array(0..<UInt32(n)),
                       "every program appears exactly once")
        // Consecutive entries form the pairs; a permutation makes them disjoint.
        var seen = Set<UInt32>()
        for p in 0..<(n / 2) {
            let (a, b) = (perm[2 * p], perm[2 * p + 1])
            XCTAssertNotEqual(a, b)
            XCTAssertTrue(seen.insert(a).inserted)
            XCTAssertTrue(seen.insert(b).inserted)
        }
    }

    // Literal golden pairing vector (hard-coded from an independent reimplementation
    // of the documented Fisher–Yates): unlike the permutation-validity tests above,
    // this pins the *draw convention* — swaps iterate i = count-1 down to 1, the
    // partner is `rng3(seed, epoch*4+1, i) % (i+1)`. Any permutation would pass the
    // validity tests; only the pinned convention produces exactly this vector.
    func testPairingPermutationGoldenVector() {
        XCTAssertEqual(BFFRandom.pairingPermutation(count: 8, seed: 11, epoch: 2),
                       [1, 0, 7, 2, 4, 5, 6, 3])
    }

    func testPairingIsDeterministicPerEpoch() {
        let a = BFFRandom.pairingPermutation(count: 64, seed: 11, epoch: 2)
        XCTAssertEqual(a, BFFRandom.pairingPermutation(count: 64, seed: 11, epoch: 2))
        XCTAssertNotEqual(a, BFFRandom.pairingPermutation(count: 64, seed: 11, epoch: 3))
        XCTAssertNotEqual(a, BFFRandom.pairingPermutation(count: 64, seed: 12, epoch: 2))
    }
}

final class SimulationTests: XCTestCase {

    private func smallConfig(
        seed: UInt32 = 42,
        brackets: BracketMode = .dynamicScan,
        mutationP32: UInt32 = BFF.defaultMutationP32
    ) -> SimulationConfig {
        SimulationConfig(seed: seed, populationSize: 16, stepBudget: 512,
                         mutationP32: mutationP32, variant: .noheads,
                         bracketMode: brackets)
    }

    func testFixedSeedRunsAreBitIdentical() {
        for brackets in BracketMode.allCases {
            var a = Simulation(config: smallConfig(brackets: brackets))
            var b = Simulation(config: smallConfig(brackets: brackets))
            let statsA = a.run(epochs: 4)
            let statsB = b.run(epochs: 4)
            XCTAssertEqual(a.soup, b.soup, "\(brackets)")
            XCTAssertEqual(statsA, statsB, "\(brackets)")
            XCTAssertEqual(a.histogram(), b.histogram(), "\(brackets)")
        }
    }

    func testDifferentSeedsDiverge() {
        var a = Simulation(config: smallConfig(seed: 1))
        var b = Simulation(config: smallConfig(seed: 2))
        XCTAssertNotEqual(a.soup, b.soup, "initial soups differ by seed")
        a.run(epochs: 2)
        b.run(epochs: 2)
        XCTAssertNotEqual(a.soup, b.soup)
    }

    func testEpochStatsAreConsistent() {
        var sim = Simulation(config: smallConfig())
        let stats = sim.runEpoch()
        XCTAssertEqual(stats.epoch, 0)
        XCTAssertEqual(stats.interactions, 8)
        XCTAssertEqual(stats.haltBudget + stats.haltPCOut + stats.haltUnmatched, 8,
                       "every interaction halts with exactly one reason")
        XCTAssertGreaterThan(stats.totalSteps, 0)
        XCTAssertEqual(stats.meanSteps, Double(stats.totalSteps) / 8.0)
        XCTAssertEqual(sim.epoch, 1)
        XCTAssertEqual(sim.lastEpochStats, stats)
    }

    func testSoupSizeAndHistogramInvariant() {
        var sim = Simulation(config: smallConfig())
        XCTAssertEqual(sim.soup.count, 16 * BFF.tapeSize)
        sim.run(epochs: 3)
        XCTAssertEqual(sim.soup.count, 16 * BFF.tapeSize)
        XCTAssertEqual(sim.histogram().totalCount, UInt64(16 * BFF.tapeSize))
    }

    func testZeroMutationSimulationIsStillDeterministic() {
        var a = Simulation(config: smallConfig(mutationP32: 0))
        var b = Simulation(config: smallConfig(mutationP32: 0))
        a.run(epochs: 3)
        b.run(epochs: 3)
        XCTAssertEqual(a.soup, b.soup)
    }

    func testProgramAccessor() {
        let sim = Simulation(config: smallConfig())
        let p3 = sim.program(at: 3)
        XCTAssertEqual(p3.count, BFF.tapeSize)
        XCTAssertEqual(p3, Array(sim.soup[3 * 64 ..< 4 * 64]))
    }
}

final class HistogramTests: XCTestCase {

    func testCountsAndEntropy() {
        let h = ByteHistogram(bytes: [0, 0, 1, 1] as [UInt8])
        XCTAssertEqual(h.bins[0], 2)
        XCTAssertEqual(h.bins[1], 2)
        XCTAssertEqual(h.totalCount, 4)
        XCTAssertEqual(h.shannonEntropyBitsPerByte, 1.0, accuracy: 1e-12)

        let uniform = ByteHistogram(bytes: (0...255).map { UInt8($0) })
        XCTAssertEqual(uniform.shannonEntropyBitsPerByte, 8.0, accuracy: 1e-12)

        let constant = ByteHistogram(bytes: [UInt8](repeating: 7, count: 100))
        XCTAssertEqual(constant.shannonEntropyBitsPerByte, 0.0, accuracy: 1e-12)
        XCTAssertEqual(ByteHistogram(bytes: [] as [UInt8]).shannonEntropyBitsPerByte, 0)
    }

    func testMismatchReporting() {
        let a = ByteHistogram(bytes: [1, 2, 3] as [UInt8])
        let b = ByteHistogram(bytes: [1, 2, 4] as [UInt8])
        let diffs = a.mismatches(against: b)
        XCTAssertEqual(diffs.map(\.value), [3, 4])
        XCTAssertTrue(a.mismatches(against: a).isEmpty)
    }
}
