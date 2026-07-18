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
import BrotliMetrics
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
// Paper high-order-complexity (`H0 − brotli_bpb`) thresholds; the paper's regime of
// interest is `>= 1`, so that is the default. Only used when `--brotli` is on.
var highOrderThresholds: [Double] = [PaperComplexity.defaultThreshold]
var sampleInterval = 1
// Signal-measurement cadence (distinct from `--sample-interval`, which is the JSON
// emission cadence). `1` = per-epoch (default); `N > 1` = cadence-only signal analysis.
var signalInterval = 1
var allowMissingGPUTiming = false
// `--no-samples` disables ALL sample-only metric analysis (entropy/transition/LZ/
// kinetics), not merely JSON emission — the throughput-only mode. `--compression`
// opts the O(n·window) LZ proxy in; it is ignored when analysis is off.
var analyzeSignals = true
var includeCompression = false
// `--brotli` opts in to the paper-aligned Brotli 1.1.0 q2 measurement (distinct from
// the deterministic LZ proxy). Bounded to the LZ-proxy cadence; ignored when analysis
// is off; emitted only when the linked Brotli is exactly 1.1.0 (else "not computed").
var includeBrotli = false

let usageExit = BenchmarkExitCode.usage

func intArg(_ name: String, _ v: String) -> Int {
    guard let n = Int(v) else { fail("\(name) requires an integer, got '\(v)'", exitCode: usageExit) }
    return n
}
func u32Arg(_ name: String, _ v: String) -> UInt32 {
    guard let n = UInt32(v) else { fail("\(name) requires a 0...\(UInt32.max) integer, got '\(v)'", exitCode: usageExit) }
    return n
}
func intList(_ name: String, _ v: String) -> [Int] {
    let parts = v.split(separator: ",").map(String.init)
    guard !parts.isEmpty else { fail("\(name) requires at least one value", exitCode: usageExit) }
    return parts.map { intArg(name, $0) }
}
func doubleList(_ name: String, _ v: String) -> [Double] {
    v.split(separator: ",").map(String.init).map {
        guard let d = Double($0) else { fail("\(name) requires numbers, got '\($0)'", exitCode: usageExit) }
        return d
    }
}

