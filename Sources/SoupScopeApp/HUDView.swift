#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import SoupScopeCore

/// Compact, diagnostic HUD overlay (REQUIRED 6). Monospaced text only — no charts,
/// no profiling UI. Reads the published `HUDModel`.
struct HUDView: View {
    let hud: HUDModel
    let lod: LODReadout
    let metricChannel: UInt32
    /// Resident path channel label, or nil on the legacy CPU-snapshot path.
    let residentChannel: ResidentVizChannel?
    let running: Bool

    private func f(_ x: Double, _ p: Int = 3) -> String {
        String(format: "%.\(p)f", x)
    }

    private func opt(_ x: Double?) -> String {
        x.map { f($0) } ?? "nil"
    }

    private var channelName: String {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SoupScope  epoch \(hud.epoch)\(running ? "" : "  [PAUSED]")")
                .fontWeight(.semibold)
            Text("batch \(hud.lastBatchEpochs) ep in \(f(hud.lastBatchMs)) ms "
                 + "(\(f(hud.msPerEpoch, 4)) ms/ep)")
            Text("steps raw \(hud.rawSteps)  noop \(hud.noopSteps)  cmd \(hud.commandSteps)")
            Text("halt  budget \(hud.haltBudget)  pcOut \(hud.haltPCOut)  "
                 + "unmatched \(hud.haltUnmatched)  unknown \(hud.haltUnknown)")
            Text("copyWrites \(hud.copyWrites)   channel \(channelName)")
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
            Text("programs \(hud.programCount)   \(hud.deviceName)")
            if let error = hud.errorState {
                Text("ERROR: \(error)")
                    .foregroundColor(.red)
                    .fontWeight(.bold)
            }
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
