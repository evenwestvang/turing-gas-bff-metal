import SoupScopeCore

#if canImport(SwiftUI) && canImport(MetalKit)
import SwiftUI

/// SoupScope: a native macOS SwiftUI app that continuously runs the validated
/// configurable soup on the GPU and visualizes it from an aggregate program-level
/// entropy/activity field down to individual byte cells/opcodes, with pan/zoom and
/// a minimal live diagnostic HUD.
@main
struct SoupScopeApp: App {
    @StateObject private var appModel: AppModel

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print(AppLaunchOptions.usage)
        }
        _appModel = StateObject(wrappedValue: AppModel(arguments: args))
    }

    var body: some Scene {
        WindowGroup(ScaffoldInfo.appName) {
            ContentView(appModel: appModel)
        }
    }
}
#else
/// SwiftUI/Metal are unavailable on this platform; a stub entry point keeps the
/// target buildable so `swift build` / `swift test` cover the whole package on
/// Linux CI.
@main
struct SoupScopeApp {
    static func main() {
        print("\(ScaffoldInfo.appName) is a macOS SwiftUI + Metal app. "
              + "\(ScaffoldInfo.oracleWiring)")
    }
}
#endif
