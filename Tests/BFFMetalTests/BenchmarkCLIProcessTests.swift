import XCTest
import Foundation

/// Process-level coverage for the built `bff-metal-bench` executable (blocker 5).
///
/// These tests spawn the ACTUAL compiled binary — not the library — so they exercise
/// argument parsing, exit-code mapping, and the emitted JSON envelope end to end, the
/// way a real invocation does. They are:
/// - **bounded**: tiny matrices, no measured epochs where the platform can't run them;
/// - **non-flaky**: if the product hasn't been built yet (`swift test` does not force
///   an executable-product build), each test `XCTSkip`s rather than fails;
/// - **platform-correct**: the "no Metal → exit 2, empty results" assertion is compiled
///   in only on non-Metal hosts, so a Metal-capable host never asserts "no Metal".
final class BenchmarkCLIProcessTests: XCTestCase {

    private struct RunResult { let status: Int32; let stdout: String; let stderr: String }

    /// Directory holding the built products (and the xctest bundle) for this build.
    private func productsDirectory() -> URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not locate the products directory")
        #else
        return Bundle.main.bundleURL
        #endif
    }

    /// URL of the built `bff-metal-bench`, or skip the test if it isn't present.
    private func benchURL() throws -> URL {
        let url = productsDirectory().appendingPathComponent("bff-metal-bench")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("bff-metal-bench not built at \(url.path); run `swift build` first")
        }
        return url
    }

    private func runBench(_ args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = try benchURL()
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain both pipes before waiting so a large document can't deadlock the pipe.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus,
                         stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self))
    }

    // MARK: - Usage errors happen before any Metal work

    /// A malformed strict seed token is a usage error (exit 64), decided during
    /// argument parsing — before Metal initialization — on every platform.
    func testMalformedSeedExitsUsage64BeforeMetal() throws {
        // Value beyond the UInt32 seed domain: strict parser rejects, never truncates.
        let outside = try runBench(["--seed", "4294967296", "--programs", "2"])
        XCTAssertEqual(outside.status, 64, "out-of-range seed must be a usage error")
        XCTAssertTrue(outside.stderr.lowercased().contains("seed"),
                      "usage error should name the offending seed")

        // A doubled comma yields an empty token, also rejected (not silently dropped).
        let empty = try runBench(["--seeds", "1,,3", "--programs", "2"])
        XCTAssertEqual(empty.status, 64)

        // Non-decimal token.
        let junk = try runBench(["--seed", "0x10", "--programs", "2"])
        XCTAssertEqual(junk.status, 64)
    }

    // MARK: - --no-samples propagation and schema behavior

    /// `--no-samples` is accepted and propagated; on a non-Metal host the run emits a
    /// schemaVersion-3 envelope with an empty `results` array and exits 2. On a Metal
    /// host the same invocation actually runs, so we only require schemaVersion 3 and a
    /// documented exit code.
    func testNoSamplesFlagPropagatesAndSchemaIsStable() throws {
        let r = try runBench(["--programs", "2", "--seed", "1",
                              "--warmup", "0", "--epochs", "1", "--no-samples"])

        #if canImport(Metal)
        // Metal host: it ran. Require the schema marker and one of the valid codes.
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 3)
        XCTAssertTrue([BenchmarkExitCodeValue.success,
                       BenchmarkExitCodeValue.runtimeFailure,
                       BenchmarkExitCodeValue.gpuTimingUnavailable].contains(r.status),
                      "unexpected exit code \(r.status)")
        #else
        // No Metal: nothing ran — exit 2 with an explicit empty results array.
        XCTAssertEqual(r.status, 2, "non-Metal valid config exits 2 (nothing ran)")
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 3, "schemaVersion 3 emitted")
        XCTAssertEqual((obj?["results"] as? [Any])?.count, 0, "empty results array")
        XCTAssertTrue(r.stderr.contains("analyzeSignals=false"),
                      "--no-samples propagated to the resolved config")
        #endif
    }

    // MARK: - Compression option/cadence propagation and exit-code mapping

    /// `--compression` is accepted (opt-in) and propagated to the resolved config; it
    /// does not change the exit-code mapping (still 2 on a non-Metal host). Combined
    /// with `--no-samples` it is ignored with an explicit stderr note.
    func testCompressionPropagationAndIgnoreUnderNoSamples() throws {
        let r = try runBench(["--programs", "2", "--seed", "1",
                              "--warmup", "0", "--epochs", "1",
                              "--compression", "--sample-interval", "2"])
        #if canImport(Metal)
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 3)
        #else
        XCTAssertEqual(r.status, 2, "compression does not change the no-Metal exit code")
        XCTAssertTrue(r.stderr.contains("compression=true"),
                      "--compression propagated to the resolved config")
        #endif

        // --compression under --no-samples: accepted, but explicitly ignored.
        let ignored = try runBench(["--programs", "2", "--seed", "1",
                                    "--warmup", "0", "--epochs", "1",
                                    "--no-samples", "--compression"])
        XCTAssertTrue(ignored.stderr.contains("--compression is ignored under --no-samples"),
                      "compression-under-no-samples emits the documented note")
        #if !canImport(Metal)
        XCTAssertEqual(ignored.status, 2)
        #endif
    }

    // MARK: - --brotli (paper metric) propagation and gating

    /// `--brotli` is accepted and propagated; it does not change the exit-code mapping
    /// (still 2 on a non-Metal host) and is distinct from `--compression`. Under
    /// `--no-samples` it is ignored with an explicit stderr note.
    func testBrotliPropagationAndIgnoreUnderNoSamples() throws {
        let r = try runBench(["--programs", "2", "--seed", "1",
                              "--warmup", "0", "--epochs", "1", "--brotli"])
        #if canImport(Metal)
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 3)
        #else
        XCTAssertEqual(r.status, 2, "brotli does not change the no-Metal exit code")
        XCTAssertTrue(r.stderr.contains("brotli=true"),
                      "--brotli propagated to the resolved config")
        #endif

        // --brotli under --no-samples: accepted, but explicitly ignored.
        let ignored = try runBench(["--programs", "2", "--seed", "1",
                                    "--warmup", "0", "--epochs", "1",
                                    "--no-samples", "--brotli"])
        XCTAssertTrue(ignored.stderr.contains("--brotli is ignored under --no-samples"),
                      "brotli-under-no-samples emits the documented note")
        #if !canImport(Metal)
        XCTAssertEqual(ignored.status, 2)
        #endif
    }

    /// `--high-order-thresholds` parses like the ΔH thresholds; a non-numeric level is a
    /// usage error (exit 64) decided during argument parsing on every platform.
    func testHighOrderThresholdsParsing() throws {
        let bad = try runBench(["--programs", "2", "--seed", "1",
                                "--warmup", "0", "--epochs", "1",
                                "--brotli", "--high-order-thresholds", "1,abc"])
        XCTAssertEqual(bad.status, 64, "non-numeric high-order threshold is a usage error")

        let ok = try runBench(["--programs", "2", "--seed", "1",
                               "--warmup", "0", "--epochs", "2",
                               "--brotli", "--high-order-thresholds", "0.5,1,2"])
        XCTAssertNotEqual(ok.status, 64, "valid high-order thresholds are accepted")
    }

    // MARK: - --signal-interval cadence: parsing, propagation, exit-code policy

    /// A sparse `--signal-interval` combined with `--delta-h-thresholds` is a usage
    /// error (exit 64), decided during argument validation — before any Metal work — on
    /// every platform. Per-epoch `--signal-interval 1` with thresholds is accepted.
    func testSignalIntervalWithThresholdsIsUsageError64() throws {
        let bad = try runBench(["--programs", "2", "--seed", "1",
                                "--warmup", "0", "--epochs", "4",
                                "--signal-interval", "2",
                                "--delta-h-thresholds", "0.1,0.5"])
        XCTAssertEqual(bad.status, 64, "sparse signals + ΔH thresholds must be a usage error")
        XCTAssertTrue(bad.stderr.contains("--delta-h-thresholds")
                      && bad.stderr.contains("--signal-interval"),
                      "usage error names both incompatible options")

        // Non-positive interval is also a usage error.
        let zero = try runBench(["--programs", "2", "--seed", "1",
                                 "--warmup", "0", "--epochs", "1",
                                 "--signal-interval", "0"])
        XCTAssertEqual(zero.status, 64)

        // Per-epoch signals + thresholds: NOT a usage error (accepted).
        let ok = try runBench(["--programs", "2", "--seed", "1",
                               "--warmup", "0", "--epochs", "4",
                               "--signal-interval", "1",
                               "--delta-h-thresholds", "0.1"])
        XCTAssertNotEqual(ok.status, 64, "per-epoch signals with thresholds is allowed")
    }

    /// Cadence-only signal analysis (sparse interval, no thresholds) is accepted and the
    /// resolved interval is propagated. On a non-Metal host the would-run echo carries it.
    func testSignalIntervalPropagatesWhenCadenceOnly() throws {
        let r = try runBench(["--programs", "2", "--seed", "1",
                              "--warmup", "0", "--epochs", "6",
                              "--signal-interval", "3"])
        #if canImport(Metal)
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 3)
        XCTAssertNotEqual(r.status, 64, "cadence-only analysis is not a usage error")
        #else
        XCTAssertEqual(r.status, 2, "cadence-only signal analysis does not change the exit code")
        XCTAssertTrue(r.stderr.contains("signalInterval=3"),
                      "--signal-interval propagated to the resolved config")
        #endif
    }

    /// `--signal-interval` under `--no-samples` is accepted but explicitly ignored.
    func testSignalIntervalIgnoredUnderNoSamples() throws {
        let r = try runBench(["--programs", "2", "--seed", "1",
                              "--warmup", "0", "--epochs", "4",
                              "--no-samples", "--signal-interval", "2"])
        XCTAssertTrue(r.stderr.contains("--signal-interval is ignored under --no-samples"),
                      "signal-interval-under-no-samples emits the documented note")
        #if !canImport(Metal)
        XCTAssertEqual(r.status, 2)
        #endif
    }

    /// The sparse-signals + ΔH-thresholds incompatibility only exists when signals are
    /// actually analyzed. Under `--no-samples` no trajectory is measured, so
    /// `--no-samples --signal-interval 2 --delta-h-thresholds 0.1` must NOT exit usage 64
    /// solely for cadence — the flags are accepted and noted as ignored (blocker 2).
    func testNoSamplesWithSparseSignalsAndThresholdsIsNotUsageError() throws {
        let r = try runBench(["--programs", "2", "--seed", "1",
                              "--warmup", "0", "--epochs", "4",
                              "--no-samples", "--signal-interval", "2",
                              "--delta-h-thresholds", "0.1"])
        XCTAssertNotEqual(r.status, 64,
                          "sparse signals + thresholds under --no-samples is not a usage error")
        XCTAssertTrue(r.stderr.contains("--signal-interval is ignored under --no-samples"),
                      "signal-interval ignored note emitted")
        XCTAssertTrue(r.stderr.contains("--delta-h-thresholds is ignored under --no-samples"),
                      "delta-h-thresholds ignored note emitted")
        #if !canImport(Metal)
        XCTAssertEqual(r.status, 2, "nothing runs on a non-Metal host")
        #endif

        // Guard against regressing the *analyzing* path: the same sparse+thresholds combo
        // WITHOUT --no-samples is still a usage error (exit 64).
        let analyzing = try runBench(["--programs", "2", "--seed", "1",
                                      "--warmup", "0", "--epochs", "4",
                                      "--signal-interval", "2",
                                      "--delta-h-thresholds", "0.1"])
        XCTAssertEqual(analyzing.status, 64,
                       "sparse signals + thresholds while analyzing remains a usage error")
    }
}

/// Local mirror of the documented exit codes, so the Metal-host branch above can name
/// them without importing the CLI (the executable is not importable) and without a
/// magic-number literal.
private enum BenchmarkExitCodeValue {
    static let success: Int32 = 0
    static let runtimeFailure: Int32 = 1
    static let gpuTimingUnavailable: Int32 = 3
}
