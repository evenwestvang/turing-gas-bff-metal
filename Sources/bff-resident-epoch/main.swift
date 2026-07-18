/// bff-resident-epoch - experimental GPU-resident BFF epoch slice.
///
/// macOS only for GPU execution. Linux parses arguments and exits 2 without trying
/// Metal. This product is intentionally separate from bff-metal-soup/bench so existing
/// defaults and exact Brotli/high-order observability paths are unchanged.

import BFFMetal
import BFFOracle
import Foundation

func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write(Data(("bff-resident-epoch: " + message + "\n").utf8))
    exit(exitCode)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("bff-resident-epoch: " + message + "\n").utf8))
}

enum ValidationMode: String {
    case none
    case tiny
    case medium
    case smoke
}

var seeds: [UInt32] = [1]
var programs = BFF.defaultSoupPrograms
var epochs = 1
var budget = BFF.stepBudget
var mutationP32 = BFF.defaultMutationP32
var variant: BFFVariant = .noheads
var initMode: SoupConfig.InitMode = .uniform
var shadowSample: Int? = 0
var shadowSampleWasSet = false
var checkpointInterval = 0
var capturePairs = false
var visualization = false
var visualizationWidth = 512
var validationMode = ValidationMode.none

let usageExit: Int32 = 64

func intArg(_ name: String, _ raw: String) -> Int {
    guard let n = Int(raw) else {
        fail("\(name) requires an integer, got '\(raw)'", exitCode: usageExit)
    }
    return n
}

func u32Arg(_ name: String, _ raw: String) -> UInt32 {
    guard let n = UInt32(raw) else {
        fail("\(name) requires a 0...\(UInt32.max) integer, got '\(raw)'",
             exitCode: usageExit)
    }
    return n
}

func seedArg(_ name: String, _ raw: String) -> [UInt32] {
    do { return try parseSeedList(raw) }
    catch let e as SeedParseError { fail("\(name): \(e.description)", exitCode: usageExit) }
    catch { fail("\(name): \(error)", exitCode: usageExit) }
}

let args = Array(CommandLine.arguments.dropFirst())
var cursor = 0
@MainActor func nextValue(_ name: String) -> String {
    guard cursor < args.count else { fail("\(name) requires a value", exitCode: usageExit) }
    defer { cursor += 1 }
    return args[cursor]
}

while cursor < args.count {
    let arg = args[cursor]
    cursor += 1
    switch arg {
    case "--seed":
        let parsed = seedArg(arg, nextValue(arg))
        guard parsed.count == 1 else {
            fail("--seed takes exactly one seed; use --seeds for a list", exitCode: usageExit)
        }
        seeds = parsed
    case "--seeds":
        seeds = seedArg(arg, nextValue(arg))
    case "--programs":
        programs = intArg(arg, nextValue(arg))
    case "--epochs":
        epochs = intArg(arg, nextValue(arg))
    case "--budget":
        budget = intArg(arg, nextValue(arg))
    case "--mutation-p32":
        mutationP32 = u32Arg(arg, nextValue(arg))
    case "--variant":
        let raw = nextValue(arg)
        guard let parsed = BFFVariant(rawValue: raw) else {
            fail("unknown variant '\(raw)' (use noheads or bff)", exitCode: usageExit)
        }
        variant = parsed
    case "--init":
        let raw = nextValue(arg)
        guard let parsed = SoupConfig.InitMode(rawValue: raw) else {
            fail("unknown init mode '\(raw)' (use uniform, constant, or opcode)",
                 exitCode: usageExit)
        }
        initMode = parsed
    case "--shadow-sample":
        let raw = nextValue(arg)
        shadowSample = raw == "all" ? nil : intArg(arg, raw)
        shadowSampleWasSet = true
    case "--checkpoint-interval":
        checkpointInterval = intArg(arg, nextValue(arg))
    case "--capture-pairs":
        capturePairs = true
    case "--visualize":
        visualization = true
    case "--visualization-width":
        visualizationWidth = intArg(arg, nextValue(arg))
    case "--validate":
        let raw = nextValue(arg)
        guard let parsed = ValidationMode(rawValue: raw) else {
            fail("unknown validation mode '\(raw)' (use none, tiny, medium, or smoke)",
                 exitCode: usageExit)
        }
        validationMode = parsed
    case "--help", "-h":
        print("""
        usage: bff-resident-epoch [options]
          --seed N | --seeds N[,N...]  run seed(s), default 1
          --programs EVEN             program count, default \(BFF.defaultSoupPrograms)
          --epochs N                  epochs, default 1
          --budget N                  per-pair budget, default \(BFF.stepBudget)
          --mutation-p32 N            mutation threshold, default \(BFF.defaultMutationP32)
          --variant noheads|bff       initial head mode, default noheads
          --init uniform|constant|opcode
          --shadow-sample N|all       CPU-shadow captured pairs; omit/0 for throughput
          --checkpoint-interval N     full soup readback cadence; 0 disables
          --capture-pairs             keep/read pre/post pair tapes for diagnostics
          --visualize                 emit approximate GPU visualization texture/buffer
          --visualization-width N     visualization texture width, default 512
          --validate tiny|medium|smoke|none

        validation:
          tiny   exhaustive 2...1024 even program counts, checkpoint/capture/full shadow
          medium 16K programs, several seeds/epochs, digest/counters/sampled tapes
          smoke  bounded 131K native run, no large CPU parity
        """)
        exit(0)
    default:
        fail("unknown argument '\(arg)'", exitCode: usageExit)
    }
}

