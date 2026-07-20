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
                    running: appModel.isRunning)
            if appModel.usesResidentRendering {
                VizEntropyOverlay(history: appModel.vizEntropyHistory,
                                  available: appModel.vizEntropyAvailable,
                                  channel: appModel.residentVizChannel)
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
