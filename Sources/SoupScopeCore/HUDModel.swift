import BFFMetal
import BFFOracle
import BFFEcologyMetal

/// The compact, diagnostic HUD state (REQUIRED 6). A pure value model updated from
/// each epoch batch, so the HUD view is a trivial projection and the counter/halt/
/// shadow propagation is unit-tested without any UI or Metal.
///
/// Per-epoch fields (steps, halt mix, copy writes) reflect the **latest** epoch in
/// the most recent batch; shadow counts are **cumulative** over the run so the
/// persona can confirm many pairs were checked with zero mismatches. This is a
/// diagnostic surface, not a chart: no time series, no profiling UI.
public struct HUDModel: Equatable, Sendable {
    // Fixed for the run.
    /// Metal device the run executes on (or a placeholder before init).
    public var deviceName: String
    /// Program count of the configured soup.
    public var programCount: Int

    // Progress / timing.
    /// Epochs completed so far.
    public var epoch: Int
    /// Wall/GPU milliseconds the last batch took.
    public var lastBatchMs: Double
    /// Epochs run in the last batch.
    public var lastBatchEpochs: Int
    /// Last batch's milliseconds per epoch (`lastBatchMs / lastBatchEpochs`).
    public var msPerEpoch: Double

    // Latest-epoch counters.
    /// Raw executed ops (budget accounting), last epoch summed over pairs.
    public var rawSteps: Int
    /// Executed null/non-command bytes (cubff `nskip`), last epoch.
    public var noopSteps: Int
    /// cubff observable op count (`raw − noop`), last epoch.
    public var commandSteps: Int
    /// Halt-reason mix of the last epoch.
    public var haltBudget: Int
    public var haltPCOut: Int
    public var haltUnmatched: Int
    /// Out-of-contract halt codes surfaced globally (normatively 0).
    public var haltUnknown: Int
    /// Cross-half copy executions, last epoch.
    public var copyWrites: Int

    // Cumulative CPU-shadow accounting.
    /// Pairs CPU-shadow-checked across the whole run.
    public var shadowChecked: Int
    /// Shadow divergences found across the whole run (must stay 0).
    public var shadowMismatch: Int

    /// A visible error state; non-nil means advancement has stopped.
    public var errorState: String?
    /// Resident-only diagnostics. `nil` on the default CPU-snapshot app path.
    public var resident: ResidentHUDDiagnostics?
    /// Ecology-only diagnostics. `nil` unless the app routes to the
    /// "Experimental Spatial Ecology" engine. Carries the truthful ecology
    /// epoch/phase and soup-derived counters — never energy/death/movement/
    /// predation/fitness/reproduction/paper metrics.
    public var ecology: EcologyHUDDiagnostics?

    public init(deviceName: String = "—", programCount: Int = 0) {
        self.deviceName = deviceName
        self.programCount = programCount
        self.epoch = 0
        self.lastBatchMs = 0
        self.lastBatchEpochs = 0
        self.msPerEpoch = 0
        self.rawSteps = 0
        self.noopSteps = 0
        self.commandSteps = 0
        self.haltBudget = 0
        self.haltPCOut = 0
        self.haltUnmatched = 0
        self.haltUnknown = 0
        self.copyWrites = 0
        self.shadowChecked = 0
        self.shadowMismatch = 0
        self.errorState = nil
        self.resident = nil
        self.ecology = nil
    }

    /// Fold one completed batch of epoch reports (in order) plus its measured
    /// duration into the HUD. `epoch` is the number of epochs completed after the
    /// batch. Latest-epoch counters come from the last report; shadow counts
    /// accumulate over every report in the batch.
    public mutating func record(batch reports: [EpochReport], epoch: Int, batchMs: Double) {
        self.epoch = epoch
        lastBatchEpochs = reports.count
        lastBatchMs = batchMs
        msPerEpoch = reports.isEmpty ? 0 : batchMs / Double(reports.count)

        for r in reports {
            shadowChecked += r.shadowChecked
            shadowMismatch += r.shadowMismatches.count
        }

        if let last = reports.last {
            let c = last.counters
            rawSteps = c.totalRawSteps
            noopSteps = c.totalNoopSteps
            commandSteps = c.totalCommandSteps
            haltBudget = c.haltBudget
            haltPCOut = c.haltPCOut
            haltUnmatched = c.haltUnmatched
            haltUnknown = c.haltUnknown
            copyWrites = c.totalCopyWrites
        }
    }

