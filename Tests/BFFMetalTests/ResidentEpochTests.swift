import XCTest
import Foundation
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

    func testResidentSnapshotLayoutChecksByteCountAndCanonicalOffsets() throws {
        XCTAssertEqual(ResidentSnapshotLayout.programByteCount, 64)
        XCTAssertEqual(try ResidentSnapshotLayout.checkedSoupByteCount(programCount: 4), 256)
        XCTAssertEqual(try ResidentSnapshotLayout.byteOffset(programID: 0,
                                                            byteIndex: 0,
                                                            programCount: 4),
                       0)
        XCTAssertEqual(try ResidentSnapshotLayout.byteOffset(programID: 3,
                                                            byteIndex: 63,
                                                            programCount: 4),
                       255)

        XCTAssertThrowsError(try ResidentSnapshotLayout.checkedSoupByteCount(programCount: 0))
        XCTAssertThrowsError(try ResidentSnapshotLayout.byteOffset(programID: 4,
                                                                  byteIndex: 0,
                                                                  programCount: 4))
        XCTAssertThrowsError(try ResidentSnapshotLayout.byteOffset(programID: 0,
                                                                  byteIndex: 64,
                                                                  programCount: 4))
    }

    func testResidentSnapshotRingPublishesOnlyCompletedReservations() throws {
        var ring = try ResidentSnapshotRingState(slotCount: 2, expectedByteCount: 128)

        let first = try XCTUnwrap(ring.reserveForWrite())
        XCTAssertNil(ring.acquire(expectedByteCount: 128),
                     "a reserved slot must not be visible until completion publishes it")
        ring.cancel(first)
        XCTAssertNil(ring.acquire(expectedByteCount: 128))

        let second = try XCTUnwrap(ring.reserveForWrite())
        ring.publish(second, sourceEpoch: 1, byteCount: 128,
                     blitHostSeconds: 0.001, blitGPUSeconds: 0.0005)
        let token = try XCTUnwrap(ring.acquire(expectedByteCount: 128))

        XCTAssertEqual(token.generation, second.generation)
        XCTAssertEqual(token.sourceEpoch, 1)
        XCTAssertEqual(token.byteCount, 128)
        XCTAssertEqual(ring.diagnostics.publishCount, 1)
        XCTAssertEqual(ring.diagnostics.cancelledReservationCount, 1)
        XCTAssertEqual(ring.diagnostics.lastBlitHostSeconds, Optional(0.001))
        XCTAssertEqual(ring.diagnostics.lastBlitGPUSeconds, Optional(0.0005))
    }

    func testResidentSnapshotRingNeverRecyclesActiveRendererGeneration() throws {
        var ring = try ResidentSnapshotRingState(slotCount: 2, expectedByteCount: 128)
        let first = try XCTUnwrap(ring.reserveForWrite())
        ring.publish(first, sourceEpoch: 1, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        let active = try XCTUnwrap(ring.acquire(expectedByteCount: 128))

        let second = try XCTUnwrap(ring.reserveForWrite())
        XCTAssertNotEqual(second.slot, active.slot)
        ring.publish(second, sourceEpoch: 2, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)

        XCTAssertNil(ring.reserveForWrite(),
                     "current published slot plus active old generation leaves no recyclable slot")
        XCTAssertEqual(ring.diagnostics.skippedReservationCount, 1)

        ring.release(active)
        let third = try XCTUnwrap(ring.reserveForWrite())
        XCTAssertEqual(third.slot, active.slot)
        XCTAssertGreaterThan(third.generation, second.generation)
    }

    func testResidentSnapshotRingDoesNotRegressPublishedGeneration() throws {
        var ring = try ResidentSnapshotRingState(slotCount: 2, expectedByteCount: 128)
        let older = try XCTUnwrap(ring.reserveForWrite())
        let newer = try XCTUnwrap(ring.reserveForWrite())

        ring.publish(newer, sourceEpoch: 2, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        ring.publish(older, sourceEpoch: 1, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)

        let token = try XCTUnwrap(ring.acquire(expectedByteCount: 128))
        XCTAssertEqual(token.generation, newer.generation)
        XCTAssertEqual(token.sourceEpoch, 2)
        XCTAssertEqual(ring.diagnostics.stalePublicationCount, 1)
    }

    func testResidentSnapshotRingRejectsWrongSizeAndStaleRelease() throws {
        var ring = try ResidentSnapshotRingState(slotCount: 2, expectedByteCount: 128)
        let first = try XCTUnwrap(ring.reserveForWrite())
        ring.publish(first, sourceEpoch: 1, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        let oldToken = try XCTUnwrap(ring.acquire(expectedByteCount: 128))
        XCTAssertNil(ring.acquire(expectedByteCount: 64))
        XCTAssertEqual(ring.diagnostics.failedAcquireCount, 1)
        ring.release(oldToken)

        let second = try XCTUnwrap(ring.reserveForWrite())
        ring.publish(second, sourceEpoch: 2, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        let third = try XCTUnwrap(ring.reserveForWrite())
        XCTAssertEqual(third.slot, oldToken.slot)
        ring.publish(third, sourceEpoch: 3, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        let current = try XCTUnwrap(ring.acquire(expectedByteCount: 128))

        ring.release(oldToken)
        XCTAssertEqual(ring.diagnostics.staleReleaseCount, 1)
        XCTAssertEqual(ring.diagnostics.activeLeaseCount, 1,
                       "stale release for an older generation must not free the new one")

        ring.release(current)
        XCTAssertEqual(ring.diagnostics.activeLeaseCount, 0)
    }

    func testResidentSnapshotRingSkipsSafelyWhenGenerationExhausted() throws {
        var ring = try ResidentSnapshotRingState(slotCount: 2,
                                                 expectedByteCount: 128,
                                                 initialNextGeneration: UInt64.max - 1)
        let lastPublishable = try XCTUnwrap(ring.reserveForWrite())
        XCTAssertEqual(lastPublishable.generation, UInt64.max - 1)
        ring.publish(lastPublishable, sourceEpoch: 41, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        let published = try XCTUnwrap(ring.acquire(expectedByteCount: 128))

        XCTAssertNil(ring.reserveForWrite(),
                     "exhausted generations must skip without wrapping")
        let diagnostics = ring.diagnostics
        XCTAssertEqual(diagnostics.nextGeneration, UInt64.max)
        XCTAssertEqual(diagnostics.generationExhaustedReservationCount, 1)
        XCTAssertEqual(diagnostics.skippedReservationCount, 1)
        XCTAssertEqual(diagnostics.publishedGeneration, UInt64.max - 1)
        XCTAssertEqual(diagnostics.publishedSourceEpoch, 41)
        XCTAssertEqual(published.generation, UInt64.max - 1)

        ring.release(published)
    }

    func testResidentSnapshotRingStaleCancellationDoesNotCancelReusedSlot() throws {
        var ring = try ResidentSnapshotRingState(slotCount: 2, expectedByteCount: 128)
        let older = try XCTUnwrap(ring.reserveForWrite())
        let newer = try XCTUnwrap(ring.reserveForWrite())

        ring.publish(newer, sourceEpoch: 2, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        ring.publish(older, sourceEpoch: 1, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        let reused = try XCTUnwrap(ring.reserveForWrite())
        XCTAssertEqual(reused.slot, older.slot)

        ring.cancel(older)
        XCTAssertEqual(ring.diagnostics.cancelledReservationCount, 0)
        XCTAssertEqual(ring.diagnostics.writingSlotCount, 1)
        XCTAssertTrue(ring.diagnostics.slots[reused.slot].isWriting)

        ring.publish(reused, sourceEpoch: 3, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)
        let token = try XCTUnwrap(ring.acquire(expectedByteCount: 128))
        XCTAssertEqual(token.sourceEpoch, 3)
        XCTAssertEqual(ring.diagnostics.stalePublicationCount, 1)
    }

    func testResidentSnapshotRingCancellationRetainsPreviousPublication() throws {
        var ring = try ResidentSnapshotRingState(slotCount: 2, expectedByteCount: 128)
        let first = try XCTUnwrap(ring.reserveForWrite())
        ring.publish(first, sourceEpoch: 1, byteCount: 128,
                     blitHostSeconds: nil, blitGPUSeconds: nil)

        let failed = try XCTUnwrap(ring.reserveForWrite())
        ring.cancel(failed)

        let token = try XCTUnwrap(ring.acquire(expectedByteCount: 128))
        XCTAssertEqual(token.slot, first.slot)
        XCTAssertEqual(token.generation, first.generation)
        XCTAssertEqual(token.sourceEpoch, 1)
        XCTAssertEqual(ring.diagnostics.publishCount, 1)
        XCTAssertEqual(ring.diagnostics.cancelledReservationCount, 1)
    }

    func testResidentRenderDecisionSelectsLeasedSnapshotForTransitionAndCloseLOD() {
        for blend in [Float(0.5), Float(1)] {
            let decision = ResidentRenderDecision.decide(expectedByteCount: 128,
                                                         leaseByteCount: 128,
                                                         expectedOverviewWidth: 512,
                                                         expectedOverviewHeight: 256,
                                                         leaseOverviewWidth: 512,
                                                         leaseOverviewHeight: 256,
                                                         microBlend: blend)
            XCTAssertTrue(decision.usesLeasedSnapshot)
            XCTAssertEqual(decision.source, .leasedSnapshot)
            XCTAssertNil(decision.fallbackReason)
        }
    }

    func testResidentRenderDecisionFallsBackWhenSnapshotUnavailable() {
        let decision = ResidentRenderDecision.decide(expectedByteCount: 128,
                                                     leaseByteCount: nil,
                                                     expectedOverviewWidth: 512,
                                                     expectedOverviewHeight: 256,
                                                     leaseOverviewWidth: nil,
                                                     leaseOverviewHeight: nil,
                                                     microBlend: 1)
        XCTAssertFalse(decision.usesLeasedSnapshot)
        XCTAssertEqual(decision.source, .liveOverview)
        XCTAssertEqual(decision.fallbackReason, .unavailable)
    }

    func testResidentRenderDecisionFallsBackForWrongSizedSnapshot() {
        let wrongSoup = ResidentRenderDecision.decide(expectedByteCount: 128,
                                                      leaseByteCount: 64,
                                                      expectedOverviewWidth: 512,
                                                      expectedOverviewHeight: 256,
                                                      leaseOverviewWidth: 512,
                                                      leaseOverviewHeight: 256,
                                                      microBlend: 1)
        XCTAssertFalse(wrongSoup.usesLeasedSnapshot)
        XCTAssertEqual(wrongSoup.source, .liveOverview)
        XCTAssertEqual(wrongSoup.fallbackReason, .wrongByteCount(expected: 128, actual: 64))

        let wrongOverview = ResidentRenderDecision.decide(expectedByteCount: 128,
                                                          leaseByteCount: 128,
                                                          expectedOverviewWidth: 512,
                                                          expectedOverviewHeight: 256,
                                                          leaseOverviewWidth: 256,
                                                          leaseOverviewHeight: 256,
                                                          microBlend: 1)
        XCTAssertFalse(wrongOverview.usesLeasedSnapshot)
        XCTAssertEqual(wrongOverview.source, .liveOverview)
        XCTAssertEqual(wrongOverview.fallbackReason,
                       .wrongOverviewSize(expectedWidth: 512, expectedHeight: 256,
                                          actualWidth: 256, actualHeight: 256))
    }

    func testResidentRenderDecisionKeepsFarLODOnOverviewTextureWithoutLease() {
        XCTAssertFalse(ResidentRenderDecision.requiresSnapshotLease(microBlend: 0))
        let decision = ResidentRenderDecision.decide(expectedByteCount: nil,
                                                     leaseByteCount: nil,
                                                     expectedOverviewWidth: 512,
                                                     expectedOverviewHeight: 256,
                                                     leaseOverviewWidth: nil,
                                                     leaseOverviewHeight: nil,
                                                     microBlend: 0)
        XCTAssertFalse(decision.usesLeasedSnapshot)
        XCTAssertEqual(decision.source, .liveOverview)
        XCTAssertEqual(decision.fallbackReason, .farLOD(microBlend: 0))
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
    private func eventuallyAcquireSnapshot(_ gpu: ResidentMetalEpochRunner,
                                           expectedByteCount: Int,
                                           minimumSourceEpoch: Int,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) -> ResidentGPUSnapshotLease? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let lease = gpu.acquireResidentSnapshot(expectedByteCount: expectedByteCount) {
                if lease.sourceEpoch >= minimumSourceEpoch {
                    return lease
                }
                lease.release()
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("resident snapshot was not published", file: file, line: line)
        return nil
    }

    func testResidentSnapshotLeaseCarriesPairedSoupAndOverviewPublication() throws {
        let config = try ResidentEpochConfig(seed: 3,
                                             programCount: 16,
                                             visualizationEnabled: true,
                                             visualizationWidth: 8)
        let gpu: ResidentMetalEpochRunner
        do {
            gpu = try ResidentMetalEpochRunner(config: config)
        } catch ResidentMetalEpochRunner.RunnerError.noDevice {
            throw XCTSkip("no Metal device available")
        }

        XCTAssertNil(gpu.acquireResidentSnapshot(expectedByteCount: config.soupByteCount),
                     "no snapshot lease may be visible before the first coherent soup+overview publication")
        let initialDiagnostics = gpu.residentSnapshotDiagnostics
        XCTAssertNil(initialDiagnostics.publishedSlot)
        XCTAssertNil(initialDiagnostics.publishedSourceEpoch)
        XCTAssertEqual(initialDiagnostics.publishCount, 0)

        _ = try gpu.runEpoch()
        let lease = try XCTUnwrap(eventuallyAcquireSnapshot(
            gpu,
            expectedByteCount: config.soupByteCount,
            minimumSourceEpoch: 1))
        defer { lease.release() }

        let diagnostics = gpu.residentSnapshotDiagnostics
        XCTAssertEqual(Optional(lease.slot), diagnostics.publishedSlot)
        XCTAssertEqual(Optional(lease.generation), diagnostics.publishedGeneration)
        XCTAssertEqual(Optional(lease.sourceEpoch), diagnostics.publishedSourceEpoch)
        XCTAssertEqual(diagnostics.publishCount, 1)
        XCTAssertEqual(lease.sourceEpoch, 1)
        XCTAssertEqual(lease.byteCount, config.soupByteCount)
        XCTAssertEqual(lease.buffer.label, Optional("resident.snapshot[\(lease.slot)]"))
        XCTAssertEqual(lease.overviewTexture.label,
                       Optional("resident.snapshotOverview[\(lease.slot)]"))
        XCTAssertEqual(lease.overviewTexture.width, config.visualizationWidth)
        XCTAssertEqual(lease.overviewTexture.height,
                       (config.programCount + config.visualizationWidth - 1)
                       / config.visualizationWidth)
    }

    func testResidentSnapshotLeaseReleasesFromActualCommandBufferCompletion() throws {
        let config = try ResidentEpochConfig(seed: 3,
                                             programCount: 16,
                                             visualizationEnabled: true,
                                             visualizationWidth: 8)
        let gpu: ResidentMetalEpochRunner
        do {
            gpu = try ResidentMetalEpochRunner(config: config)
        } catch ResidentMetalEpochRunner.RunnerError.noDevice {
            throw XCTSkip("no Metal device available")
        }

        _ = try gpu.runEpoch()
        let lease = try XCTUnwrap(eventuallyAcquireSnapshot(
            gpu,
            expectedByteCount: config.soupByteCount,
            minimumSourceEpoch: 1))
        XCTAssertEqual(gpu.residentSnapshotDiagnostics.activeLeaseCount, 1)

        guard let commandBuffer = gpu.commandQueue.makeCommandBuffer() else {
            XCTFail("could not create command buffer")
            lease.release()
            return
        }
        lease.releaseOnCommandBufferCompletion(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertNil(commandBuffer.error)
        XCTAssertEqual(gpu.residentSnapshotDiagnostics.activeLeaseCount, 0)
    }

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
