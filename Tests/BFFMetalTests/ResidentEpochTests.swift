import XCTest
import BFFOracle
@testable import BFFMetal

final class ResidentEpochTests: XCTestCase {
    func testResidentPlannerCLIParserAndIdentifiers() throws {
        XCTAssertEqual(try ResidentPairingPlanner(cliValue: "keyed"), .keyed)
        XCTAssertEqual(try ResidentPairingPlanner(cliValue: "cpu-upload"), .cpuUpload)
        XCTAssertEqual(ResidentPairingPlanner.keyed.cliValue, "keyed")
        XCTAssertEqual(ResidentPairingPlanner.cpuUpload.cliValue, "cpu-upload")
        XCTAssertEqual(ResidentPairingPlanner.keyed.identifier, "parallel-swap-or-not-v1")
        XCTAssertEqual(ResidentPairingPlanner.cpuUpload.identifier,
                       "cpu-upload-fisher-yates-v1")
        XCTAssertThrowsError(try ResidentPairingPlanner(cliValue: "parallel-swap-or-not-v1"))
    }

    func testResidentCPUReferenceIsDeterministicForRepresentativeTinySizes() throws {
        let sizes = [2, 4, 6, 10, 16, 256, 1024]
        for seed in [UInt32(1), UInt32(0xC0FF_EE)] {
            for programs in sizes {
                let config = try ResidentEpochConfig(seed: seed,
                                                     programCount: programs,
                                                     checkpointInterval: 1,
                                                     capturePairTapes: true)
                var a = ResidentCPUReferenceRunner(config: config)
                var b = ResidentCPUReferenceRunner(config: config)

                let ra = a.runEpoch()
                let rb = b.runEpoch()

                XCTAssertEqual(a.soup, b.soup, "seed \(seed) programs \(programs)")
                XCTAssertEqual(ra.checkpointSoup, Optional(a.soup),
                               "seed \(seed) programs \(programs)")
                XCTAssertEqual(ra.digest, Optional(SoupDigest.digest(a.soup)),
                               "seed \(seed) programs \(programs)")
                XCTAssertEqual(ra.counters, rb.counters,
                               "seed \(seed) programs \(programs)")
                XCTAssertEqual(ra.capturedPairs, rb.capturedPairs,
                               "seed \(seed) programs \(programs)")
                XCTAssertEqual(ra.counters.haltUnknown, 0,
                               "seed \(seed) programs \(programs)")
                XCTAssertEqual(ra.counters.haltAccounted, programs / 2,
                               "seed \(seed) programs \(programs)")
                XCTAssertEqual(ra.shadowMismatches, [],
                               "seed \(seed) programs \(programs)")
            }
        }
    }

    func testResidentPlannerFingerprintsArePinnedForSmallVectors() {
        struct Vector {
            var planner: ResidentPairingPlanner
            var count: Int
            var seed: UInt32
            var epoch: UInt32
            var fingerprint: UInt64
        }
        let vectors = [
            Vector(planner: .keyed, count: 2, seed: 1, epoch: 0,
                   fingerprint: 0x08CD_4C29_D1E4_7D34),
            Vector(planner: .cpuUpload, count: 2, seed: 1, epoch: 0,
                   fingerprint: 0x08CD_4C29_D1E4_7D34),
            Vector(planner: .keyed, count: 8, seed: 11, epoch: 2,
                   fingerprint: 0xFBBF_308D_B75B_6595),
            Vector(planner: .cpuUpload, count: 8, seed: 11, epoch: 2,
                   fingerprint: 0xA7B4_FFBE_0E6F_1EE5),
            Vector(planner: .keyed, count: 16, seed: 7, epoch: 3,
                   fingerprint: 0xE6E7_176E_82DE_BE95),
            Vector(planner: .cpuUpload, count: 16, seed: 7, epoch: 3,
                   fingerprint: 0x195C_2AF9_7FAA_AFF5),
        ]

        for v in vectors {
            let perm = v.planner.permutation(count: v.count, seed: v.seed, epoch: v.epoch)
            XCTAssertEqual(PermutationDigest.digest(perm), v.fingerprint,
                           "\(v.planner.identifier) count \(v.count) seed \(v.seed) epoch \(v.epoch)")
        }
    }

