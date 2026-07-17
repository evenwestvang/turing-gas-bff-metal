/// bff-metal-bench — headless deterministic benchmark harness for the small-soup
/// GPU evaluator, sized for native Apple-silicon (M4 Max) runs.
///
/// It runs a matrix of configs (the cartesian product of `--seeds` × `--programs`,
/// all other knobs shared), each for `--warmup` discarded epochs then
/// `--epochs` measured epochs, and emits ONE machine-readable JSON document to
/// stdout. Per config it reports: the config, warmup/measured split, wall ms/epoch,
/// GPU command-buffer ms/epoch, host residual (wall − GPU), epochs/s, pairs/s,
/// raw/command steps/s, halt buckets, copy writes, entropy kinetics (absolute H, ΔH,
/// epochs+wall to ΔH thresholds), the structure metrics, shadow correctness, and
/// max RSS when obtainable.
///
/// It does NOT change any app default, evaluator semantics, or RNG: it only measures.
/// The full 8192-step budget is the default here as elsewhere.
///
/// Exit codes: 0 = all configs ran, GPU timing present, no shadow mismatch;
/// 1 = a shadow mismatch or GPU/runtime error; 2 = Metal unavailable (nothing ran);
/// 3 = ran, but GPU command-buffer timestamps were unavailable (honest-timing
/// failure) and `--allow-missing-gpu-timing` was not given; 64 = bad arguments.
///
/// Usage (from the repository root):
///     swift run -c release bff-metal-bench [options]

import BFFMetal
import BFFOracle
import Foundation
import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write(Data(("bff-metal-bench: " + message + "\n").utf8))
    exit(exitCode)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("bff-metal-bench: " + message + "\n").utf8))
}

// MARK: - Argument parsing (platform-independent; validated before any GPU work)

var seeds: [UInt32] = [1]
var programsList: [Int] = [1024]
var measuredEpochs = 8
var warmupEpochs = 1
var budget = BFF.stepBudget
var mutationP32 = BFF.defaultMutationP32
var variant: BFFVariant = .noheads
var initMode: SoupConfig.InitMode = .uniform
var shadowSampleArg: String? = nil     // nil => 0 (throughput mode)
var deltaHThresholds: [Double] = []
var sampleInterval = 1
var allowMissingGPUTiming = false
var emitSamples = true