guard epochs >= 0 else { fail("epochs must be >= 0", exitCode: usageExit) }

@MainActor func makeConfig(seed: UInt32, programs: Int, epochs _: Int,
                checkpoint: Int? = nil, capture: Bool? = nil,
                shadowOverride: Int? = nil, overrideShadow: Bool = false,
                visualize: Bool? = nil) -> ResidentEpochConfig {
    do {
        let resolvedShadow = overrideShadow ? shadowOverride : shadowSample
        let requestedCapture = capture ?? capturePairs
        let shadowNeedsCapture = resolvedShadow == nil || (resolvedShadow ?? 0) > 0
        return try ResidentEpochConfig(
            seed: seed,
            programCount: programs,
            stepBudget: budget,
            mutationP32: mutationP32,
            variant: variant,
            initMode: initMode,
            shadowSampleCount: resolvedShadow,
            checkpointInterval: checkpoint ?? checkpointInterval,
            capturePairTapes: requestedCapture || shadowNeedsCapture,
            visualizationEnabled: visualize ?? visualization,
            visualizationWidth: visualizationWidth)
    } catch let e as ResidentEpochConfig.ConfigError {
        fail(e.description, exitCode: usageExit)
    } catch {
        fail("\(error)", exitCode: usageExit)
    }
}

func hexDigest(_ digest: UInt64?) -> String {
    guard let digest else { return "none" }
    return "0x" + SoupDigest.hexString(digest)
}

func ms(_ seconds: Double?) -> String {
    guard let seconds else { return "nil" }
    return String(format: "%.3f", seconds * 1000)
}

func printReport(seed: UInt32, report: ResidentEpochReport) {
    let c = report.counters
    let kernelText = report.instrumentation.kernelTimings.map {
        "\($0.name):hostMs=\(ms($0.hostSeconds)),gpuMs=\(ms($0.gpuSeconds))"
    }.joined(separator: ";")
    print("seed=\(seed) epoch=\(c.epoch) pairs=\(c.interactions) "
          + "mutations=\(c.mutationCount) rawSteps=\(c.totalRawSteps) "
          + "noopSteps=\(c.totalNoopSteps) commandSteps=\(c.totalCommandSteps) "
          + "loopOps=\(c.totalLoopOps) copyWrites=\(c.totalCopyWrites) "
          + "halt[budget=\(c.haltBudget),pcOut=\(c.haltPCOut),"
          + "unmatched=\(c.haltUnmatched),unknown=\(c.haltUnknown)] "
          + "digest=\(hexDigest(report.digest)) "
          + "shadowChecked=\(report.shadowChecked) "
          + "shadowMismatch=\(report.shadowMismatches.count) "
          + "epochWallMs=\(ms(report.instrumentation.epochWallSeconds)) "
          + "checkpointMs=\(ms(report.instrumentation.checkpointSeconds)) "
          + "epochsPerSec=\(String(format: "%.3f", report.instrumentation.epochsPerSecond)) "
          + "uploadBytes=\(report.instrumentation.uploadBytes) "
          + "readbackBytes=\(report.instrumentation.readbackBytes) "
          + "paramBytes=\(report.instrumentation.parameterBytes) "
          + "buffersBytes=\(report.instrumentation.bufferSizes.totalPersistentBytes) "
          + "kernels=[\(kernelText)]")
}