    func testPairingDistributionDiagnosticsUseDocumentedBins() {
        let perm = ResidentPairingPlanner.keyed.permutation(count: 16, seed: 7, epoch: 3)
        let diagnostics = PairingDistributionDiagnostics.analyze(permutation: perm)
        XCTAssertEqual(PairingDistributionDiagnostics.distanceBinLabels,
                       ["0", "1", "2...3", "4...7", "8...15", "16...31",
                        "32...63", "64...127", "128...255", "256...511",
                        "512...1023", "1024..."])
        XCTAssertEqual(diagnostics.fixedPointCount, 0)
        XCTAssertEqual(diagnostics.adjacentIDPairCount, 1)
        XCTAssertEqual(diagnostics.meanAbsolutePairIDDistance, 5.75, accuracy: 1e-12)
        XCTAssertEqual(diagnostics.distanceHistogram.map(\.count),
                       [0, 1, 2, 2, 2, 1, 0, 0, 0, 0, 0, 0])
    }

    func testCPUUploadPlannerUsesCanonicalFisherYatesPermutation() {
        let perm = ResidentPairingPlanner.cpuUpload.permutation(count: 8, seed: 11, epoch: 2)
        XCTAssertEqual(perm, BFFRandom.pairingPermutation(count: 8, seed: 11, epoch: 2))
        XCTAssertEqual(perm, [1, 0, 7, 2, 4, 5, 6, 3])
    }

    func testBothResidentPlannersHaveNoDuplicateOrOmittedProgramIDs() {
        let planners: [ResidentPairingPlanner] = [.keyed, .cpuUpload]
        for planner in planners {
            for count in [2, 4, 6, 10, 16, 64, 256] {
                let perm = planner.permutation(count: count, seed: 0xC0FF_EE, epoch: 7)
                XCTAssertEqual(perm.count, count)
                XCTAssertEqual(perm.sorted(), Array(0..<UInt32(count)),
                               "\(planner.identifier) count \(count)")
            }
        }
    }

    func testCPUUploadResidentReferenceMatchesCanonicalFisherYatesEpoch() throws {
        let residentConfig = try ResidentEpochConfig(seed: 11,
                                                     programCount: 16,
                                                     mutationP32: 1 << 24,
                                                     planner: .cpuUpload,
                                                     shadowSampleCount: 0,
                                                     checkpointInterval: 1)
        var resident = ResidentCPUReferenceRunner(config: residentConfig)
        let residentReport = resident.runEpoch()

        let canonicalConfig = try SoupConfig(seed: 11,
                                            programCount: 16,
                                            stepBudget: residentConfig.stepBudget,
                                            mutationP32: residentConfig.mutationP32,
                                            variant: residentConfig.variant,
                                            shadowSampleCount: 0,
                                            initMode: residentConfig.initMode)
        var canonical = SoupRunner(config: canonicalConfig)
        let canonicalReport = try canonical.runEpoch(using: CPUPairEvaluator(),
                                                     metrics: .disabled)

        XCTAssertEqual(resident.soup, canonical.soup)
        XCTAssertEqual(residentReport.checkpointSoup, Optional(canonical.soup))
        XCTAssertEqual(residentReport.digest, Optional(canonicalReport.digest))
        XCTAssertEqual(residentReport.counters.epoch, canonicalReport.counters.epoch)
        XCTAssertEqual(residentReport.counters.interactions,
                       canonicalReport.counters.interactions)
        XCTAssertEqual(residentReport.counters.mutationCount,
                       canonicalReport.counters.mutationCount)
        XCTAssertEqual(residentReport.counters.totalRawSteps,
                       canonicalReport.counters.totalRawSteps)
        XCTAssertEqual(residentReport.counters.totalNoopSteps,
                       canonicalReport.counters.totalNoopSteps)
        XCTAssertEqual(residentReport.counters.totalCommandSteps,
                       canonicalReport.counters.totalCommandSteps)
        XCTAssertEqual(residentReport.counters.totalLoopOps,
                       canonicalReport.counters.totalLoopOps)
        XCTAssertEqual(residentReport.counters.totalCopyWrites,
                       canonicalReport.counters.totalCopyWrites)
        XCTAssertEqual(residentReport.counters.haltBudget,
                       canonicalReport.counters.haltBudget)
        XCTAssertEqual(residentReport.counters.haltPCOut,
                       canonicalReport.counters.haltPCOut)
        XCTAssertEqual(residentReport.counters.haltUnmatched,
                       canonicalReport.counters.haltUnmatched)
        XCTAssertEqual(residentReport.counters.haltUnknown,
                       canonicalReport.counters.haltUnknown)
    }

