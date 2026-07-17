import BFFOracle

/// Platform-independent support for the `bff-metal-bench` CLI: strict argument
/// parsing and exit-code policy that must be identical on every host and therefore
/// must be unit-testable *without* a Metal device.
///
/// The CLI's `main.swift` cannot be imported by the test target (it is an
/// executable), so the pieces a reviewer needs to trust — how a `--seeds`/`--seed`
/// token is lexed, and how an evaluator-construction failure maps to a process exit
/// code — live here in the library where `BFFMetalTests` can exercise them directly.

// MARK: - Exit codes

/// The documented process exit codes of `bff-metal-bench`. One place so the CLI, the
/// docs, and the tests cannot drift.
public enum BenchmarkExitCode {
    /// All configs ran, GPU timing present, no shadow mismatch.
    public static let success: Int32 = 0
    /// A shadow mismatch or a generic GPU/runtime failure.
    public static let runtimeFailure: Int32 = 1
    /// Metal is unavailable — either the platform has no Metal at all, or
    /// `MTLCreateSystemDefaultDevice()` returned no default device. Nothing ran.
    public static let metalUnavailable: Int32 = 2
    /// Ran, but the hardware reported no usable command-buffer timestamps and
    /// `--allow-missing-gpu-timing` was not given.
    public static let gpuTimingUnavailable: Int32 = 3
    /// Bad command-line arguments (usage error).
    public static let usage: Int32 = 64
}

/// Classification of an evaluator-construction outcome, decoupled from the
/// Metal-only `MetalBFFEvaluator.EvaluatorError` type so the exit-code policy is
/// testable on non-Metal hosts.
///
/// The contract (blocker: normalize "no Metal / no default device" to exit 2):
/// a missing device normalizes to `metalUnavailable` (2); every *other*
/// initialization or runtime failure stays a distinct `runtimeFailure` (1) so a
/// genuine compile/layout/allocation bug is never masquerading as "no GPU here".
public enum EvaluatorInitOutcome: Equatable {
    case metalUnavailable
    case runtimeFailure

    public var exitCode: Int32 {
        switch self {
        case .metalUnavailable: return BenchmarkExitCode.metalUnavailable
        case .runtimeFailure: return BenchmarkExitCode.runtimeFailure
        }
    }
}

// MARK: - Strict seed parsing

/// Why a `--seeds`/`--seed` token was rejected. Each case is a distinct, testable
/// failure mode; the parser never truncates or wraps a value to make it fit.
public enum SeedParseError: Error, Equatable, CustomStringConvertible {
    /// An empty token — an empty string, or a doubled / leading / trailing comma.
    case emptyToken(index: Int)
    /// A leading `+` or `-`. Seeds are unsigned; signs are not accepted.
    case signNotAllowed(token: String)
    /// The token contains whitespace (leading, trailing, or interior).
    case whitespaceNotAllowed(token: String)
    /// The token has a non-decimal character (letters, `.`, `0x…`, trailing junk).
    case notDecimal(token: String)
    /// All-decimal, but larger than `UInt64.max` — cannot be lexed at all.
    case overflowsUInt64(token: String)
    /// A valid `UInt64` that does not fit the simulator's `UInt32` seed domain.
    case outsideUInt32(value: UInt64, token: String)

    public var description: String {
        switch self {
        case .emptyToken(let i):
            return "empty seed token at position \(i) "
                + "(check for a leading, trailing, or doubled comma)"
        case .signNotAllowed(let t):
            return "seed '\(t)' has a sign; seeds are unsigned decimal integers"
        case .whitespaceNotAllowed(let t):
            return "seed '\(t)' contains whitespace"
        case .notDecimal(let t):
            return "seed '\(t)' is not an unsigned decimal integer"
        case .overflowsUInt64(let t):
            return "seed '\(t)' overflows UInt64"
        case .outsideUInt32(let v, let t):
            return "seed '\(t)' = \(v) is outside the UInt32 seed domain "
                + "(0...\(UInt32.max))"
        }
    }
}

/// Parse a comma-separated `--seeds` value strictly into `UInt32` seeds.
///
/// Contract (deliberately strict — a benchmark seed is a scientific input, so a
/// silently-wrapped seed would be a silently-wrong run):
///
/// 1. Split on `,` *without* dropping empties, so a doubled / leading / trailing
///    comma is a rejected empty token, not silently ignored.
/// 2. Each token is lexed lexically as an unsigned decimal integer: no sign, no
///    whitespace, no `0x`/`0o` prefixes, no decimal point, no trailing junk.
/// 3. The decimal digits are parsed through `UInt64` (so a value beyond `UInt64`
///    is caught as overflow), then required to fit `0...UInt32.max`.
/// 4. Nothing is ever truncated or wrapped; any violation throws `SeedParseError`
///    and the caller exits with the usage code.
///
/// At least one token is always present (an empty input yields one empty token,
/// which is rejected), so a successful return is a non-empty `[UInt32]`.
public func parseSeedList(_ raw: String) throws -> [UInt32] {
    let tokens = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    var seeds: [UInt32] = []
    seeds.reserveCapacity(tokens.count)
    for (index, token) in tokens.enumerated() {
        if token.isEmpty { throw SeedParseError.emptyToken(index: index) }
        if let first = token.first, first == "+" || first == "-" {
            throw SeedParseError.signNotAllowed(token: token)
        }
        if token.contains(where: { $0.isWhitespace }) {
            throw SeedParseError.whitespaceNotAllowed(token: token)
        }
        guard token.unicodeScalars.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            throw SeedParseError.notDecimal(token: token)
        }
        // All-decimal: the only remaining `UInt64` failure is > UInt64.max.
        guard let u64 = UInt64(token) else {
            throw SeedParseError.overflowsUInt64(token: token)
        }
        guard u64 <= UInt64(UInt32.max) else {
            throw SeedParseError.outsideUInt32(value: u64, token: token)
        }
        seeds.append(UInt32(u64))
    }
    return seeds
}

/// Parse a single `--seed` value: exactly one strictly-parsed token.
public func parseSingleSeed(_ raw: String) throws -> UInt32 {
    let seeds = try parseSeedList(raw)
    guard seeds.count == 1 else {
        // A comma made it multi-valued; `--seed` is the single-seed shorthand.
        throw SeedParseError.notDecimal(token: raw)
    }
    return seeds[0]
}
