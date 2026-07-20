import Foundation
import XCTest
@testable import BFFOracle

final class EcologyConfigAndTopologyTests: XCTestCase {

    func testCanonicalConfigCarriesContractLabels() throws {
        let config = EcologyConfig(seed: 7)
        XCTAssertEqual(EcologyConfig.engineID, "ecology-v1")
        XCTAssertEqual(EcologyConfig.topologyID, "torus-512x256-v1")
        XCTAssertEqual(EcologyConfig.schedulerID, "edge-color-sync-v1")
        XCTAssertEqual(EcologyConfig.rngContractID, "ecology-counter-pcg-v1")
        XCTAssertEqual(config.stepBudget, 8192)
        XCTAssertEqual(config.mutationP32, 1 << 20)
        XCTAssertEqual(config.variant, .noheads)
        XCTAssertEqual(config.bracketMode, .dynamicScan)

        let data = try JSONEncoder().encode(config)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("ecology-v1"))
        XCTAssertTrue(text.contains("torus-512x256-v1"))
        XCTAssertTrue(text.contains("edge-color-sync-v1"))
        XCTAssertTrue(text.contains("ecology-counter-pcg-v1"))
        XCTAssertEqual(try JSONDecoder().decode(EcologyConfig.self, from: data), config)
    }

    func testCanonicalTopologyCoordinatesAndWrap() {
        XCTAssertEqual(EcologyTopology.width, 512)
        XCTAssertEqual(EcologyTopology.height, 256)
        XCTAssertEqual(EcologyTopology.siteCount, 131_072)
        XCTAssertEqual(EcologyTopology.pairCount, 65_536)
        XCTAssertEqual(EcologyTopology.soupByteCount, 8_388_608)
        XCTAssertEqual(EcologyTopology.maxProgramByteElement, 0x7F_FFFF)
        XCTAssertLessThan(EcologyTopology.maxProgramByteElement,
                          EcologyTopology.elementLimit)

        XCTAssertEqual(EcologyTopology.siteID(x: 0, y: 0), 0)
        XCTAssertEqual(EcologyTopology.siteID(x: 511, y: 255), 131_071)
        XCTAssertEqual(EcologyTopology.coordinate(siteID: 131_071),
                       EcologyCoordinate(x: 511, y: 255))
        XCTAssertEqual(EcologyTopology.east(siteID: 511), 0)
        XCTAssertEqual(EcologyTopology.south(siteID: 255 * 512 + 17), 17)
    }

    func testPhasePairBoundaryVectors() {
        XCTAssertEqual(EcologyTopology.pair(at: 0, phase: .horizontalEven),
                       EcologyPair(index: 0, a: 0, b: 1))
        XCTAssertEqual(EcologyTopology.pair(at: 255, phase: .horizontalEven),
                       EcologyPair(index: 255, a: 510, b: 511))
        XCTAssertEqual(EcologyTopology.pair(at: 0, phase: .horizontalOdd),
                       EcologyPair(index: 0, a: 1, b: 2))
        XCTAssertEqual(EcologyTopology.pair(at: 255, phase: .horizontalOdd),
                       EcologyPair(index: 255, a: 511, b: 0))
        XCTAssertEqual(EcologyTopology.pair(at: 0, phase: .verticalEven),
                       EcologyPair(index: 0, a: 0, b: 512))
        XCTAssertEqual(EcologyTopology.pair(at: 0, phase: .verticalOdd),
                       EcologyPair(index: 0, a: 512, b: 1024))
        XCTAssertEqual(EcologyTopology.pair(at: EcologyTopology.pairCount - 1,
                                            phase: .verticalOdd),
                       EcologyPair(index: EcologyTopology.pairCount - 1,
                                   a: 255 * 512 + 511, b: 511))
    }

    func testEachPhaseWritesEverySiteExactlyOnce() {
        for phase in EcologyMatchingPhase.allCases {
            var counts = [UInt8](repeating: 0, count: EcologyTopology.siteCount)
            for i in 0..<EcologyTopology.pairCount {
                let pair = EcologyTopology.pair(at: i, phase: phase)
                counts[pair.a] &+= 1
                counts[pair.b] &+= 1
            }
            XCTAssertEqual(counts.filter { $0 == 1 }.count,
                           EcologyTopology.siteCount, phase.label)
            XCTAssertEqual(counts.filter { $0 != 1 }.count, 0, phase.label)
        }
    }

    func testFourPhasesCoverEveryVonNeumannEdgeOnce() {
        var edges = Set<UInt64>()
        for phase in EcologyMatchingPhase.allCases {
            for i in 0..<EcologyTopology.pairCount {
                let pair = EcologyTopology.pair(at: i, phase: phase)
                let lo = UInt64(min(pair.a, pair.b))
                let hi = UInt64(max(pair.a, pair.b))
                XCTAssertTrue(edges.insert((lo << 32) | hi).inserted,
                              "duplicate edge \(pair) in phase \(phase)")
            }
        }
        XCTAssertEqual(edges.count, EcologyTopology.siteCount * 2)
    }
}

