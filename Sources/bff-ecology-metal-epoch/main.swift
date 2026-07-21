import BFFOracle
import BFFEcologyMetal
import Foundation

#if canImport(Metal)
import Metal
#endif

/// `bff-ecology-metal-epoch` — headless Metal runner for BFF-Ecology v1.
///
/// Emits byte-identical output to `bff-ecology-epoch` (the CPU CLI) for the same
/// config in the supported Metal domain (stepBudget 1...8192). Exits 2 on
/// non-Metal hosts (parallels `bff-resident-epoch`, `bff-metal-soup`).
///
/// Metal-runner limitation: `stepBudget` is pinned to 1...8192 (overflow-safe
/// counter domain). The CPU CLI retains its own (already-accepted) budget
/// handling. Checkpoints with `stepBudget > 8192` are rejected clearly, never
/// clamped.

let usage = """
usage: bff-ecology-metal-epoch [options]

  Experimental Spatial Ecology (BFF-Ecology v1) Metal runner / checkpoint CLI.
  Emits byte-identical output to bff-ecology-epoch for the supported Metal domain.
  Exits 2 on non-Metal hosts.

  Required when --checkpoint is not given:
    --seed N                 UInt32 seed (decimal digits only).

  Config (rejected when --checkpoint is given; the checkpoint is authoritative):
    --budget N               per-pair step budget, 1...8192 (default \(BFF.stepBudget))
    --mutation-p32 N         mutate iff uint32 draw < N; 0 disables (default \(BFF.defaultMutationP32))
    --variant noheads|bff    initial head mode (default noheads)
    --brackets dynamicScan|jumpTable (default dynamicScan)

  Execution:
    --epochs N               epochs to run, >= 0 (default 0)
    --checkpoint PATH        restore from a BFFECO1 checkpoint file
    --save PATH              write a BFFECO1 checkpoint after running
    --info                   print checkpoint metadata and exit (no execution)

  Exit codes:
    0  success
    1  runtime error (after a valid restore)
    2  Metal unavailable (non-Metal host)
    64 usage error / malformed input / checkpoint contract rejection
"""

func fail(_ message: String, exitCode: Int32 = 64) -> Never {
    FileHandle.standardError.write(
        Data(("bff-ecology-metal-epoch: " + message + "\n").utf8))
    if exitCode == 64 {
        FileHandle.standardError.write(Data(("\n" + usage + "\n").utf8))
    }
    exit(exitCode)
}

// MARK: - Metal availability gate

// Metal availability is checked at runtime via MTLCreateSystemDefaultDevice().
// On non-Metal hosts, the `#if canImport(Metal)` gate at the bottom of this file
// exits with code 2 (parallels bff-resident-epoch, bff-metal-soup).

// MARK: - Argument parsing (reuses EcologyCLIOptions from BFFOracle)

let rawArgs = Array(CommandLine.arguments.dropFirst())
if rawArgs.contains("--help") || rawArgs.contains("-h") {
    print(usage)
    exit(0)
}

let options: EcologyCLIOptions
do {
    options = try EcologyCLIParser.parse(args: rawArgs)
} catch let e as EcologyCLIError {
    fail("\(e)")
} catch {
    fail("\(error)")
}

// MARK: - Formatting helpers (identical to bff-ecology-epoch)

func hexDigest(_ value: UInt64) -> String {
    "0x" + EcologyDigest.hexString(value)
}

func headerLine(config: EcologyConfig, epoch: UInt64, digest: UInt64) -> String {
    "ecology label=\"Experimental Spatial Ecology\" "
    + "engine=\(EcologyConfig.engineID) "
    + "topology=\(EcologyConfig.topologyID) "
    + "scheduler=\(EcologyConfig.schedulerID) "
    + "rng=\(EcologyConfig.rngContractID) "
    + "evaluator=\(config.evaluatorContractID) "
    + "seed=\(config.seed) epoch=\(epoch) "
    + "budget=\(config.stepBudget) mutationP32=\(config.mutationP32) "
    + "variant=\(config.variant.rawValue) brackets=\(config.bracketMode.rawValue) "
    + "digest=\(hexDigest(digest))"
}

