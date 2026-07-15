import Foundation

/// Versioned, Codable golden-vector format for the validation chain of 01 §7.
///
/// A fixture pins everything needed to replay and diff a checkpoint: the run
/// configuration (seed, population, budget, mutation, variant, bracket semantics),
/// the RNG contract, the checkpoint epoch, the exact soup bytes, and the global
/// byte histogram. Fixtures may come from this oracle (self-consistency / GPU
/// diffing, 01 §7.2) or — once the grounding work of 01 §7.1 is done — from an
/// instrumented cubff run. **No genuine cubff fixture exists yet**; see
/// `Docs/GoldenVectors.md` for the import procedure and the parity caveats.
public struct GoldenFixture: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    /// Format version of this file; readers must reject versions they don't know.
    public var formatVersion: Int
    /// Provenance, e.g. `"oracle"` or `"cubff@<commit>"`. Free-form but required.
    public var source: String
    /// Exact command line (or code path) that produced the fixture, for replay.
    public var commandLine: String?
    /// RNG contract the run used (`BFFRandom.contractID`, or a future
    /// `"cubff-compat-..."`). Comparing across contracts is meaningless.
    public var rngContract: String
    /// Full run configuration, including variant and bracket semantics.
    public var config: SimulationConfig
    /// Number of epochs run before capture (soup state is *after* this many epochs).
    public var checkpointEpoch: Int
    /// The exact soup bytes at the checkpoint, base64-encoded
    /// (`config.populationSize * 64` bytes when decoded).
    public var soupBase64: String
    /// Global 256-bin byte histogram of the soup at the checkpoint.
    public var histogram: [UInt64]
    /// Optional summary stats of the checkpoint epoch (the last epoch run).
    public var expectedStats: EpochStats?

    public enum FixtureError: Error, Equatable {
        case unsupportedFormatVersion(Int)
        case corruptSoup(String)
    }

    /// Decode the soup bytes, validating length against the config.
    public func soupBytes() throws -> [UInt8] {
        guard let data = Data(base64Encoded: soupBase64) else {
            throw FixtureError.corruptSoup("soupBase64 is not valid base64")
        }
        let expected = config.populationSize * BFF.tapeSize
        guard data.count == expected else {
            throw FixtureError.corruptSoup(
                "decoded soup is \(data.count) bytes, expected \(expected)")
        }
        return [UInt8](data)
    }

    /// Capture a fixture from a live simulation at its current epoch.
    public init(capturing sim: Simulation, source: String, commandLine: String? = nil) {
        self.formatVersion = Self.currentFormatVersion
        self.source = source
        self.commandLine = commandLine
        self.rngContract = BFFRandom.contractID
        self.config = sim.config
        self.checkpointEpoch = sim.epoch
        self.soupBase64 = Data(sim.soup).base64EncodedString()
        self.histogram = sim.histogram().bins
        self.expectedStats = sim.lastEpochStats
    }

    // MARK: - JSON I/O

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> GoldenFixture {
        let fixture = try JSONDecoder().decode(GoldenFixture.self, from: data)
        guard fixture.formatVersion == currentFormatVersion else {
            throw FixtureError.unsupportedFormatVersion(fixture.formatVersion)
        }
        return fixture
    }

    public func write(to url: URL) throws {
        try jsonData().write(to: url)
    }

    public static func load(from url: URL) throws -> GoldenFixture {
        try decode(from: Data(contentsOf: url))
    }
}

/// Result of diffing a fixture against an actual soup state.
public struct FixtureComparison: Equatable, Sendable {
    public var matches: Bool { issues.isEmpty }
    /// Human-readable descriptions of every divergence found.
    public var issues: [String]
    /// Number of soup bytes that differ (0 when soups match or lengths differ —
    /// see `issues` for the length case).
    public var soupByteMismatchCount: Int
    /// Index of the first differing soup byte, if any.
    public var firstSoupMismatchIndex: Int?
    /// Byte values whose histogram bins differ.
    public var histogramMismatchValues: [Int]
}

public enum FixtureComparator {

    /// Diff a fixture against a soup + histogram (+ optional stats) produced by a
    /// replay. Purely structural: it does not run anything.
    public static func compare(
        fixture: GoldenFixture,
        soup: [UInt8],
        histogram: ByteHistogram,
        stats: EpochStats? = nil
    ) -> FixtureComparison {
        var issues: [String] = []
        var mismatchCount = 0
        var firstMismatch: Int?

        var expectedSoup: [UInt8] = []
        do {
            expectedSoup = try fixture.soupBytes()
        } catch {
            issues.append("fixture soup undecodable: \(error)")
        }

        if !expectedSoup.isEmpty {
            if expectedSoup.count != soup.count {
                issues.append("soup length \(soup.count) != fixture \(expectedSoup.count)")
            } else {
                for i in 0..<soup.count where soup[i] != expectedSoup[i] {
                    if firstMismatch == nil { firstMismatch = i }
                    mismatchCount += 1
                }
                if mismatchCount > 0 {
                    issues.append(
                        "soup diverges at \(mismatchCount) byte(s), first at index \(firstMismatch!) "
                        + "(fixture 0x\(String(expectedSoup[firstMismatch!], radix: 16)), "
                        + "actual 0x\(String(soup[firstMismatch!], radix: 16)))")
                }
            }
        }

        let fixtureHist = ByteHistogram(bins: fixture.histogram)
        let histMismatches = histogram.mismatches(against: fixtureHist)
        let mismatchValues = histMismatches.map(\.value)
        if !histMismatches.isEmpty {
            let preview = histMismatches.prefix(4)
                .map { "bin \($0.value): actual \($0.lhs) vs fixture \($0.rhs)" }
                .joined(separator: "; ")
            issues.append("histogram diverges in \(histMismatches.count) bin(s): \(preview)")
        }

        if let expected = fixture.expectedStats {
            if let actual = stats {
                if actual != expected {
                    issues.append("epoch stats diverge: actual \(actual) vs fixture \(expected)")
                }
            } else {
                issues.append("fixture carries expectedStats but no actual stats were provided")
            }
        }

        return FixtureComparison(
            issues: issues,
            soupByteMismatchCount: mismatchCount,
            firstSoupMismatchIndex: firstMismatch,
            histogramMismatchValues: mismatchValues)
    }

    /// Replay the fixture's configuration from scratch to its checkpoint epoch with
    /// this oracle, then diff. Only valid for fixtures recorded under the oracle's
    /// RNG contract — a cubff-sourced fixture (different RNG) is reported as
    /// incomparable rather than silently mismatching.
    public static func replayAndCompare(fixture: GoldenFixture) -> FixtureComparison {
        guard fixture.rngContract == BFFRandom.contractID else {
            return FixtureComparison(
                issues: ["fixture RNG contract '\(fixture.rngContract)' does not match "
                         + "this oracle's '\(BFFRandom.contractID)'; replay would be meaningless "
                         + "(a cubffCompat mode does not exist yet — see Docs/GoldenVectors.md)"],
                soupByteMismatchCount: 0,
                firstSoupMismatchIndex: nil,
                histogramMismatchValues: [])
        }
        var sim = Simulation(config: fixture.config)
        sim.run(epochs: fixture.checkpointEpoch)
        return compare(fixture: fixture, soup: sim.soup,
                       histogram: sim.histogram(), stats: sim.lastEpochStats)
    }
}
