#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI

/// The app shell: the continuous Metal soup view with the diagnostic HUD overlaid
/// bottom-left. No sidebars, controls, or charts (bounded slice).
struct ContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SoupMetalView(appModel: appModel)
                .ignoresSafeArea()
            HUDView(hud: appModel.hud,
                    lod: appModel.lodReadout,
                    metricChannel: appModel.metricChannel,
                    running: appModel.isRunning)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
#endif
