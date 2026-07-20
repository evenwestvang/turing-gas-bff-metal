import BFFOracle
import Foundation

/// `bff-ecology-epoch` — headless CPU runner for BFF-Ecology v1.
///
/// Normative source: `Docs/Architecture/07-ecological-mode.md` §9 (Reset,
/// checkpoint, replay) and §11 (CLI surface `bff-ecology-epoch`, emits
/// `engine=ecology-v1`). This CLI is a separate product from `bff-oracle`,
/// `bff-metal-soup`, `bff-metal-bench`, and `bff-resident-epoch`; those
/// products keep their existing defaults and output contracts.
///
/// The CLI reuses the `BFFECO1` checkpoint implementation
/// (`Sources/BFFOracle/Ecology.swift`); there is no second on-disk format.
///
/// Output is stable, machine-readable, key=value tokens. Every line carries the
/// `ecology` prefix; the header explicitly labels the run as
/// `Experimental Spatial Ecology` per §1.
///
/// Exit codes:
///   0  success (run, save, restore, or --info all completed)
///   1  runtime error (e.g. epoch execution failed after a valid restore)
///   64 usage error / malformed input / checkpoint contract rejection (no trap)

let usage = """
usage: bff-ecology-epoch [options]

  Experimental Spatial Ecology (BFF-Ecology v1) CPU oracle / checkpoint CLI.
  Emits stable key=value output suitable for diffing two identical runs.

  Required when --checkpoint is not given:
    --seed N                 UInt32 seed (decimal digits only).

  Config (rejected when --checkpoint is given; the checkpoint is authoritative):
    --budget N               per-pair step budget, > 0 (default \(BFF.stepBudget))
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
    64 usage error / malformed input / checkpoint contract rejection
"""

func fail(_ message: String, exitCode: Int32 = 64) -> Never {
    FileHandle.standardError.write(
        Data(("bff-ecology-epoch: " + message + "\n").utf8))
    if exitCode == 64 {
        FileHandle.standardError.write(Data(("\n" + usage + "\n").utf8))
    }
    exit(exitCode)
}

// MARK: - Argument parsing (--help / -h handled before parser entry)

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

// MARK: - Formatting helpers (stable machine-readable output)

func hexDigest(_ value: UInt64) -> String {
    "0x" + EcologyDigest.hexString(value)
}

/// One-line header carrying every contract label required by
/// `Docs/Architecture/07-ecological-mode.md` §1: the literal
/// "Experimental Spatial Ecology" badge, plus the engine, topology, scheduler,
/// RNG contract, evaluator contract, seed, epoch, budget, mutation threshold,
/// variant, bracket mode, and the initial digest.
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
    // `soupBytes()` and `config()` are idempotent on a checkpoint that already
    // passed `EcologyCheckpoint.decode`; wrap defensively so any future
    // contract regression surfaces as a controlled error instead of a top-level
    // throw trap.
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

var runner: EcologyOracleRunner
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
        runner = try EcologyOracleRunner(checkpoint: checkpoint)
        resolvedConfig = runner.config
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
    // The parser already rejects stepBudget <= 0; this guard is a defensive
    // second layer so a future code path cannot trip EcologyConfig's
    // precondition(stepBudget > 0).
    guard budget > 0 else { fail("step budget must be > 0, got \(budget)") }
    let config = EcologyConfig(seed: seed, stepBudget: budget,
                               mutationP32: mutP32, variant: variant,
                               bracketMode: brackets)
    runner = EcologyOracleRunner(config: config)
    resolvedConfig = config
}

// MARK: - Run

print(headerLine(config: resolvedConfig, epoch: runner.epoch, digest: runner.digest))

for _ in 0..<options.epochs {
    let counters: EcologyEpochCounters
    do {
        counters = try runner.runEpoch()
    } catch let e as EcologyContractError {
        fail("epoch \(runner.epoch) failed: \(e)", exitCode: 1)
    } catch {
        fail("epoch \(runner.epoch) failed: \(error)", exitCode: 1)
    }
    print(epochLine(counters))
}

print(finalLine(config: resolvedConfig, epoch: runner.epoch, digest: runner.digest))

// MARK: - Save (after running)

if let saveURL = options.saveURL {
    let checkpoint = EcologyCheckpoint(capturing: runner)
    do {
        let data = try checkpoint.jsonData()
        try data.write(to: saveURL)
    } catch {
        fail("could not write checkpoint to \(saveURL.path): \(error)",
             exitCode: 1)
    }
}

exit(0)
