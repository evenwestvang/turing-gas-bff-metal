// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BFFOracle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BFFOracle", targets: ["BFFOracle"]),
        .executable(name: "bff-oracle", targets: ["bff-oracle"]),
        .executable(name: "SoupScope", targets: ["SoupScopeApp"]),
    ],
    targets: [
        .target(name: "BFFOracle"),
        .executableTarget(name: "bff-oracle", dependencies: ["BFFOracle"]),
        // Platform-independent app core; the SwiftUI shell stays view-only.
        .target(name: "SoupScopeCore", dependencies: ["BFFOracle"]),
        // SwiftUI shell on macOS; a stub entry point elsewhere so Linux CI builds it.
        .executableTarget(name: "SoupScopeApp", dependencies: ["SoupScopeCore"]),
        .testTarget(
            name: "BFFOracleTests",
            dependencies: ["BFFOracle"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SoupScopeCoreTests",
            dependencies: ["SoupScopeCore"]
        ),
    ]
)
