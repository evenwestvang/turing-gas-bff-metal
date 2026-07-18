import XCTest
import BFFOracle
@testable import BFFMetal

/// Focused regression tests for the bounded deterministic optimization of
/// `SoupMetrics` program-entropy allocation churn, parallel metric construction,
/// and `SoupDigest` FNV-1a byte-loop optimization.
///
/// These tests pin the three invariants the optimization must preserve:
/// 1. The allocation-free entropy path is bit-identical to the legacy
///    `ByteHistogram`-based path (same byte-value-order summation).
/// 2. The serial and parallel `programMetrics` paths are element-for-element
///    identical across thresholds and repeated runs.
/// 3. Every pinned soup digest remains unchanged (the 8× unroll preserves FNV-1a),
///    and the full soup/digest/counters/trajectory are preserved end-to-end.
final class SoupMetricsOptimizationTests: XCTestCase {

    // MARK: - 1. Allocation-free entropy == legacy ByteHistogram entropy

    /// The allocation-free `entropyBitsPerByte(soup:start:length:bins:)` path must
    /// return bit-identical values to the legacy `ByteHistogram`-based
    /// `entropyBitsPerByte(_:)` path for every edge case and deterministic random
    /// 64-byte input. `bitPattern` comparison enforces exact IEEE-754 equality.
    func testAllocationFreeEntropyEqualsLegacyExactly() {
        var bins = [UInt64](repeating: 0, count: 256)

        // Edge cases — each embedded in a "soup" at offset 0.
        let edgeCases: [(name: String, bytes: [UInt8])] = [
            ("empty", []),
            ("single-byte", [42]),
            ("two-bytes", [0, 255]),
            ("uniform-64", [UInt8](repeating: 0x41, count: 64)),
            ("64-distinct", (0..<64).map { UInt8($0) }),
            ("two-symbol", (0..<64).map { UInt8($0 % 2 == 0 ? 0x2B : 0x2D) }),
            ("all-256-ascending", (0...255).map { UInt8($0) }),
            ("all-256-descending", (0...255).reversed().map { UInt8($0) }),
            ("all-zero-64", [UInt8](repeating: 0, count: 64)),
            ("all-255-64", [UInt8](repeating: 0xFF, count: 64)),
            ("three-symbols-63", (0..<63).map { UInt8($0 % 3) }),
        ]
        for (name, bytes) in edgeCases {
            let legacy = SoupMetrics.entropyBitsPerByte(bytes)
            let optimized = SoupMetrics.entropyBitsPerByte(soup: bytes, start: 0,
                                                           length: bytes.count,
                                                           bins: &bins)
            XCTAssertEqual(legacy.bitPattern, optimized.bitPattern,
                           "\(name): allocation-free entropy must match legacy bit-for-bit")
        }

        // Deterministic random 64-byte inputs via the pinned counter-pcg-v1 RNG.
        for seed in [UInt32(1), 2, 3, 17, 999, 12345, 4242, 65535] {
            let bytes = BFFRandom.initialSoup(programs: 1, seed: seed)
            let legacy = SoupMetrics.entropyBitsPerByte(bytes)
            let optimized = SoupMetrics.entropyBitsPerByte(soup: bytes, start: 0,
                                                           length: BFF.tapeSize,
                                                           bins: &bins)
            XCTAssertEqual(legacy.bitPattern, optimized.bitPattern,
                           "seed=\(seed): allocation-free entropy must match legacy bit-for-bit")
        }

        // Entropy at a non-zero offset within a larger buffer: the slice
        // [start..<start+64] must match a standalone Array of the same bytes.
        // This is the exact access pattern `programMetrics` uses.
        let big = BFFRandom.initialSoup(programs: 4, seed: 7)
        for id in 0..<4 {
            let start = id * BFF.tapeSize
            let slice = Array(big[start ..< start + BFF.tapeSize])
            let legacy = SoupMetrics.entropyBitsPerByte(slice)
            let optimized = SoupMetrics.entropyBitsPerByte(soup: big, start: start,
                                                           length: BFF.tapeSize,
                                                           bins: &bins)
            XCTAssertEqual(legacy.bitPattern, optimized.bitPattern,
                           "offset \(id): slice entropy must match standalone")
        }
    }

