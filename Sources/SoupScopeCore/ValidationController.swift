/// Pure decision logic for the bounded native-validation run (`--validation-seconds`).
///
/// The Metal app's validation must terminate *finitely* even when the MTKView never
/// receives a drawable or a display callback — so the decision of when (and how) a
/// validation run ends is factored out here as a platform-independent state machine
/// that any host can unit-test. It consumes three display-independent facts —
/// elapsed wall time, completed render submissions, and the current error/mismatch
/// state — and returns a single terminal outcome. It advances **no** epochs and
/// schedules **no** work; it only decides.
///
/// Two things drive it in the app: the MTKView's command-buffer completion handler
/// (the success path, so a run finishes only after a real render has landed) and a
/// one-shot main-run-loop watchdog (the finite backstop, so a run without any
/// drawable still ends). Both feed the same `ValidationRun`, which latches the first
/// terminal outcome so completion exactly once even if they race.

/// Why a validation run ended.
public enum ValidationFailure: String, Equatable, Sendable {
    /// No Metal device ever came up — nothing to validate. Exit code 2.
    case noMetal
    /// An app/evaluator/render error was surfaced. Exit code 1.
    case error
    /// One or more CPU-shadow mismatches were observed. Exit code 1.
    case shadowMismatch
    /// The grace deadline passed with no completed draw (no drawable / no display
    /// callback). Exit code 1.
    case noDrawProgress
}

/// The terminal (or not-yet-terminal) verdict.
public enum ValidationOutcome: Equatable, Sendable {
    case pending
    case success
    case failure(ValidationFailure)

    /// Process exit status: 0 success, 2 no-Metal, 1 any other failure. `pending`
    /// is not terminal and maps to `-1` (never used to exit).
    public var exitCode: Int32 {
        switch self {
        case .pending: return -1
        case .success: return 0
        case .failure(.noMetal): return 2
        case .failure: return 1
        }
    }

    /// Short stable token for the single diagnostic line.
    public var statusToken: String {
        switch self {
        case .pending: return "pending"
        case .success: return "ok"
        case .failure(let f): return f.rawValue
        }
    }
}

/// The display-independent facts a verdict is computed from.
public struct ValidationInputs: Equatable, Sendable {
    /// Seconds elapsed since validation began (never draw-gated).
    public var elapsedSeconds: Double
    /// Render command buffers that have *completed* so far (real progress).
    public var completedDraws: Int
    /// Whether an app/evaluator/render error is currently surfaced.
    public var hasError: Bool
    /// Cumulative CPU-shadow mismatches observed.
    public var shadowMismatch: Int

    public init(elapsedSeconds: Double, completedDraws: Int,
                hasError: Bool, shadowMismatch: Int) {
        self.elapsedSeconds = elapsedSeconds
        self.completedDraws = completedDraws
        self.hasError = hasError
        self.shadowMismatch = shadowMismatch
    }
}

/// The fixed policy of a validation run: the requested render duration, the grace
/// added on top before the no-progress backstop fires, and whether Metal is present.
public struct ValidationPolicy: Equatable, Sendable {
    /// Requested render/advance duration in seconds.
    public let requestedSeconds: Double
    /// Extra wall time allowed, beyond `requestedSeconds`, for the first drawable to
    /// appear before the run fails as no-progress.
    public let graceSeconds: Double
    /// Whether a Metal device came up at all.
    public let metalAvailable: Bool

    /// Default grace beyond the requested duration for a window to produce its first
    /// drawable (a rendering window produces one within a frame; this is generous).
    public static let defaultGraceSeconds: Double = 2.0

    public init(requestedSeconds: Double,
                graceSeconds: Double = ValidationPolicy.defaultGraceSeconds,
                metalAvailable: Bool) {
        self.requestedSeconds = Swift.max(0, requestedSeconds)
        self.graceSeconds = Swift.max(0, graceSeconds)
        self.metalAvailable = metalAvailable
    }

    /// Absolute deadline (seconds from start) after which a run with no completed
    /// draw fails as no-progress rather than hanging.
    public var graceDeadline: Double { requestedSeconds + graceSeconds }

    /// Compute the verdict for one snapshot of facts. Ordering: hard stops
    /// (no-Metal, mismatch, error) win over timing; success needs the full requested
    /// duration *and* at least one completed draw; otherwise the no-progress
    /// backstop fires once past the grace deadline with zero completed draws.
    public func evaluate(_ inp: ValidationInputs) -> ValidationOutcome {
        if !metalAvailable { return .failure(.noMetal) }
        if inp.shadowMismatch > 0 { return .failure(.shadowMismatch) }
        if inp.hasError { return .failure(.error) }
        if inp.elapsedSeconds >= requestedSeconds && inp.completedDraws >= 1 {
            return .success
        }
        if inp.elapsedSeconds >= graceDeadline && inp.completedDraws == 0 {
            return .failure(.noDrawProgress)
        }
        return .pending
    }
}

/// Stateful wrapper that latches the first terminal outcome so a run completes
/// exactly once. `step` returns the terminal outcome the single time it is reached
/// and `nil` on every other call (still-pending, or already-finished) — giving the
/// caller one and only one termination signal even under a watchdog/frame race.
public struct ValidationRun: Equatable, Sendable {
    public let policy: ValidationPolicy
    public private(set) var finished = false
    public private(set) var outcome: ValidationOutcome = .pending

    public init(policy: ValidationPolicy) { self.policy = policy }

    public mutating func step(_ inp: ValidationInputs) -> ValidationOutcome? {
        guard !finished else { return nil }
        let o = policy.evaluate(inp)
        if case .pending = o { return nil }
        finished = true
        outcome = o
        return o
    }
}
