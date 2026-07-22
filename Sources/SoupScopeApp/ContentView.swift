#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI
import SoupScopeCore

/// The app shell: the continuous Metal soup view with the diagnostic HUD overlaid
/// bottom-left and the resident entropy overlay bottom-right. No sidebars,
/// controls, or charts (bounded slice).
struct ContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SoupMetalView(appModel: appModel)
                .ignoresSafeArea()
            HUDView(hud: appModel.hud,
                    lod: appModel.lodReadout,
                    metricChannel: appModel.metricChannel,
                    residentChannel: appModel.usesResidentRendering
                        ? appModel.residentVizChannel
                        : nil,
                    ecologyChannel: appModel.usesEcologyRendering
                        ? appModel.ecologyVizChannel
                        : nil,
                    running: appModel.isRunning,
                    vizEntropyBitsPerByte: appModel.vizEntropyAvailable
                        ? appModel.vizEntropyHistory.latest?.meanByteEntropyBitsPerByte
                        : nil)
            if appModel.usesResidentRendering || appModel.usesEcologyRendering {
                VizEntropyOverlay(history: appModel.vizEntropyHistory,
                                   available: appModel.vizEntropyAvailable,
                                   channelLabel: appModel.usesResidentRendering
                                       ? appModel.residentVizChannel.label
                                       : appModel.ecologyVizChannel.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onDisappear {
            appModel.stopResidentSimulation()
        }
    }
}
#endif
