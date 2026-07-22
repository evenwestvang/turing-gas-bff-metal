#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import SoupScopeCore

/// Compact, diagnostic HUD overlay (REQUIRED 6). Monospaced text only — no charts,
/// no profiling UI. Reads the published `HUDModel`.
///
/// The HUD is split into a **primary** section (engine/mode, epoch, rate, channel,
/// entropy status, error) and a **Raw metrics** disclosure that is collapsed by
/// default. The disclosure state is `@State` so it survives ordinary SwiftUI body
/// updates for the view's lifetime.
///
/// In ecology mode the primary section persistently shows the
/// "Experimental Spatial Ecology" signage (`HUDPrimaryModeLine`), so the
/// explicit route stays visibly labeled while Raw metrics is collapsed; the
/// produced/published/displayed provenance detail stays in the disclosure.
struct HUDView: View {
    let hud: HUDModel
    let lod: LODReadout
    let metricChannel: UInt32
    /// Resident path channel label, or nil on the legacy CPU-snapshot path.
    let residentChannel: ResidentVizChannel?
    /// Ecology path channel label, or nil when the app is not in ecology mode.
    let ecologyChannel: EcologyVizChannel?
    let running: Bool
    /// Latest visualization entropy in bits/byte, or nil when unavailable.
    let vizEntropyBitsPerByte: Double?

    @State private var rawMetricsExpanded = false

    private func f(_ x: Double, _ p: Int = 3) -> String {
        String(format: "%.\(p)f", x)
    }

    private func opt(_ x: Double?) -> String {
        x.map { f($0) } ?? "nil"
    }

    private var channelName: String {
        if let ecologyChannel {
            return ecologyChannel.label
        }
        if let residentChannel {
            return residentChannel.label
        }
        switch metricChannel {
        case 1: return "activity"
        case 2: return "entropy"
        case 3: return "legacy composite"
        default: return "composite"
        }
    }

    private var usesResident: Bool { residentChannel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // ── Primary HUD ──
            Text("SoupScope  epoch \(hud.epoch)\(running ? "" : "  [PAUSED]")")
                .fontWeight(.semibold)
            // Persistent ecology-route signage: visible whenever ecology mode
            // is active, independent of the Raw metrics disclosure below.
            if let modeLine = HUDPrimaryModeLine.text(ecologyChannel: ecologyChannel) {
                Text(modeLine)
            }
            Text("\(f(hud.msPerEpoch, 4)) ms/ep   channel \(channelName)")
            if let entropy = vizEntropyBitsPerByte {
                Text("Entropy  \(f(entropy)) bits/byte")
            } else if usesResident {
                Text("Entropy  —")
            }
            if let error = hud.errorState {
                Text("ERROR: \(error)")
                    .foregroundColor(.red)
                    .fontWeight(.bold)
            }

            // ── Raw metrics (collapsed by default) ──
            DisclosureGroup("Raw metrics", isExpanded: $rawMetricsExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("batch \(hud.lastBatchEpochs) ep in \(f(hud.lastBatchMs)) ms")
                    Text("steps raw \(hud.rawSteps)  noop \(hud.noopSteps)  cmd \(hud.commandSteps)")
                    Text("halt  budget \(hud.haltBudget)  pcOut \(hud.haltPCOut)  "
                         + "unmatched \(hud.haltUnmatched)  unknown \(hud.haltUnknown)")
                    Text("copyWrites \(hud.copyWrites)")
                    Text("zoom \(f(lod.bytePx, 2)) px/byte   "
                         + "macro/micro \(f(lod.macroBlend, 2))/\(f(lod.microBlend, 2))   "
                         + "glyph \(f(lod.glyphBlend, 2))")
                    Text("shadow checked \(hud.shadowChecked)  mismatch \(hud.shadowMismatch)")
                    if let resident = hud.resident {
                        Text("resident src \(resident.sourceEpoch)  shown \(resident.displayedEpoch)  "
                             + "planner \(resident.plannerCLI) \(resident.plannerModeID)")
                        Text("resident epoch \(f(resident.epochWallMs)) ms  "
                             + "gpu m/p/e/v "
                             + "\(opt(resident.mutationGpuMs))/\(opt(resident.plannerGpuMs))/"
                             + "\(opt(resident.evalGpuMs))/\(opt(resident.visualizationGpuMs))")
                        Text("checkpoint every \(resident.checkpointInterval)  "
                             + "checkpointBytes \(resident.checkpointBytes)  "
                             + "readbackBytes \(resident.readbackBytes)  failures \(resident.failureCount)")
                    }
                    if let ecology = hud.ecology {
                        // HUD text describing visible state uses ONLY the displayed
                        // lease's source epoch/phase. Produced/published diagnostics
                        // are reported on separate lines so simulation reports never
                        // alternate the meaning of the visible-state line. The mode
                        // signage itself lives in the primary section above
                        // (HUDPrimaryModeLine), not in this disclosure.
                        let displayedEpochText = ecology.displayedSourceEpoch
                            .map(String.init) ?? "unavailable"
                        let displayedPhaseText = ecology.displayedPhase ?? "—"
                        Text("ecology displayed src \(displayedEpochText)  "
                             + "phase \(displayedPhaseText)")
                        // Simulation diagnostics: latest completed/produced epoch and
                        // producing phase, separately from the displayed lease.
                        let publishedEpochText = ecology.publishedSourceEpoch
                            .map(String.init) ?? "unavailable"
                        let publishedPhaseText = ecology.publishedPhase ?? "—"
                        let producedPhaseText = ecology.producedPhase ?? "—"
                        Text("ecology produced \(ecology.producedEpoch)  "
                             + "phase \(producedPhaseText)  "
                             + "published src \(publishedEpochText)  "
                             + "phase \(publishedPhaseText)")
                        Text("ecology epoch \(f(ecology.epochWallMs)) ms  "
                             + "gpu m/e/v "
                             + "\(opt(ecology.mutateGpuMs))/\(opt(ecology.evalGpuMs))"
                             + "/\(opt(ecology.visualizationGpuMs))")
                        Text("ecology snapshotBytes \(ecology.snapshotBytes)  "
                             + "readbackBytes \(ecology.readbackBytes)  "
                             + "failures \(ecology.failureCount)  "
                             + "spatial metrics: unavailable")
                    }
                    Text("programs \(hud.programCount)   \(hud.deviceName)")
                }
                .padding(.top, 2)
            }
            .accessibilityLabel("Raw metrics diagnostics")

            Text("drag pan · scroll/pinch zoom · space pause · f fit · m channel · r reset")
                .foregroundColor(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.55))
        .cornerRadius(6)
        .padding(10)
    }
}
#endif
