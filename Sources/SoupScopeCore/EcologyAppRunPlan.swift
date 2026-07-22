import BFFOracle
import Foundation

/// Experimental "SoupScope Spatial Ecology" app integration plan.
///
/// This is a **separate engine** from `ResidentAppRunPlan`: it drives the
/// accepted `EcologyMetalEpochRunner` (BFF-Ecology v1 contract — fixed
/// 512×256 torus, edge-color-sync scheduler, ecology-counter-pcg RNG) through
/// an **app-safe** execution path that shares the CLI's accepted semantics but
/// performs no full-soup CPU readback, no CPU digest, and no GPU wait on the
/// display thread. The plan is a pure, immutable value so interactive Reset
/// reconstructs the driver from it deterministically.
///
/// Naming discipline: this type and its channels are prefixed `Ecology…` and
/// deliberately named apart from `ResidentAppRunPlan` / `ResidentViz…`. The
/// ecology engine constructs neither the legacy `SoupRunner` nor the grounded
/// `ResidentSimulationDriver`; it routes through `EcologySimulationDriver`.
///
/// The ecology topology is fixed (`EcologyTopology.siteCount` = 131,072 =
/// `ProgramGrid.capacity`), so the plan carries no program-count or
/// visualization-width knob — the canvas and the soup are pinned by the
/// contract, not configurable at launch.
public struct EcologyAppRunPlan: Equatable, Sendable {
    public var enabled: Bool
    public var seed: UInt32
    public var stepBudget: Int
    public var mutationP32: UInt32
    public var variant: BFFVariant
    public var bracketMode: BracketMode
    public var limit: ResidentRunLimit
    public var tinyValidation: Bool

    public init(enabled: Bool,
                seed: UInt32,
                stepBudget: Int = BFF.stepBudget,
                mutationP32: UInt32 = BFF.defaultMutationP32,
                variant: BFFVariant = .noheads,
                bracketMode: BracketMode = .dynamicScan,
                limit: ResidentRunLimit = .unbounded,
                tinyValidation: Bool = false) {
        self.enabled = enabled
        self.seed = seed
        self.stepBudget = stepBudget
        self.mutationP32 = mutationP32
        self.variant = variant
        self.bracketMode = bracketMode
        self.limit = limit
        self.tinyValidation = tinyValidation
    }

    /// The fixed ecology topology site count (512 × 256), sourced from
    /// `EcologyTopology`/`ProgramGrid` — never a duplicated literal.
    public static let siteCount: Int = EcologyTopology.siteCount

    /// The persistent, user-visible label for this mode. Exactly the string
    /// the headless ecology CLIs already emit in their header line, so the app,
    /// the Metal CLI, and the CPU CLI share one source of truth.
    public static let label = "Experimental Spatial Ecology"

    /// The ecology evaluator contract token, matching the headless CLI's
    /// `evaluatorContractID` form (variant:bracketMode).
    public var evaluatorContractID: String {
        "bff-evaluator-v1:\(variant.rawValue):\(bracketMode.rawValue)"
    }
}

/// Ecology HUD diagnostics block. Carries three explicitly separated
/// epoch/phase domains so the HUD never conflates them:
///
/// 1. **Produced** — latest completed/produced simulation epoch and the
///    producing phase, sourced from the simulation report. Always set after
///    the first app-safe epoch report arrives. When no ecology epoch has
///    completed (`producedEpoch == 0`), `producedPhase` is `nil`
///    (unavailable) — it is never fabricated as `H0`. This is simulation
///    diagnostics only; it must not be presented as the displayed lease.
///
/// 2. **Published** — latest successfully published immutable snapshot
///    source epoch and phase, sourced from the snapshot ring's
///    `publishedSourceEpoch` (set only when `state.publish()` succeeds).
///    `nil` until the first successful ring publication completes.
///    Skipped reservation, failed blit, and first-publication absence leave
///    it `nil` (or at its prior truthful value after a later publication).
///
/// 3. **Displayed** — actually displayed immutable snapshot source epoch and
///    phase, sourced from the lease's `sourceEpoch` the renderer submitted a
///    command buffer with. `nil` until the renderer submits a frame using a
///    valid immutable ecology lease. A displayed lease may be recorded BEFORE
///    the first simulation report arrives: in that case `ecology` is
///    initialized with ONLY the displayed domain set (produced and published
///    remain `nil`/unavailable), and a later report adds produced/published
///    state while preserving the displayed metadata. The neutral fallback path
///    never fabricates these — it leaves them at their prior value (or `nil`
///    if no valid lease has ever been rendered).
///
/// This is a diagnostic surface only — it never claims energy, death, movement,
/// predation, fitness, reproduction, or paper reproduction. The fields are
/// the accepted ecology epoch counters (steps, halt mix, copy writes,
/// remapEvents) and the producer's GPU timing attribution.
public struct EcologyHUDDiagnostics: Equatable, Sendable {
    // MARK: - Produced (simulation diagnostics)
    /// Latest completed/produced simulation epoch (1-indexed completed count:
    /// `Int(counters.epoch) + 1` for the latest report), or `0` when no
    /// ecology epoch has completed yet (the displayed-only state initialized
    /// by `noteEcologyDisplayedLease` before the first report). Always set to
    /// a value `>= 1` after the first app-safe epoch report arrives.
    public var producedEpoch: Int
    /// The producing phase for the latest completed simulation epoch
    /// (`EcologyMatchingPhase(epoch: counters.epoch).label`). `nil`
    /// (unavailable) when no ecology epoch has completed yet
    /// (`producedEpoch == 0`) — never fabricated as `H0`.
    public var producedPhase: String?

