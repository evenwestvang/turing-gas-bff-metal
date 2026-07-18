import BFFMetal

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
}
