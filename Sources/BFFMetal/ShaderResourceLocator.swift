import Foundation

/// Locates a bundled shader source so the *same* Swift source works in two very
/// different runtime layouts without changing any renderer or evaluator behavior:
///
///   1. As a SwiftPM product — `swift run`, `swift test`, and the headless CLIs —
///      where a target's `.copy` resources live in that target's per-target
///      resource bundle, reached through the SwiftPM-generated `Bundle.module`.
///   2. Inside a conventional macOS `.app` — executable in `Contents/MacOS`,
///      resources laid out flat in `Contents/Resources` — reached through
///      `Bundle.main`.
///
/// A conventional `.app` deliberately ships **no** SwiftPM per-target resource
/// bundle, so `Bundle.module` there would trap inside its generated accessor
/// (`Swift.fatalError("unable to find bundle …")`). This helper therefore looks in
/// `Bundle.main` first and only *then* consults the module bundle. The module
/// bundle is taken as an `@autoclosure`, so `Bundle.module` is not even evaluated —
/// and cannot trap — once the flat `Bundle.main` lookup has found the resource.
public enum ShaderResourceLocator {
    /// Resolve a resource URL, preferring the conventional `.app` layout
    /// (`Bundle.main`, flat under `Contents/Resources`) and falling back to the
    /// SwiftPM per-target resource bundle for CLI/test runs.
    ///
    /// - Parameters:
    ///   - name: resource base name, e.g. `"BFFEvaluate"`.
    ///   - ext: resource extension, e.g. `"metal"`.
    ///   - moduleBundle: the caller's `Bundle.module`, passed as an autoclosure so
    ///     it is evaluated only if the `mainBundle` lookup misses. Pass `.module`
    ///     from the *calling* target so the correct per-target bundle is used.
    ///   - mainBundle: the app bundle to search first; defaults to `Bundle.main`
    ///     and is injectable for tests.
    /// - Returns: the located URL, or `nil` if neither location has the resource.
    public static func url(forResource name: String,
                           withExtension ext: String,
                           moduleBundle: @autoclosure () -> Bundle,
                           mainBundle: Bundle = .main) -> URL? {
        resolve(preferred: mainBundle.url(forResource: name, withExtension: ext),
                fallback: { moduleBundle().url(forResource: name, withExtension: ext) })
    }

    /// The precedence + laziness core, isolated from `Bundle` so the contract is
    /// unit-testable on every platform (including Linux, which has no Metal and no
    /// `.app` bundles): return `preferred` when present and only *then* invoke
    /// `fallback`. `fallback` must not be called when `preferred != nil` — that is
    /// exactly what keeps a call site's `Bundle.module` autoclosure from being
    /// evaluated (and trapping) inside a resource-bundle-less `.app`.
    static func resolve(preferred: URL?, fallback: () -> URL?) -> URL? {
        preferred ?? fallback()
    }
}

/// Runtime packaging-contract accessors for the BFFMetal shader resources.
/// The evaluator/resident runner load these via `ShaderResourceLocator`
/// against this module's resource bundle; these accessors expose the same
/// lookups so the packaging contract ("each shader is a single, provenanced
/// resource the runtime loads by name") is verifiable at runtime without
/// asserting on shader source strings.
public enum BFFMetalShaderPackaging {
    /// The bundled `BFFEvaluate.metal` source URL, or `nil` if missing.
    public static var evaluateShaderResourceURL: URL? {
        ShaderResourceLocator.url(forResource: "BFFEvaluate",
                                  withExtension: "metal", moduleBundle: .module)
    }
    /// The bundled `BFFResidentEpoch.metal` source URL, or `nil` if missing.
    public static var residentEpochShaderResourceURL: URL? {
        ShaderResourceLocator.url(forResource: "BFFResidentEpoch",
                                  withExtension: "metal", moduleBundle: .module)
    }
}