    /// The bins buffer is zeroed and refilled per call, so calling the function
    /// twice with different inputs must not leak counts between calls.
    func testBinsBufferIsZeroedBetweenCalls() {
        var bins = [UInt64](repeating: 0, count: 256)
        let uniform = [UInt8](repeating: 0x41, count: 64)
        let distinct = (0..<64).map { UInt8($0) }

        // Fill with uniform, then distinct, then uniform again — each call must
        // be independent (no stale counts from the previous call).
        let h1 = SoupMetrics.entropyBitsPerByte(soup: uniform, start: 0, length: 64, bins: &bins)
        let h2 = SoupMetrics.entropyBitsPerByte(soup: distinct, start: 0, length: 64, bins: &bins)
        let h3 = SoupMetrics.entropyBitsPerByte(soup: uniform, start: 0, length: 64, bins: &bins)
        XCTAssertEqual(h1, 0.0, "uniform -> 0")
        XCTAssertEqual(h2, 6.0, "64 distinct -> 6")
        XCTAssertEqual(h3, 0.0, "uniform again -> 0 (bins were zeroed)")
    }

    // MARK: - 2. Serial and parallel program metrics are element-for-element identical

    /// The serial and parallel paths of `programMetrics` must produce
    /// element-for-element identical `ProgramMetric` arrays, and the parallel path
    /// must be deterministic across repeated runs (no scheduling-dependent drift).
    func testSerialAndParallelProgramMetricsAreIdentical() throws {
        let programs = 8192 // above parallelThreshold (4096)
        let cfg = try SoupConfig(seed: 42, programCount: programs, stepBudget: 256,
                                 mutationP32: 0, shadowSampleCount: 0)
        let soup = BFFRandom.initialSoup(programs: programs, seed: 42)
        let (_, plan) = SoupPlanner.plan(soup: soup, config: cfg, epoch: 0)

        // Synthetic outcomes: echo each input tape, assign deterministic commandSteps.
        let outcomes = plan.inputTapes.enumerated().map { (p, tape) -> GPUPairOutcome in
            GPUPairOutcome(finalTape: tape,
                           steps: UInt32(10 + (p % 100)),
                           noopSteps: UInt32(p % 5),
                           copyWrites: 0, loopOps: 0,
                           halt: UInt32(HaltReason.budget.rawValue))
        }

        let serial = SoupMetrics.programMetrics(soup: soup, plan: plan, outcomes: outcomes,
                                                programCount: programs, parallel: false)
        let par1 = SoupMetrics.programMetrics(soup: soup, plan: plan, outcomes: outcomes,
                                              programCount: programs, parallel: true)
        let par2 = SoupMetrics.programMetrics(soup: soup, plan: plan, outcomes: outcomes,
                                              programCount: programs, parallel: true)

        XCTAssertEqual(serial.count, programs)
        XCTAssertEqual(par1.count, programs)

        // Element-for-element identical: serial == parallel.
        for id in 0..<programs {
            XCTAssertEqual(serial[id], par1[id],
                           "program \(id) differs between serial and parallel")
        }
        // Parallel path is deterministic across repeated runs.
        XCTAssertEqual(par1, par2, "parallel path must be deterministic across runs")
    }

    /// Below the threshold, the public `programMetrics` runs serially and must match
    /// the forced-parallel path — proving the threshold only selects serial vs
    /// parallel, not different math.
    func testBelowThresholdSerialMatchesForcedParallel() throws {
        let programs = 64 // well below parallelThreshold (4096)
        let cfg = try SoupConfig(seed: 7, programCount: programs, stepBudget: 256,
                                 mutationP32: 0, shadowSampleCount: 0)
        let soup = BFFRandom.initialSoup(programs: programs, seed: 7)
        let (_, plan) = SoupPlanner.plan(soup: soup, config: cfg, epoch: 0)
        let outcomes = plan.inputTapes.enumerated().map { (p, tape) -> GPUPairOutcome in
            GPUPairOutcome(finalTape: tape, steps: UInt32(p + 1), noopSteps: 0,
                           copyWrites: 0, loopOps: 0,
                           halt: UInt32(HaltReason.budget.rawValue))
        }
        let publicResult = SoupMetrics.programMetrics(soup: soup, plan: plan,
                                                      outcomes: outcomes,
                                                      programCount: programs)
        let forced = SoupMetrics.programMetrics(soup: soup, plan: plan, outcomes: outcomes,
                                                programCount: programs, parallel: true)
        XCTAssertEqual(publicResult, forced,
                       "below-threshold serial must match forced parallel")
    }

