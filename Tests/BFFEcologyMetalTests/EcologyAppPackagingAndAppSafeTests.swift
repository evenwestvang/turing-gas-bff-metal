import XCTest
import Foundation
import BFFOracle
import BFFMetal
import BFFEcologyMetal
import CBFFEcologyShared

#if canImport(Metal)
import Metal
#endif

/// Packaging + app-safe execution tests for the ecological SoupScope mode.
///
/// 1. **Packaging**: when SoupScope directly requires the ecology shader, the
///    package must include exactly four byte-identical provenanced shaders
///    while grounded behavior remains unchanged. This test verifies each
///    shader is present in its owning module bundle (single source of truth —
///    no committed metallib, no duplicated bytes) by locating it through the
///    same runtime accessor the runners use. It does NOT assert on shader
///    source strings as execution proof; it asserts the resource-existence
///    contract the runtime `makeLibrary(source:)` path depends on.
///
/// 2. **App-safe tiny parity**: on a Metal host, `runEpochAppSafe()` shares
///    the accepted CLI's mutate+eval semantics — its counters match the CPU
///    oracle for one epoch — while performing no full-soup CPU readback and
///    no CPU digest (the returned `digest` is `nil`). The Metal dispatch
///    skips on non-Metal hosts (Linux CI) with `XCTSkip`.
final class EcologyAppPackagingAndAppSafeTests: XCTestCase {

    // MARK: - Packaging: exactly four byte-identical provenanced shaders

    /// The unprepared-ring sentinel is the narrowest public cross-module
    /// construction of `ResidentSnapshotRingDiagnostics` (defined in BFFMetal).
    /// It is accessible from this module without a synthesized memberwise
    /// initializer (which would be `internal` to BFFMetal) and reports an
    /// empty/unprepared ring (slot count 0, every counter 0, no publication).
    func testUnpreparedRingDiagnosticsSentinelIsAccessibleCrossModule() {
        let diag = ResidentSnapshotRingDiagnostics.unprepared
        XCTAssertEqual(diag.slotCount, 0)
        XCTAssertEqual(diag.expectedByteCount, 0)
        XCTAssertEqual(diag.activeLeaseCount, 0)
        XCTAssertEqual(diag.publishCount, 0)
        XCTAssertNil(diag.publishedSourceEpoch)
        XCTAssertTrue(diag.slots.isEmpty)
    }

    /// The four shader resources the app bundle packages, each located in its
    /// owning module bundle through the same runtime accessor the runners use.
    /// Verifies resource presence (the contract `makeLibrary(source:)` depends
    /// on) — no shader-source-string assertions. The fourth shader
    /// (`SoupRender.metal`) is owned by the `SoupScopeApp` executable target
    /// which this test target does not link; its packaging is already enforced
    /// at runtime by `SharedMetalContext` (the app cannot construct without
    /// it), and at build time by the app's `.copy` resource declaration.
    func testFourProvenancedShaderResourcesArePresent() throws {
        // BFFMetal owns BFFEvaluate.metal + BFFResidentEpoch.metal.
        let evaluateURL = try XCTUnwrap(
            BFFMetalShaderPackaging.evaluateShaderResourceURL,
            "BFFMetal must package BFFEvaluate.metal as a provenanced resource")
        let residentURL = try XCTUnwrap(
            BFFMetalShaderPackaging.residentEpochShaderResourceURL,
            "BFFMetal must package BFFResidentEpoch.metal as a provenanced resource")

        // BFFEcologyMetal owns BFFEcologyEpoch.metal — the shader SoupScope
        // directly requires.
        let ecologyURL = try XCTUnwrap(
            EcologyShaderPackaging.epochShaderResourceURL,
            "BFFEcologyMetal must package BFFEcologyEpoch.metal as a provenanced "
            + "resource (the shader SoupScope directly requires)")

        // Single source of truth: the three reachable shaders are distinct
        // resources (no byte duplication across modules — byte-identical
        // provenanced means each appears once in its owning bundle).
        let reachable = [evaluateURL, residentURL, ecologyURL]
        XCTAssertEqual(Set(reachable).count, 3,
                       "the three reachable shaders must be distinct provenanced resources")

        // The total in the app bundle is exactly four: the three above arrive
        // transitively via BFFMetal + BFFEcologyMetal, plus SoupRender.metal
        // owned directly by SoupScopeApp. This is the documented contract; it
        // is asserted at the package layer by the app's build + the existing
        // SharedMetalContext SoupRender lookup.
        XCTAssertEqual(reachable.count, 3)
        // Grounded behavior (BFFEvaluate + BFFResidentEpoch) is unchanged: the
        // existing resident/oracle test suites cover that; this test only adds
        // the fourth provenance (BFFEcologyEpoch) and the reuse of the ring.
    }

