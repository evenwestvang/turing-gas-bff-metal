import Foundation

/// Strict-lexical option parsing, file-loading, and error types for the
/// `bff-ecology-epoch` headless CLI. Lives in the library so unit tests can
/// exercise the parser directly without spawning the binary.
///
/// Normative source: `Docs/Architecture/07-ecological-mode.md` §11 (CLI surface
/// `bff-ecology-epoch`, emits `engine=ecology-v1`) and §9 (checkpoint/replay
/// contract; `BFFECO1` magic, cross-engine rejection).
///
/// Design notes:
/// - Strict lexical numeric parsing: only ASCII decimal digits `0...9` are
///   accepted. Whitespace, signs (`+`/`-`), hex/octal prefixes, exponents, and
///   non-ASCII digit characters are rejected so two runs of the same CLI cannot
///   silently diverge on locale- or `Foundation`-specific `Int(_:)` behavior.
/// - All malformed/oversized/truncated/inconsistent inputs return a controlled
///   `EcologyCLIError` or `EcologyCheckpointLoadError`; the CLI converts these
///   to a nonzero exit (64) and never traps.
/// - Cross-engine rejection: a well-mixed `GoldenFixture` JSON file passed to
///   `--checkpoint` is detected by its `formatVersion`/`rngContract` shape and
///   rejected with a clear `wrongEngineFixture` error before `JSONDecoder`
///   produces an opaque `DecodingError`.

// MARK: - Errors

public enum EcologyCLIError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case malformedNumber(name: String, raw: String)
    case outOfRange(name: String, raw: String)
    case unknownOption(String)
    case invalidEnum(name: String, raw: String, allowed: [String])
    case stepBudgetNotPositive(Int)
    case seedRequiredWithoutCheckpoint
    case checkpointAndSeedMutuallyExclusive
    case checkpointAndConfigShapeConflict(String)
    case infoRequiresCheckpoint
    case infoIncompatible(String)

    public var description: String {
        switch self {
        case .missingValue(let n):
            return "\(n) requires a value"
        case .malformedNumber(let name, let raw):
            return "\(name) requires a strict decimal integer (ASCII digits only), "
                + "got '\(raw)'"
        case .outOfRange(let name, let raw):
            return "\(name) is out of range: '\(raw)'"
        case .unknownOption(let s):
            return "unknown argument '\(s)'"
        case .invalidEnum(let name, let raw, let allowed):
            return "\(name) must be one of \(allowed.joined(separator: "|")), "
                + "got '\(raw)'"
        case .stepBudgetNotPositive(let n):
            return "step budget must be > 0, got \(n)"
        case .seedRequiredWithoutCheckpoint:
            return "--seed is required when --checkpoint is not given"
        case .checkpointAndSeedMutuallyExclusive:
            return "--seed and --checkpoint are mutually exclusive; the seed is "
                + "part of the checkpoint's signed config"
        case .checkpointAndConfigShapeConflict(let flag):
            return "\(flag) may not be combined with --checkpoint; the config is "
                + "part of the checkpoint's signed metadata"
        case .infoRequiresCheckpoint:
            return "--info requires --checkpoint PATH"
        case .infoIncompatible(let flag):
            return "--info is read-only and cannot be combined with \(flag)"
        }
    }
}

public enum EcologyCheckpointLoadError: Error, Equatable, CustomStringConvertible {
    case fileUnreadable(String)
    case empty
    case oversized(Int)
    case invalidJSON(String)
    case wrongEngineFixture(String)
    case contractViolation(String)

    public var description: String {
        switch self {
        case .fileUnreadable(let s):
            return "checkpoint file unreadable: \(s)"
        case .empty:
            return "checkpoint file is empty"
        case .oversized(let n):
            return "checkpoint file is \(n) bytes; max accepted is "
                + "\(EcologyCheckpointFile.maxCheckpointBytes)"
        case .invalidJSON(let s):
            return "checkpoint is not valid JSON: \(s)"
        case .wrongEngineFixture(let s):
            return "checkpoint is \(s); bff-ecology-epoch reads BFFECO1 ecology "
                + "checkpoints only (engine=ecology-v1). Well-mixed runners reject "
                + "ecology checkpoints the same way."
        case .contractViolation(let s):
            return "checkpoint contract violation: \(s)"
        }
    }
}

// MARK: - Options

public struct EcologyCLIOptions: Equatable, Sendable {
    public var seed: UInt32?
    public var stepBudget: Int?
    public var mutationP32: UInt32?
    public var variant: BFFVariant?
    public var bracketMode: BracketMode?
    public var epochs: Int
    public var checkpointURL: URL?
    public var saveURL: URL?
    public var infoOnly: Bool