    /// At the exact threshold boundary, the public path switches to parallel; it
    /// must still match the forced-serial path.
    func testAtThresholdParallelMatchesForcedSerial() throws {
        let programs = SoupMetrics.parallelThreshold
        let cfg = try SoupConfig(seed: 13, programCount: programs, stepBudget: 256,
                                 mutationP32: 0, shadowSampleCount: 0)
        let soup = BFFRandom.initialSoup(programs: programs, seed: 13)
        let (_, plan) = SoupPlanner.plan(soup: soup, config: cfg, epoch: 0)
        let outcomes = plan.inputTapes.enumerated().map { (p, tape) -> GPUPairOutcome in
            GPUPairOutcome(finalTape: tape, steps: UInt32(p + 1), noopSteps: 0,
                           copyWrites: 0, loopOps: 0,
                           halt: UInt32(HaltReason.budget.rawValue))
        }
        let publicResult = SoupMetrics.programMetrics(soup: soup, plan: plan,
                                                      outcomes: outcomes,
                                                      programCount: programs)
        let serial = SoupMetrics.programMetrics(soup: soup, plan: plan, outcomes: outcomes,
                                                programCount: programs, parallel: false)
        XCTAssertEqual(publicResult, serial,
                       "at-threshold parallel must match forced serial")
    }

    // MARK: - 3. Soup / digest / counters / trajectory equivalence

    /// Enabling or disabling per-program metrics must not change the soup trajectory,
    /// digest, or counters — the metric scan is a pure side computation. This pins
    /// that the allocation-free path did not perturb the simulation.
    func testMetricsEnabledVsDisabledPreservesTrajectory() throws {
        let cfg = try SoupConfig(seed: 4242, programCount: 32, mutationP32: 1 << 22,
                                 initMode: .opcode)
        var full = SoupRunner(config: cfg)
        var raw = SoupRunner(config: cfg)
        let cpu = CPUPairEvaluator()
        let epochs = 5
        for _ in 0..<epochs {
            let f = try full.runEpoch(using: cpu, metrics: .enabled)
            let r = try raw.runEpoch(using: cpu, metrics: .disabled)
            XCTAssertEqual(f.counters, r.counters, "counters must match")
            XCTAssertEqual(f.digest, r.digest, "digest must match")
            XCTAssertEqual(f.metrics.count, cfg.programCount)
            XCTAssertTrue(r.metrics.isEmpty)
        }
        XCTAssertEqual(full.soup, raw.soup, "soup trajectory identical")
        XCTAssertEqual(full.digest, raw.digest, "final digest identical")
        XCTAssertEqual(full.programMetricBuildCount, epochs)
        XCTAssertEqual(raw.programMetricBuildCount, 0)
    }

    /// The full epoch trajectory over the CPU reference — soup, digest, counters,
    /// and per-program metrics — is byte-for-byte identical across repeated runs,
    /// proving the optimized metric and digest paths are deterministic.
    func testTrajectoryIsDeterministicAcrossRuns() throws {
        let cfg = try SoupConfig(seed: 1234, programCount: 32, stepBudget: 8192,
                                 mutationP32: 1 << 24, variant: .noheads,
                                 shadowSampleCount: 0)
        let cpu = CPUPairEvaluator()
        var a = SoupRunner(config: cfg)
        var b = SoupRunner(config: cfg)
        let ra = try a.run(epochs: 5, using: cpu)
        let rb = try b.run(epochs: 5, using: cpu)
        XCTAssertEqual(a.soup, b.soup, "soup must be identical across runs")
        XCTAssertEqual(a.digest, b.digest, "digest must be identical across runs")
        for (x, y) in zip(ra, rb) {
            XCTAssertEqual(x.counters, y.counters, "counters must match")
            XCTAssertEqual(x.metrics, y.metrics,
                           "metrics must match element-for-element")
            XCTAssertEqual(x.digest, y.digest, "per-epoch digest must match")
        }
    }

    // MARK: - 4. Pinned digests remain unchanged