final class EcologyRandomTests: XCTestCase {

    func testBoundarySeedsAlwaysDifferFromWellMixedSeed() {
        XCTAssertEqual(EcologyRandom.ecologySeed(seed: 0), 0xEC0E_C001)
        XCTAssertEqual(EcologyRandom.ecologySeed(seed: 1), 0xEC0E_C000)
        XCTAssertEqual(EcologyRandom.ecologySeed(seed: .max), 0x13F1_3FFE)
        for seed in [UInt32(0), 1, .max] {
            XCTAssertNotEqual(EcologyRandom.ecologySeed(seed: seed), seed)
        }
    }

    func testEncodedSlotGoldenBoundaryVectors() throws {
        XCTAssertEqual(try EcologyRandom.encode(purpose: .initBytes, epoch: 0, element: 0),
                       EcologyRNGSlot(stream: 0x0100_0000, index: 0))
        XCTAssertEqual(try EcologyRandom.encode(purpose: .mutateFlag,
                                                epoch: 255,
                                                element: 0x7F_FFFF),
                       EcologyRNGSlot(stream: 0x0200_0000, index: 0xFF7F_FFFF))
        XCTAssertEqual(try EcologyRandom.encode(purpose: .mutateValue,
                                                epoch: 256,
                                                element: 1),
                       EcologyRNGSlot(stream: 0x0300_0001, index: 1))
        XCTAssertEqual(try EcologyRandom.encode(purpose: .shadow,
                                                epoch: .max,
                                                element: 0xFF_FFFF),
                       EcologyRNGSlot(stream: 0x04FF_FFFF, index: 0xFFFF_FFFF))
    }

    func testPurposeEpochElementBoundarySlotsArePairwiseDistinct() throws {
        let epochs: [UInt32] = [0, 1, 255, 256, .max - 1, .max]
        let elements: [UInt32] = [0, 1, 0x7F_FFFF, 0xFF_FFFF]
        var slots: [EcologyRNGSlot: (EcologyRNGPurpose, UInt32, UInt32)] = [:]

        for purpose in EcologyRNGPurpose.allCases {
            for epoch in epochs {
                for element in elements {
                    let slot = try EcologyRandom.encode(purpose: purpose,
                                                        epoch: epoch,
                                                        element: element)
                    if let previous = slots[slot] {
                        XCTFail("slot \(slot) aliased \(previous) and "
                                + "\(purpose), \(epoch), \(element)")
                    }
                    slots[slot] = (purpose, epoch, element)
                }
            }
        }

        XCTAssertEqual(slots.count,
                       EcologyRNGPurpose.allCases.count * epochs.count * elements.count)
    }

    func testSamePurposeBoundaryAssertionsAreOnEncodedInputs() throws {
        let e0 = try EcologyRandom.encode(purpose: .mutateFlag, epoch: 123, element: 0)
        let e1 = try EcologyRandom.encode(purpose: .mutateFlag, epoch: 123, element: 1)
        XCTAssertEqual(e0.stream, e1.stream)
        XCTAssertNotEqual(e0.index, e1.index)
        XCTAssertEqual(e0.index ^ e1.index, 1, "element LSB distinguishes index")

        let epoch0 = try EcologyRandom.encode(purpose: .mutateValue, epoch: 0, element: 7)
        let epoch256 = try EcologyRandom.encode(purpose: .mutateValue,
                                                epoch: 256,
                                                element: 7)
        XCTAssertEqual(epoch0.index, epoch256.index,
                       "epoch low bytes are both zero")
        XCTAssertNotEqual(epoch0.stream, epoch256.stream,
                          "e >> 8 distinguishes the stream")

        let flag = try EcologyRandom.encode(purpose: .mutateFlag,
                                            epoch: .max,
                                            element: 0xFF_FFFF)
        let value = try EcologyRandom.encode(purpose: .mutateValue,
                                             epoch: .max,
                                             element: 0xFF_FFFF)
        XCTAssertNotEqual(flag, value)
    }