func intArg(_ name: String, _ v: String) -> Int {
    guard let n = Int(v) else { fail("\(name) requires an integer, got '\(v)'", exitCode: 64) }
    return n
}
func u32Arg(_ name: String, _ v: String) -> UInt32 {
    guard let n = UInt32(v) else { fail("\(name) requires a 0...\(UInt32.max) integer, got '\(v)'", exitCode: 64) }
    return n
}
func intList(_ name: String, _ v: String) -> [Int] {
    let parts = v.split(separator: ",").map(String.init)
    guard !parts.isEmpty else { fail("\(name) requires at least one value", exitCode: 64) }
    return parts.map { intArg(name, $0) }
}
func doubleList(_ name: String, _ v: String) -> [Double] {
    v.split(separator: ",").map(String.init).map {
        guard let d = Double($0) else { fail("\(name) requires numbers, got '\($0)'", exitCode: 64) }
        return d
    }
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
    case "--seeds": seeds = intList(argument, nextValue(argument)).map { UInt32(truncatingIfNeeded: $0) }
    case "--seed": seeds = [u32Arg(argument, nextValue(argument))]
    case "--programs": programsList = intList(argument, nextValue(argument))
    case "--epochs": measuredEpochs = intArg(argument, nextValue(argument))
    case "--warmup": warmupEpochs = intArg(argument, nextValue(argument))
    case "--budget": budget = intArg(argument, nextValue(argument))
    case "--mutation-p32": mutationP32 = u32Arg(argument, nextValue(argument))
    case "--shadow-sample": shadowSampleArg = nextValue(argument)
    case "--delta-h-thresholds": deltaHThresholds = doubleList(argument, nextValue(argument))
    case "--sample-interval": sampleInterval = intArg(argument, nextValue(argument))
    case "--allow-missing-gpu-timing": allowMissingGPUTiming = true
    case "--no-samples": emitSamples = false
    case "--variant":
        let raw = nextValue(argument)
        guard let v = BFFVariant(rawValue: raw) else {
            fail("unknown variant '\(raw)' (use 'noheads' or 'bff')", exitCode: 64)
        }
        variant = v
    case "--init":
        let raw = nextValue(argument)
        guard let m = SoupConfig.InitMode(rawValue: raw) else {
            fail("unknown init mode '\(raw)' (use 'uniform', 'constant', or 'opcode')", exitCode: 64)
        }
        initMode = m
    case "--help", "-h":
        print("""
        usage: bff-metal-bench [options]
          --seeds N[,N...]        run seeds; matrixed with --programs (default 1)
          --seed N                shorthand for a single seed
          --programs N[,N...]     soup sizes, positive & even; matrixed (default 1024)
          --epochs N              measured epochs per config (default 8)
          --warmup N              warmup epochs discarded from timing (default 1)
          --budget N              per-interaction step budget (default \(BFF.stepBudget))
          --mutation-p32 N        mutate iff a uint32 draw < N; 0 disables (default \(BFF.defaultMutationP32))
          --variant V             noheads | bff (default noheads)
          --init MODE             uniform | constant | opcode (default uniform)
          --shadow-sample N|all   pairs CPU-shadowed per epoch; 0/omit = throughput mode
          --delta-h-thresholds L  comma bits/byte ΔH levels to time (e.g. 0.25,0.5,1.0)
          --sample-interval N     emit a kinetics sample every N epochs (default 1)
          --no-samples            omit the per-epoch samples array from the output
          --allow-missing-gpu-timing  exit 0 even if GPU timestamps are unavailable
        Output: one JSON document {schemaVersion, results:[...]} on stdout.
        """)
        exit(0)
    default:
        fail("unknown argument '\(argument)'", exitCode: 64)
    }
}

guard measuredEpochs >= 0, warmupEpochs >= 0 else {
    fail("epochs and warmup must be >= 0", exitCode: 64)
}
guard sampleInterval >= 1 else { fail("--sample-interval must be >= 1", exitCode: 64) }

// Build the matrix (programs outer, seeds inner) and validate every cell up front so
// a bad size fails before any GPU work.
var configs: [BenchmarkConfig] = []
for programs in programsList {
    for seed in seeds {
        let shadow: Int
        if let raw = shadowSampleArg {
            shadow = (raw == "all") ? programs / 2 : intArg("--shadow-sample", raw)
        } else {
            shadow = 0
        }
        let cfg = BenchmarkConfig(
            seed: seed, programCount: programs, stepBudget: budget,
            mutationP32: mutationP32, variant: variant, initMode: initMode,
            shadowSampleCount: shadow, warmupEpochs: warmupEpochs,
            measuredEpochs: measuredEpochs, deltaHThresholds: deltaHThresholds,
            sampleInterval: sampleInterval)
        do {
            _ = try cfg.soupConfig()   // validate bounds now
        } catch let e as SoupConfig.ConfigError {
            fail("invalid config (programs=\(programs) seed=\(seed)): \(e.description)", exitCode: 64)
        } catch {
            fail("invalid config (programs=\(programs) seed=\(seed)): \(error)", exitCode: 64)
        }
        configs.append(cfg)
    }
}

// MARK: - Host helpers

/// Peak resident set size in bytes, or nil if unobtainable. `ru_maxrss` is bytes on
/// Darwin and kilobytes on Linux (normalized here). It is the process high-water
/// mark, not per-config — reported as a single ceiling for the whole run.
func maxResidentBytes() -> Int? {
    var usage = rusage()
    #if canImport(Darwin)
    let ok = getrusage(RUSAGE_SELF, &usage) == 0
    #else
    let ok = getrusage(Int32(RUSAGE_SELF.rawValue), &usage) == 0
    #endif
    guard ok else { return nil }
    let raw = Int(usage.ru_maxrss)
    guard raw > 0 else { return nil }
    #if canImport(Darwin)
    return raw            // bytes
    #else
    return raw * 1024     // KiB -> bytes
    #endif
}

