import Foundation

/// Evaluator-level golden fixtures produced by executing the pinned, unmodified
/// cubff evaluator source (`Tools/cubff-grounding/generate.sh`).
///
/// This is a deliberately separate format from `GoldenFixture`:
/// - `GoldenFixture` pins whole-soup **simulation** checkpoints under the oracle's
///   own `counter-pcg-v1` RNG contract.
/// - `CubffFixtureFile` pins single-interaction **evaluator** behavior against
///   cubff itself: fixed 128-byte input tape in, final tape + op count out. No RNG
///   is involved, so these are the strongest cross-implementation anchor available
///   without porting cubff's RNG/shuffle. See `Docs/CubffGrounding.md`.
public struct CubffFixtureFile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public struct Upstream: Codable, Equatable, Sendable {
        /// Upstream repository URL.
        public var url: String
        /// Exact upstream commit SHA the evaluator was compiled from.
        public var commit: String
        /// Upstream source files the harness compiled.
        public var sourceFiles: [String]
        /// Compiler/flags facts of the generating build.
        public var build: String
    }

    public struct Generator: Codable, Equatable, Sendable {
        public var command: String
        public var version: Int
    }

    public struct Case: Codable, Equatable, Sendable {
        public var name: String
        /// Upstream language name: `"bff"` (seeded heads) or `"bff_noheads"`.
        public var variant: String
        public var stepBudget: Int
        /// Input 128-byte pair tape, lowercase hex.
        public var inputTapeHex: String
        /// Final tape after cubff's `Evaluate`, lowercase hex.
        public var expectedTapeHex: String
        /// cubff `Evaluate` return value: executed steps minus null/non-command
        /// "comment" steps (`i - nskip` in `bff.inc.h`).
        public var expectedOps: Int
        public var note: String?

        public var inputTape: [UInt8]? { Self.bytes(fromHex: inputTapeHex) }
        public var expectedTape: [UInt8]? { Self.bytes(fromHex: expectedTapeHex) }

        /// The oracle variant this case runs under, if the upstream name is known.
        public var oracleVariant: BFFVariant? {
            switch variant {
            case "bff_noheads": return .noheads
            case "bff": return .seededHeads
            default: return nil
            }
        }

        static func bytes(fromHex hex: String) -> [UInt8]? {
            guard hex.count % 2 == 0 else { return nil }
            var out = [UInt8]()
            out.reserveCapacity(hex.count / 2)
            var iterator = hex.makeIterator()
            while let hi = iterator.next() {
                guard let lo = iterator.next(),
                      let h = hi.hexDigitValue, let l = lo.hexDigitValue else {
                    return nil
                }
                out.append(UInt8(h << 4 | l))
            }
            return out
        }
    }

    public var formatVersion: Int
    public var upstream: Upstream
    public var generator: Generator
    /// Human-readable statement of what each case pins.
    public var observables: String
    public var cases: [Case]

    public static func load(from url: URL) throws -> CubffFixtureFile {
        let file = try JSONDecoder().decode(CubffFixtureFile.self,
                                            from: Data(contentsOf: url))
        guard file.formatVersion == currentFormatVersion else {
            throw GoldenFixture.FixtureError.unsupportedFormatVersion(file.formatVersion)
        }
        return file
    }
}

public enum CubffFixtureComparator {

    /// Run one cubff evaluator case through the oracle and return every
    /// divergence, empty when the oracle matches cubff exactly.
    ///
    /// cubff has no jump table: its taken brackets always scan the live tape, so
    /// cases are compared against the oracle's normative `.dynamicScan` mode. The
    /// comparable observables are the final tape and cubff's op count
    /// (`InteractionResult.commandSteps`); cubff exposes no halt reason or
    /// per-op counters.
    public static func compare(_ c: CubffFixtureFile.Case) -> [String] {
        guard let variant = c.oracleVariant else {
            return ["unknown variant '\(c.variant)'"]
        }
        guard let input = c.inputTape, input.count == BFF.pairTapeSize else {
            return ["undecodable or wrong-size input tape"]
        }
        guard let expected = c.expectedTape, expected.count == BFF.pairTapeSize else {
            return ["undecodable or wrong-size expected tape"]
        }

        let r = BFFInterpreter.run(pairTape: input, variant: variant,
                                   bracketMode: .dynamicScan,
                                   stepBudget: c.stepBudget)
        var issues: [String] = []
        if r.tape != expected {
            let first = (0..<BFF.pairTapeSize).first { r.tape[$0] != expected[$0] }!
            let count = (0..<BFF.pairTapeSize).count { r.tape[$0] != expected[$0] }
            issues.append("final tape diverges at \(count) byte(s), first at "
                          + "index \(first): oracle 0x\(String(r.tape[first], radix: 16)) "
                          + "vs cubff 0x\(String(expected[first], radix: 16))")
        }
        if r.commandSteps != c.expectedOps {
            issues.append("op count diverges: oracle \(r.commandSteps) "
                          + "(steps \(r.steps) - noops \(r.noopSteps)) "
                          + "vs cubff \(c.expectedOps)")
        }
        return issues
    }
}
