/// bff-metal-soup — headless deterministic small-soup epoch runner.
///
/// Runs a configurable, deliberately modest soup for several epochs on the default
/// Metal device (mutate → pair → dispatch the normative dynamic-scan evaluator →
/// scatter), aggregates counters and per-program metrics, and CPU-shadow-checks a
/// deterministic sample of pairs each epoch. Output is consistently formatted
/// `key=value` tokens so two runs with the same arguments can be diffed directly.
///
/// Exit codes: 0 = every epoch ran and every shadowed pair matched the CPU; 1 =
/// a shadow mismatch or GPU/runtime error; 2 = Metal unavailable (nothing ran);
/// 64 = bad command-line arguments / invalid configuration.
///
/// Usage (from the repository root):
///     swift run bff-metal-soup [--seed N] [--programs EVEN] [--epochs N]
///                              [--budget N] [--mutation-p32 N]
///                              [--variant noheads|bff] [--shadow-sample N|all]
///
/// `bff-metal-parity` is unaffected by this tool.

import BFFMetal
import BFFOracle
import Foundation

func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write(Data(("bff-metal-soup: " + message + "\n").utf8))
    exit(exitCode)
}

// MARK: - Argument parsing (platform-independent; validated before any GPU work)

var seed: UInt32 = 1
var programs = 16
var epochs = 4
var budget = BFF.stepBudget
var mutationP32 = BFF.defaultMutationP32
var variant: BFFVariant = .noheads
var shadowSampleArg: String? = nil // nil => full shadow

func intArg(_ name: String, _ value: String) -> Int {
    guard let n = Int(value) else { fail("\(name) requires an integer, got '\(value)'", exitCode: 64) }
    return n
}
func u32Arg(_ name: String, _ value: String) -> UInt32 {
    guard let n = UInt32(value) else { fail("\(name) requires a 0...\(UInt32.max) integer, got '\(value)'", exitCode: 64) }
    return n
}

let arguments = Array(CommandLine.arguments.dropFirst())
var cursor = 0
@MainActor func nextValue(_ name: String) -> String {
    guard cursor < arguments.count else { fail("\(name) requires a value", exitCode: 64) }
    defer { cursor += 1 }
    return arguments[cursor]
}
while cursor < arguments.count {
    let argument = arguments[cursor]
    cursor += 1
    switch argument {
    case "--seed": seed = u32Arg(argument, nextValue(argument))
    case "--programs": programs = intArg(argument, nextValue(argument))
    case "--epochs": epochs = intArg(argument, nextValue(argument))
    case "--budget": budget = intArg(argument, nextValue(argument))
    case "--mutation-p32": mutationP32 = u32Arg(argument, nextValue(argument))
    case "--shadow-sample": shadowSampleArg = nextValue(argument)
    case "--variant":
        let raw = nextValue(argument)
        guard let v = BFFVariant(rawValue: raw) else {
            fail("unknown variant '\(raw)' (use 'noheads' or 'bff')", exitCode: 64)
        }
        variant = v
    case "--help", "-h":
        print("""
        usage: bff-metal-soup [options]
          --seed N            run seed (default 1)
          --programs EVEN     soup size, positive & even (default 16)
          --epochs N          epochs to run (default 4)
          --budget N          per-interaction step budget (default \(BFF.stepBudget))
          --mutation-p32 N    mutate iff uint32 draw < N; 0 disables (default \(BFF.defaultMutationP32))
          --variant V         noheads | bff (default noheads)
          --shadow-sample N   pairs to CPU-shadow per epoch; 'all' or omit = every pair; 0 disables
        """)
        exit(0)
    default:
        fail("unknown argument '\(argument)'", exitCode: 64)
    }
}

guard epochs >= 0 else { fail("epochs must be >= 0", exitCode: 64) }

// Resolve the shadow sample: 'all' / omitted => full shadow (nil sentinel to config).
var shadowSampleCount: Int? = nil
if let raw = shadowSampleArg, raw != "all" {
    shadowSampleCount = intArg("--shadow-sample", raw)
}