    func testResidentCPUReferenceSupportsSeededHeadsAndMultipleEpochs() throws {
        let config = try ResidentEpochConfig(seed: 7,
                                             programCount: 32,
                                             variant: .seededHeads,
                                             checkpointInterval: 1,
                                             capturePairTapes: true)
        var resident = ResidentCPUReferenceRunner(config: config)
        var repeatResident = ResidentCPUReferenceRunner(config: config)

        for epoch in 0..<3 {
            let r = resident.runEpoch()
            let rr = repeatResident.runEpoch()
            XCTAssertEqual(r.counters.epoch, epoch)
            XCTAssertEqual(resident.soup, repeatResident.soup)
            XCTAssertEqual(r.counters, rr.counters)
            XCTAssertEqual(r.capturedPairs, rr.capturedPairs)
            XCTAssertEqual(r.shadowMismatches, [])
        }
    }

    func testPairCapturesCarryStableIDsAndExactTapes() throws {
        let config = try ResidentEpochConfig(seed: 11,
                                             programCount: 8,
                                             mutationP32: 0,
                                             shadowSampleCount: nil,
                                             checkpointInterval: 1,
                                             capturePairTapes: true)
        var runner = ResidentCPUReferenceRunner(config: config)
        let initial = runner.soup
        let report = runner.runEpoch()
        let perm = BFFRandom.residentPairingPermutation(count: 8, seed: 11, epoch: 0)

        XCTAssertEqual(report.capturedPairs.count, 4)
        XCTAssertEqual(report.shadowChecked, 4)
        XCTAssertEqual(report.shadowMismatches, [])
        for pairIndex in 0..<4 {
            let capture = report.capturedPairs[pairIndex]
            let a = perm[2 * pairIndex]
            let b = perm[2 * pairIndex + 1]
            XCTAssertEqual(capture.pairIndex, pairIndex)
            XCTAssertEqual(capture.programA, a)
            XCTAssertEqual(capture.programB, b)

            let aStart = Int(a) * BFF.tapeSize
            let bStart = Int(b) * BFF.tapeSize
            let expectedInput = Array(initial[aStart..<aStart + BFF.tapeSize])
                + Array(initial[bStart..<bStart + BFF.tapeSize])
            XCTAssertEqual(capture.inputTape, expectedInput)
            XCTAssertEqual(capture.finalTape, capture.outcome.finalTape)
        }
    }

    func testResidentBufferSizingCoversTailsCapturesAndVisualization() throws {
        let tiny = try ResidentEpochConfig(seed: 1,
                                           programCount: 2,
                                           capturePairTapes: true,
                                           visualizationEnabled: true,
                                           visualizationWidth: 3)
        let tinySizes = ResidentEpochBufferSizer.sizes(config: tiny)
        XCTAssertEqual(tinySizes.soupBytes, 128)
        XCTAssertEqual(tinySizes.permutationBytes, 8)
        XCTAssertEqual(tinySizes.pairInputCaptureBytes, 128)
        XCTAssertEqual(tinySizes.pairFinalCaptureBytes, 128)
        XCTAssertEqual(tinySizes.visualizationBytes, 12)

        let smoke = try ResidentEpochConfig(seed: 1,
                                            programCount: 131_072,
                                            capturePairTapes: false,
                                            visualizationEnabled: true,
                                            visualizationWidth: 512)
        let smokeSizes = ResidentEpochBufferSizer.sizes(config: smoke)
        XCTAssertEqual(smokeSizes.soupBytes, 131_072 * 64)
        XCTAssertEqual(smokeSizes.permutationBytes, 131_072 * 4)
        XCTAssertEqual(smokeSizes.pairInputCaptureBytes, 0)
        XCTAssertEqual(smokeSizes.pairFinalCaptureBytes, 0)
        XCTAssertEqual(smokeSizes.visualizationBytes, 512 * 256 * 4)
        XCTAssertGreaterThan(smokeSizes.totalPersistentBytes, smokeSizes.soupBytes)
    }

    func testResidentConfigRejectsOddSmallAndInvalidSizingInputs() {
        XCTAssertThrowsError(try ResidentEpochConfig(seed: 1, programCount: 0))
        XCTAssertThrowsError(try ResidentEpochConfig(seed: 1, programCount: 3))
        XCTAssertThrowsError(try ResidentEpochConfig(seed: 1, programCount: 5))
        XCTAssertThrowsError(try ResidentEpochConfig(seed: 1, programCount: 2,
                                                     stepBudget: 0))
        XCTAssertThrowsError(try ResidentEpochConfig(seed: 1, programCount: 2,
                                                     checkpointInterval: -1))
        XCTAssertThrowsError(try ResidentEpochConfig(seed: 1, programCount: 2,
                                                     visualizationWidth: 0))
    }
}

