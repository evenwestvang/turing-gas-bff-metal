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
        // Experimental GPU-resident ecology epoch runner library. Separate engine
        // from ResidentMetalEpochRunner; ports the BFF-Ecology v1 contract
        // (torus-512x256, edge-color-sync scheduler, ecology-counter-pcg RNG) to
        // Metal with byte-exact CPU parity against EcologyOracleRunner.
        .library(name: "BFFEcologyMetal", targets: ["BFFEcologyMetal"]),
        .executable(name: "bff-oracle", targets: ["bff-oracle"]),
        .executable(name: "bff-metal-parity", targets: ["bff-metal-parity"]),
        .executable(name: "bff-metal-soup", targets: ["bff-metal-soup"]),
        .executable(name: "bff-metal-bench", targets: ["bff-metal-bench"]),
        .executable(name: "bff-resident-epoch", targets: ["bff-resident-epoch"]),
        // Headless CPU ecology checkpoint/replay CLI (BFF-Ecology v1). Pure
        // Swift, no Metal dependency; emits `engine=ecology-v1` and the
        // "Experimental Spatial Ecology" label. Existing products keep their
        // defaults and output contracts.
        .executable(name: "bff-ecology-epoch", targets: ["bff-ecology-epoch"]),
        // Headless Metal ecology epoch runner CLI (exits 2 on non-Metal hosts).
        // Emits byte-identical output to bff-ecology-epoch for stepBudget
        // 1...8192. The Metal contract pins stepBudget to that range; larger
        // budgets are rejected clearly, never clamped.
        .executable(name: "bff-ecology-metal-epoch",
                    targets: ["bff-ecology-metal-epoch"]),
        .executable(name: "SoupScope", targets: ["SoupScopeApp"]),
    ],
    targets: [
        .target(name: "BFFOracle"),
        .executableTarget(name: "bff-oracle", dependencies: ["BFFOracle"]),
        // Shared CPU/MSL byte layouts: one C header, compile-time asserted on
        // every platform (see Sources/CBFFShared/include/BFFShared.h).
        .target(name: "CBFFShared"),
        // Shared host/MSL byte layout for the ecology Metal runner: one C
        // header, compile-time asserted on every platform. Same three-layer
        // mirror contract pattern as CBFFShared.h.
        .target(name: "CBFFEcologyShared"),
        // Shared host/MSL layout of the render uniform block; same C-header
        // pattern so its layout asserts are checked on every platform.
        .target(name: "CSoupRender"),
        // System Brotli encoder (module map over <brotli/encode.h>). Resolved via
        // pkg-config on Linux and Homebrew on macOS arm64. Depended on ONLY by
        // BrotliMetrics, its tests, and bff-metal-bench — never by the oracle,
        // the Metal evaluator, or the app. Requires libbrotli-dev (apt) /
        // `brew install brotli`; the encoder version is verified at runtime
        // (pinned to 1.1.0) before any paper metric is emitted.
        .systemLibrary(
            name: "CBrotli",
            path: "Sources/CBrotli",
            pkgConfig: "libbrotlienc",
            providers: [.apt(["libbrotli-dev"]), .brew(["brotli"])]
        ),
        // Paper-aligned Brotli measurement (the exact cubff q2/lgwin24/generic
        // call), isolated so Brotli is a dependency of the benchmark only. The
        // pure H0 − brotli_bpb arithmetic lives in BFFOracle.PaperComplexity.
        .target(name: "BrotliMetrics", dependencies: ["CBrotli", "BFFOracle"]),
        // Metal evaluator host + platform-independent fixture planning/checking.
        // Builds everywhere; the Metal dispatch paths are #if canImport(Metal).
        .target(
            name: "BFFMetal",
            dependencies: ["BFFOracle", "CBFFShared"],
            resources: [
                .copy("Shaders/BFFEvaluate.metal"),
                .copy("Shaders/BFFResidentEpoch.metal"),
            ]
        ),
        // Experimental GPU-resident ecology epoch runner host. Builds everywhere;
        // the Metal dispatch paths are #if canImport(Metal). The shader source is
        // bundled as a .copy resource and compiled at runtime via makeLibrary.
        // Does NOT change BFFMetal's resource list (2 shaders) — BFFEcologyMetal
        // carries its own shader resource. The app bundle therefore packages
        // exactly four byte-identical provenanced shaders (SoupRender.metal via
        // SoupScopeApp, BFFEvaluate.metal + BFFResidentEpoch.metal via BFFMetal,
        // and BFFEcologyEpoch.metal via BFFEcologyMetal).
        .target(
            name: "BFFEcologyMetal",
            dependencies: ["BFFOracle", "BFFMetal", "CBFFEcologyShared"],
            resources: [
                .copy("Shaders/BFFEcologyEpoch.metal"),
            ]
        ),
        // Command-line GPU fixture parity runner (exits 2 on non-Metal hosts).
        .executableTarget(name: "bff-metal-parity",
                          dependencies: ["BFFMetal", "BFFOracle"]),
        // Headless small-soup epoch runner (exits 2 on non-Metal hosts).
        .executableTarget(name: "bff-metal-soup",
                          dependencies: ["BFFMetal", "BFFOracle"]),
        // Headless measurement-first benchmark harness / matrix runner sized for
        // native M4 Max runs (exits 2 on non-Metal hosts).
        .executableTarget(name: "bff-metal-bench",
                          dependencies: ["BFFMetal", "BFFOracle", "BrotliMetrics"]),
        // Experimental first runnable GPU-resident epoch vertical slice. This is an
        // opt-in product with its own shader and CLI; existing defaults/products stay
        // unchanged.
        .executableTarget(name: "bff-resident-epoch",
                          dependencies: ["BFFMetal", "BFFOracle"]),
        // Headless CPU ecology checkpoint/replay CLI. Pure Swift, no Metal
        // dependency. Reuses the BFFECO1 checkpoint implementation in
        // `Sources/BFFOracle/Ecology.swift`; no second on-disk format. Existing
        // products keep their defaults and output contracts.
        .executableTarget(name: "bff-ecology-epoch",
                          dependencies: ["BFFOracle"]),
        // Headless Metal ecology epoch runner CLI. Emits byte-identical output to
        // bff-ecology-epoch for stepBudget 1...8192. Exits 2 on non-Metal hosts.
        .executableTarget(name: "bff-ecology-metal-epoch",
                          dependencies: ["BFFEcologyMetal", "BFFOracle"]),
        // Platform-independent app core: grid/camera/LOD/normalization/opcode/
        // batcher/HUD/snapshot pure models + launch-option parsing. Depends on
        // BFFMetal for the soup runner and epoch types, and on BFFEcologyMetal
        // for the immutable `EcologyMetalEpochConfig` the ecology launch path
        // reconstructs from (the same way it depends on BFFMetal for
        // `ResidentEpochConfig`). Builds and is tested on Linux. The SwiftUI/
        // Metal shell stays view-only.
        .target(name: "SoupScopeCore",
                dependencies: ["BFFOracle", "BFFMetal", "BFFEcologyMetal", "CSoupRender"]),
        // SwiftUI + Metal shell on macOS; a stub entry point elsewhere so Linux CI
        // builds it. The render shader is bundled as source and compiled at runtime
        // (same pattern as BFFMetal's evaluator — no committed metallib). The app
        // directly depends on BFFEcologyMetal so it can load and drive the ecology
        // shader at runtime; the app bundle therefore packages exactly four
        // byte-identical provenanced shaders (SoupRender.metal via SoupScopeApp,
        // BFFEvaluate.metal + BFFResidentEpoch.metal via BFFMetal, and
        // BFFEcologyEpoch.metal via BFFEcologyMetal). Grounded behavior is
        // unchanged: each shader has a single source of truth in its owning
        // target and is never duplicated across the bundle.
        .executableTarget(
            name: "SoupScopeApp",
            dependencies: ["SoupScopeCore", "BFFMetal", "BFFEcologyMetal",
                           "BFFOracle", "CSoupRender"],
            resources: [.copy("Shaders/SoupRender.metal")]
        ),
        .testTarget(
            name: "BFFOracleTests",
            dependencies: ["BFFOracle"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SoupScopeCoreTests",
            dependencies: ["SoupScopeCore", "BFFOracle", "BFFMetal",
                           "BFFEcologyMetal", "CSoupRender"]
        ),
        .testTarget(
            name: "BFFMetalTests",
            dependencies: ["BFFMetal", "BFFOracle", "CBFFShared"]
        ),
        // Experimental GPU-resident ecology epoch runner tests. Verifies:
        // 1. Layout probe (Metal-compiled struct sizes match host MemoryLayout)
        // 2. RNG boundary vectors (pinned literals from EcologyTests)
        // 3. Pair-probe topology (invariants from EcologyTests)
        // 4. Full-epoch parity (16K stress, 131K smoke) against EcologyOracleRunner
        // Builds everywhere; Metal dispatch tests skip on non-Metal hosts.
        .testTarget(
            name: "BFFEcologyMetalTests",
            dependencies: ["BFFEcologyMetal", "BFFOracle", "BFFMetal",
                           "CBFFEcologyShared"]
        ),
        // Fixture + version-gate coverage for the Brotli 1.1.0 q2 integration.
        // Requires libbrotli (apt/brew); the exact-byte-count assertions hold on
        // any 1.0.9/1.1.0 host (verified version-stable for these small inputs),
        // and the provenance gate is asserted directly.
        .testTarget(
            name: "BrotliMetricsTests",
            dependencies: ["BrotliMetrics", "BFFOracle"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
