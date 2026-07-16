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
        // Shared host/MSL layout of the render uniform block; same C-header
        // pattern so its layout asserts are checked on every platform.
        .target(name: "CSoupRender"),
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
        // Platform-independent app core: grid/camera/LOD/normalization/opcode/
        // batcher/HUD/snapshot pure models + launch-option parsing. Depends on
        // BFFMetal for the soup runner and epoch types; builds and is tested on
        // Linux. The SwiftUI/Metal shell stays view-only.
        .target(name: "SoupScopeCore",
                dependencies: ["BFFOracle", "BFFMetal", "CSoupRender"]),
        // SwiftUI + Metal shell on macOS; a stub entry point elsewhere so Linux CI
        // builds it. The render shader is bundled as source and compiled at runtime
        // (same pattern as BFFMetal's evaluator — no committed metallib).
        .executableTarget(
            name: "SoupScopeApp",
            dependencies: ["SoupScopeCore", "BFFMetal", "BFFOracle", "CSoupRender"],
            resources: [.copy("Shaders/SoupRender.metal")]
        ),
        .testTarget(
            name: "BFFOracleTests",
            dependencies: ["BFFOracle"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SoupScopeCoreTests",
            dependencies: ["SoupScopeCore", "BFFOracle", "BFFMetal", "CSoupRender"]
        ),
        .testTarget(
            name: "BFFMetalTests",
            dependencies: ["BFFMetal", "BFFOracle", "CBFFShared"]
        ),
    ]
)
