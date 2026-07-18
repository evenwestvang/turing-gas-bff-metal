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
    /// Opt-in per-frame host-stage timing (`--frame-stage-timing`). Off by default. When
    /// on, the app folds `AppFrameStageSample`s and appends an `AppFrameStageAttribution`
    /// summary to the validation diagnostic line, including a separate soup-buffer
    /// allocation/copy stage and signed reconciliation validity. It never changes
    /// rendering, the soup, or the simulation — a handful of monotonic reads per frame —
    /// and is only wired into the Metal shell (a non-Metal host produces no frames to
    /// time).
    public var frameStageTiming: Bool
    /// Experimental GPU-resident app integration. Omitted by default so the existing
    /// CPU-snapshot app path remains the product default.
    public var simulationMode: AppSimulationMode
    public var residentPlanner: ResidentPairingPlanner
    public var residentEpochLimit: Int?
    public var residentSecondsLimit: Double?
    public var residentTinyValidation: Bool
    public var residentCheckpointInterval: Int
    public var residentVisualizationWidth: Int

    public init(seed: UInt32 = 0xB00F,
                programCount: Int = ProgramGrid.capacity,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                shadowSampleCount: Int = 8,
                validationSeconds: Double? = nil,
                frameStageTiming: Bool = false,
                simulationMode: AppSimulationMode = .nonResident,
                residentPlanner: ResidentPairingPlanner = .keyed,
                residentEpochLimit: Int? = nil,
                residentSecondsLimit: Double? = nil,
                residentTinyValidation: Bool = false,
                residentCheckpointInterval: Int = 0,
                residentVisualizationWidth: Int = ProgramGrid.canonicalWidth) {
        self.seed = seed
        self.programCount = programCount
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.shadowSampleCount = shadowSampleCount
        self.validationSeconds = validationSeconds
        self.frameStageTiming = frameStageTiming
        self.simulationMode = simulationMode
        self.residentPlanner = residentPlanner
        self.residentEpochLimit = residentEpochLimit
        self.residentSecondsLimit = residentSecondsLimit
        self.residentTinyValidation = residentTinyValidation
        self.residentCheckpointInterval = residentCheckpointInterval
        self.residentVisualizationWidth = residentVisualizationWidth
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case notAnInteger(flag: String, value: String)
        case notANumber(flag: String, value: String)
        case unknownVariant(String)
        case unknownPlanner(String)
        case unknownFlag(String)
        /// `--programs` above the 512×256 canonical canvas capacity (131072).
        case programCountExceedsCanvas(count: Int, capacity: Int)
        case conflictingResidentLimits

        public var description: String {
            switch self {
            case .missingValue(let f): return "\(f) requires a value"
            case .notAnInteger(let f, let v): return "\(f) requires an integer, got '\(v)'"
            case .notANumber(let f, let v): return "\(f) requires a number, got '\(v)'"
            case .unknownVariant(let v): return "unknown variant '\(v)' (use 'noheads' or 'bff')"
            case .unknownPlanner(let v): return "unknown resident planner '\(v)' (use 'keyed' or 'cpu-upload')"
            case .unknownFlag(let f): return "unknown argument '\(f)'"
            case .programCountExceedsCanvas(let n, let cap):
                return "program count \(n) exceeds the 512×256 canonical canvas capacity \(cap)"
            case .conflictingResidentLimits:
                return "use at most one of --resident-epochs or --resident-seconds"
            }
        }
    }

    public static let usage = """
    SoupScope launch arguments:
      --seed N               run seed (default 45071)
      --programs EVEN        soup size, positive & even, ≤ 131072 (default 131072 = ProgramGrid.capacity)
      --budget N             per-interaction step budget (default \(BFF.stepBudget))
      --mutation-p32 N       mutate iff a uint32 draw < N; 0 disables
      --variant noheads|bff  initial-state variant (default noheads)
      --shadow-sample N      pairs CPU-shadowed per epoch (default 8; 0 disables)
      --validation-seconds S render for S seconds then print a diagnostic and exit
      --frame-stage-timing   opt in to per-frame host-stage timing in the diagnostic
      --resident             opt into GPU-resident simulation/rendering
      --resident-planner keyed|cpu-upload
                             keyed = parallel-swap-or-not-v1; cpu-upload = cpu-upload-fisher-yates-v1
      --resident-epochs N    resident measurement bound; print diagnostics and exit
      --resident-seconds S   resident measurement bound; print diagnostics and exit
      --resident-tiny-validation
                             checkpoint/capture/shadow resident epochs against the CPU reference
      --resident-checkpoint-interval N
                             full-soup checkpoint cadence; 0 disables (default 0)
      --resident-visualization-width N
                             resident visualization texture width (default 512)
    """

    /// Parse arguments (already stripped of the executable name). Recognizes the
    /// `--flag value` forms above; `--shadow-sample all` shadows every pair.
    ///
    /// `all` resolves to `programCount / 2` against the *final* program count, so the
    /// result is independent of whether `--programs` precedes or follows
    /// `--shadow-sample all` on the command line (resolution is deferred to after the
    /// whole argument list is consumed).
    public static func parse(_ args: [String]) throws -> AppLaunchOptions {
        var options = AppLaunchOptions()
        var shadowSampleAll = false
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
                if raw == "all" {
                    // Resolve after the whole list is parsed, against the final program
                    // count — order-independent (see below).
                    shadowSampleAll = true
                } else {
                    shadowSampleAll = false
                    options.shadowSampleCount = try int(flag, raw)
                }
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
            case "--frame-stage-timing":
                options.frameStageTiming = true
            case "--resident":
                options.simulationMode = .resident
            case "--resident-planner":
                let raw = try value(flag)
                do {
                    options.residentPlanner = try ResidentPairingPlanner(cliValue: raw)
                    options.simulationMode = .resident
                } catch {
                    throw ParseError.unknownPlanner(raw)
                }
            case "--resident-epochs":
                options.residentEpochLimit = try int(flag, try value(flag))
                options.simulationMode = .resident
            case "--resident-seconds":
                let raw = try value(flag)
                guard let s = Double(raw) else {
                    throw ParseError.notANumber(flag: flag, value: raw)
                }
                options.residentSecondsLimit = s
                options.simulationMode = .resident
            case "--resident-tiny-validation":
                options.residentTinyValidation = true
                options.simulationMode = .resident
            case "--resident-checkpoint-interval":
                options.residentCheckpointInterval = try int(flag, try value(flag))
                options.simulationMode = .resident
            case "--resident-visualization-width":
                options.residentVisualizationWidth = try int(flag, try value(flag))
                options.simulationMode = .resident
            case "--help", "-h":
                // Recognized but not an error; the shell prints usage and continues.
                break
            default:
                throw ParseError.unknownFlag(flag)
            }
        }
        // `--shadow-sample all` resolves here, against the final program count, so it is
        // independent of the order of `--programs` and `--shadow-sample` on the line.
        if shadowSampleAll {
            options.shadowSampleCount = max(0, options.programCount / 2)
        }
        if options.residentEpochLimit != nil && options.residentSecondsLimit != nil {
            throw ParseError.conflictingResidentLimits
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

    public func residentRunPlan() -> ResidentAppRunPlan {
        let limit: ResidentRunLimit
        if let residentEpochLimit {
            limit = .epochs(residentEpochLimit)
        } else if let residentSecondsLimit {
            limit = .seconds(residentSecondsLimit)
        } else if residentTinyValidation {
            limit = .epochs(1)
        } else {
            limit = .unbounded
        }
        return ResidentAppRunPlan(
            enabled: simulationMode == .resident,
            planner: residentPlanner,
            limit: limit,
            tinyValidation: residentTinyValidation,
            checkpointInterval: residentTinyValidation ? 1 : residentCheckpointInterval,
            capturePairTapes: residentTinyValidation,
            shadowSampleCount: residentTinyValidation ? nil : 0,
            visualizationWidth: residentVisualizationWidth)
    }

    public func residentConfig() throws -> ResidentEpochConfig {
        guard programCount <= ProgramGrid.capacity else {
            throw ParseError.programCountExceedsCanvas(count: programCount,
                                                       capacity: ProgramGrid.capacity)
        }
        let plan = residentRunPlan()
        return try ResidentEpochConfig(seed: seed,
                                      programCount: programCount,
                                      stepBudget: stepBudget,
                                      mutationP32: mutationP32,
                                      variant: variant,
                                      planner: plan.planner,
                                      shadowSampleCount: plan.shadowSampleCount,
                                      checkpointInterval: plan.checkpointInterval,
                                      capturePairTapes: plan.capturePairTapes,
                                      visualizationEnabled: true,
                                      visualizationWidth: plan.visualizationWidth,
                                      pairingDiagnosticsEnabled: false)
    }
}
