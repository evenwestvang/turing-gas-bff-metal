import Foundation
import XCTest
@testable import BFFOracle

/// Process-level coverage for the built `bff-ecology-epoch` executable.
///
/// These tests spawn the ACTUAL compiled binary — not the library — so they
/// exercise argument parsing, exit-code mapping, and the emitted output lines
/// end to end, the way a real invocation does. They are:
/// - **bounded**: tiny step budgets, no mutation, few epochs — each epoch is
///   ~65k 1-step pair evaluations plus an 8 MiB soup hash, well under a second;
/// - **non-flaky**: if the product hasn't been built yet (`swift test` does not
///   force an executable-product build), each test `XCTSkip`s rather than fails;
/// - **platform-portable**: the CLI is pure Swift (no Metal), so the same exit
///   codes and output labels are expected on macOS and Linux.
///
/// Coverage areas:
/// - Parsing: strict-lexical rejection of malformed numeric tokens (exit 64).
/// - Stable labeled output: every run emits "Experimental Spatial Ecology" and
///   the engine/topology/scheduler/RNG/evaluator contract IDs.
/// - Continuation: save→restore→run matches an uninterrupted run's final digest.
/// - Rejection: well-mixed fixtures, truncated/empty/oversized/wrong-magic
///   checkpoints all return controlled nonzero errors (never trap).
/// - Info mode: `--info --checkpoint PATH` prints metadata and exits 0.
final class EcologyCLIProcessTests: XCTestCase {

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

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