    public init(seed: UInt32? = nil,
                stepBudget: Int? = nil,
                mutationP32: UInt32? = nil,
                variant: BFFVariant? = nil,
                bracketMode: BracketMode? = nil,
                epochs: Int = 0,
                checkpointURL: URL? = nil,
                saveURL: URL? = nil,
                infoOnly: Bool = false) {
        self.seed = seed
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.bracketMode = bracketMode
        self.epochs = epochs
        self.checkpointURL = checkpointURL
        self.saveURL = saveURL
        self.infoOnly = infoOnly
    }
}

// MARK: - Strict lexical numeric parsing

public enum EcologyCLIParser {

    /// Parse a strict decimal `UInt32`: ASCII digits `0...9` only. Rejects empty
    /// strings, signs, whitespace, hex/octal prefixes, exponents, and non-ASCII
    /// Unicode digit characters. Returns a `malformedNumber` error for any
    /// non-digit byte; an `outOfRange` error when all bytes are digits but the
    /// value does not fit in `UInt32`.
    public static func parseUInt32(_ raw: String, name: String) throws -> UInt32 {
        guard !raw.isEmpty else {
            throw EcologyCLIError.malformedNumber(name: name, raw: raw)
        }
        for scalar in raw.unicodeScalars {
            guard scalar.value >= 0x30 && scalar.value <= 0x39 else {
                throw EcologyCLIError.malformedNumber(name: name, raw: raw)
            }
        }
        guard let value = UInt32(raw) else {
            throw EcologyCLIError.outOfRange(name: name, raw: raw)
        }
        return value
    }

    /// Parse a strict decimal non-negative `Int`: ASCII digits `0...9` only.
    /// Same lexical rules as `parseUInt32`; the result is an `Int` so callers
    /// can apply their own upper-bound range checks (e.g. step budget).
    public static func parseNonNegativeInt(_ raw: String, name: String) throws -> Int {
        guard !raw.isEmpty else {
            throw EcologyCLIError.malformedNumber(name: name, raw: raw)
        }
        for scalar in raw.unicodeScalars {
            guard scalar.value >= 0x30 && scalar.value <= 0x39 else {
                throw EcologyCLIError.malformedNumber(name: name, raw: raw)
            }
        }
        guard let value = Int(raw) else {
            throw EcologyCLIError.outOfRange(name: name, raw: raw)
        }
        return value
    }

    /// Parse the full argument list. `--help`/`-h` must be handled by the caller
    /// before invoking this method (they print usage and exit 0).
    public static func parse(args: [String]) throws -> EcologyCLIOptions {
        var opts = EcologyCLIOptions()
        var i = 0

        func value(_ name: String) throws -> String {
            i += 1
            guard i < args.count else {
                throw EcologyCLIError.missingValue(name)
            }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--seed":
                let raw = try value(arg)
                opts.seed = try parseUInt32(raw, name: "--seed")
            case "--epochs":
                let raw = try value(arg)
                opts.epochs = try parseNonNegativeInt(raw, name: "--epochs")
            case "--budget":
                let raw = try value(arg)
                let n = try parseNonNegativeInt(raw, name: "--budget")
                guard n > 0 else {
                    throw EcologyCLIError.stepBudgetNotPositive(n)
                }
                opts.stepBudget = n
            case "--mutation-p32":
                let raw = try value(arg)
                opts.mutationP32 = try parseUInt32(raw, name: "--mutation-p32")
            case "--variant":
                let raw = try value(arg)
                guard let v = BFFVariant(rawValue: raw) else {
                    throw EcologyCLIError.invalidEnum(
                        name: "--variant", raw: raw,
                        allowed: BFFVariant.allCases.map(\.rawValue))
                }
                opts.variant = v
            case "--brackets":
                let raw = try value(arg)
                guard let v = BracketMode(rawValue: raw) else {
                    throw EcologyCLIError.invalidEnum(
                        name: "--brackets", raw: raw,
                        allowed: BracketMode.allCases.map(\.rawValue))
                }
                opts.bracketMode = v
            case "--checkpoint":
                let raw = try value(arg)
                opts.checkpointURL = URL(fileURLWithPath: raw)
            case "--save":
                let raw = try value(arg)
                opts.saveURL = URL(fileURLWithPath: raw)
            case "--info":
                opts.infoOnly = true
            default:
                throw EcologyCLIError.unknownOption(arg)
            }
            i += 1
        }