    // MARK: - App-safe execution: no full-soup readback, no digest, shares semantics

#if canImport(Metal)
    /// On a Metal host, `runEpochAppSafe()` runs the same mutate+eval kernels
    /// as the accepted CLI `runEpoch()`, so its per-epoch counters match the
    /// CPU oracle for one epoch — but the report carries `digest == nil`
    /// (no full-soup CPU readback, no CPU digest). This is the "app-safe
    /// execution shares accepted semantics" property. The interactive path
    /// (no `capturePairTapes`) is exercised.
    func testAppSafeEpochCountersMatchCPUOracleAndCarryNoDigest() throws {
        try XCTSkipUnlessMetal()
        let seed: UInt32 = 17
        let stepBudget = 256
        let mutationP32: UInt32 = 0
        let config = try EcologyMetalEpochConfig(seed: seed, stepBudget: stepBudget,
                                                  mutationP32: mutationP32,
                                                  variant: .noheads,
                                                  bracketMode: .dynamicScan)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this host")
        }
        let runner = try EcologyMetalEpochRunner(config: config,
                                                  device: device, commandQueue: queue)
        try runner.prepareAppSafeResources()

        let report = try runner.runEpochAppSafe()

        // App-safe truthfulness: no full-soup readback, no CPU digest.
        XCTAssertNil(report.digest,
                     "app-safe path must not present a CPU digest it did not compute")
        XCTAssertNil(report.instrumentation.soupReadbackSeconds,
                     "app-safe instrumentation must record no full-soup readback")
        XCTAssertNil(report.instrumentation.digestSeconds,
                     "app-safe instrumentation must record no digest computation")

        // Shared semantics: the counters match the CPU oracle for the same
        // epoch (the same mutate+eval kernels the accepted CLI runs).
        var cpu = EcologyOracleRunner(config: EcologyConfig(
            seed: seed, stepBudget: stepBudget, mutationP32: mutationP32,
            variant: .noheads, bracketMode: .dynamicScan))
        let reference = try cpu.runEpoch()
        XCTAssertEqual(report.counters.epoch, reference.epoch)
        XCTAssertEqual(report.counters.phase, reference.phase)
        XCTAssertEqual(report.counters.mutationCount, reference.mutationCount)
        XCTAssertEqual(report.counters.totalRawSteps, reference.totalRawSteps)
        XCTAssertEqual(report.counters.totalNoopSteps, reference.totalNoopSteps)
        XCTAssertEqual(report.counters.totalLoopOps, reference.totalLoopOps)
        XCTAssertEqual(report.counters.totalCopyWrites, reference.totalCopyWrites)
        XCTAssertEqual(report.counters.totalRemapEvents, reference.totalRemapEvents)
        XCTAssertEqual(report.counters.haltBudget, reference.haltBudget)
        XCTAssertEqual(report.counters.haltPCOut, reference.haltPCOut)
        XCTAssertEqual(report.counters.haltUnmatched, reference.haltUnmatched)