func epochLine(_ c: EcologyEpochCounters) -> String {
    "ecology epoch=\(c.epoch) phase=\(c.phase.label) "
    + "interactions=\(c.interactions) mutations=\(c.mutationCount) "
    + "rawSteps=\(c.totalRawSteps) noopSteps=\(c.totalNoopSteps) "
    + "commandSteps=\(c.totalCommandSteps) loopOps=\(c.totalLoopOps) "
    + "copyWrites=\(c.totalCopyWrites) remapEvents=\(c.totalRemapEvents) "
    + "haltBudget=\(c.haltBudget) haltPCOut=\(c.haltPCOut) "
    + "haltUnmatched=\(c.haltUnmatched) "
    + "writeSites=\(c.writeSites) writeConflicts=\(c.writeConflicts) "
    + "digest=\(hexDigest(c.digest))"
}

func finalLine(config: EcologyConfig, epoch: UInt64, digest: UInt64) -> String {
    "ecology final epoch=\(epoch) digest=\(hexDigest(digest)) "
    + "seed=\(config.seed) budget=\(config.stepBudget) "
    + "mutationP32=\(config.mutationP32) variant=\(config.variant.rawValue) "
    + "brackets=\(config.bracketMode.rawValue)"
}

func infoLine(url: URL, checkpoint: EcologyCheckpoint, soupDigest: UInt64) -> String {
    "ecology checkpoint path=\(url.path) "
    + "schemaVersion=\(checkpoint.schemaVersion) "
    + "engine=\(checkpoint.engineID) topology=\(checkpoint.topologyID) "
    + "scheduler=\(checkpoint.schedulerID) rng=\(checkpoint.rngContractID) "
    + "evaluator=\(checkpoint.evaluatorContractID) "
    + "seed=\(checkpoint.seed) epoch=\(checkpoint.epoch) "
    + "budget=\(checkpoint.stepBudget) mutationP32=\(checkpoint.mutationP32) "
    + "variant=\(checkpoint.variant.rawValue) "
    + "brackets=\(checkpoint.bracketMode.rawValue) "
    + "soupBytes=\(EcologyTopology.soupByteCount) "
    + "soupDigest=\(hexDigest(soupDigest))"
}

// MARK: - --info: print checkpoint metadata and exit (no execution)

if options.infoOnly {
    let cpURL = options.checkpointURL!
    let checkpoint: EcologyCheckpoint
    do {
        checkpoint = try EcologyCheckpointFile.load(from: cpURL)
    } catch let e as EcologyCheckpointLoadError {
        fail("\(e)")
    } catch {
        fail("\(error)")
    }
    let soupDigest: UInt64
    let resolvedConfig: EcologyConfig
    do {
        let soup = try checkpoint.soupBytes()
        soupDigest = EcologyDigest.digest(soup)
        resolvedConfig = try checkpoint.config()
    } catch {
        fail("\(error)")
    }
    print(headerLine(config: resolvedConfig, epoch: checkpoint.epoch,
                    digest: soupDigest))
    print(infoLine(url: cpURL, checkpoint: checkpoint, soupDigest: soupDigest))
    exit(0)
}

// MARK: - Build (or restore) the runner

#if canImport(Metal)

var runner: EcologyMetalEpochRunner
let resolvedConfig: EcologyConfig

