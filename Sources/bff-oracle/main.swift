import Foundation
import BFFOracle

/// `bff-oracle` — minimal CLI for generating and comparing golden fixtures
/// (Docs/GoldenVectors.md). Deliberately tiny: the library is the product.

let usage = """
usage:
  bff-oracle generate --seed S --population N --epochs E --output PATH
                      [--step-budget B] [--mutation-p32 M]
                      [--variant noheads|bff] [--brackets dynamicScan|jumpTable]
      Run the oracle from scratch and write a golden fixture JSON.

  bff-oracle compare PATH
      Replay a fixture's config from epoch 0 and diff soup, histogram, and stats.
      Exit 0 on match, 2 on mismatch.

  bff-oracle stats --seed S --population N --epochs E
                   [--step-budget B] [--mutation-p32 M]
                   [--variant noheads|bff] [--brackets dynamicScan|jumpTable]
      Run and print per-epoch stats (no fixture written).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n\n" + usage + "\n").utf8))
    exit(1)
}

struct Options {
    var seed: UInt32 = 1
    var population = 64
    var epochs = 1
    var stepBudget = BFF.stepBudget
    var mutationP32 = BFF.defaultMutationP32
    var variant: BFFVariant = .noheads
    var brackets: BracketMode = .dynamicScan
    var output: String?
}

func parseOptions(_ args: [String]) -> Options {
    var opts = Options()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(flag)") }
        return args[i]
    }
    while i < args.count {
        let flag = args[i]
        switch flag {
        case "--seed":
            guard let v = UInt32(value(flag)) else { fail("bad --seed") }
            opts.seed = v
        case "--population":
            guard let v = Int(value(flag)), v > 0, v % 2 == 0 else {
                fail("--population must be positive and even")
            }
            opts.population = v
        case "--epochs":
            guard let v = Int(value(flag)), v >= 0 else { fail("bad --epochs") }
            opts.epochs = v
        case "--step-budget":
            guard let v = Int(value(flag)), v > 0 else { fail("bad --step-budget") }
            opts.stepBudget = v
        case "--mutation-p32":
            guard let v = UInt32(value(flag)) else { fail("bad --mutation-p32") }
            opts.mutationP32 = v
        case "--variant":
            guard let v = BFFVariant(rawValue: value(flag)) else {
                fail("--variant must be noheads or bff")
            }
            opts.variant = v
        case "--brackets":
            guard let v = BracketMode(rawValue: value(flag)) else {
                fail("--brackets must be dynamicScan or jumpTable")
            }
            opts.brackets = v
        case "--output":
            opts.output = value(flag)
        default:
            fail("unknown flag \(flag)")
        }
        i += 1
    }
    return opts
}

func makeConfig(_ o: Options) -> SimulationConfig {
    SimulationConfig(
        seed: o.seed, populationSize: o.population, stepBudget: o.stepBudget,
        mutationP32: o.mutationP32, variant: o.variant, bracketMode: o.brackets)
}

func printStats(_ s: EpochStats) {
    let mean = String(format: "%.1f", s.meanSteps)
    print("epoch \(s.epoch): meanSteps=\(mean) "
          + "halt(budget=\(s.haltBudget) pcOut=\(s.haltPCOut) unmatched=\(s.haltUnmatched)) "
          + "copyWrites=\(s.totalCopyWrites) loopOps=\(s.totalLoopOps) "
          + "remaps=\(s.totalRemapEvents)")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("no command") }

switch command {
case "generate":
    let opts = parseOptions(Array(args.dropFirst()))
    guard let output = opts.output else { fail("generate requires --output") }
    var sim = Simulation(config: makeConfig(opts))
    for s in sim.run(epochs: opts.epochs) { printStats(s) }
    let commandLine = "bff-oracle " + args.joined(separator: " ")
    let fixture = GoldenFixture(capturing: sim, source: "oracle", commandLine: commandLine)
    try fixture.write(to: URL(fileURLWithPath: output))
    let entropy = String(format: "%.4f", sim.histogram().shannonEntropyBitsPerByte)
    print("wrote \(output) (epoch \(sim.epoch), \(sim.soup.count) soup bytes, "
          + "entropy \(entropy) bits/byte)")

case "compare":
    guard args.count == 2 else { fail("compare takes exactly one fixture path") }
    let fixture = try GoldenFixture.load(from: URL(fileURLWithPath: args[1]))
    let result = FixtureComparator.replayAndCompare(fixture: fixture)
    if result.matches {
        print("MATCH: replay reproduces the fixture bit-identically "
              + "(epoch \(fixture.checkpointEpoch), source \(fixture.source))")
    } else {
        print("MISMATCH (\(result.issues.count) issue(s)):")
        for issue in result.issues { print("  - \(issue)") }
        exit(2)
    }

case "stats":
    let opts = parseOptions(Array(args.dropFirst()))
    var sim = Simulation(config: makeConfig(opts))
    for s in sim.run(epochs: opts.epochs) { printStats(s) }

case "--help", "-h", "help":
    print(usage)

default:
    fail("unknown command \(command)")
}
