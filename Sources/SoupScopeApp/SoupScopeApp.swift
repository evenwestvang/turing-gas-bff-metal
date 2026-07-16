import SoupScopeCore

#if canImport(SwiftUI)
import SwiftUI

@main
struct SoupScopeApp: App {
    var body: some Scene {
        WindowGroup(ScaffoldInfo.appName) {
            PlaceholderView()
        }
    }
}
#else
/// SwiftUI is unavailable on this platform; a stub entry point keeps the target
/// buildable so `swift build` / `swift test` cover the whole package on Linux.
@main
struct SoupScopeApp {
    static func main() {
        print("\(ScaffoldInfo.appName) is a macOS SwiftUI app. \(ScaffoldInfo.oracleWiring)")
    }
}
#endif
