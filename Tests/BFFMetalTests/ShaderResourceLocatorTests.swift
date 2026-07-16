import XCTest
import Foundation
@testable import BFFMetal

/// Pins the resource-location contract that lets one Swift source find its shader
/// both as a SwiftPM product (`Bundle.module`) and inside a conventional macOS
/// `.app` (flat `Contents/Resources` via `Bundle.main`). These run on every
/// platform — no Metal, no `.app` bundle required — because they exercise the
/// `Bundle`-free `resolve` core plus the public API against injected bundles.
final class ShaderResourceLocatorTests: XCTestCase {
    private let preferredHit = URL(fileURLWithPath: "/app/Contents/Resources/SoupRender.metal")
    private let fallbackHit = URL(fileURLWithPath: "/build/SoupScope.resources/SoupRender.metal")

    /// The conventional `.app` case: `Bundle.main` has the flat resource, so the
    /// module-bundle fallback is NEVER evaluated. This is the property that keeps
    /// `Bundle.module` — which traps in a resource-bundle-less `.app` — from being
    /// touched once the flat lookup has already succeeded.
    func testPreferredHitShortCircuitsFallback() {
        var fallbackEvaluated = false
        let url = ShaderResourceLocator.resolve(preferred: preferredHit) {
            fallbackEvaluated = true
            return self.fallbackHit
        }
        XCTAssertEqual(url, preferredHit)
        XCTAssertFalse(fallbackEvaluated,
                       "fallback (Bundle.module) must not be evaluated when the app bundle hits")
    }

    /// The SwiftPM CLI/test case: `Bundle.main` has no flat resource, so the lookup
    /// falls back to the per-target module bundle.
    func testFallbackUsedWhenPreferredMisses() {
        var fallbackEvaluated = false
        let url = ShaderResourceLocator.resolve(preferred: nil) {
            fallbackEvaluated = true
            return self.fallbackHit
        }
        XCTAssertTrue(fallbackEvaluated)
        XCTAssertEqual(url, fallbackHit)
    }

    /// Neither location has the resource → `nil`, which both call sites turn into a
    /// `shaderSourceMissing` error rather than a crash.
    func testReturnsNilWhenNeitherHasResource() {
        XCTAssertNil(ShaderResourceLocator.resolve(preferred: nil) { nil })
    }

    /// End-to-end through the public API with real `Bundle`s: a flat resource in the
    /// injected `mainBundle` is returned without evaluating the (trapping-stand-in)
    /// module-bundle autoclosure. Skips only if this platform's Foundation cannot
    /// treat an ad-hoc directory as a resource-bearing bundle.
    func testPublicAPIPrefersMainBundleWithoutTouchingModule() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("// shader".utf8).write(to: dir.appendingPathComponent("SoupRender.metal"))

        guard let mainBundle = Bundle(url: dir),
              mainBundle.url(forResource: "SoupRender", withExtension: "metal") != nil else {
            throw XCTSkip("directory-backed Bundle resource lookup unavailable on this platform")
        }

        let tripwire = AutoclosureTripwire()
        let url = ShaderResourceLocator.url(forResource: "SoupRender",
                                            withExtension: "metal",
                                            moduleBundle: tripwire.bundle(),
                                            mainBundle: mainBundle)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "SoupRender.metal")
        XCTAssertFalse(tripwire.tripped,
                       "the module-bundle autoclosure must stay unevaluated when Bundle.main hits")
    }

    /// The public API falls through to the module bundle when `Bundle.main` misses.
    func testPublicAPIFallsBackToModuleBundle() throws {
        let mainDir = try makeTempDir()
        let moduleDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: mainDir)
            try? FileManager.default.removeItem(at: moduleDir)
        }
        // Only the module dir carries the resource.
        try Data("// shader".utf8).write(to: moduleDir.appendingPathComponent("SoupRender.metal"))

        guard let mainBundle = Bundle(url: mainDir),
              let moduleBundle = Bundle(url: moduleDir),
              moduleBundle.url(forResource: "SoupRender", withExtension: "metal") != nil,
              mainBundle.url(forResource: "SoupRender", withExtension: "metal") == nil else {
            throw XCTSkip("directory-backed Bundle resource lookup unavailable on this platform")
        }

        let url = ShaderResourceLocator.url(forResource: "SoupRender",
                                            withExtension: "metal",
                                            moduleBundle: moduleBundle,
                                            mainBundle: mainBundle)
        XCTAssertEqual(url?.lastPathComponent, "SoupRender.metal")
        XCTAssertEqual(url?.resolvingSymlinksInPath().deletingLastPathComponent(),
                       moduleDir.resolvingSymlinksInPath())
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShaderResLoc-\(ProcessInfo.processInfo.globallyUniqueString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Records whether its `bundle()` autoclosure argument was evaluated, standing in
    /// for the real `Bundle.module` accessor that would trap inside a bare `.app`.
    private final class AutoclosureTripwire {
        private(set) var tripped = false
        func bundle() -> Bundle {
            tripped = true
            return Bundle.main
        }
    }
}