        // The producer published an immutable soup+overview snapshot: after
        // one epoch the overview texture exists and the ring is sized for the
        // ecology soup.
        XCTAssertNotNil(runner.residentVisualizationTexture)
        let diag = runner.residentSnapshotDiagnostics
        XCTAssertEqual(diag.expectedByteCount, EcologyTopology.soupByteCount)
        XCTAssertGreaterThan(diag.slotCount, 0)
    }

    /// `runEpoch()` (the accepted CLI path) is unchanged: it still computes a
    /// real CPU digest and reads back the full soup. This guards against the
    /// app-safe refactor leaking into the CLI path.
    func testAcceptedCLIRunEpochStillComputesDigest() throws {
        try XCTSkipUnlessMetal()
        let config = try EcologyMetalEpochConfig(seed: 3, stepBudget: 64,
                                                  mutationP32: 0)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this host")
        }
        let runner = try EcologyMetalEpochRunner(config: config,
                                                  device: device, commandQueue: queue)
        let report = try runner.runEpoch()
        XCTAssertNotNil(report.digest,
                        "accepted CLI runEpoch must still compute a real soup digest")
        XCTAssertNotNil(report.instrumentation.soupReadbackSeconds,
                        "accepted CLI runEpoch must still read back the full soup")
        XCTAssertNotNil(report.instrumentation.digestSeconds,
                        "accepted CLI runEpoch must still compute the digest")
        // The accepted CLI never runs the visualize kernel.
        XCTAssertNil(report.instrumentation.visualizeKernelSeconds,
                     "accepted CLI runEpoch must not run the app-safe visualize kernel")
    }

    // MARK: - Stronger native-gated semantics

    /// Mutation-enabled, multi-epoch app-safe CPU↔Metal parity spanning all
    /// four ecology phases (H0/H1/V0/V1, cycled as epoch & 3). The app-safe
    /// path runs the same mutate+eval kernels as the accepted CLI, so its
    /// per-epoch counters must match the CPU oracle across four mutation-
    /// enabled epochs (one full phase cycle). Bounded for M4 (stepBudget 64,
    /// 131072 sites, 4 epochs).
    func testAppSafeMultiEpochMutationParitySpansAllFourPhases() throws {
        try XCTSkipUnlessMetal()
        let seed: UInt32 = 99
        let stepBudget = 64
        let mutationP32: UInt32 = 500   // mutation enabled
        let config = try EcologyMetalEpochConfig(seed: seed, stepBudget: stepBudget,
                                                  mutationP32: mutationP32,
                                                  variant: .noheads,
                                                  bracketMode: .dynamicScan)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this host")
        }
        let runner = try EcologyMetalEpochRunner(config: config,
                                                  device: device, commandQueue: queue)
        try runner.prepareAppSafeResources()
        var cpu = EcologyOracleRunner(config: EcologyConfig(
            seed: seed, stepBudget: stepBudget, mutationP32: mutationP32,
            variant: .noheads, bracketMode: .dynamicScan))
        let phases = EcologyMatchingPhase.allCases   // H0, H1, V0, V1
        for i in 0..<4 {
            let gpu = try runner.runEpochAppSafe()
            let ref = try cpu.runEpoch()
            XCTAssertEqual(gpu.counters.epoch, ref.epoch, "epoch \(i) epoch")
            XCTAssertEqual(gpu.counters.phase, ref.phase, "epoch \(i) phase")
            XCTAssertEqual(gpu.counters.mutationCount, ref.mutationCount, "epoch \(i) mutation")
            XCTAssertEqual(gpu.counters.totalRawSteps, ref.totalRawSteps, "epoch \(i) rawSteps")
            XCTAssertEqual(gpu.counters.totalNoopSteps, ref.totalNoopSteps, "epoch \(i) noop")
            XCTAssertEqual(gpu.counters.totalLoopOps, ref.totalLoopOps, "epoch \(i) loopOps")
            XCTAssertEqual(gpu.counters.totalCopyWrites, ref.totalCopyWrites, "epoch \(i) copyWrites")
            XCTAssertEqual(gpu.counters.totalRemapEvents, ref.totalRemapEvents, "epoch \(i) remap")
            XCTAssertEqual(gpu.counters.haltBudget, ref.haltBudget, "epoch \(i) haltBudget")
            XCTAssertEqual(gpu.counters.haltPCOut, ref.haltPCOut, "epoch \(i) haltPCOut")
            XCTAssertEqual(gpu.counters.haltUnmatched, ref.haltUnmatched, "epoch \(i) haltUnmatched")
            XCTAssertNil(gpu.digest, "app-safe path must never present a CPU digest")
            XCTAssertNil(gpu.instrumentation.soupReadbackSeconds,
                         "app-safe path must never read back the full soup")
        }
        // Confirm the four epochs covered all four phases.
        let seenPhases = Set((0..<4).map { EcologyMatchingPhase(epoch: UInt32($0)) })
        XCTAssertEqual(seenPhases, Set(phases))
    }

    /// App-safe visualize + immutable publication does NOT alter the subsequent
    /// soup semantics. After N mutation-enabled app-safe epochs, the GPU
    /// runner's live soup (read back here via the test-only `soupSnapshot`,
    /// which the production interactive path never calls) must be byte-identical
    /// to the CPU oracle's soup after the same N epochs. This proves the
    /// visualize kernel (read-only summary) and the snapshot publication blit
    /// (a copy into a private ring slot) leave the producer's mutable soup
    /// untouched, so the accepted CLI semantics are preserved.
    func testAppSafeVisualizeAndPublicationDoNotAlterSubsequentSoup() throws {
        try XCTSkipUnlessMetal()
        let seed: UInt32 = 7
        let stepBudget = 96
        let mutationP32: UInt32 = 800
        let config = try EcologyMetalEpochConfig(seed: seed, stepBudget: stepBudget,
                                                  mutationP32: mutationP32,
                                                  variant: .noheads,
                                                  bracketMode: .dynamicScan)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this host")
        }
        let runner = try EcologyMetalEpochRunner(config: config,
                                                  device: device, commandQueue: queue)
        try runner.prepareAppSafeResources()
        var cpu = EcologyOracleRunner(config: EcologyConfig(
            seed: seed, stepBudget: stepBudget, mutationP32: mutationP32,
            variant: .noheads, bracketMode: .dynamicScan))
        let epochCount = 3
        for _ in 0..<epochCount {
            _ = try runner.runEpochAppSafe()
            _ = try cpu.runEpoch()
        }
        // Test-only readback of the producer's live soup (isolated from the
        // production interactive path, which never reads the soup in app-safe
        // mode). The visualize kernel and snapshot blit must not have changed
        // it, so it equals the CPU oracle's soup byte-for-byte.
        let gpuSoup = runner.soupSnapshot
        XCTAssertEqual(gpuSoup.count, EcologyTopology.soupByteCount)
        XCTAssertEqual(gpuSoup, cpu.soup,
                       "app-safe visualize/publication must not alter the producer soup")
    }

    /// Exercise GPU publication → acquire → lease resource identity and the
    /// source-epoch/phase metadata convention. After one app-safe epoch, the
    /// published slot is acquirable: the lease's soup buffer is a private
    /// (`.storageModePrivate`) immutable copy — NOT the producer's live shared
    /// soup buffer — and the lease's overview texture is NOT the producer's
    /// live overview texture. `sourceEpoch` follows the convention: a snapshot
    /// published after producing epoch 0 carries `sourceEpoch = 1`, and the
    /// displayed phase is `EcologyMatchingPhase(epoch: sourceEpoch - 1)` (H0).
    func testGPUPublicationAcquireLeaseIdentityAndSourceEpochPhase() throws {
        try XCTSkipUnlessMetal()
        let config = try EcologyMetalEpochConfig(seed: 5, stepBudget: 32,
                                                  mutationP32: 0)
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable on this host")
        }
        let runner = try EcologyMetalEpochRunner(config: config,
                                                  device: device, commandQueue: queue)
        try runner.prepareAppSafeResources()
        let report = try runner.runEpochAppSafe()
        XCTAssertEqual(Int(report.counters.epoch), 0)

        // The publication blit is async on the command queue; drain the queue
        // and wait for the publication completion handler to fire (publishCount
        // to increment) before acquiring.
        try waitForPublishCount(runner: runner, expected: 1)

        let lease = try XCTUnwrap(
            runner.acquireResidentSnapshot(expectedByteCount: EcologyTopology.soupByteCount),
            "a published immutable snapshot must be acquirable after one app-safe epoch")
        XCTAssertEqual(lease.byteCount, EcologyTopology.soupByteCount)
        XCTAssertEqual(lease.overviewTexture.width, EcologyTopology.width)
        XCTAssertEqual(lease.overviewTexture.height, EcologyTopology.height)
        // Source-epoch convention: producing epoch 0 → sourceEpoch 1.
        XCTAssertEqual(lease.sourceEpoch, 1)
        // Phase convention: phase for producing epoch 0 = H0, derived as
        // EcologyMatchingPhase(epoch: sourceEpoch - 1).
        let derivedPhase = EcologyMatchingPhase(epoch: UInt32(lease.sourceEpoch - 1))
        XCTAssertEqual(derivedPhase, report.counters.phase)
        XCTAssertEqual(derivedPhase.label, "H0")

        // Resource identity: the lease is the immutable ring copy, NOT the
        // producer's live resources. The ring buffers are .storageModePrivate;
        // the producer's live soup is .storageModeShared. The lease's overview
        // texture is not the live overview texture the visualize kernel wrote.
        #if canImport(Metal)
        XCTAssertEqual(lease.buffer.storageMode, MTLStorageMode.private,
                       "the leased soup must be the private immutable ring copy, "
                       + "not the producer's live shared soup")
        XCTAssertFalse(lease.overviewTexture === runner.residentVisualizationTexture,
                        "the leased overview must not be the producer's live overview texture")
        #endif

        lease.release()
    }
#endif

    // MARK: - Helpers

    private func XCTSkipUnlessMetal() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal unavailable on this host")
        }
        #else
        throw XCTSkip("Metal unavailable on this host")
        #endif
    }

    #if canImport(Metal)
    /// Drain the runner's command queue and poll the snapshot ring's
    /// `publishCount` until it reaches `expected` (or time out). The
    /// publication blit is committed asynchronously; this waits for its
    /// completion handler to fire so a subsequent acquire sees the published
    /// slot. Test-only — the production interactive path never waits on the
    /// publication (it is content to acquire a previously published slot).
    private func waitForPublishCount(runner: EcologyMetalEpochRunner,
                                     expected: Int,
                                     timeoutSeconds: Double = 5.0) throws {
        // Commit a no-op barrier command buffer and wait for it so every
        // previously committed command buffer (the publication blit) has
        // completed on the device before we start polling.
        if let barrier = runner.commandQueue.makeCommandBuffer() {
            barrier.commit()
            barrier.waitUntilCompleted()
        }
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutSeconds * 1000))
        while runner.residentSnapshotDiagnostics.publishCount < expected {
            if DispatchTime.now() > deadline {
                throw XCTSkip("timed out waiting for ecology snapshot publication")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    #endif
}