func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

func emit(_ results: [BenchmarkResult]) {
    struct Envelope: Codable { var schemaVersion: Int; var results: [BenchmarkResult] }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(Envelope(schemaVersion: 1, results: results))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("failed to encode results: \(error)", exitCode: 1)
    }
}

#if canImport(Metal)
import Metal

let evaluator: MetalBFFEvaluator
do {
    evaluator = try MetalBFFEvaluator()
} catch {
    fail("could not initialize Metal evaluator: \(error)", exitCode: 1)
}

var results: [BenchmarkResult] = []
var anyShadowMismatch = false
var anyMissingGPUTiming = false

for config in configs {
    let soupConfig: SoupConfig
    do { soupConfig = try config.soupConfig() }
    catch { fail("config build failed: \(error)", exitCode: 64) }

    var runner = SoupRunner(config: soupConfig)
    let initialSignals = SoupSignals.measure(soup: runner.soup,
                                             programCount: config.programCount,
                                             includeCompression: true)

    var observations: [EpochObservation] = []
    observations.reserveCapacity(config.totalEpochs)

    for e in 0..<config.totalEpochs {
        let isWarmup = e < config.warmupEpochs
        let completed = e + 1
        let isSamplePoint = (completed % config.sampleInterval == 0)
            || completed == config.totalEpochs

        let t0 = monotonicSeconds()
        let report: EpochReport
        do {
            report = try runner.runEpoch(using: evaluator)
        } catch {
            fail("epoch execution failed (programs=\(config.programCount) "
                 + "seed=\(config.seed) epoch=\(e)): \(error)", exitCode: 1)
        }
        let wall = monotonicSeconds() - t0
        let gpu = evaluator.lastGPUCommandBufferSeconds
        if !isWarmup && gpu == nil { anyMissingGPUTiming = true }

        let signals = SoupSignals.measure(soup: runner.soup,
                                          programCount: config.programCount,
                                          includeCompression: isSamplePoint)

        for mm in report.shadowMismatches {
            warn("SHADOW MISMATCH " + mm.summary)
        }

        observations.append(EpochObservation(
            epoch: completed, isWarmup: isWarmup, wallSeconds: wall, gpuSeconds: gpu,
            counters: report.counters, shadowChecked: report.shadowChecked,
            shadowMismatches: report.shadowMismatches.count, signals: signals))
    }

    var result = BenchmarkAggregator.aggregate(
        config: config, deviceName: evaluator.deviceName,
        initialSignals: initialSignals, observations: observations,
        finalDigestHex: SoupDigest.hexString(runner.digest),
        maxRSSBytes: maxResidentBytes())
    if !emitSamples { result.samples = [] }

    if result.shadowMismatchTotal > 0 { anyShadowMismatch = true }
    if config.measuredEpochs > 0 && !result.gpuTimingAvailable { anyMissingGPUTiming = true }
    results.append(result)
}

emit(results)

if anyShadowMismatch {
    fail("one or more CPU-shadow mismatches — GPU diverged from the oracle", exitCode: 1)
}
if anyMissingGPUTiming && !allowMissingGPUTiming {
    fail("GPU command-buffer timestamps were unavailable; wall timing is still "
         + "reported but GPU/host attribution is not. Re-run with "
         + "--allow-missing-gpu-timing to accept this.", exitCode: 3)
}
exit(0)

#else
// Non-Metal host: nothing can run. Echo the resolved matrix so the invocation is
// still verifiable, then exit 2 exactly like the other GPU CLIs.
warn("Metal is unavailable on this platform; the benchmark harness needs a Metal "
     + "device (see Docs/Benchmarking.md). Nothing was executed.")
for config in configs {
    warn("would-run programs=\(config.programCount) seed=\(config.seed) "
         + "warmup=\(config.warmupEpochs) epochs=\(config.measuredEpochs) "
         + "budget=\(config.stepBudget) init=\(config.initMode.rawValue) "
         + "variant=\(config.variant.rawValue) shadowSample=\(config.shadowSampleCount) "
         + "rng=\(BFFRandom.contractID)")
}
emit([])
exit(2)
#endif
