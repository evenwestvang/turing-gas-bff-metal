#if canImport(SwiftUI)
import SwiftUI
import SoupScopeCore

/// Static placeholder proving app → core → oracle wiring. No simulation or rendering.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text(ScaffoldInfo.appName)
                .font(.largeTitle)
            Text(ScaffoldInfo.oracleWiring)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 300)
    }
}
#endif