        try validate(opts: &opts)
        return opts
    }

    private static func validate(opts: inout EcologyCLIOptions) throws {
        if opts.infoOnly {
            guard opts.checkpointURL != nil else {
                throw EcologyCLIError.infoRequiresCheckpoint
            }
            if opts.saveURL != nil {
                throw EcologyCLIError.infoIncompatible("--save")
            }
            if opts.epochs != 0 {
                throw EcologyCLIError.infoIncompatible("--epochs")
            }
            if opts.seed != nil || opts.stepBudget != nil
                || opts.mutationP32 != nil || opts.variant != nil
                || opts.bracketMode != nil {
                throw EcologyCLIError.infoIncompatible(
                    "config-shaping options (--seed/--budget/--mutation-p32/--variant/--brackets)")
            }
        }

        if opts.checkpointURL != nil {
            if opts.seed != nil {
                throw EcologyCLIError.checkpointAndSeedMutuallyExclusive
            }
            if opts.stepBudget != nil {
                throw EcologyCLIError.checkpointAndConfigShapeConflict("--budget")
            }
            if opts.mutationP32 != nil {
                throw EcologyCLIError.checkpointAndConfigShapeConflict("--mutation-p32")
            }
            if opts.variant != nil {
                throw EcologyCLIError.checkpointAndConfigShapeConflict("--variant")
            }
            if opts.bracketMode != nil {
                throw EcologyCLIError.checkpointAndConfigShapeConflict("--brackets")
            }
        } else if opts.seed == nil {
            throw EcologyCLIError.seedRequiredWithoutCheckpoint
        }
    }
}

// MARK: - Checkpoint file loader

public enum EcologyCheckpointFile {
    /// Maximum accepted checkpoint file size. The canonical 8 MiB ecology soup
    /// base64-encodes to ~11.2 MiB plus a few hundred bytes of metadata. 16 MiB
    /// bounds any valid checkpoint and rejects malformed oversized input before
    /// any JSON parsing begins.
    public static let maxCheckpointBytes: Int = 16 * 1024 * 1024

    /// Load and fully validate a `BFFECO1` checkpoint from disk. Performs, in
    /// order:
    ///   1. File size and read checks (empty / oversized / unreadable).
    ///   2. JSON well-formedness (any `JSONSerialization` failure is reported).
    ///   3. Well-mixed `GoldenFixture` shape detection: a JSON object carrying
    ///      `formatVersion` and `rngContract` but no `magic`/`engineID` is a
    ///      well-mixed fixture and is rejected with `wrongEngineFixture` before
    ///      an opaque `DecodingError` is produced.
    ///   4. `EcologyCheckpoint.decode(from:)`, which runs `validateMetadata()`
    ///      (magic, schemaVersion, engineID, topologyID, schedulerID,
    ///      rngContractID, evaluatorContractID, stepBudget, epoch range) and
    ///      `soupBytes()` (decoded soup length matches the canonical 8 MiB
    ///      topology). Any failure is wrapped as `contractViolation`.
    public static func load(from url: URL) throws -> EcologyCheckpoint {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EcologyCheckpointLoadError.fileUnreadable(error.localizedDescription)
        }
        return try decode(data: data)
    }

    /// Decode and fully validate a `BFFECO1` checkpoint from in-memory bytes.
    /// See `load(from:)` for the validation stages.
    public static func decode(data: Data) throws -> EcologyCheckpoint {
        guard !data.isEmpty else { throw EcologyCheckpointLoadError.empty }
        guard data.count <= maxCheckpointBytes else {
            throw EcologyCheckpointLoadError.oversized(data.count)
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EcologyCheckpointLoadError.invalidJSON(error.localizedDescription)
        }

        if let obj = parsed as? [String: Any] {
            let hasFormatVersion = obj["formatVersion"] != nil
            let hasRngContract = obj["rngContract"] != nil
            let hasMagic = obj["magic"] != nil
            let hasEngineID = obj["engineID"] != nil
            if hasFormatVersion && hasRngContract && !hasMagic && !hasEngineID {
                throw EcologyCheckpointLoadError.wrongEngineFixture(
                    "a well-mixed GoldenFixture (counter-pcg-v1)")
            }
        }

        do {
            return try EcologyCheckpoint.decode(from: data)
        } catch let err as EcologyContractError {
            throw EcologyCheckpointLoadError.contractViolation("\(err)")
        } catch let err as DecodingError {
            throw EcologyCheckpointLoadError.invalidJSON(err.localizedDescription)
        } catch {
            throw EcologyCheckpointLoadError.invalidJSON("\(error)")
        }
    }
}
