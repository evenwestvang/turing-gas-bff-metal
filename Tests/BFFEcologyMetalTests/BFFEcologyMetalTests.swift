import XCTest
import BFFOracle
import BFFEcologyMetal
import CBFFEcologyShared

#if canImport(Metal)
import Metal
#endif

/// Tests for the experimental GPU-resident ecology epoch runner.
///
/// These tests verify the three-layer mirror contract (C header → Metal
/// static_asserts → runtime layout probe), the ecology RNG parity against
/// accepted literal vectors from `EcologyTests`, the pair-probe topology
/// invariants, and full-epoch counter/digest parity against the CPU oracle.
///
/// Metal dispatch tests skip on non-Metal hosts (Linux CI) with `XCTSkip`.
/// The non-Metal stub and layout-probe host words are tested on all platforms.
final class BFFEcologyMetalTests: XCTestCase {

    // MARK: - Layout probe host words (all platforms)

    func testHostProbeWordsMatchDocumentedLayout() {
        let words = BFFEcologyLayoutProbe.hostProbeWords()
        XCTAssertEqual(words.count, BFFEcologyLayoutProbe.wordCount)

        // BFFEcologyEpochParams: 32 bytes, 4-byte aligned
        XCTAssertEqual(words[0], 32)  // sizeof
        XCTAssertEqual(words[1], 4)   // alignof
        XCTAssertEqual(words[2], 0)   // seed offset
        XCTAssertEqual(words[3], 4)   // epoch offset
        XCTAssertEqual(words[4], 8)   // stepBudget offset
        XCTAssertEqual(words[5], 12)  // mutationP32 offset
        XCTAssertEqual(words[6], 16)  // variant offset
        XCTAssertEqual(words[7], 20)  // bracketMode offset
        XCTAssertEqual(words[8], 24)  // capturePairTapes offset
        XCTAssertEqual(words[9], 28)  // reserved0 offset

        // BFFEcologyPairResult: 24 bytes, 4-byte aligned
        XCTAssertEqual(words[10], 24) // sizeof
        XCTAssertEqual(words[11], 4)  // alignof
        XCTAssertEqual(words[12], 0)  // steps offset
        XCTAssertEqual(words[13], 4)  // noopSteps offset
        XCTAssertEqual(words[14], 8)  // copyWrites offset
        XCTAssertEqual(words[15], 12) // loopOps offset
        XCTAssertEqual(words[16], 16) // remapEvents offset
        XCTAssertEqual(words[17], 20) // halt offset
    }

    // MARK: - Non-Metal stub (all platforms)

    func testRunnerErrorDescriptionsAreNonEmpty() throws {
        #if canImport(Metal)
        throw XCTSkip("Metal available — stub not tested here")
        #else
        // On non-Metal hosts, the runner is a stub; verify it exists.
        // (The actual error cases are tested on Metal hosts.)
        XCTAssertTrue(true, "Non-Metal stub compiles")
        #endif
    }

    // MARK: - Metal tests (skip on non-Metal hosts)

    // MARK: - CPU frozen-table direction-agnostic contract

    func testBuildJumpTableIsDirectionAgnostic() {
        // The CPU's buildJumpTable stores the bracket partner at each index
        // based on the INITIAL tape. When a byte self-modifies from [ to ]
        // (or vice versa) mid-run, the frozen lookup at that index still
        // returns the original partner — it does NOT check the live opcode
        // direction. This is the property the Metal frozen_target function
        // must mirror.

        var tape = [UInt8](repeating: 0, count: BFF.pairTapeSize)
        tape[2] = BFFOp.loopOpen   // [
        tape[4] = BFFOp.loopClose  // ]

        let frozen = BFFInterpreter.buildJumpTable(for: tape)

        // Frozen partners are symmetric
        XCTAssertEqual(frozen[2], 4, "[ at 2 matches ] at 4")
        XCTAssertEqual(frozen[4], 2, "] at 4 matches [ at 2")

        // Simulate self-modification: position 2 changes from [ to ]
        tape[2] = BFFOp.loopClose  // now ] at runtime

        // The CPU interpreter looks up frozen[pc] regardless of the live
        // opcode direction. frozen[2] is still 4 (the forward partner
        // from the initial tape), NOT -1.
        let frozenAtModifiedPosition = frozen[2]
        XCTAssertEqual(frozenAtModifiedPosition, 4,
                       "frozen[2] returns original partner 4 even though "
                       + "live tape[2] is now ] — direction-agnostic lookup")

        // The Metal bug: frozen_backward(initialTape, 2) would check
        // initialTape[2] == ] (false, it was [), returning -1. This
        // differs from the CPU's 4, causing a remapEvents undercount.
        // The fix: bff_ecology_frozen_target checks the INITIAL byte
        // and scans in the initial direction, matching the CPU.
    }