    // MARK: - Published (immutable snapshot ring)
    /// Latest successfully published immutable snapshot source epoch, or
    /// `nil` if no publication has completed yet. Derived from the snapshot
    /// ring's `publishedSourceEpoch`, which is set only when `state.publish()`
    /// succeeds (not on attempted production).
    public var publishedSourceEpoch: Int?
    /// The phase for the published source epoch
    /// (`EcologyMatchingPhase(epoch: publishedSourceEpoch - 1).label`), or
    /// `nil` if no publication has completed yet.
    public var publishedPhase: String?

    // MARK: - Displayed (renderer-submitted lease)
    /// Actually displayed immutable snapshot source epoch the renderer
    /// submitted a command buffer with, or `nil` if no valid lease has ever
    /// been rendered. Updated only on the valid-lease render path; the
    /// neutral fallback never fabricates this.
    public var displayedSourceEpoch: Int?
    /// The phase for the displayed source epoch
    /// (`EcologyMatchingPhase(epoch: displayedSourceEpoch - 1).label`), or
    /// `nil` if no valid lease has ever been rendered.
    public var displayedPhase: String?

    // MARK: - Producer GPU timing + readback accounting
    public var epochWallMs: Double
    public var mutateGpuMs: Double?
    public var evalGpuMs: Double?
    public var visualizationGpuMs: Double?
    public var snapshotBytes: Int
    public var readbackBytes: Int
    public var failureCount: Int
    public var unknownHalts: Int

    public init(producedEpoch: Int,
                producedPhase: String?,
                publishedSourceEpoch: Int?,
                publishedPhase: String?,
                displayedSourceEpoch: Int?,
                displayedPhase: String?,
                epochWallMs: Double,
                mutateGpuMs: Double?,
                evalGpuMs: Double?,
                visualizationGpuMs: Double?,
                snapshotBytes: Int,
                readbackBytes: Int,
                failureCount: Int,
                unknownHalts: Int) {
        self.producedEpoch = producedEpoch
        self.producedPhase = producedPhase
        self.publishedSourceEpoch = publishedSourceEpoch
        self.publishedPhase = publishedPhase
        self.displayedSourceEpoch = displayedSourceEpoch
        self.displayedPhase = displayedPhase
        self.epochWallMs = epochWallMs
        self.mutateGpuMs = mutateGpuMs
        self.evalGpuMs = evalGpuMs
        self.visualizationGpuMs = visualizationGpuMs
        self.snapshotBytes = snapshotBytes
        self.readbackBytes = readbackBytes
        self.failureCount = failureCount
        self.unknownHalts = unknownHalts
    }
}

/// Ecology final diagnostic — the terminal JSON line a bounded/tiny-validation
/// ecology run emits. A **distinct type** from `ResidentFinalDiagnostic`: the
/// ecology path must not label latest-produced state as texture source /
/// published / displayed, so this type carries explicit `producedEpoch`,
/// `publishedSourceEpoch` (nullable), and `displayedSourceEpoch` (nullable)
/// fields with truthful names. The resident diagnostic schema and default
/// behavior are unchanged.
///
/// `publishedSourceEpoch` is `nil` if no ring publication ever completed
/// (first-publication absence, skipped reservation, failed blit, or a
/// reset/stop before any publication landed). `displayedSourceEpoch` is `nil`
/// if the renderer never submitted a command buffer using a valid immutable
/// ecology lease. `producedPhase` is `nil` (unavailable) when no ecology
/// epoch has completed (`producedEpoch == 0`) — it is never fabricated as
/// `H0`. Both published/displayed fields are derived from actual success
/// events, not from attempted production.
public struct EcologyFinalDiagnostic: Codable, Equatable, Sendable {
    public var kind: String
    public var producedEpoch: Int
    public var producedPhase: String?
    public var publishedSourceEpoch: Int?
    public var publishedPhase: String?
    public var displayedSourceEpoch: Int?
    public var displayedPhase: String?
    public var frameCount: Int
    public var failures: Int
    public var unknownHalts: Int
    public var stopReason: ResidentDriverStopReason

    public init(producedEpoch: Int,
                producedPhase: String?,
                publishedSourceEpoch: Int?,
                publishedPhase: String?,
                displayedSourceEpoch: Int?,
                displayedPhase: String?,
                frameCount: Int,
                failures: Int,
                unknownHalts: Int,
                stopReason: ResidentDriverStopReason,
                kind: String = "ecologyFinalDiagnostic") {
        self.kind = kind
        self.producedEpoch = producedEpoch
        self.producedPhase = producedPhase
        self.publishedSourceEpoch = publishedSourceEpoch
        self.publishedPhase = publishedPhase
        self.displayedSourceEpoch = displayedSourceEpoch
        self.displayedPhase = displayedPhase
        self.frameCount = frameCount
        self.failures = failures
        self.unknownHalts = unknownHalts
        self.stopReason = stopReason
    }

    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            preconditionFailure("ecology final diagnostic must be JSON-encodable")
        }
        return line
    }
}

/// One-shot emitter for `EcologyFinalDiagnostic`. Mirrors the resident
/// emitter's "first termination wins" contract: the first `emit` writes the
/// JSON line and returns `true`; later calls are inert and return `false`.
/// Distinct from `ResidentFinalDiagnosticEmitter` so the resident path's
/// schema/default behavior is preserved exactly.
public struct EcologyFinalDiagnosticEmitter: Sendable {
    public private(set) var emitted = false

    public init() {}

    @discardableResult
    public mutating func emit(_ diagnostic: EcologyFinalDiagnostic,
                              write: (String) -> Void) -> Bool {
        guard !emitted else { return false }
        emitted = true
        write(diagnostic.jsonLine())
        return true
    }
}