    /// The exact FNV-1a digest values captured before the optimization must remain
    /// bit-identical — the 8× unroll and unsafe pointer access preserve the hash.
    func testPinnedDigestsUnchanged() {
        func hex(_ soup: [UInt8]) -> String { SoupDigest.hexString(soup) }

        // Empty input returns the FNV-1a offset basis.
        XCTAssertEqual(hex([]), "cbf29ce484222325", "empty soup digest")
        // Single-byte anchors.
        XCTAssertEqual(hex([0]), "af63bd4c8601b7df", "single byte 0")
        XCTAssertEqual(hex([255]), "af64724c8602eb6e", "single byte 255")
        // All 256 byte values, ascending and descending (order-sensitive).
        XCTAssertEqual(hex((0...255).map { UInt8($0) }), "4242dc5249c33625",
                       "0..255 ascending")
        XCTAssertEqual(hex((0...255).reversed().map { UInt8($0) }), "02a06ff442d86525",
                       "255..0 descending")
        // Seeded initial soups at various sizes.
        XCTAssertEqual(hex(BFFRandom.initialSoup(programs: 8, seed: 1)),
                       "e91e92a98682e5eb")
        XCTAssertEqual(hex(BFFRandom.initialSoup(programs: 8, seed: 7)),
                       "0ac31bac111d0fe1")
        XCTAssertEqual(hex(BFFRandom.initialSoup(programs: 8, seed: 11)),
                       "8b2fc00482bf7840")
        XCTAssertEqual(hex(BFFRandom.initialSoup(programs: 16, seed: 42)),
                       "0c6a14f9874dfc0a")
        XCTAssertEqual(hex(BFFRandom.initialSoup(programs: 16, seed: 99)),
                       "aa8d48d9ff7b963b")
        XCTAssertEqual(hex(BFFRandom.initialSoup(programs: 32, seed: 12345)),
                       "5386a70f632b5a2d")
        // The 131,072-program default-scale soup (the optimization target).
        XCTAssertEqual(hex(BFFRandom.initialSoup(programs: 131_072, seed: 42)),
                       "0e8c2bf6e96eafc8",
                       "131072-program soup digest")
        // Constant soup.
        XCTAssertEqual(hex(BFFRandom.constantSoup(programs: 8)),
                       "7da144b97d054b25")
    }

    /// The golden post-epoch digest from `SliceOracleEquivalenceTests` remains
    /// unchanged after 8 epochs over seed=1234, programs=32 — the end-to-end
    /// trajectory fingerprint is preserved.
    func testGoldenEpochDigestUnchanged() throws {
        let cfg = try SoupConfig(seed: 1234, programCount: 32, stepBudget: 8192,
                                 mutationP32: 1 << 24, variant: .noheads,
                                 shadowSampleCount: 0)
        var runner = SoupRunner(config: cfg)
        try runner.run(epochs: 8, using: CPUPairEvaluator())
        XCTAssertEqual(SoupDigest.hexString(runner.digest), "0e5d7f125243d332",
                       "golden final soup digest after 8 epochs")
    }

    /// Pinned entropy edge-case values — the allocation-free path produces the
    /// same anchor values the legacy path was pinned to.
    func testPinnedEntropyAnchors() {
        var bins = [UInt64](repeating: 0, count: 256)
        XCTAssertEqual(SoupMetrics.entropyBitsPerByte(soup: [], start: 0, length: 0,
                                                      bins: &bins), 0.0,
                       "empty -> 0")
        XCTAssertEqual(SoupMetrics.entropyBitsPerByte(soup: [UInt8](repeating: 0x41, count: 64),
                                                      start: 0, length: 64, bins: &bins), 0.0,
                       "uniform -> 0")
        XCTAssertEqual(SoupMetrics.entropyBitsPerByte(soup: (0..<64).map { UInt8($0) },
                                                      start: 0, length: 64, bins: &bins), 6.0,
                       "64 distinct -> 6")
        let twoSym = (0..<64).map { UInt8($0 % 2 == 0 ? 0x2B : 0x2D) }
        XCTAssertEqual(SoupMetrics.entropyBitsPerByte(soup: twoSym, start: 0, length: 64,
                                                      bins: &bins), 1.0,
                       "two-symbol -> 1")
    }
}