    func testElementFieldRejectsOverflow() {
        XCTAssertThrowsError(try EcologyRandom.encode(purpose: .initBytes,
                                                      epoch: 0,
                                                      element: 0x0100_0000)) { error in
            XCTAssertEqual(error as? EcologyContractError,
                           .elementOutOfRange(0x0100_0000))
        }
    }

    func testInitialSoupUsesEcologyInitDomain() throws {
        let seed: UInt32 = 42
        let soup = EcologyRandom.initialSoup(seed: seed)
        XCTAssertEqual(soup.count, EcologyTopology.soupByteCount)
        for i in 0..<8 {
            let draw = try EcologyRandom.draw(seed: seed, purpose: .initBytes,
                                              epoch: 0, element: UInt32(i))
            XCTAssertEqual(soup[i], UInt8(truncatingIfNeeded: draw))
        }
    }

    func testMutationUsesSeparateFlagAndValueDomains() throws {
        let seed: UInt32 = 99
        let epoch: UInt32 = 257
        var soup = [UInt8](repeating: 0xAA, count: 128)
        var expected = soup
        var expectedCount = 0

        for i in 0..<expected.count {
            let element = UInt32(i)
            let flag = try EcologyRandom.draw(seed: seed, purpose: .mutateFlag,
                                              epoch: epoch, element: element)
            if flag < UInt32.max {
                let value = try EcologyRandom.draw(seed: seed, purpose: .mutateValue,
                                                   epoch: epoch, element: element)
                expected[i] = UInt8(truncatingIfNeeded: value)
                expectedCount += 1
            }
        }

        let actualCount = EcologyRandom.mutate(soup: &soup, seed: seed,
                                               epoch: epoch,
                                               mutationP32: .max)
        XCTAssertEqual(actualCount, expectedCount)
        XCTAssertEqual(soup, expected)

        let flagSlot = try EcologyRandom.encode(purpose: .mutateFlag,
                                                epoch: epoch,
                                                element: 0)
        let valueSlot = try EcologyRandom.encode(purpose: .mutateValue,
                                                 epoch: epoch,
                                                 element: 0)
        XCTAssertNotEqual(flagSlot, valueSlot)
        XCTAssertNotEqual(valueSlot.index, flagSlot.index ^ 0x8000_0000,
                          "ecology must not port well-mixed index xor value draws")
    }
}

final class EcologyOracleRunnerTests: XCTestCase {

    private func quickHaltingSoup() -> [UInt8] {
        var soup = [UInt8](repeating: 0, count: EcologyTopology.soupByteCount)
        for site in 0..<EcologyTopology.siteCount {
            soup[site * BFF.tapeSize] = BFFOp.loopClose
        }
        return soup
    }

    func testHorizontalPairOrientationAndConflictFreeWriteback() throws {
        let config = EcologyConfig(seed: 1, stepBudget: 256, mutationP32: 0)
        var soup = quickHaltingSoup()
        let site0 = 0
        let site1 = 1
        let start0 = site0 * BFF.tapeSize
        let start1 = site1 * BFF.tapeSize
        soup.replaceSubrange(start0 ..< start0 + BFF.tapeSize,
                             with: [UInt8](repeating: BFFOp.head0Right,
                                           count: BFF.tapeSize))
        var b = [UInt8](repeating: 0, count: BFF.tapeSize)
        b[0] = BFFOp.read
        b[1] = BFFOp.loopClose
        soup.replaceSubrange(start1 ..< start1 + BFF.tapeSize, with: b)

        var runner = try EcologyOracleRunner(config: config, soup: soup)
        let counters = try runner.runEpoch()

        XCTAssertEqual(counters.phase, .horizontalEven)
        XCTAssertEqual(counters.interactions, EcologyTopology.pairCount)
        XCTAssertEqual(counters.writeSites, EcologyTopology.siteCount)
        XCTAssertEqual(counters.writeConflicts, 0)
        XCTAssertEqual(counters.haltAccounted, counters.interactions)
        XCTAssertEqual(runner.program(at: site1)[0], BFFOp.head0Right,
                       "site 0 is A/west and site 1 is B/east")

        XCTAssertEqual(runner.lastSiteStats.count, EcologyTopology.siteCount)
        XCTAssertEqual(runner.lastSiteStats[0].siteID, site0)
        XCTAssertEqual(runner.lastSiteStats[0].partnerSiteID, site1)
        XCTAssertEqual(runner.lastSiteStats[1].siteID, site1)
        XCTAssertEqual(runner.lastSiteStats[1].partnerSiteID, site0)
        XCTAssertEqual(runner.lastSiteStats[0].copyWrites, 1)
        XCTAssertEqual(runner.lastSiteStats[0].pairIndex, 0)
    }