    public mutating func record(resident report: ResidentEpochReport,
                                planner: ResidentPairingPlanner,
                                checkpointInterval: Int,
                                displayedEpoch: Int,
                                failureCount: Int) {
        let c = report.counters
        epoch = c.epoch + 1
        lastBatchEpochs = 1
        lastBatchMs = report.instrumentation.epochWallSeconds * 1000
        msPerEpoch = lastBatchMs
        rawSteps = c.totalRawSteps
        noopSteps = c.totalNoopSteps
        commandSteps = c.totalCommandSteps
        haltBudget = c.haltBudget
        haltPCOut = c.haltPCOut
        haltUnmatched = c.haltUnmatched
        haltUnknown = c.haltUnknown
        copyWrites = c.totalCopyWrites
        shadowChecked += report.shadowChecked
        shadowMismatch += report.shadowMismatches.count

        func gpuMs(_ name: String) -> Double? {
            report.instrumentation.kernelTimings
                .first { $0.name == name }?
                .gpuSeconds
                .map { $0 * 1000 }
        }

        resident = ResidentHUDDiagnostics(
            sourceEpoch: c.epoch + 1,
            displayedEpoch: displayedEpoch,
            plannerCLI: planner.cliValue,
            plannerModeID: planner.identifier,
            plannerProvenance: planner.provenanceLabel,
            epochWallMs: report.instrumentation.epochWallSeconds * 1000,
            mutationGpuMs: gpuMs("mutate"),
            plannerGpuMs: report.instrumentation.plannerGPUSeconds.map { $0 * 1000 },
            evalGpuMs: gpuMs("eval-scatter"),
            visualizationGpuMs: gpuMs("visualize"),
            checkpointInterval: checkpointInterval,
            checkpointBytes: report.checkpointSoup?.count ?? 0,
            readbackBytes: report.instrumentation.readbackBytes,
            failureCount: failureCount,
            unknownHalts: c.haltUnknown)
    }

    /// Set (or clear) the visible error state.
    public mutating func setError(_ message: String?) {
        errorState = message
    }

    /// Fold one ecology epoch report (app-safe path) plus its failure count
    /// into the HUD. The app-safe report carries no digest and no captured
    /// pairs; its counters (steps, halt mix, copy writes, remap events) and the
    /// producer's GPU timing attribution are real and soup-derived. No spatial
    /// metrics are claimed.
    ///
    /// **Truthful domain separation**: this records ONLY the **produced**
    /// epoch/phase (from the simulation report) and the **published** source
    /// epoch/phase (from the snapshot ring's `publishedSourceEpoch`, which is
    /// set only when `state.publish()` succeeds — not on attempted
    /// production). It does NOT touch the **displayed** source epoch/phase:
    /// those update only when the renderer submits a frame using a valid
    /// immutable ecology lease (see `noteEcologyDisplayedLease`/
    /// `noteEcologyDisplayUnavailable`). The previous `ecology.displayed*`
    /// values are preserved verbatim across this call, so a simulation report
    /// arriving after a frame was rendered never overwrites the displayed
    /// phase with the producing phase.
    ///
    /// `publishedSourceEpoch` may be `nil` (no successful publication yet —
    /// first-publication absence, skipped reservation, or failed blit) or a
    /// value smaller than `producedEpoch` (the producer has advanced past the
    /// last successfully published slot). Both are truthful.
    public mutating func record(ecology report: EcologyMetalEpochReport,
                                publishedSourceEpoch: Int?,
                                failureCount: Int) {
        let c = report.counters
        epoch = Int(c.epoch) + 1
        lastBatchEpochs = 1
        lastBatchMs = report.instrumentation.epochWallSeconds * 1000
        msPerEpoch = lastBatchMs
        rawSteps = c.totalRawSteps
        noopSteps = c.totalNoopSteps
        commandSteps = c.totalCommandSteps
        haltBudget = c.haltBudget
        haltPCOut = c.haltPCOut
        haltUnmatched = c.haltUnmatched
        haltUnknown = 0  // ecology app-safe runner throws if nonzero, so 0 on success
        copyWrites = c.totalCopyWrites

        func gpuMs(_ seconds: Double?) -> Double? {
            seconds.map { $0 * 1000 }
        }
        let publishedPhase = publishedSourceEpoch.map {
            EcologyMatchingPhase(epoch: UInt32($0 - 1)).label
        }
        // Preserve the displayed fields across the report: a simulation report
        // arriving never overwrites the displayed lease's source epoch/phase.
        let preservedDisplayedSourceEpoch = ecology?.displayedSourceEpoch
        let preservedDisplayedPhase = ecology?.displayedPhase
        ecology = EcologyHUDDiagnostics(
            producedEpoch: Int(c.epoch) + 1,
            producedPhase: c.phase.label,
            publishedSourceEpoch: publishedSourceEpoch,
            publishedPhase: publishedPhase,
            displayedSourceEpoch: preservedDisplayedSourceEpoch,
            displayedPhase: preservedDisplayedPhase,
            epochWallMs: report.instrumentation.epochWallSeconds * 1000,
            mutateGpuMs: gpuMs(report.instrumentation.mutateKernelSeconds),
            evalGpuMs: gpuMs(report.instrumentation.evalKernelSeconds),
            visualizationGpuMs: gpuMs(report.instrumentation.visualizeKernelSeconds),
            snapshotBytes: EcologyTopology.soupByteCount,
            readbackBytes: report.instrumentation.readbackBytes,
            failureCount: failureCount,
            unknownHalts: 0)
    }

