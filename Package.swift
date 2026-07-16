// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BFFOracle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BFFOracle", targets: ["BFFOracle"]),
        .library(name: "BFFMetal", targets: ["BFFMetal"]),
        .executable(name: "bff-oracle", targets: ["bff-oracle"]),
        .executable(name: "bff-metal-parity", targets: ["bff-metal-parity"]),
        .executable(name: "bff-metal-soup", targets: ["bff-metal-soup"]),
        .executable(name: "SoupScope", targets: ["SoupScopeApp"]),
    ],
    targets: [
        .target(name: "BFFOracle"),
        .executableTarget(name: "bff-oracle", dependencies: ["BFFOracle"]),
        // Shared CPU/MSL byte layouts: one C header, compile-time asserted on
        // every platform (see Sources/CBFFShared/include/BFFShared.h).
        .target(name: "CBFFShared"),
        // Metal evaluator host + platform-independent fixture planning/checking.
        // Builds everywhere; the Metal dispatch paths are #if canImport(Metal).
        .target(
            name: "BFFMetal",
            dependencies: ["BFFOracle", "CBFFShared"],
            resources: [.copy("Shaders/BFFEvaluate.metal")]
        ),
        // Command-line GPU fixture parity runner (exits 2 on non-Metal hosts).
        .executableTarget(name: "bff-metal-parity",
                          dependencies: ["BFFMetal", "BFFOracle"]),
        // Headless small-soup epoch runner (exits 2 on non-Metal hosts).
        .executableTarget(name: "bff-metal-soup",
                          dependencies: ["BFFMetal", "BFFOracle"]),
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
        .testTarget(
            name: "BFFMetalTests",
            dependencies: ["BFFMetal", "BFFOracle", "CBFFShared"]
        ),
    ]
)
