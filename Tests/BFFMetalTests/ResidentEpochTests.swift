import XCTest
import BFFOracle
@testable import BFFMetal

final class ResidentEpochTests: XCTestCase {

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
}
#endif
