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
        // Pinned literal bytes (ecology-v1 CPU contract checkpoint; mechanically
        // generated by an independent Python port of the pcg_hash/rng3/ecologySeed
        // primitives — NOT recomputed by the production draw() path).
        let pinnedFirst8: [UInt8] = [0x76, 0xB1, 0xBE, 0x82, 0x01, 0x29, 0xB7, 0x79]
        for i in 0..<8 {
            XCTAssertEqual(soup[i], pinnedFirst8[i], "byte \(i)")
            // Same-path consistency: the soup byte equals the low 8 bits of the
            // corresponding initBytes draw (kept as a structural cross-check).
            let draw = try EcologyRandom.draw(seed: seed, purpose: .initBytes,
                                              epoch: 0, element: UInt32(i))
            XCTAssertEqual(soup[i], UInt8(truncatingIfNeeded: draw), "byte \(i)")
        }
    }

    func testDrawOutputsArePinnedToLiteralContractCheckpoint() throws {
        // ecology-v1 CPU contract checkpoint. Pinned literal rng3 draw OUTPUTS
        // for boundary (seed, purpose, epoch, element) vectors. These verify the
        // pcg_hash/rng3 output, not just the encode() input mapping pinned by
        // testEncodedSlotGoldenBoundaryVectors. Mechanically generated by an
        // independent Python port; do NOT regenerate via the production path.
        XCTAssertEqual(
            try EcologyRandom.draw(seed: 42, purpose: .initBytes, epoch: 0, element: 0),
            0x61E5_4D76)
        XCTAssertEqual(
            try EcologyRandom.draw(seed: 42, purpose: .initBytes, epoch: 0, element: 1),
            0x6AE1_83B1)
        XCTAssertEqual(
            try EcologyRandom.draw(seed: 123, purpose: .mutateFlag, epoch: 0, element: 0),
            0xB3A7_2CBF)
        XCTAssertEqual(
            try EcologyRandom.draw(seed: 123, purpose: .mutateValue, epoch: 0, element: 0),
            0xC4EA_0F8B)
        XCTAssertEqual(
            try EcologyRandom.draw(seed: 123, purpose: .mutateFlag, epoch: 1, element: 0),
            0xA4D1_DB89)
        XCTAssertEqual(
            try EcologyRandom.draw(seed: 7, purpose: .initBytes, epoch: 0,
                                  element: EcologyTopology.soupByteCount - 1),
            0x344E_B244)
    }

    func testInitialSoupDigestIsPinnedToLiteralContractCheckpoint() throws {
        // ecology-v1 CPU contract checkpoint. The digest of the full 8 MiB
        // initialSoup(seed: 7) is a literal constant; changing any primitive —
        // pcg_hash, rng3, ecologySeed, encode, initialSoup, or digest — must
        // re-pin this value with an independent implementation.
        let soup = EcologyRandom.initialSoup(seed: 7)
        XCTAssertEqual(EcologyDigest.digest(soup), 0x9E9A_BE65_6CB5_2499)
        XCTAssertEqual(EcologyDigest.hexString(0x9E9A_BE65_6CB5_2499),
                       "9e9abe656cb52499")
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

    // MARK: - Regression: malformed stepBudget through production decode/validate path

    func testMalformedStepBudgetRejectedThroughProductionDecodeValidatePath() throws {
        // Regression for the validateMetadata() ordering fix: stepBudget <= 0
        // must throw EcologyContractError.invalidStepBudget BEFORE any
        // preconditioned EcologyConfig initializer can run (which would trap and
        // crash the process). Covers every production entry point that routes
        // through validateMetadata: direct call, jsonData, config, and
        // decode(from:). Audited decode/json path: EcologyConfig.init(from:)
        // already validates budget > 0 before assignment (no equivalent trap);
        // the synthesized EcologyCheckpoint Codable init performs no initializer
        // calls. validateMetadata() is the only malformed-input trap site.
        let runner = try EcologyOracleRunner(
            config: EcologyConfig(seed: 5, stepBudget: 16, mutationP32: 0),
            soup: quickHaltingSoup())
        let valid = EcologyCheckpoint(capturing: runner)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for budget in [0, -1] {
            var cp = valid
            cp.stepBudget = budget
            // 1. Direct validateMetadata()
            XCTAssertThrowsError(try cp.validateMetadata(), "budget \(budget)") { error in
                XCTAssertEqual(error as? EcologyContractError,
                               .invalidStepBudget(budget), "budget \(budget)")
            }
            // 2. jsonData() calls validateMetadata() before encoding
            XCTAssertThrowsError(try cp.jsonData(), "budget \(budget)") { error in
                XCTAssertEqual(error as? EcologyContractError,
                               .invalidStepBudget(budget), "budget \(budget)")
            }
            // 3. config() calls validateMetadata() before EcologyConfig init
            XCTAssertThrowsError(try cp.config(), "budget \(budget)") { error in
                XCTAssertEqual(error as? EcologyContractError,
                               .invalidStepBudget(budget), "budget \(budget)")
            }
            // 4. Production decode path: encode WITHOUT validation (bypassing
            //    jsonData), then decode(from:) which calls validateMetadata().
            let malformed = try encoder.encode(cp)
            XCTAssertThrowsError(try EcologyCheckpoint.decode(from: malformed),
                                 "budget \(budget)") { error in
                XCTAssertEqual(error as? EcologyContractError,
                               .invalidStepBudget(budget), "budget \(budget)")
            }
        }

        // Sanity: the unmutated valid checkpoint still passes every path.
        XCTAssertNoThrow(try valid.validateMetadata())
        XCTAssertNoThrow(try valid.jsonData())
        XCTAssertNoThrow(try valid.config())
        XCTAssertNoThrow(try EcologyCheckpoint.decode(from: try valid.jsonData()))
    }

    // MARK: - Pinned-literal normative fixture: nonzero-mutation save/restore

    func testNonzeroMutationSaveRestoreDigestIsPinnedToLiteralContractCheckpoint() throws {
        // ecology-v1 CPU contract checkpoint.
        //
        // The literal digest and counter constants below are FROZEN expected
        // values for a nonzero-mutation continuation/save-restore scenario.
        // Provenance: mechanically generated by an independent Python port of
        // the pcg_hash/rng3/ecologySeed/EcologyRandom.encode/initialSoup/mutate
        // primitives and a minimal BFF interpreter mirroring
        // Sources/BFFOracle/Interpreter.swift semantics, run against the same
        // scenario config as the assertion. The constants are NOT recomputed
        // by invoking the production Swift path — they guard against drift in
        // any primitive the ecology contract depends on. Any change to the
        // ecology RNG contract, topology, scheduler, mutation ordering, BFF
        // evaluator step semantics, or digest function requires re-pinning these
        // values with an independent implementation and updating this note.
        let config = EcologyConfig(seed: 123, stepBudget: 1, mutationP32: .max)
        let soup0 = quickHaltingSoup()

        // Pinned digest of the canonical quickHaltingSoup initial state.
        XCTAssertEqual(EcologyDigest.digest(soup0), 0xB477_87F7_E122_2325)

        var split = try EcologyOracleRunner(config: config, soup: soup0)
        let counters0 = try split.runEpoch()

        // Pinned literal counters for epoch 0 (phase H0, full mutation, stepBudget=1).
        XCTAssertEqual(counters0.epoch, 0)
        XCTAssertEqual(counters0.phase, .horizontalEven)
        XCTAssertEqual(counters0.interactions, 65_536)
        XCTAssertEqual(counters0.mutationCount, 8_388_608)
        XCTAssertEqual(counters0.totalRawSteps, 65_536)
        XCTAssertEqual(counters0.totalNoopSteps, 62_972)
        XCTAssertEqual(counters0.totalCommandSteps, 2_564)
        XCTAssertEqual(counters0.totalLoopOps, 532)
        XCTAssertEqual(counters0.totalCopyWrites, 0)
        XCTAssertEqual(counters0.totalRemapEvents, 0)
        XCTAssertEqual(counters0.haltBudget, 65_262)
        XCTAssertEqual(counters0.haltPCOut, 0)
        XCTAssertEqual(counters0.haltUnmatched, 274)
        XCTAssertEqual(counters0.haltAccounted, counters0.interactions)
        XCTAssertEqual(counters0.writeSites, 131_072)
        XCTAssertEqual(counters0.writeConflicts, 0)
        XCTAssertEqual(counters0.digest, 0x774E_8C45_A3A7_EC35)
        XCTAssertEqual(split.digest, 0x774E_8C45_A3A7_EC35)
        XCTAssertEqual(split.epoch, 1)

        // Save/restore continuation: capture, restore, run one more epoch.
        let checkpoint = EcologyCheckpoint(capturing: split)

        // The captured checkpoint round-trips through the production decode path.
        let roundTripData = try checkpoint.jsonData()
        let decoded = try EcologyCheckpoint.decode(from: roundTripData)
        XCTAssertEqual(decoded, checkpoint)

        // Restored runner starts at the captured epoch with the captured soup
        // and last counters, before the continuation epoch runs.
        var restored = try EcologyOracleRunner(checkpoint: checkpoint)
        XCTAssertEqual(restored.epoch, 1)
        XCTAssertEqual(restored.lastEpochCounters, counters0)

        let counters1 = try restored.runEpoch()

        // Pinned literal counters for epoch 1 (phase H1, continuation after restore).
        XCTAssertEqual(counters1.epoch, 1)
        XCTAssertEqual(counters1.phase, .horizontalOdd)
        XCTAssertEqual(counters1.interactions, 65_536)
        XCTAssertEqual(counters1.mutationCount, 8_388_608)
        XCTAssertEqual(counters1.totalRawSteps, 65_536)
        XCTAssertEqual(counters1.totalNoopSteps, 62_944)
        XCTAssertEqual(counters1.totalCommandSteps, 2_592)
        XCTAssertEqual(counters1.totalLoopOps, 520)
        XCTAssertEqual(counters1.totalCopyWrites, 0)
        XCTAssertEqual(counters1.totalRemapEvents, 0)
        XCTAssertEqual(counters1.haltBudget, 65_277)
        XCTAssertEqual(counters1.haltPCOut, 0)
        XCTAssertEqual(counters1.haltUnmatched, 259)
        XCTAssertEqual(counters1.haltAccounted, counters1.interactions)
        XCTAssertEqual(counters1.writeSites, 131_072)
        XCTAssertEqual(counters1.writeConflicts, 0)
        XCTAssertEqual(counters1.digest, 0x9CF3_3A38_3122_D1ED)
        XCTAssertEqual(restored.digest, 0x9CF3_3A38_3122_D1ED)
        XCTAssertEqual(restored.epoch, 2)
    }
}