    /// URL of the built `bff-ecology-epoch`, or skip the test if it isn't present.
    private func cliURL() throws -> URL {
        let url = productsDirectory().appendingPathComponent("bff-ecology-epoch")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("bff-ecology-epoch not built at \(url.path); "
                          + "run `swift build` first")
        }
        return url
    }

    private func runCLI(_ args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = try cliURL()
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain both pipes before waiting so a large document can't deadlock
        // the pipe (e.g. a saved 11 MiB checkpoint would otherwise fill it).
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eco-cli-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Final-line digest extractor. The CLI always prints
    /// `ecology final epoch=N digest=0x<hex> ...` as its last stdout line.
    private func finalDigest(from stdout: String) -> String? {
        for line in stdout.split(separator: "\n").reversed() {
            if line.hasPrefix("ecology final ") {
                if let range = line.range(of: "digest=0x") {
                    let start = range.upperBound
                    let hex = String(line[start...].prefix(16))
                    if hex.count == 16,
                       hex.allSatisfy({ $0.isHexDigit }) {
                        return "0x" + hex
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Help

    func testHelpExitsZeroAndPrintsUsage() throws {
        let r = try runCLI(["--help"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.stdout.contains("usage: bff-ecology-epoch"))
        XCTAssertTrue(r.stdout.contains("Experimental Spatial Ecology"))
    }

    // MARK: - Parsing: strict lexical numeric rejection (exit 64, no trap)

    func testOutOfWorkRangeSeedExits64() throws {
        // 2^32 is one past UInt32.max; strict parser must reject, never truncate.
        let r = try runCLI(["--seed", "4294967296", "--epochs", "0"])
        XCTAssertEqual(r.status, 64, "out-of-range seed must be a usage error")
        XCTAssertTrue(r.stderr.contains("--seed"),
                      "usage error should name the offending flag")
        XCTAssertTrue(r.stderr.contains("out of range"))
    }

    func testHexSeedExits64() throws {
        let r = try runCLI(["--seed", "0x10", "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--seed"))
    }

    func testLeadingWhitespaceSeedExits64() throws {
        let r = try runCLI(["--seed", " 1", "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--seed"))
    }

    func testSignedSeedExits64() throws {
        let r = try runCLI(["--seed", "+1", "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
        let r2 = try runCLI(["--seed", "-1", "--epochs", "0"])
        XCTAssertEqual(r2.status, 64)
    }

    func testDecimalPointSeedExits64() throws {
        let r = try runCLI(["--seed", "1.0", "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
    }

    func testNegativeEpochsExits64() throws {
        let r = try runCLI(["--seed", "1", "--epochs", "-1"])
        XCTAssertEqual(r.status, 64)
    }

    func testNonPositiveBudgetExits64() throws {
        let r = try runCLI(["--seed", "1", "--budget", "0"])
        XCTAssertEqual(r.status, 64)
    }

    func testInvalidVariantExits64() throws {
        let r = try runCLI(["--seed", "1", "--variant", "fast"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--variant"))
    }

    func testInvalidBracketsExits64() throws {
        let r = try runCLI(["--seed", "1", "--brackets", "fast"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--brackets"))
    }

    func testUnknownOptionExits64() throws {
        let r = try runCLI(["--seed", "1", "--nonsense"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("unknown argument"))
    }

    func testMissingSeedWithoutCheckpointExits64() throws {
        let r = try runCLI(["--epochs", "1"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--seed"))
    }

    func testInfoWithoutCheckpointExits64() throws {
        let r = try runCLI(["--info"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--info"))
    }

    func testSeedAndCheckpointMutuallyExclusiveExits64() throws {
        // Even with a valid checkpoint file at the path, the parser rejects the
        // combination before any file is opened.
        let r = try runCLI(["--seed", "1", "--checkpoint", "/dev/null"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("mutually exclusive"))
    }

    func testCheckpointAndBudgetMutuallyExclusiveExits64() throws {
        let r = try runCLI(["--checkpoint", "/dev/null", "--budget", "8"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("--budget"))
    }

    // MARK: - Stable labeled output

    /// Every invocation emits the "Experimental Spatial Ecology" label and the
    /// full set of contract IDs required by §1, on a stable key=value line.
    func testRunEmitsStableLabeledOutput() throws {
        let r = try runCLI(["--seed", "1", "--epochs", "1",
                            "--budget", "1", "--mutation-p32", "0"])
        XCTAssertEqual(r.status, 0, "valid run must succeed")
        // The header line is emitted before any epoch runs.
        XCTAssertTrue(r.stdout.contains("label=\"Experimental Spatial Ecology\""),
                      "header must carry the literal badge")
        XCTAssertTrue(r.stdout.contains("engine=ecology-v1"))
        XCTAssertTrue(r.stdout.contains("topology=torus-512x256-v1"))
        XCTAssertTrue(r.stdout.contains("scheduler=edge-color-sync-v1"))
        XCTAssertTrue(r.stdout.contains("rng=ecology-counter-pcg-v1"))
        XCTAssertTrue(r.stdout.contains("evaluator=bff-evaluator-v1:noheads:dynamicScan"))
        // Every line starts with the `ecology` prefix.
        for line in r.stdout.split(separator: "\n") where !line.isEmpty {
            XCTAssertTrue(line.hasPrefix("ecology "),
                          "line must carry the ecology prefix: \(line)")
        }
        // Final line carries a 16-hex digest.
        XCTAssertNotNil(finalDigest(from: r.stdout),
                        "final digest line must be present and well-formed")
    }

    func testBracketModePropagatesToEvaluatorLabel() throws {
        let r = try runCLI(["--seed", "1", "--epochs", "0",
                            "--brackets", "jumpTable"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.stdout.contains(
            "evaluator=bff-evaluator-v1:noheads:jumpTable"),
            "bracket mode must appear in the evaluator contract label")
    }

    func testVariantPropagatesToEvaluatorLabel() throws {
        let r = try runCLI(["--seed", "1", "--epochs", "0",
                            "--variant", "bff"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.stdout.contains(
            "evaluator=bff-evaluator-v1:bff:dynamicScan"),
            "variant must appear in the evaluator contract label")
    }

    // MARK: - Continuation: save→restore→run matches uninterrupted run

    /// The core save/restore contract (§9): saving at epoch E, restoring, and
    /// running to E + K matches an uninterrupted run to E + K. We split 4 into
    /// (2 + restore + 2) and compare the final digests.
    func testSaveRestoreContinuationMatchesUninterruptedRun() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Uninterrupted: run 4 epochs, save the final state.
        let cp4 = dir.appendingPathComponent("cp4.json")
        let r1 = try runCLI(["--seed", "88", "--epochs", "4",
                              "--budget", "1", "--mutation-p32", "0",
                              "--save", cp4.path])
        XCTAssertEqual(r1.status, 0, "uninterrupted run must succeed")
        guard let digestUninterrupted = finalDigest(from: r1.stdout) else {
            XCTFail("uninterrupted run did not emit a final digest")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cp4.path),
                      "checkpoint file must be written")

        // Split: run 2 epochs, save the intermediate state.
        let cp2 = dir.appendingPathComponent("cp2.json")
        let r2 = try runCLI(["--seed", "88", "--epochs", "2",
                              "--budget", "1", "--mutation-p32", "0",
                              "--save", cp2.path])
        XCTAssertEqual(r2.status, 0)

        // Restore from epoch 2 and run 2 more epochs to reach epoch 4.
        let r3 = try runCLI(["--checkpoint", cp2.path, "--epochs", "2"])
        XCTAssertEqual(r3.status, 0, "restored continuation must succeed")
        guard let digestRestored = finalDigest(from: r3.stdout) else {
            XCTFail("restored run did not emit a final digest")
            return
        }

        XCTAssertEqual(digestRestored, digestUninterrupted,
                       "restored continuation must match the uninterrupted digest")
    }

    /// The same checkpoint restored twice must produce identical final digests
    /// at the same offset (§9 replay definition of done).
    func testSameCheckpointRestoredTwiceYieldsIdenticalDigests() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cp = dir.appendingPathComponent("cp.json")
        let r1 = try runCLI(["--seed", "77", "--epochs", "2",
                              "--budget", "1", "--mutation-p32", "0",
                              "--save", cp.path])
        XCTAssertEqual(r1.status, 0)

        let a = try runCLI(["--checkpoint", cp.path, "--epochs", "2"])
        let b = try runCLI(["--checkpoint", cp.path, "--epochs", "2"])
        XCTAssertEqual(a.status, 0)
        XCTAssertEqual(b.status, 0)
        XCTAssertEqual(finalDigest(from: a.stdout),
                       finalDigest(from: b.stdout),
                       "two restores of the same checkpoint must match")
    }

    /// A zero-epoch run with `--save` captures the initial state; restoring and
    /// running K epochs must match a fresh run of K epochs. This pins the
    /// "epoch-0 checkpoint" as a valid save point.
    func testEpochZeroSaveRestoreMatchesFreshRun() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cp0 = dir.appendingPathComponent("cp0.json")
        let r0 = try runCLI(["--seed", "123", "--epochs", "0",
                              "--budget", "1", "--mutation-p32", "0",
                              "--save", cp0.path])
        XCTAssertEqual(r0.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cp0.path))

        // Initial digest from the epoch-0 save line.
        let initialDigest = finalDigest(from: r0.stdout)

        let fresh = try runCLI(["--seed", "123", "--epochs", "3",
                                 "--budget", "1", "--mutation-p32", "0"])
        let restored = try runCLI(["--checkpoint", cp0.path, "--epochs", "3"])
        XCTAssertEqual(fresh.status, 0)
        XCTAssertEqual(restored.status, 0)
        XCTAssertEqual(finalDigest(from: fresh.stdout),
                       finalDigest(from: restored.stdout),
                       "epoch-0 save→restore must match a fresh run")

        // The epoch-0 checkpoint's initial digest is also the digest reported
        // by the restored run's header (before any epoch executes).
        if let d = initialDigest {
            XCTAssertTrue(restored.stdout.contains("digest=\(d)"),
                         "restored header must echo the saved initial digest")
        }
    }

    // MARK: - Rejection: malformed, truncated, oversized, wrong-engine

    private func writeData(_ data: Data, to dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testEmptyCheckpointFileExits64() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeData(Data(), to: dir, name: "empty.json")
        let r = try runCLI(["--checkpoint", url.path, "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.lowercased().contains("empty"))
    }

    func testTruncatedCheckpointFileExits64() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let truncated = Data("{\"magic\":\"BFFECO1\",".utf8)
        let url = try writeData(truncated, to: dir, name: "truncated.json")
        let r = try runCLI(["--checkpoint", url.path, "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.lowercased().contains("json")
                      || r.stderr.lowercased().contains("checkpoint"))
    }

    func testOversizedCheckpointFileExits64() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // One byte over the loader's hard cap; never parsed as JSON.
        let oversized = Data(count: EcologyCheckpointFile.maxCheckpointBytes + 1)
        let url = try writeData(oversized, to: dir, name: "oversized.json")
        let r = try runCLI(["--checkpoint", url.path, "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.lowercased().contains("oversized")
                      || r.stderr.lowercased().contains("max"))
    }

    func testWrongMagicCheckpointExits64() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a valid ecology checkpoint, then mutate its magic.
        let config = EcologyConfig(seed: 5, stepBudget: 16, mutationP32: 0)
        var soup = [UInt8](repeating: 0, count: EcologyTopology.soupByteCount)
        for site in 0..<EcologyTopology.siteCount {
            soup[site * BFF.tapeSize] = BFFOp.loopClose
        }
        var runner = try EcologyOracleRunner(config: config, soup: soup)
        try runner.runEpoch()
        let data = try EcologyCheckpoint(capturing: runner).jsonData()
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"BFFECO1\"",
                                         with: "\"BFFECO2\"")
        let url = try writeData(Data(text.utf8), to: dir, name: "wrong-magic.json")

        let r = try runCLI(["--checkpoint", url.path, "--epochs", "0"])
        XCTAssertEqual(r.status, 64)
        XCTAssertTrue(r.stderr.contains("magic"))
    }

    func testWellMixedFixtureCheckpointExits64WithClearMessage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a real well-mixed GoldenFixture and pass it as --checkpoint.
        let wellMixed = GoldenFixture(capturing:
            Simulation(config: SimulationConfig(
                seed: 1, populationSize: 8, stepBudget: 8,
                mutationP32: 0, variant: .noheads, bracketMode: .dynamicScan)),
            source: "process-test")
        let data = try wellMixed.jsonData()
        let url = try writeData(data, to: dir, name: "well-mixed.json")

        let r = try runCLI(["--checkpoint", url.path, "--epochs", "0"])
        XCTAssertEqual(r.status, 64, "well-mixed fixture must be rejected")
        XCTAssertTrue(r.stderr.lowercased().contains("well-mixed")
                      || r.stderr.lowercased().contains("wrongengine")
                      || r.stderr.lowercased().contains("ecology"),
                      "rejection should name the engine mismatch: \(r.stderr)")
    }

    // MARK: - Info mode

    func testInfoModePrintsMetadataAndExitsZero() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Save a checkpoint via the CLI itself, then --info it.
        let cp = dir.appendingPathComponent("cp.json")
        let r1 = try runCLI(["--seed", "42", "--epochs", "2",
                              "--budget", "1", "--mutation-p32", "0",
                              "--save", cp.path])
        XCTAssertEqual(r1.status, 0)

        let r2 = try runCLI(["--info", "--checkpoint", cp.path])
        XCTAssertEqual(r2.status, 0, "--info must succeed on a valid checkpoint")
        XCTAssertTrue(r2.stdout.contains("Experimental Spatial Ecology"))
        XCTAssertTrue(r2.stdout.contains("engine=ecology-v1"))
        XCTAssertTrue(r2.stdout.contains("topology=torus-512x256-v1"))
        XCTAssertTrue(r2.stdout.contains("scheduler=edge-color-sync-v1"))
        XCTAssertTrue(r2.stdout.contains("rng=ecology-counter-pcg-v1"))
        XCTAssertTrue(r2.stdout.contains("evaluator=bff-evaluator-v1:noheads:dynamicScan"))
        XCTAssertTrue(r2.stdout.contains("seed=42"))
        XCTAssertTrue(r2.stdout.contains("epoch=2"),
                      "info should report the saved epoch")
        XCTAssertTrue(r2.stdout.contains("soupBytes=8388608"))
        XCTAssertTrue(r2.stdout.contains("soupDigest=0x"))
    }

    func testInfoModeRejectsWellMixedFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wellMixed = GoldenFixture(capturing:
            Simulation(config: SimulationConfig(
                seed: 1, populationSize: 8, stepBudget: 8,
                mutationP32: 0, variant: .noheads, bracketMode: .dynamicScan)),
            source: "process-test")
        let data = try wellMixed.jsonData()
        let url = try writeData(data, to: dir, name: "well-mixed.json")
        let r = try runCLI(["--info", "--checkpoint", url.path])
        XCTAssertEqual(r.status, 64)
    }

    // MARK: - Output determinism: two identical runs diff cleanly

    func testTwoIdenticalRunsProduceIdenticalOutput() throws {
        let args = ["--seed", "7", "--epochs", "2",
                    "--budget", "1", "--mutation-p32", "0"]
        let a = try runCLI(args)
        let b = try runCLI(args)
        XCTAssertEqual(a.status, 0)
        XCTAssertEqual(b.status, 0)
        XCTAssertEqual(a.stdout, b.stdout,
                       "two identical runs must produce byte-identical stdout")
    }
}