    func testMutationHappensBeforePairEvaluation() throws {
        let config = EcologyConfig(seed: 123, stepBudget: 1, mutationP32: .max)
        let soup = quickHaltingSoup()
        var manuallyMutated = soup
        let mutationCount = EcologyRandom.mutate(soup: &manuallyMutated,
                                                 seed: config.seed,
                                                 epoch: 0,
                                                 mutationP32: config.mutationP32)
        let pair = EcologyTopology.pair(at: 0, phase: .horizontalEven)
        let rangeA = pair.a * BFF.tapeSize ..< (pair.a + 1) * BFF.tapeSize
        let rangeB = pair.b * BFF.tapeSize ..< (pair.b + 1) * BFF.tapeSize
        let expected = BFFInterpreter.run(
            pairTape: Array(manuallyMutated[rangeA]) + Array(manuallyMutated[rangeB]),
            variant: config.variant,
            bracketMode: config.bracketMode,
            stepBudget: config.stepBudget)

        var runner = try EcologyOracleRunner(config: config, soup: soup)
        let counters = try runner.runEpoch()
        XCTAssertEqual(counters.mutationCount, mutationCount)
        XCTAssertEqual(runner.program(at: pair.a),
                       Array(expected.tape[0..<BFF.tapeSize]))
        XCTAssertEqual(runner.program(at: pair.b),
                       Array(expected.tape[BFF.tapeSize..<BFF.pairTapeSize]))
    }

    func testSameCheckpointRestoredTwiceMatchesAtReplayOffsets() throws {
        let config = EcologyConfig(seed: 77, stepBudget: 16, mutationP32: 0)
        let soup = quickHaltingSoup()
        let checkpoint = EcologyCheckpoint(capturing:
            try EcologyOracleRunner(config: config, soup: soup))

        for offset in [1, 4, 128] {
            var a = try EcologyOracleRunner(checkpoint: checkpoint)
            var b = try EcologyOracleRunner(checkpoint: checkpoint)
            try a.run(epochs: offset)
            try b.run(epochs: offset)
            XCTAssertEqual(a.digest, b.digest, "offset \(offset)")
            XCTAssertEqual(a.soup, b.soup, "offset \(offset)")
            XCTAssertEqual(a.lastEpochCounters, b.lastEpochCounters, "offset \(offset)")
        }
    }

    func testSaveRestoreContinuationMatchesUninterruptedRun() throws {
        let config = EcologyConfig(seed: 88, stepBudget: 16, mutationP32: 0)
        let soup = quickHaltingSoup()

        var uninterrupted = try EcologyOracleRunner(config: config, soup: soup)
        try uninterrupted.run(epochs: 7)

        var split = try EcologyOracleRunner(config: config, soup: soup)
        try split.run(epochs: 3)
        let checkpoint = EcologyCheckpoint(capturing: split)
        var restored = try EcologyOracleRunner(checkpoint: checkpoint)
        try restored.run(epochs: 4)

        XCTAssertEqual(restored.epoch, uninterrupted.epoch)
        XCTAssertEqual(restored.digest, uninterrupted.digest)
        XCTAssertEqual(restored.soup, uninterrupted.soup)
        XCTAssertEqual(restored.lastEpochCounters, uninterrupted.lastEpochCounters)
    }

    func testCheckpointRoundTripAndContractRejection() throws {
        var runner = try EcologyOracleRunner(
            config: EcologyConfig(seed: 5, stepBudget: 16, mutationP32: 0),
            soup: quickHaltingSoup())
        try runner.runEpoch()

        let checkpoint = EcologyCheckpoint(capturing: runner)
        let data = try checkpoint.jsonData()
        let decoded = try EcologyCheckpoint.decode(from: data)
        XCTAssertEqual(decoded, checkpoint)
        XCTAssertEqual(try decoded.soupBytes(), runner.soup)

        var wrongEngine = checkpoint
        wrongEngine.engineID = "well-mixed"
        XCTAssertThrowsError(try wrongEngine.jsonData()) { error in
            XCTAssertEqual(error as? EcologyContractError, .engineID("well-mixed"))
        }

        let wellMixed = GoldenFixture(capturing: Simulation(config:
            SimulationConfig(seed: 1, populationSize: 8, stepBudget: 8,
                             mutationP32: 0, variant: .noheads,
                             bracketMode: .dynamicScan)),
                                      source: "unit-test")
        XCTAssertThrowsError(try EcologyCheckpoint.decode(from: try wellMixed.jsonData()))
        XCTAssertThrowsError(try GoldenFixture.decode(from: data))
    }
}