if let cpURL = options.checkpointURL {
    let checkpoint: EcologyCheckpoint
    do {
        checkpoint = try EcologyCheckpointFile.load(from: cpURL)
    } catch let e as EcologyCheckpointLoadError {
        fail("\(e)")
    } catch {
        fail("\(error)")
    }
    do {
        let ecoConfig = try checkpoint.config()
        // Check Metal contract before constructing the config — produces
        // the specialized error message for over-budget checkpoints.
        guard ecoConfig.stepBudget <= 8192 else {
            fail("checkpoint stepBudget \(ecoConfig.stepBudget) exceeds Metal contract (1...8192); "
                 + "the CPU CLI (bff-ecology-epoch) accepts this checkpoint", exitCode: 64)
        }
        let metalConfig = try EcologyMetalEpochConfig(fromEcologyConfig: ecoConfig)
        runner = try EcologyMetalEpochRunner(
            checkpoint: checkpoint,
            capturePairTapes: false)
        resolvedConfig = EcologyConfig(seed: metalConfig.seed, stepBudget: metalConfig.stepBudget,
                                       mutationP32: metalConfig.mutationP32,
                                       variant: metalConfig.variant,
                                       bracketMode: metalConfig.bracketMode)
    } catch let e as EcologyCLIError {
        fail("\(e)")
    } catch let e as EcologyContractError {
        fail("\(e)", exitCode: 1)
    } catch {
        fail("\(error)", exitCode: 1)
    }
} else {
    let seed = options.seed!
    let budget = options.stepBudget ?? BFF.stepBudget
    let mutP32 = options.mutationP32 ?? BFF.defaultMutationP32
    let variant = options.variant ?? .noheads
    let brackets = options.bracketMode ?? .dynamicScan

    // Metal contract: reject stepBudget > 8192 clearly
    guard budget > 0, budget <= 8192 else {
        if budget <= 0 {
            fail("step budget must be > 0, got \(budget)")
        } else {
            fail("Metal contract pins step budget to 1...8192, got \(budget); "
                 + "use the CPU CLI (bff-ecology-epoch) for larger budgets")
        }
    }

    let metalConfig: EcologyMetalEpochConfig
    do {
        metalConfig = try EcologyMetalEpochConfig(
            seed: seed, stepBudget: budget, mutationP32: mutP32,
            variant: variant, bracketMode: brackets, capturePairTapes: false)
    } catch {
        fail("\(error)")
    }
    runner = try EcologyMetalEpochRunner(config: metalConfig)
    resolvedConfig = EcologyConfig(seed: seed, stepBudget: budget,
                                   mutationP32: mutP32, variant: variant,
                                   bracketMode: brackets)
}

// Emit header (matches CPU CLI byte-for-byte)
print(headerLine(config: resolvedConfig, epoch: runner.epoch,
                digest: EcologyDigest.digest(runner.soupSnapshot)))

for _ in 0..<options.epochs {
    do {
        let report = try runner.runEpoch()
        print(epochLine(report.counters))
    } catch {
        fail("epoch \(runner.epoch) failed: \(error)", exitCode: 1)
    }
}

print(finalLine(config: resolvedConfig, epoch: runner.epoch,
                digest: EcologyDigest.digest(runner.soupSnapshot)))

// MARK: - Save (after running)

if let saveURL = options.saveURL {
    let checkpoint = EcologyCheckpoint(
        seed: resolvedConfig.seed,
        epoch: runner.epoch,
        mutationP32: resolvedConfig.mutationP32,
        stepBudget: resolvedConfig.stepBudget,
        variant: resolvedConfig.variant,
        bracketMode: resolvedConfig.bracketMode,
        soup: runner.soupSnapshot,
        lastEpochCounters: runner.lastEpochCounters)
    do {
        let data = try checkpoint.jsonData()
        try data.write(to: saveURL)
    } catch {
        fail("could not write checkpoint to \(saveURL.path): \(error)", exitCode: 1)
    }
}

exit(0)

#else
// Non-Metal host
FileHandle.standardError.write(
    Data("bff-ecology-metal-epoch: Metal unavailable — non-Metal host\n".utf8))
exit(2)
#endif