    /// Note that the renderer submitted a command buffer using a valid
    /// immutable ecology lease. Updates ONLY the displayed source epoch/phase
    /// fields, derived from the lease's `sourceEpoch`. Does not touch the
    /// produced or published fields.
    ///
    /// Before the first simulation report arrives (`ecology == nil`), this
    /// initializes the HUD's ecology block with ONLY the displayed domain set;
    /// produced (`producedEpoch == 0`, `producedPhase == nil`) and published
    /// (`nil`) domains remain unavailable. A later `record(ecology:)` report
    /// adds produced/published state while preserving these displayed values.
    ///
    /// Phase convention: a snapshot published after producing ecology epoch
    /// `e` carries `sourceEpoch = e + 1` (completed epochs), so the displayed
    /// phase is `EcologyMatchingPhase(epoch: sourceEpoch - 1)`. `sourceEpoch`
    /// is always `>= 1` for a real publication (the first publication follows
    /// epoch 0), so the subtraction is safe. An invalid `sourceEpoch <= 0` is
    /// rejected without mutation — no trap on `UInt32(sourceEpoch - 1)` and no
    /// fabricated displayed metadata; fields stay at their prior value or nil.
    public mutating func noteEcologyDisplayedLease(sourceEpoch: Int) {
        guard sourceEpoch > 0 else {
            // Invalid source epoch (0 or negative): no real publication
            // carries sourceEpoch 0 (the first publication follows epoch 0).
            // Reject without mutation — do not trap on UInt32(sourceEpoch - 1)
            // and do not fabricate displayed metadata. Mirrors the neutral
            // fallback: displayed fields stay at their prior value (or nil).
            return
        }
        let phase = EcologyMatchingPhase(epoch: UInt32(sourceEpoch - 1)).label
        guard ecology != nil else {
            // No simulation report yet: initialize ONLY the displayed domain.
            // Produced (epoch 0, phase nil) and published (nil) remain
            // unavailable; a later report adds them while preserving these
            // displayed values (see `record(ecology:)`).
            ecology = EcologyHUDDiagnostics(
                producedEpoch: 0,
                producedPhase: nil,
                publishedSourceEpoch: nil,
                publishedPhase: nil,
                displayedSourceEpoch: sourceEpoch,
                displayedPhase: phase,
                epochWallMs: 0,
                mutateGpuMs: nil,
                evalGpuMs: nil,
                visualizationGpuMs: nil,
                snapshotBytes: 0,
                readbackBytes: 0,
                failureCount: 0,
                unknownHalts: 0)
            return
        }
        ecology?.displayedSourceEpoch = sourceEpoch
        ecology?.displayedPhase = phase
    }

    /// Note that the renderer fell back to the neutral background (no valid
    /// immutable ecology lease was available). Does NOT fabricate source
    /// epoch/phase: the displayed fields are left at their prior value (the
    /// last valid lease rendered), or `nil` if no valid lease has ever been
    /// rendered. The neutral fallback is the unavailable state, truthfully.
    public mutating func noteEcologyDisplayUnavailable() {
        // Intentionally no mutation: displayed metadata updates only on a
        // valid-lease render submission (see `noteEcologyDisplayedLease`).
        // Resetting to `nil` here would discard the last rendered lease's
        // truthful info on a transient fallback; fabricating a 0/"—" value
        // would mislabel the neutral background as a real source.
    }
}

/// The persistent primary-HUD mode line. The explicit ecology route must stay
/// visibly labeled "Experimental Spatial Ecology" in the primary HUD section
/// even while the Raw metrics disclosure is collapsed, so the signage is a
/// pure function of mode routing (the ecology channel the HUD receives) —
/// never of the disclosure state or of whether diagnostics have arrived.
public enum HUDPrimaryModeLine {
    /// Returns `EcologyAppRunPlan.label` whenever the app is routed to ecology
    /// mode (a non-nil ecology channel), and `nil` in every other mode — the
    /// resident and CPU-snapshot paths carry no ecology signage. Deliberately
    /// independent of `EcologyHUDDiagnostics`: the label states the route, not
    /// data availability, and the produced/published/displayed provenance
    /// detail stays under the Raw metrics disclosure.
    public static func text(ecologyChannel: EcologyVizChannel?) -> String? {
        ecologyChannel != nil ? EcologyAppRunPlan.label : nil
    }
}