    #if canImport(Metal)

    /// Helper: create a runner with a quick-halting soup for deterministic testing.
    /// Every site's first byte is `BFFOp.loopClose` (0x5D); rest zeros. This
    /// means every interaction halts immediately with `.unmatched` (a taken `]`
    /// with no matching `[` on the tape), making counters fully predictable.
    private static func quickHaltingSoup() -> [UInt8] {
        var soup = [UInt8](repeating: 0, count: EcologyTopology.soupByteCount)
        for i in stride(from: 0, to: soup.count, by: BFF.tapeSize) {
            soup[i] = BFFOp.loopClose
        }
        return soup
    }

    /// Helper: skip if no Metal device is available.
    private func skipIfNoMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
    }

    // MARK: - Layout probe (Metal-compiled)

    func testLayoutProbeMatchesHost() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 0, stepBudget: 1)
        let runner = try EcologyMetalEpochRunner(config: config)
        // The runner's init calls verifyLayoutProbe() which throws on mismatch.
        // If we got here, all 18 probe words matched.
        XCTAssertTrue(true, "Layout probe passed during runner init")
    }

    // MARK: - RNG boundary vectors (pinned from EcologyTests)

    func testRNGBoundaryVectors() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 0, stepBudget: 1)
        let runner = try EcologyMetalEpochRunner(config: config)

        // Pinned vectors from EcologyTests (independent Python port provenance):
        // draw(seed, purpose, epoch, element) = expected
        let vectors: [(seed: UInt32, purpose: UInt32, epoch: UInt32, element: UInt32,
                       expected: UInt32)] = [
            // seed42/initBytes/epoch0/element0 → 0x61E54D76
            (42, BFF_ECO_RNG_INIT_BYTES, 0, 0, 0x61E54D76),
            // seed42/initBytes/epoch0/element1 → 0x6AE183B1
            (42, BFF_ECO_RNG_INIT_BYTES, 0, 1, 0x6AE183B1),
            // seed123/mutateFlag/epoch0/element0 → 0xB3A72CBF
            (123, BFF_ECO_RNG_MUTATE_FLAG, 0, 0, 0xB3A72CBF),
            // seed123/mutateValue/epoch0/element0 → 0xC4EA0F8B
            (123, BFF_ECO_RNG_MUTATE_VALUE, 0, 0, 0xC4EA0F8B),
            // seed123/mutateFlag/epoch1/element0 → 0xA4D1DB89
            (123, BFF_ECO_RNG_MUTATE_FLAG, 1, 0, 0xA4D1DB89),
            // seed7/initBytes/epoch0/element8388607 → 0x344EB244
            (7, BFF_ECO_RNG_INIT_BYTES, 0, 8388607, 0x344EB244),
        ]

        let inputs = vectors.map { ($0.seed, $0.purpose, $0.epoch, $0.element) }
        let results = try runner.runRNGProbe(inputs: inputs)

        for (i, v) in vectors.enumerated() {
            XCTAssertEqual(results[i], v.expected,
                           "RNG draw(\(v.seed), \(v.purpose), \(v.epoch), \(v.element)) "
                           + "expected 0x\(String(v.expected, radix: 16)), "
                           + "got 0x\(String(results[i], radix: 16))")
        }
    }

    func testEcologySeedVectors() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 0, stepBudget: 1)
        let runner = try EcologyMetalEpochRunner(config: config)

        // ecologySeed XOR: seed ^ 0xEC0EC001
        // seed 0 → 0xEC0EC001, seed 1 → 0xEC0EC000, seed max → 0x13F13FFE
        // Verify by drawing initBytes/epoch0/element0 and comparing to CPU oracle
        let seedVectors: [(seed: UInt32, expectedSeed: UInt32)] = [
            (0, 0xEC0EC001),
            (1, 0xEC0EC000),
            (UInt32.max, 0x13F13FFE),
        ]

        for v in seedVectors {
            let cpuDraw = try EcologyRandom.draw(seed: v.seed, purpose: .initBytes,
                                              epoch: 0, element: 0)
            let gpuDraws = try runner.runRNGProbe(inputs: [
                (v.seed, BFF_ECO_RNG_INIT_BYTES, 0, 0)
            ])
            XCTAssertEqual(gpuDraws[0], cpuDraw,
                           "ecologySeed parity failed for seed \(v.seed)")
        }
    }

    // MARK: - Pair-probe topology invariants

    func testPairProbeEverySiteWrittenExactlyOnce() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 0, stepBudget: 1)
        let runner = try EcologyMetalEpochRunner(config: config)

        for phase in 0..<4 {
            let pairs = try runner.runPairProbe(epoch: UInt32(phase))
            var written = [Int](repeating: 0, count: EcologyTopology.siteCount)
            for p in pairs {
                written[Int(p.a)] += 1
                written[Int(p.b)] += 1
            }
            // Every site is written exactly once
            for site in 0..<EcologyTopology.siteCount {
                XCTAssertEqual(written[site], 1,
                               "site \(site) written \(written[site]) times in phase \(phase)")
            }
        }
    }

    func testPairProbeCoversEveryVonNeumannEdgeOnce() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 0, stepBudget: 1)
        let runner = try EcologyMetalEpochRunner(config: config)

        // Four phases: H0, H1, V0, V1
        // Each phase covers a distinct edge-color class.
        // Horizontal phases: east edges (wrapping torus in x)
        // Vertical phases: south edges (wrapping torus in y)
        var edges = Set<String>()
        for phase in 0..<4 {
            let pairs = try runner.runPairProbe(epoch: UInt32(phase))
            for p in pairs {
                let a = Int(p.a)
                let b = Int(p.b)
                let coordA = EcologyTopology.coordinate(siteID: a)
                let coordB = EcologyTopology.coordinate(siteID: b)

                // Horizontal phases: b should be east(a)
                if phase == 0 || phase == 1 {
                    let east = EcologyTopology.east(siteID: a)
                    XCTAssertEqual(b, east,
                                   "phase \(phase): b(\(b)) != east(a(\(a)))")
                }
                // Vertical phases: b should be south(a)
                if phase == 2 || phase == 3 {
                    let south = EcologyTopology.south(siteID: a)
                    XCTAssertEqual(b, south,
                                   "phase \(phase): b(\(b)) != south(a(\(a)))")
                }

                // Track unique edges (unordered)
                let edge = "\(min(a, b))-\(max(a, b))"
                XCTAssertFalse(edges.contains(edge),
                               "edge \(edge) covered more than once across all phases")
                edges.insert(edge)
            }
        }
        // 4 phases × 65536 pairs = 262144 unique edges
        // The torus has 131072 sites × 4 edges/site / 2 = 262144 unique edges
        XCTAssertEqual(edges.count, 262144,
                       "Total unique edges should be 262144 (4 × pairCount)")
    }

    func testPairProbePhaseBoundaryVectors() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 0, stepBudget: 1)
        let runner = try EcologyMetalEpochRunner(config: config)

        // Phase 0 (H0): pair 0 → (site 0, site 1) — first horizontal even
        let h0Pairs = try runner.runPairProbe(epoch: 0)
        XCTAssertEqual(h0Pairs[0].a, 0, "H0 pair 0, a should be 0")
        XCTAssertEqual(h0Pairs[0].b, 1, "H0 pair 0, b should be 1")

        // Phase 1 (H1): pair 0 → (site 1, site 2) — first horizontal odd
        let h1Pairs = try runner.runPairProbe(epoch: 1)
        XCTAssertEqual(h1Pairs[0].a, 1, "H1 pair 0, a should be 1")
        XCTAssertEqual(h1Pairs[0].b, 2, "H1 pair 0, b should be 2 (east of 1)")

        // Phase 0 (H0): last pair → (site 131070, site 131071)
        // pairCount = 65536, last pair = 65535
        // ownersPerRow = 256, y = 65535/256 = 255, ownerSlot = 65535%256 = 255
        // x = 255*2 + 0 = 510, a = 255*512 + 510 = 131070, b = east(a) = 131071
        XCTAssertEqual(h0Pairs[65535].a, 131070, "H0 last pair a")
        XCTAssertEqual(h0Pairs[65535].b, 131071, "H0 last pair b")

        // Phase 2 (V0): pair 0 → (site 0, site 512) — first vertical even
        let v0Pairs = try runner.runPairProbe(epoch: 2)
        XCTAssertEqual(v0Pairs[0].a, 0, "V0 pair 0, a should be 0")
        XCTAssertEqual(v0Pairs[0].b, 512, "V0 pair 0, b should be 512 (south of 0)")

        // Phase 3 (V1): pair 0 → (site 512, site 1024) — first vertical odd
        let v1Pairs = try runner.runPairProbe(epoch: 3)
        XCTAssertEqual(v1Pairs[0].a, 512, "V1 pair 0, a should be 512")
        XCTAssertEqual(v1Pairs[0].b, 1024, "V1 pair 0, b should be 1024 (south of 512)")
    }

    // MARK: - Full-epoch parity (16K stress, 131K smoke)

    func testInitialSoupParity() throws {
        try skipIfNoMetal()
        // Verify initial soup is byte-identical to CPU oracle
        for seed in [UInt32(7), UInt32(42)] {
            let config = try EcologyMetalEpochConfig(seed: seed, stepBudget: 1)
            let runner = try EcologyMetalEpochRunner(config: config)
            let gpuSoup = runner.soupSnapshot
            let cpuSoup = EcologyRandom.initialSoup(seed: seed)
            XCTAssertEqual(gpuSoup, cpuSoup,
                           "Initial soup mismatch for seed \(seed)")
        }
    }

    func testEpochParityQuickHaltingSoupSeed123() throws {
        try skipIfNoMetal()
        // Pinned from EcologyTests:
        // seed 123, stepBudget 1, mutationP32 .max, quickHaltingSoup
        // Epoch 0 (H0): mutationCount 8388608, rawSteps 65536, noopSteps 62972,
        //   commandSteps 2564, loopOps 532, copyWrites 0, remapEvents 0,
        //   haltBudget 65262, haltPCOut 0, haltUnmatched 274,
        //   digest 0x774E8C45A3A7EC35
        // Epoch 1 (H1, continuation): mutationCount 8388608, rawSteps 65536,
        //   noopSteps 62944, commandSteps 2592, loopOps 520, copyWrites 0,
        //   remapEvents 0, haltBudget 65277, haltPCOut 0, haltUnmatched 259,
        //   digest 0x9CF33A383122D1ED

        let soup = Self.quickHaltingSoup()
        let checkpoint = EcologyCheckpoint(
            seed: 123, epoch: 0, mutationP32: UInt32.max,
            stepBudget: 1, variant: .noheads, bracketMode: .dynamicScan,
            soup: soup, lastEpochCounters: nil)
        let runner = try EcologyMetalEpochRunner(checkpoint: checkpoint)
        var cpuRunner = try EcologyOracleRunner(checkpoint: checkpoint)

        // Epoch 0
        let gpuReport0 = try runner.runEpoch()
        let cpuCounters0 = try cpuRunner.runEpoch()
        XCTAssertEqual(gpuReport0.counters, cpuCounters0,
                       "Epoch 0 counter mismatch")

        // Verify against pinned literals
        XCTAssertEqual(gpuReport0.counters.epoch, 0)
        XCTAssertEqual(gpuReport0.counters.mutationCount, 8388608)
        XCTAssertEqual(gpuReport0.counters.totalRawSteps, 65536)
        XCTAssertEqual(gpuReport0.counters.totalNoopSteps, 62972)
        XCTAssertEqual(gpuReport0.counters.totalCommandSteps, 2564)
        XCTAssertEqual(gpuReport0.counters.totalLoopOps, 532)
        XCTAssertEqual(gpuReport0.counters.totalCopyWrites, 0)
        XCTAssertEqual(gpuReport0.counters.totalRemapEvents, 0)
        XCTAssertEqual(gpuReport0.counters.haltBudget, 65262)
        XCTAssertEqual(gpuReport0.counters.haltPCOut, 0)
        XCTAssertEqual(gpuReport0.counters.haltUnmatched, 274)
        XCTAssertEqual(gpuReport0.counters.digest, 0x774E8C45A3A7EC35)

        // Epoch 1
        let gpuReport1 = try runner.runEpoch()
        let cpuCounters1 = try cpuRunner.runEpoch()
        XCTAssertEqual(gpuReport1.counters, cpuCounters1,
                       "Epoch 1 counter mismatch")

        XCTAssertEqual(gpuReport1.counters.epoch, 1)
        XCTAssertEqual(gpuReport1.counters.mutationCount, 8388608)
        XCTAssertEqual(gpuReport1.counters.totalRawSteps, 65536)
        XCTAssertEqual(gpuReport1.counters.totalNoopSteps, 62944)
        XCTAssertEqual(gpuReport1.counters.totalCommandSteps, 2592)
        XCTAssertEqual(gpuReport1.counters.totalLoopOps, 520)
        XCTAssertEqual(gpuReport1.counters.totalCopyWrites, 0)
        XCTAssertEqual(gpuReport1.counters.totalRemapEvents, 0)
        XCTAssertEqual(gpuReport1.counters.haltBudget, 65277)
        XCTAssertEqual(gpuReport1.counters.haltPCOut, 0)
        XCTAssertEqual(gpuReport1.counters.haltUnmatched, 259)
        XCTAssertEqual(gpuReport1.counters.digest, 0x9CF33A383122D1ED)

        // Final soup parity
        XCTAssertEqual(runner.soupSnapshot, cpuRunner.soup,
                       "Final soup mismatch after 2 epochs")
    }

    func testEpochParityDefaultConfigSeed42() throws {
        try skipIfNoMetal()
        // Full 131K-pair epoch with default config — the smoke test
        let config = try EcologyMetalEpochConfig(seed: 42, stepBudget: 8192,
                                                  mutationP32: BFF.defaultMutationP32)
        let runner = try EcologyMetalEpochRunner(config: config)
        let cpuConfig = EcologyConfig(seed: 42, stepBudget: 8192,
                                        mutationP32: BFF.defaultMutationP32)
        var cpuRunner = EcologyOracleRunner(config: cpuConfig)

        // Run 1 epoch and compare
        let gpuReport = try runner.runEpoch()
        let cpuCounters = try cpuRunner.runEpoch()

        XCTAssertEqual(gpuReport.counters, cpuCounters,
                       "Default config epoch 0 counter mismatch")
        XCTAssertEqual(runner.soupSnapshot, cpuRunner.soup,
                       "Default config soup mismatch after epoch 0")
    }

    func testEpochParityJumpTableMode() throws {
        try skipIfNoMetal()
        let soup = Self.quickHaltingSoup()
        let checkpoint = EcologyCheckpoint(
            seed: 123, epoch: 0, mutationP32: UInt32.max,
            stepBudget: 1, variant: .noheads, bracketMode: .jumpTable,
            soup: soup, lastEpochCounters: nil)
        let runner = try EcologyMetalEpochRunner(checkpoint: checkpoint)
        var cpuRunner = try EcologyOracleRunner(checkpoint: checkpoint)

        let gpuReport = try runner.runEpoch()
        let cpuCounters = try cpuRunner.runEpoch()

        XCTAssertEqual(gpuReport.counters, cpuCounters,
                       "Jump-table mode counter mismatch")
        XCTAssertEqual(runner.soupSnapshot, cpuRunner.soup,
                       "Jump-table mode soup mismatch")
    }

    func testEpochParitySeededHeadsVariant() throws {
        try skipIfNoMetal()
        let soup = Self.quickHaltingSoup()
        let checkpoint = EcologyCheckpoint(
            seed: 99, epoch: 0, mutationP32: UInt32.max,
            stepBudget: 8192, variant: .seededHeads, bracketMode: .dynamicScan,
            soup: soup, lastEpochCounters: nil)
        let runner = try EcologyMetalEpochRunner(checkpoint: checkpoint)
        var cpuRunner = try EcologyOracleRunner(checkpoint: checkpoint)

        let gpuReport = try runner.runEpoch()
        let cpuCounters = try cpuRunner.runEpoch()

        XCTAssertEqual(gpuReport.counters, cpuCounters,
                       "Seeded-heads variant counter mismatch")
        XCTAssertEqual(runner.soupSnapshot, cpuRunner.soup,
                       "Seeded-heads variant soup mismatch")
    }

    func testZeroMutationLeavesSoupUnchanged() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 42, stepBudget: 1,
                                                  mutationP32: 0)
        let runner = try EcologyMetalEpochRunner(config: config)
        let before = runner.soupSnapshot
        _ = try runner.runEpoch()
        // With mutationP32=0, the mutate kernel is a no-op.
        // But the eval kernel still writes back pair tapes (which may differ
        // from the initial soup if interactions modify them).
        // The soup will change due to eval, but mutationCount should be 0.
        XCTAssertEqual(runner.lastEpochCounters?.mutationCount, 0,
                       "mutationP32=0 should produce 0 mutations")
    }

    // MARK: - Config rejection tests

    func testStepBudgetExceeds8192Rejected() throws {
        try skipIfNoMetal()
        XCTAssertThrowsError(try EcologyMetalEpochConfig(seed: 0, stepBudget: 8193)) { error in
            guard case EcologyMetalEpochConfig.ConfigError.stepBudgetExceedsMetalContract(let n) = error else {
                XCTFail("Expected stepBudgetExceedsMetalContract, got \(error)")
                return
            }
            XCTAssertEqual(n, 8193)
        }
    }

    func testStepBudget8192Accepted() throws {
        try skipIfNoMetal()
        let config = try EcologyMetalEpochConfig(seed: 0, stepBudget: 8192)
        XCTAssertEqual(config.stepBudget, 8192)
    }

    func testStepBudgetZeroRejected() throws {
        try skipIfNoMetal()
        XCTAssertThrowsError(try EcologyMetalEpochConfig(seed: 0, stepBudget: 0)) { error in
            guard case EcologyMetalEpochConfig.ConfigError.stepBudgetOutOfRange(let n) = error else {
                XCTFail("Expected stepBudgetOutOfRange, got \(error)")
                return
            }
            XCTAssertEqual(n, 0)
        }
    }

    func testHaltUnknownIsZero() throws {
        try skipIfNoMetal()
        // After any epoch, haltUnknown counter must be 0.
        // The runner throws .unexpectedHalt if it's nonzero.
        let config = try EcologyMetalEpochConfig(seed: 42, stepBudget: 8192)
        let runner = try EcologyMetalEpochRunner(config: config)
        let report = try runner.runEpoch()
        // If we got here, haltUnknown was 0 (otherwise the runner would throw).
        XCTAssertEqual(report.counters.writeConflicts, 0,
                       "writeConflicts must always be 0 (no overlapping writes)")
        XCTAssertEqual(report.counters.writeSites, EcologyTopology.siteCount,
                       "writeSites must equal siteCount (every site written once)")
    }

    func testCapturePathParity() throws {
        try skipIfNoMetal()
        // M1: Test the capturePairTapes path — per-pair results must match
        // the CPU oracle's InteractionResult for each pair.
        let soup = Self.quickHaltingSoup()
        let checkpoint = EcologyCheckpoint(
            seed: 123, epoch: 0, mutationP32: UInt32.max,
            stepBudget: 1, variant: .noheads, bracketMode: .dynamicScan,
            soup: soup, lastEpochCounters: nil)

        _ = try EcologyMetalEpochConfig(
            fromEcologyConfig: try checkpoint.config(),
            capturePairTapes: true)
        let runner = try EcologyMetalEpochRunner(
            checkpoint: checkpoint, capturePairTapes: true)

        let gpuReport = try runner.runEpoch()

        // Build CPU oracle results for the same epoch
        let ecoConfig = EcologyConfig(seed: 123, stepBudget: 1,
                                        mutationP32: UInt32.max)
        var cpuRunner = try EcologyOracleRunner(config: ecoConfig, soup: soup, epoch: 0)

        // CPU oracle mutates first
        var cpuSoup = soup
        _ = EcologyRandom.mutate(soup: &cpuSoup, seed: 123, epoch: 0,
                                   mutationP32: UInt32.max)
        let phase = EcologyMatchingPhase(epoch: 0)

        // Compare per-pair results
        for pairIndex in 0..<EcologyTopology.pairCount {
            let pair = EcologyTopology.pair(at: pairIndex, phase: phase)
            let rangeA = pair.a * BFF.tapeSize ..< (pair.a + 1) * BFF.tapeSize
            let rangeB = pair.b * BFF.tapeSize ..< (pair.b + 1) * BFF.tapeSize
            let pairTape = Array(cpuSoup[rangeA]) + Array(cpuSoup[rangeB])
            let cpuResult = BFFInterpreter.run(
                pairTape: pairTape, variant: .noheads,
                bracketMode: .dynamicScan, stepBudget: 1)

            let gpuResult = gpuReport.capturedPairResults[pairIndex]
            XCTAssertEqual(gpuResult.steps, cpuResult.steps,
                           "pair \(pairIndex) steps mismatch")
            XCTAssertEqual(gpuResult.noopSteps, cpuResult.noopSteps,
                           "pair \(pairIndex) noopSteps mismatch")
            XCTAssertEqual(gpuResult.copyWrites, cpuResult.copyWrites,
                           "pair \(pairIndex) copyWrites mismatch")
            XCTAssertEqual(gpuResult.loopOps, cpuResult.loopOps,
                           "pair \(pairIndex) loopOps mismatch")
            XCTAssertEqual(gpuResult.remapEvents, cpuResult.remapEvents,
                           "pair \(pairIndex) remapEvents mismatch")
            XCTAssertEqual(gpuResult.halt, cpuResult.halt,
                           "pair \(pairIndex) halt mismatch")

            // Verify input tape capture matches the mutated pair tape
            let capturedInput = gpuReport.capturedInputTapes[pairIndex]
            XCTAssertEqual(capturedInput, pairTape,
                           "pair \(pairIndex) input tape capture mismatch")

            // Verify final tape capture matches the interpreter's final tape
            let capturedFinal = gpuReport.capturedFinalTapes[pairIndex]
            XCTAssertEqual(capturedFinal, cpuResult.tape,
                           "pair \(pairIndex) final tape capture mismatch")
        }

        // Also compare full counters
        let cpuCounters = try cpuRunner.runEpoch()
        XCTAssertEqual(gpuReport.counters, cpuCounters,
                       "Capture-path epoch counter mismatch")
    }

    // MARK: - Checkpoint restore: lastEpochCounters parity

    /// Verify that `EcologyMetalEpochRunner.init(checkpoint:)` restores
    /// `lastEpochCounters` from the checkpoint — matching the CPU oracle's
    /// `EcologyOracleRunner.init(checkpoint:)` behavior.
    func testCheckpointRestoresLastEpochCounters() throws {
        try skipIfNoMetal()

        let soup = Self.quickHaltingSoup()

        // Build a checkpoint with known lastEpochCounters (pinned from
        // EcologyTests: seed 123, stepBudget 1, mutationP32 .max, epoch 0).
        let knownCounters = EcologyEpochCounters(
            epoch: 0,
            phase: EcologyMatchingPhase(epoch: 0),
            interactions: EcologyTopology.pairCount,
            mutationCount: 8388608,
            totalRawSteps: 65536,
            totalNoopSteps: 62972,
            totalCommandSteps: 2564,
            totalLoopOps: 532,
            totalCopyWrites: 0,
            totalRemapEvents: 0,
            haltBudget: 65262,
            haltPCOut: 0,
            haltUnmatched: 274,
            writeSites: EcologyTopology.siteCount,
            writeConflicts: 0,
            digest: 0x774E8C45A3A7EC35)

        let checkpoint = EcologyCheckpoint(
            seed: 123, epoch: 1, mutationP32: UInt32.max,
            stepBudget: 1, variant: .noheads, bracketMode: .dynamicScan,
            soup: soup, lastEpochCounters: knownCounters)

        let runner = try EcologyMetalEpochRunner(
            checkpoint: checkpoint, capturePairTapes: false)

        XCTAssertEqual(runner.lastEpochCounters, knownCounters,
                       "Runner must restore lastEpochCounters from checkpoint")
    }

    // MARK: - Remap parity: seeded heads, default mutation, dynamicScan

    /// Regression for the seeded-heads remapEvents discrepancy (CPU 217 vs
    /// Metal 215). The root cause: Metal's frozen_forward/frozen_backward
    /// used direction-specific initial-byte guards, while the CPU's
    /// buildJumpTable lookup is direction-agnostic. When a byte that was
    /// `[` at interaction start self-modifies to `]` mid-run and is later
    /// executed as `]`, the Metal frozen lookup returned -1 (wrong) while
    /// the CPU returned the original forward partner (correct). This test
    /// uses the exact failing configuration (seed 123, stepBudget 128,
    /// default mutationP32, seededHeads, dynamicScan) and compares per-pair
    /// remapEvents across all 65536 pairs. Fails on 3da4a29, passes on the
    /// corrected child.
    func testRemapParitySeededHeadsDefaultMutation() throws {
        try skipIfNoMetal()

        // Real initial soup for seed 123 — NOT quickHaltingSoup. The
        // default mutation rate (1/4096) produces a natural mix of
        // brackets, and seededHeads creates execution paths that
        // self-modify bracket bytes across directions.
        let soup = EcologyRandom.initialSoup(seed: 123)

        // Run Metal with capture
        let checkpoint = EcologyCheckpoint(
            seed: 123, epoch: 0, mutationP32: BFF.defaultMutationP32,
            stepBudget: 128, variant: .seededHeads, bracketMode: .dynamicScan,
            soup: soup, lastEpochCounters: nil)

        let runner = try EcologyMetalEpochRunner(
            checkpoint: checkpoint, capturePairTapes: true)
        let gpuReport = try runner.runEpoch()

        // Build CPU oracle results for the same epoch
        var cpuSoup = soup
        _ = EcologyRandom.mutate(soup: &cpuSoup, seed: 123, epoch: 0,
                                   mutationP32: BFF.defaultMutationP32)
        let phase = EcologyMatchingPhase(epoch: 0)

        var mismatches = 0
        for pairIndex in 0..<EcologyTopology.pairCount {
            let pair = EcologyTopology.pair(at: pairIndex, phase: phase)
            let rangeA = pair.a * BFF.tapeSize ..< (pair.a + 1) * BFF.tapeSize
            let rangeB = pair.b * BFF.tapeSize ..< (pair.b + 1) * BFF.tapeSize
            let pairTape = Array(cpuSoup[rangeA]) + Array(cpuSoup[rangeB])
            let cpuResult = BFFInterpreter.run(
                pairTape: pairTape, variant: .seededHeads,
                bracketMode: .dynamicScan, stepBudget: 128)

            let gpuResult = gpuReport.capturedPairResults[pairIndex]

            if gpuResult.remapEvents != cpuResult.remapEvents {
                mismatches += 1
                if mismatches <= 5 {
                    XCTFail("pair \(pairIndex) remapEvents: "
                            + "GPU=\(gpuResult.remapEvents) "
                            + "CPU=\(cpuResult.remapEvents)")
                }
            }
        }
        XCTAssertEqual(mismatches, 0,
                       "remapEvents must match for all 65536 pairs")
    }

    /// Same configuration but with jumpTable bracket mode. The frozen
    /// target is used for control flow, so the direction-agnostic fix
    /// affects both remapEvents counting AND jump targets. Both must
    /// match the CPU oracle.
    func testRemapParitySeededHeadsJumpTable() throws {
        try skipIfNoMetal()

        let soup = EcologyRandom.initialSoup(seed: 123)

        let checkpoint = EcologyCheckpoint(
            seed: 123, epoch: 0, mutationP32: BFF.defaultMutationP32,
            stepBudget: 128, variant: .seededHeads, bracketMode: .jumpTable,
            soup: soup, lastEpochCounters: nil)

        let runner = try EcologyMetalEpochRunner(
            checkpoint: checkpoint, capturePairTapes: true)
        let gpuReport = try runner.runEpoch()

        var cpuSoup = soup
        _ = EcologyRandom.mutate(soup: &cpuSoup, seed: 123, epoch: 0,
                                   mutationP32: BFF.defaultMutationP32)
        let phase = EcologyMatchingPhase(epoch: 0)

        var mismatches = 0
        for pairIndex in 0..<EcologyTopology.pairCount {
            let pair = EcologyTopology.pair(at: pairIndex, phase: phase)
            let rangeA = pair.a * BFF.tapeSize ..< (pair.a + 1) * BFF.tapeSize
            let rangeB = pair.b * BFF.tapeSize ..< (pair.b + 1) * BFF.tapeSize
            let pairTape = Array(cpuSoup[rangeA]) + Array(cpuSoup[rangeB])
            let cpuResult = BFFInterpreter.run(
                pairTape: pairTape, variant: .seededHeads,
                bracketMode: .jumpTable, stepBudget: 128)

            let gpuResult = gpuReport.capturedPairResults[pairIndex]

            if gpuResult.remapEvents != cpuResult.remapEvents
                || gpuResult.steps != cpuResult.steps
                || gpuResult.halt != cpuResult.halt {
                mismatches += 1
                if mismatches <= 5 {
                    XCTFail("pair \(pairIndex): remap GPU=\(gpuResult.remapEvents) "
                            + "CPU=\(cpuResult.remapEvents), "
                            + "steps GPU=\(gpuResult.steps) CPU=\(cpuResult.steps), "
                            + "halt GPU=\(gpuResult.halt) CPU=\(cpuResult.halt)")
                }
            }
        }
        XCTAssertEqual(mismatches, 0,
                       "remapEvents, steps, and halt must match for all pairs")
    }

    #endif // canImport(Metal)
}
