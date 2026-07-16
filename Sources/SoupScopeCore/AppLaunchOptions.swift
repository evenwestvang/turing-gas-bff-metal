import BFFOracle
import BFFMetal

/// Launch-time configuration for the SoupScope app, parsed from command-line
/// arguments so program count / seed / budget / shadow sample are configurable
/// without any in-app UI (REQUIRED 1). Also carries `--validation-seconds`, the
/// bounded native-validation switch (advance/render for a finite interval, emit
/// one diagnostic line, terminate cleanly) — normal launch omits it and stays
/// interactive.
///
/// Parsing is platform-independent and fully tested; the macOS shell just consumes
/// the result. Defaults are a modest soup suitable for interactive launch on an
/// Apple M4 Max.
public struct AppLaunchOptions: Equatable, Sendable {
    public var seed: UInt32
    public var programCount: Int
    public var stepBudget: Int
    public var mutationP32: UInt32
    public var variant: BFFVariant
    public var shadowSampleCount: Int
    /// Finite render/advance interval in seconds for bounded native validation;
    /// `nil` means interactive (run until the window closes).
    public var validationSeconds: Double?

    public init(seed: UInt32 = 0xB00F,
                programCount: Int = 1_024,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                shadowSampleCount: Int = 8,
                validationSeconds: Double? = nil) {
        self.seed = seed
        self.programCount = programCount
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.shadowSampleCount = shadowSampleCount
        self.validationSeconds = validationSeconds
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case notAnInteger(flag: String, value: String)
        case notANumber(flag: String, value: String)
        case unknownVariant(String)
        case unknownFlag(String)
        /// `--programs` above the 512×256 canonical canvas capacity (131072).
        case programCountExceedsCanvas(count: Int, capacity: Int)

        public var description: String {
            switch self {
            case .missingValue(let f): return "\(f) requires a value"
            case .notAnInteger(let f, let v): return "\(f) requires an integer, got '\(v)'"
            case .notANumber(let f, let v): return "\(f) requires a number, got '\(v)'"
            case .unknownVariant(let v): return "unknown variant '\(v)' (use 'noheads' or 'bff')"
            case .unknownFlag(let f): return "unknown argument '\(f)'"
            case .programCountExceedsCanvas(let n, let cap):
                return "program count \(n) exceeds the 512×256 canonical canvas capacity \(cap)"
            }
        }
    }

    public static let usage = """
    SoupScope launch arguments:
      --seed N               run seed (default 45071)
      --programs EVEN        soup size, positive & even, ≤ 131072 (default 1024)
      --budget N             per-interaction step budget (default \(BFF.stepBudget))
      --mutation-p32 N       mutate iff a uint32 draw < N; 0 disables
      --variant noheads|bff  initial-state variant (default noheads)
      --shadow-sample N      pairs CPU-shadowed per epoch (default 8; 0 disables)
      --validation-seconds S render for S seconds then print a diagnostic and exit
    """

    /// Parse arguments (already stripped of the executable name). Recognizes the
    /// `--flag value` forms above; `--shadow-sample all` shadows every pair.
    public static func parse(_ args: [String]) throws -> AppLaunchOptions {
        var options = AppLaunchOptions()
        var i = 0
        func value(_ flag: String) throws -> String {
            guard i < args.count else { throw ParseError.missingValue(flag) }
            defer { i += 1 }
            return args[i]
        }
        func int(_ flag: String, _ v: String) throws -> Int {
            guard let n = Int(v) else { throw ParseError.notAnInteger(flag: flag, value: v) }
            return n
        }
        func u32(_ flag: String, _ v: String) throws -> UInt32 {
            guard let n = UInt32(v) else { throw ParseError.notAnInteger(flag: flag, value: v) }
            return n
        }

        while i < args.count {
            let flag = args[i]
            i += 1
            switch flag {
            case "--seed": options.seed = try u32(flag, try value(flag))
            case "--programs": options.programCount = try int(flag, try value(flag))
            case "--budget": options.stepBudget = try int(flag, try value(flag))
            case "--mutation-p32": options.mutationP32 = try u32(flag, try value(flag))
            case "--shadow-sample":
                let raw = try value(flag)
                options.shadowSampleCount = (raw == "all")
                    ? options.programCount / 2
                    : try int(flag, raw)
            case "--variant":
                let raw = try value(flag)
                guard let v = BFFVariant(rawValue: raw) else {
                    throw ParseError.unknownVariant(raw)
                }
                options.variant = v
            case "--validation-seconds":
                let raw = try value(flag)
                guard let s = Double(raw) else {
                    throw ParseError.notANumber(flag: flag, value: raw)
                }
                options.validationSeconds = s
            case "--help", "-h":
                // Recognized but not an error; the shell prints usage and continues.
                break
            default:
                throw ParseError.unknownFlag(flag)
            }
        }
        return options
    }

    /// Build the validated `SoupConfig` (clamps an over-large shadow sample to the
    /// pair count so `--shadow-sample all` on any size is always in range). Rejects
    /// program counts above the 512×256 canonical canvas capacity — the canvas is a
    /// visualization constraint, so this gate lives in the app launch/config path
    /// and not in the headless `SoupConfig` used by the CLIs.
    public func soupConfig() throws -> SoupConfig {
        guard programCount <= ProgramGrid.capacity else {
            throw ParseError.programCountExceedsCanvas(count: programCount,
                                                       capacity: ProgramGrid.capacity)
        }
        let pairs = programCount / 2
        let clampedSample = max(0, min(shadowSampleCount, max(pairs, 0)))
        return try SoupConfig(seed: seed, programCount: programCount,
                              stepBudget: stepBudget, mutationP32: mutationP32,
                              variant: variant, shadowSampleCount: clampedSample)
    }
}
