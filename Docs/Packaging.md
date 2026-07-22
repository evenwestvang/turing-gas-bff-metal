# Packaging SoupScope as a conventional macOS `.app`

`swift run SoupScope` launches the app straight out of the SwiftPM build directory,
which is all that CI and native validation need. To hand someone a double-clickable
bundle, package it with:

```sh
Scripts/package-soupscope-app.sh          # -> build/SoupScope.app (release, ad-hoc signed)
```

macOS + Metal only. The script needs `swift`, `codesign`, and `plutil`. It is
deterministic: the same commit and toolchain produce the same bundle layout.

Determinism and provenance are enforced, not assumed. Each invocation builds into a
fresh, dedicated SwiftPM scratch path (`swift build --scratch-path <tmp>`) rather
than the repository `.build` or any prior artifact, so the packaged shaders can only
have come from *this* build; the scratch path is removed on both success and failure
via a scoped trap, and the caller's default `.build` is left untouched.

The script packages **exactly** the four shaders below, each resolved from its
explicit, pinned SwiftPM per-target resource bundle in that fresh build
(`BFFOracle_BFFMetal.bundle`, `BFFOracle_SoupScopeApp.bundle`,
`BFFOracle_BFFEcologyMetal.bundle`), requiring exactly one unambiguous source per
basename, and each required to be **byte-identical to its explicit repository
source** (`Sources/BFFMetal/Shaders/BFFEvaluate.metal`,
`Sources/BFFMetal/Shaders/BFFResidentEpoch.metal`,
`Sources/SoupScopeApp/Shaders/SoupRender.metal`,
`Sources/BFFEcologyMetal/Shaders/BFFEcologyEpoch.metal`) before it is copied. It
aborts if the build's `.metal` set is anything other than those four (missing,
extra, duplicate, or stale copies), if a built resource's bytes drift from its
repository source, and — after copying — re-checks that `Contents/Resources`
holds precisely those four files and no SwiftPM resource bundle. The pure
resolution/verification helpers (including the byte-identity gate that rejects
stale content under a correctly named path) are covered on any host by
`Scripts/tests/package-soupscope-app-tests.sh` (portable; no Metal toolchain
needed).

## What it produces

A conventional bundle — executable in `Contents/MacOS`, resources **flat** in
`Contents/Resources`, and nothing at the bundle root but `Contents/`:

```
build/SoupScope.app/
  Contents/
    Info.plist
    MacOS/
      SoupScope                 # the SwiftPM-built executable
    Resources/
      BFFEvaluate.metal         # BFFMetal evaluator shader source
      BFFResidentEpoch.metal    # BFFMetal resident epoch shader source
      SoupRender.metal          # SoupScopeApp render shader source
      BFFEcologyEpoch.metal     # BFFEcologyMetal ecology epoch shader source
```

There is **no** SwiftPM per-target resource bundle inside the `.app` (no
`BFFOracle_BFFMetal.bundle`, no `BFFOracle_SoupScopeApp.bundle`,
`BFFOracle_BFFEcologyMetal.bundle`) — the four `.metal` sources are the exact
verbatim `.copy` resources the build produced, relocated into the conventional
`Contents/Resources`.

## How resource lookup stays correct in both layouts

Both Metal hosts (`MetalBFFEvaluator` in BFFMetal, `SharedMetalContext` in
SoupScopeApp) load their shader through `ShaderResourceLocator`
(`Sources/BFFMetal/ShaderResourceLocator.swift`) instead of calling `Bundle.module`
directly:

- **Inside the `.app`:** the shader is found via `Bundle.main`, i.e. flat under
  `Contents/Resources`.
- **Under SwiftPM** (`swift run`, `swift test`, the headless CLIs): `Bundle.main`
  has no flat shader, so lookup falls back to the target's `Bundle.module`.

The module bundle is passed as an `@autoclosure`, so `Bundle.module` is never
evaluated when the `Bundle.main` lookup already succeeded. That matters because a
resource-bundle-less `.app` would make the SwiftPM-generated `Bundle.module`
accessor trap; the precedence + laziness are pinned by `ShaderResourceLocatorTests`.

No renderer, evaluator, RNG, metric, LOD, HUD, or scheduling behavior changes — only
where the four shader sources are located on disk.

## Signing

The bundle is ad-hoc signed and the signature is verified, exactly as required:

```sh
codesign --force --deep --sign - build/SoupScope.app
codesign --verify --deep --strict build/SoupScope.app
```

The script performs **no** quarantine manipulation (`com.apple.quarantine` is left
untouched). A downloaded copy is subject to Gatekeeper as usual; a locally built
copy is not quarantined to begin with.

## Command-line arguments

Launch arguments flow through `open --args` to the app's
`CommandLine.arguments` (parsed by `AppLaunchOptions`), identically to
`swift run SoupScope …`:

```sh
open build/SoupScope.app                                   # interactive
open build/SoupScope.app --args --validation-seconds 8     # bounded validation run
open build/SoupScope.app --args --programs 4096 --shadow-sample 16 --seed 45071
```

See `Docs/SoupScopeApp.md` for the full argument list and the native-validation
procedure.