let config: SoupConfig
do {
    config = try SoupConfig(seed: seed, programCount: programs, stepBudget: budget,
                            mutationP32: mutationP32, variant: variant,
                            shadowSampleCount: shadowSampleCount)
} catch let error as SoupConfig.ConfigError {
    fail(error.description, exitCode: 64)
} catch {
    fail("\(error)", exitCode: 64)
}

// MARK: - Formatting helpers (platform-independent)

func f(_ x: Double) -> String { String(format: "%.6f", x) }

func epochLine(_ r: EpochReport) -> String {
    let c = r.counters
    let a = r.activitySummary
    let e = r.entropySummary
    return "epoch=\(c.epoch) mutations=\(c.mutationCount) pairs=\(c.interactions) "
        + "rawSteps=\(c.totalRawSteps) noopSteps=\(c.totalNoopSteps) "
        + "commandSteps=\(c.totalCommandSteps) loopOps=\(c.totalLoopOps) "
        + "copyWrites=\(c.totalCopyWrites) "
        + "halt[budget=\(c.haltBudget),pcOut=\(c.haltPCOut),unmatched=\(c.haltUnmatched),"
        + "unknown=\(c.haltUnknown)] "
        + "activity[min=\(Int(a.min)),mean=\(f(a.mean)),max=\(Int(a.max))] "
        + "entropy[min=\(f(e.min)),mean=\(f(e.mean)),max=\(f(e.max))] "
        + "shadowChecked=\(r.shadowChecked) shadowMismatch=\(r.shadowMismatches.count) "
        + "digest=0x\(SoupDigest.hexString(r.digest))"
}

#if canImport(Metal)
let evaluator: MetalBFFEvaluator
do {
    evaluator = try MetalBFFEvaluator()
} catch {
    fail("could not initialize Metal evaluator: \(error)", exitCode: 1)
}

print("soup seed=\(config.seed) programs=\(config.programCount) pairs=\(config.pairCount) "
      + "budget=\(config.stepBudget) mutationP32=\(config.mutationP32) "
      + "variant=\(config.variant.rawValue) shadowSample=\(config.shadowSampleCount) "
      + "rng=\(BFFRandom.contractID) device=\"\(evaluator.deviceName)\"")

var runner = SoupRunner(config: config)
print("epoch=init digest=0x\(SoupDigest.hexString(runner.digest))")

var totalMismatches = 0
for _ in 0 ..< epochs {
    let report: EpochReport
    do {
        report = try runner.runEpoch(using: evaluator)
    } catch {
        fail("epoch execution failed: \(error)", exitCode: 1)
    }
    print(epochLine(report))
    for mm in report.shadowMismatches {
        FileHandle.standardError.write(Data(("SHADOW MISMATCH " + mm.summary + "\n").utf8))
    }
    totalMismatches += report.shadowMismatches.count
}

print("final seed=\(config.seed) epochs=\(epochs) "
      + "digest=0x\(SoupDigest.hexString(runner.digest)) "
      + "shadowMismatchTotal=\(totalMismatches)")

if totalMismatches > 0 {
    fail("\(totalMismatches) CPU-shadow mismatch(es) — GPU diverged from the oracle",
         exitCode: 1)
}
exit(0)
#else
print("bff-metal-soup: Metal is unavailable on this platform; the small-soup epoch "
      + "runner needs a Metal device (see Docs/MetalSoupSlice.md). Nothing was executed.")
print("would-run seed=\(config.seed) programs=\(config.programCount) "
      + "pairs=\(config.pairCount) epochs=\(epochs) budget=\(config.stepBudget) "
      + "mutationP32=\(config.mutationP32) variant=\(config.variant.rawValue) "
      + "shadowSample=\(config.shadowSampleCount) rng=\(BFFRandom.contractID)")
exit(2)
#endif