#if canImport(Metal)
final class ResidentMetalEpochTests: XCTestCase {
    func testResidentMetalTinyEpochMatchesCPUReferenceWhenDeviceExists() throws {
        let config = try ResidentEpochConfig(seed: 3,
                                             programCount: 16,
                                             checkpointInterval: 1,
                                             capturePairTapes: true,
                                             visualizationEnabled: true,
                                             visualizationWidth: 8)
        let gpu: ResidentMetalEpochRunner
        do {
            gpu = try ResidentMetalEpochRunner(config: config)
        } catch ResidentMetalEpochRunner.RunnerError.noDevice {
            throw XCTSkip("no Metal device available")
        }

        var cpu = ResidentCPUReferenceRunner(config: config)
        let g = try gpu.runEpoch()
        let c = cpu.runEpoch()
        XCTAssertEqual(g.counters, c.counters)
        XCTAssertEqual(g.checkpointSoup, c.checkpointSoup)
        XCTAssertEqual(g.digest, c.digest)
        XCTAssertEqual(g.shadowMismatches, [])
        XCTAssertEqual(g.capturedPairs, c.capturedPairs)
        XCTAssertEqual(g.instrumentation.kernelTimings.map(\.name),
                       ["mutate", "plan", "eval-scatter", "visualize"])
    }

    func testResidentMetalCPUUploadTinyEpochMatchesCanonicalFisherYatesCPUReferenceWhenDeviceExists() throws {
        let config = try ResidentEpochConfig(seed: 11,
                                             programCount: 16,
                                             mutationP32: 1 << 24,
                                             planner: .cpuUpload,
                                             checkpointInterval: 1,
                                             capturePairTapes: true)
        let gpu: ResidentMetalEpochRunner
        do {
            gpu = try ResidentMetalEpochRunner(config: config)
        } catch ResidentMetalEpochRunner.RunnerError.noDevice {
            throw XCTSkip("no Metal device available")
        }

        let g = try gpu.runEpoch()
        let canonicalConfig = try SoupConfig(seed: config.seed,
                                            programCount: config.programCount,
                                            stepBudget: config.stepBudget,
                                            mutationP32: config.mutationP32,
                                            variant: config.variant,
                                            shadowSampleCount: 0,
                                            initMode: config.initMode)
        var canonical = SoupRunner(config: canonicalConfig)
        let c = try canonical.runEpoch(using: CPUPairEvaluator(), metrics: .disabled)

        XCTAssertEqual(g.checkpointSoup, Optional(canonical.soup))
        XCTAssertEqual(g.digest, Optional(c.digest))
        XCTAssertEqual(g.counters.mutationCount, c.counters.mutationCount)
        XCTAssertEqual(g.counters.totalRawSteps, c.counters.totalRawSteps)
        XCTAssertEqual(g.counters.totalNoopSteps, c.counters.totalNoopSteps)
        XCTAssertEqual(g.counters.totalCommandSteps, c.counters.totalCommandSteps)
        XCTAssertEqual(g.counters.totalLoopOps, c.counters.totalLoopOps)
        XCTAssertEqual(g.counters.totalCopyWrites, c.counters.totalCopyWrites)
        XCTAssertEqual(g.counters.haltBudget, c.counters.haltBudget)
        XCTAssertEqual(g.counters.haltPCOut, c.counters.haltPCOut)
        XCTAssertEqual(g.counters.haltUnmatched, c.counters.haltUnmatched)
        XCTAssertEqual(g.counters.haltUnknown, c.counters.haltUnknown)
        XCTAssertEqual(g.capturedPairs.map { [$0.programA, $0.programB] }.flatMap { $0 },
                       BFFRandom.pairingPermutation(count: config.programCount,
                                                    seed: config.seed,
                                                    epoch: 0))
        XCTAssertEqual(g.instrumentation.kernelTimings.map(\.name),
                       ["mutate", "eval-scatter"])
        XCTAssertNil(g.instrumentation.plannerGPUSeconds)
        XCTAssertEqual(g.instrumentation.permutationUploadBytes,
                       config.programCount * MemoryLayout<UInt32>.stride)
        XCTAssertEqual(g.instrumentation.uploadBytes,
                       config.soupByteCount
                       + config.programCount * MemoryLayout<UInt32>.stride)
    }
}
#endif