#if canImport(Metal)
func runNative(config: ResidentEpochConfig, epochs: Int, seed: UInt32,
               compareCPU: Bool) throws -> Int {
    let gpu = try ResidentMetalEpochRunner(config: config)
    var cpu = compareCPU ? ResidentCPUReferenceRunner(config: config) : nil
    print("resident seed=\(seed) programs=\(config.programCount) pairs=\(config.pairCount) "
          + "epochs=\(epochs) budget=\(config.stepBudget) mutationP32=\(config.mutationP32) "
          + "variant=\(config.variant.rawValue) init=\(config.initMode.rawValue) "
          + "checkpointInterval=\(config.checkpointInterval) "
          + "capturePairs=\(config.capturePairTapes) visualize=\(config.visualizationEnabled) "
          + "rng=\(BFFRandom.contractID) device=\"\(gpu.deviceName)\"")
    print("buffers soup=\(config.soupByteCount) total=\(ResidentEpochBufferSizer.sizes(config: config).totalPersistentBytes)")

    var mismatchCount = 0
    for _ in 0..<epochs {
        let g = try gpu.runEpoch()
        printReport(seed: seed, report: g)
        for mm in g.shadowMismatches {
            warn("SHADOW MISMATCH \(mm.summary)")
        }
        mismatchCount += g.shadowMismatches.count

        if var cpuRunner = cpu {
            let c = cpuRunner.runEpoch()
            cpu = cpuRunner
            if g.counters != c.counters {
                warn("CPU PARITY MISMATCH seed=\(seed) epoch=\(g.counters.epoch) counters gpu=\(g.counters) cpu=\(c.counters)")
                mismatchCount += 1
            }
            if let gs = g.checkpointSoup, let cs = c.checkpointSoup, gs != cs {
                let first = zip(gs.indices, gs).first { pair in cs[pair.0] != pair.1 }?.0 ?? -1
                warn("CPU PARITY MISMATCH seed=\(seed) epoch=\(g.counters.epoch) soup firstByte=\(first)")
                mismatchCount += 1
            }
            if g.capturedPairs.count == c.capturedPairs.count {
                for i in g.capturedPairs.indices where g.capturedPairs[i] != c.capturedPairs[i] {
                    warn("PAIR CAPTURE MISMATCH seed=\(seed) epoch=\(g.counters.epoch) pair=\(i)")
                    mismatchCount += 1
                    break
                }
            }
        }
    }
    return mismatchCount
}

@MainActor func runValidation() throws -> Int {
    switch validationMode {
    case .none:
        var total = 0
        for seed in seeds {
            let config = makeConfig(seed: seed, programs: programs, epochs: epochs)
            total += try runNative(config: config, epochs: epochs,
                                   seed: seed, compareCPU: false)
        }
        return total
    case .tiny:
        var total = 0
        for seed in seeds {
            for n in stride(from: 2, through: 1024, by: 2) {
                let config = makeConfig(seed: seed, programs: n, epochs: epochs,
                                        checkpoint: 1, capture: true,
                                        shadowOverride: nil, overrideShadow: true,
                                        visualize: false)
                total += try runNative(config: config, epochs: max(1, epochs),
                                       seed: seed, compareCPU: true)
            }
        }
        return total
    case .medium:
        var total = 0
        let mediumSeeds = seeds.count == 1 ? [seeds[0], seeds[0] &+ 1, seeds[0] &+ 2] : seeds
        for seed in mediumSeeds {
            let config = makeConfig(seed: seed, programs: 16_384, epochs: max(3, epochs),
                                    checkpoint: 1, capture: true,
                                    shadowOverride: min(128, 16_384 / 2),
                                    overrideShadow: true,
                                    visualize: visualization)
            total += try runNative(config: config, epochs: max(3, epochs),
                                   seed: seed, compareCPU: true)
        }
        return total
    case .smoke:
        var total = 0
        for seed in seeds {
            let config = makeConfig(seed: seed, programs: 131_072, epochs: max(1, epochs),
                                    checkpoint: checkpointInterval == 0 ? 1 : checkpointInterval,
                                    capture: capturePairs,
                                    shadowOverride: shadowSampleWasSet ? shadowSample : 32,
                                    overrideShadow: true,
                                    visualize: visualization)
            total += try runNative(config: config, epochs: max(1, epochs),
                                   seed: seed, compareCPU: false)
        }
        return total
    }
}

do {
    let mismatches = try runValidation()
    if mismatches > 0 {
        fail("\(mismatches) mismatch(es) detected", exitCode: 1)
    }
    exit(0)
} catch ResidentMetalEpochRunner.RunnerError.noDevice {
    fail("Metal unavailable", exitCode: 2)
} catch {
    fail("\(error)", exitCode: 1)
}
#else
let config = makeConfig(seed: seeds[0], programs: programs, epochs: epochs)
print("bff-resident-epoch: Metal is unavailable on this platform; no GPU epoch was executed.")
print("would-run validation=\(validationMode.rawValue) seed=\(config.seed) programs=\(config.programCount) "
      + "pairs=\(config.pairCount) epochs=\(epochs) budget=\(config.stepBudget) "
      + "mutationP32=\(config.mutationP32) checkpointInterval=\(config.checkpointInterval) "
      + "capturePairs=\(config.capturePairTapes) visualize=\(config.visualizationEnabled)")
exit(2)
#endif