/// Strict seed parsing, factored into `BFFMetal.parseSeedList` so it is unit-tested
/// without a Metal device. Any malformed token is a usage error — never truncated.
func seedArg(_ name: String, _ v: String) -> [UInt32] {
    do { return try parseSeedList(v) }
    catch let e as SeedParseError { fail("\(name): \(e.description)", exitCode: usageExit) }
    catch { fail("\(name): \(error)", exitCode: usageExit) }
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
    case "--seeds": seeds = seedArg(argument, nextValue(argument))
    case "--seed":
        let parsed = seedArg(argument, nextValue(argument))
        guard parsed.count == 1 else {
            fail("--seed takes exactly one seed (use --seeds for a list)", exitCode: usageExit)
        }
        seeds = parsed
    case "--programs": programsList = intList(argument, nextValue(argument))
    case "--epochs": measuredEpochs = intArg(argument, nextValue(argument))
    case "--warmup": warmupEpochs = intArg(argument, nextValue(argument))
    case "--budget": budget = intArg(argument, nextValue(argument))
    case "--mutation-p32": mutationP32 = u32Arg(argument, nextValue(argument))
    case "--shadow-sample": shadowSampleArg = nextValue(argument)
    case "--delta-h-thresholds": deltaHThresholds = doubleList(argument, nextValue(argument))
    case "--high-order-thresholds": highOrderThresholds = doubleList(argument, nextValue(argument))
    case "--sample-interval": sampleInterval = intArg(argument, nextValue(argument))
    case "--signal-interval": signalInterval = intArg(argument, nextValue(argument))
    case "--allow-missing-gpu-timing": allowMissingGPUTiming = true
    case "--no-samples": analyzeSignals = false
    case "--compression": includeCompression = true
    case "--brotli": includeBrotli = true
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
          --delta-h-thresholds L  comma bits/byte ΔH levels to time (e.g. 0.25,0.5,1.0);
                                  requires per-epoch signals (--signal-interval 1)
          --brotli                opt in to the paper-aligned Brotli 1.1.0 quality-2
                                  metric: reports brotli bits/byte and high-order
                                  complexity H0 - brotli_bpb (cubff's higher_entropy).
                                  DISTINCT from --compression (the LZ proxy). Runs only
                                  on the LZ-proxy cadence, outside the epoch wall; the
                                  number is emitted only when the linked Brotli is
                                  exactly 1.1.0, else reported as null (not computed).
                                  Ignored under --no-samples.
          --high-order-thresholds L  comma bits/byte high-order-complexity levels whose
                                  first-crossing epoch/time to record (default 1, the
                                  paper threshold). Only with --brotli; the crossing
                                  epoch is resolved to the Brotli measurement cadence
                                  and the observation interval is encoded explicitly
                                  (observedEpoch, previousMeasuredEpoch,
                                  crossingEpochCensoring) so the true crossing is
                                  never implied to be exact when it is not.
          --sample-interval N     JSON emission cadence: emit a kinetics sample every N
                                  epochs (+ the final epoch) (default 1). It is also the
                                  LZ-proxy MEASUREMENT cadence when --compression is on
                                  (the proxy runs only where an emission point and a
                                  measured signal epoch coincide).
          --signal-interval N     signal-MEASUREMENT cadence (distinct from
                                  --sample-interval). 1 (default) measures entropy every
                                  epoch. N>1 is cadence-only analysis: measure at epoch 0,
                                  every Nth completed epoch, and the final epoch only.
                                  Incompatible with --delta-h-thresholds (usage error).
                                  A sample is emitted only where an emission point and a
                                  measured epoch coincide. Ignored under --no-samples.
          --no-samples            throughput mode: skip ALL sample-only metric analysis
                                  (entropy/transition/LZ/kinetics), not just JSON output
          --compression           opt in to the O(n·window) LZ proxy (sampled epochs
                                  only, and only where signals are measured; off by
                                  default; ignored under --no-samples)
          --allow-missing-gpu-timing  exit 0 even if GPU timestamps are unavailable
        Seeds are strict unsigned decimals in 0...\(UInt32.max); malformed/overflowing
        tokens are a usage error (exit \(BenchmarkExitCode.usage)), never truncated.
        Output: one JSON document {schemaVersion, results:[...]} on stdout.
        """)
        exit(0)
    default:
        fail("unknown argument '\(argument)'", exitCode: usageExit)
    }
}

guard measuredEpochs >= 0, warmupEpochs >= 0 else {
    fail("epochs and warmup must be >= 0", exitCode: usageExit)
}
guard sampleInterval >= 1 else { fail("--sample-interval must be >= 1", exitCode: usageExit) }
guard signalInterval >= 1 else { fail("--signal-interval must be >= 1", exitCode: usageExit) }
// Exact ΔH thresholds require the per-epoch trajectory; a sparse signal interval is
// cadence-only. Reject the combination as a usage error (validated in the library so
// the policy is unit-tested without Metal). This incompatibility only exists when
// signals are actually analyzed: under `--no-samples` no trajectory is measured at all,
// so `--signal-interval` and `--delta-h-thresholds` are simply inert (noted below), not
// a usage error — `--no-samples --signal-interval 2 --delta-h-thresholds …` runs fine.
if analyzeSignals {
    do {
        try validateSignalCadence(signalInterval: signalInterval,
                                  deltaHThresholdCount: deltaHThresholds.count)
    } catch let e as SignalCadenceError {
        fail(e.description, exitCode: usageExit)
    } catch {
        fail("\(error)", exitCode: usageExit)
    }
}
if includeCompression && !analyzeSignals {
    warn("--compression is ignored under --no-samples (no signal analysis runs)")
}
if includeBrotli && !analyzeSignals {
    warn("--brotli is ignored under --no-samples (no signal analysis runs)")
}
if signalInterval > 1 && !analyzeSignals {
    warn("--signal-interval is ignored under --no-samples (no signal analysis runs)")
}
if !deltaHThresholds.isEmpty && !analyzeSignals {
    warn("--delta-h-thresholds is ignored under --no-samples (no signal analysis runs)")
}
// High-order-complexity thresholds need the Brotli measurement; without --brotli they
// are inert. (A `--high-order-thresholds` explicitly set to empty is silent.)
if !includeBrotli && !highOrderThresholds.isEmpty
    && highOrderThresholds != [PaperComplexity.defaultThreshold] {
    warn("--high-order-thresholds is ignored without --brotli (no complexity measured)")
}
// The paper metric is defined against Brotli 1.1.0 exactly; refuse to fabricate it
// from any other encoder. On a non-1.1.0 host the run still proceeds — the brotli
// fields are reported as null (honest "not computed").
if includeBrotli && analyzeSignals && !BrotliCompressor.isPaperPinned {
    warn("--brotli requested but the linked Brotli is "
         + "\(BrotliCompressor.encoderVersionString) (need 1.1.0); brotli bits/byte and "
         + "high-order complexity will be reported as null (not computed). Install "
         + "Brotli 1.1.0 (brew install brotli / build the pinned tag) for the paper metric.")
}

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
            // High-order thresholds are only meaningful when Brotli is measured; keep
            // them out of the config (and thus out of the crossing tracker) otherwise,
            // so `highOrderComplexityCrossings` stays empty without --brotli.
            highOrderComplexityThresholds: includeBrotli ? highOrderThresholds : [],
            sampleInterval: sampleInterval)
        do {
            _ = try cfg.soupConfig()   // validate bounds now
        } catch let e as SoupConfig.ConfigError {
            fail("invalid config (programs=\(programs) seed=\(seed)): \(e.description)", exitCode: usageExit)
        } catch {
            fail("invalid config (programs=\(programs) seed=\(seed)): \(error)", exitCode: usageExit)
        }
        configs.append(cfg)
    }
}

// MARK: - Host helpers

/// One process peak (high-water) RSS reading in bytes, or nil if unobtainable.
/// `ru_maxrss` is bytes on Darwin and kilobytes on Linux (normalized here). It is the
/// process high-water mark — cumulative for the whole process, not per-config. The
/// benchmark runner samples this at several points per cell and keeps the maximum
/// available reading (see `PeakRSSSampler`); the result is a single process ceiling
/// for the whole run, never a cell-exclusive figure.
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
        // schemaVersion 3: paper-aligned high-order complexity added — per-sample
        // brotliBitsPerByte/highOrderComplexity, result initial/final Brotli bpb +
        // high-order complexity, and highOrderComplexityCrossings (each record
        // carries observedEpoch, previousMeasuredEpoch, and crossingEpochCensoring
        // so the true crossing epoch cannot be mistaken for exact under sparse
        // measurement), plus the config key highOrderComplexityThresholds. All
        // null/empty unless --brotli measured against Brotli 1.1.0. Schema 2's key
        // set is otherwise unchanged and every optional stays an explicit null
        // (see Docs/Benchmarking.md). Custom init(from:) accepts schema-2-shaped
        // JSON missing every new key, defaulting optionals to nil and arrays to [].
        let data = try encoder.encode(Envelope(schemaVersion: 3, results: results))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("failed to encode results: \(error)", exitCode: BenchmarkExitCode.runtimeFailure)
    }
}

#if canImport(Metal)
import Metal

let evaluator: MetalBFFEvaluator
do {
    evaluator = try MetalBFFEvaluator()
} catch {
    // Normalize "no Metal device / no default device" to the documented exit 2
    // (metal unavailable); every other init failure stays a distinct exit 1.
    let outcome: EvaluatorInitOutcome
    if let ee = error as? MetalBFFEvaluator.EvaluatorError, case .noDevice = ee {
        outcome = .metalUnavailable
    } else {
        outcome = .runtimeFailure
    }
    fail("could not initialize Metal evaluator: \(error)", exitCode: outcome.exitCode)
}

let runOptions = BenchmarkRunner.Options(analyzeSignals: analyzeSignals,
                                         includeCompression: includeCompression,
                                         signalInterval: signalInterval,
                                         includeBrotli: includeBrotli)

// The paper Brotli reading, injected so BFFMetal never links Brotli. Returns nil
// (honest "not computed") unless the linked encoder is exactly 1.1.0; the runner
// calls this only on the bounded LZ-proxy cadence, outside the epoch wall.
let measureBrotli: (_ soup: [UInt8]) -> Double? = { soup in
    BrotliCompressor.paperBitsPerByte(soup: soup)
}

var results: [BenchmarkResult] = []
var anyShadowMismatch = false
var anyMissingGPUTiming = false

for config in configs {
    let soupConfig: SoupConfig
    do { soupConfig = try config.soupConfig() }
    catch { fail("config build failed: \(error)", exitCode: usageExit) }

    let result: BenchmarkResult
    do {
        result = try BenchmarkRunner.run(
            config: config,
            soupConfig: soupConfig,
            evaluator: evaluator,
            deviceName: evaluator.deviceName,
            options: runOptions,
            readMaxRSSBytes: maxResidentBytes,
            now: monotonicSeconds,
            gpuSecondsAfterEpoch: { evaluator.lastGPUCommandBufferSeconds },
            measureSignals: { soup, includeComp in
                SoupSignals.measure(soup: soup, programCount: config.programCount,
                                    includeCompression: includeComp)
            },
            measureBrotliBitsPerByte: measureBrotli,
            onEpoch: { report in
                for mm in report.shadowMismatches { warn("SHADOW MISMATCH " + mm.summary) }
            })
    } catch {
        fail("epoch execution failed (programs=\(config.programCount) "
             + "seed=\(config.seed)): \(error)", exitCode: BenchmarkExitCode.runtimeFailure)
    }

    if result.shadowMismatchTotal > 0 { anyShadowMismatch = true }
    if config.measuredEpochs > 0 && !result.gpuTimingAvailable { anyMissingGPUTiming = true }
    results.append(result)
}

emit(results)

if anyShadowMismatch {
    fail("one or more CPU-shadow mismatches — GPU diverged from the oracle",
         exitCode: BenchmarkExitCode.runtimeFailure)
}
if anyMissingGPUTiming && !allowMissingGPUTiming {
    fail("GPU command-buffer timestamps were unavailable; wall timing is still "
         + "reported but GPU/host attribution is not. Re-run with "
         + "--allow-missing-gpu-timing to accept this.",
         exitCode: BenchmarkExitCode.gpuTimingUnavailable)
}
exit(BenchmarkExitCode.success)

#else
// Non-Metal host: nothing can run. Echo the resolved matrix so the invocation is
// still verifiable, then exit 2 — the same "Metal unavailable" code the CLI uses
// when a Metal-capable host reports no default device (see EvaluatorInitOutcome).
warn("Metal is unavailable on this platform; the benchmark harness needs a Metal "
     + "device (see Docs/Benchmarking.md). Nothing was executed.")
for config in configs {
    warn("would-run programs=\(config.programCount) seed=\(config.seed) "
         + "warmup=\(config.warmupEpochs) epochs=\(config.measuredEpochs) "
         + "budget=\(config.stepBudget) init=\(config.initMode.rawValue) "
         + "variant=\(config.variant.rawValue) shadowSample=\(config.shadowSampleCount) "
         + "analyzeSignals=\(analyzeSignals) compression=\(includeCompression) "
         + "brotli=\(includeBrotli) brotliVersion=\(BrotliCompressor.encoderVersionString) "
         + "sampleInterval=\(config.sampleInterval) signalInterval=\(signalInterval) "
         + "rng=\(BFFRandom.contractID)")
}
emit([])
exit(BenchmarkExitCode.metalUnavailable)
#endif
