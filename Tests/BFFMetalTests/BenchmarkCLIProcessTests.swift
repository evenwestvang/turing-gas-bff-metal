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
    /// schemaVersion-2 envelope with an empty `results` array and exits 2. On a Metal
    /// host the same invocation actually runs, so we only require schemaVersion 2 and a
    /// documented exit code.
    func testNoSamplesFlagPropagatesAndSchemaIsStable() throws {
        let r = try runBench(["--programs", "2", "--seed", "1",
                              "--warmup", "0", "--epochs", "1", "--no-samples"])

        #if canImport(Metal)
        // Metal host: it ran. Require the schema marker and one of the valid codes.
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 2)
        XCTAssertTrue([BenchmarkExitCodeValue.success,
                       BenchmarkExitCodeValue.runtimeFailure,
                       BenchmarkExitCodeValue.gpuTimingUnavailable].contains(r.status),
                      "unexpected exit code \(r.status)")
        #else
        // No Metal: nothing ran — exit 2 with an explicit empty results array.
        XCTAssertEqual(r.status, 2, "non-Metal valid config exits 2 (nothing ran)")
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 2, "schemaVersion 2 emitted")
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
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 2)
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
}

/// Local mirror of the documented exit codes, so the Metal-host branch above can name
/// them without importing the CLI (the executable is not importable) and without a
/// magic-number literal.
private enum BenchmarkExitCodeValue {
    static let success: Int32 = 0
    static let runtimeFailure: Int32 = 1
    static let gpuTimingUnavailable: Int32 = 3
}
