/// bff-metal-parity — command-line GPU fixture parity validation.
///
/// Runs every committed cubff evaluator fixture through the Metal dynamic-scan
/// evaluator and checks final tapes and operation accounting against both the
/// fixture (genuine cubff output) and the CPU oracle. Exits 0 only on exact
/// parity; on Linux (or any platform without Metal) it states so and exits 2 —
/// it never pretends a GPU ran.
///
/// Usage (from the repository root):
///     swift run bff-metal-parity [--fixtures <path>]
///
/// The default fixture path is relative to the working directory, so run it
/// from the checkout root or pass --fixtures explicitly.

import BFFOracle
import Foundation

let defaultFixturePath = "Tests/BFFOracleTests/Fixtures/cubff-evaluator-v1.json"

func fail(_ message: String, exitCode: Int32) -> Never {
    FileHandle.standardError.write(Data(("bff-metal-parity: " + message + "\n").utf8))
    exit(exitCode)
}

var fixturePath = defaultFixturePath
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--fixtures":
        guard let value = arguments.first else {
            fail("--fixtures requires a path", exitCode: 64)
        }
        arguments.removeFirst()
        fixturePath = value
    case "--help", "-h":
        print("usage: bff-metal-parity [--fixtures <cubff-evaluator fixture JSON>]")
        exit(0)
    default:
        fail("unknown argument '\(argument)'", exitCode: 64)
    }
}

#if canImport(Metal)
import BFFMetal

let fixtureURL = URL(fileURLWithPath: fixturePath)
guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
    fail("fixture file not found at '\(fixturePath)' — run from the repository "
         + "root or pass --fixtures", exitCode: 66)
}

do {
    let file = try CubffFixtureFile.load(from: fixtureURL)
    print("fixtures: \(fixturePath) (\(file.cases.count) cases, "
          + "upstream \(file.upstream.commit))")
    let report = try GPUFixtureParityRunner.run(file: file)
    for line in report.summaryLines() {
        print(line)
    }
    exit(report.allPassed ? 0 : 1)
} catch {
    fail("\(error)", exitCode: 1)
}
#else
print("bff-metal-parity: Metal is unavailable on this platform; GPU parity can "
      + "only be validated on macOS (see Docs/GPUFixtureParity.md). "
      + "Nothing was executed.")
exit(2)
#endif
