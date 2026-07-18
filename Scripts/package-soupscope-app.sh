#!/usr/bin/env bash
# Package the SoupScope SwiftPM executable as a conventional macOS .app bundle:
#
#   SoupScope.app/
#     Contents/
#       Info.plist
#       MacOS/SoupScope           ← the SwiftPM-built executable
#       Resources/BFFEvaluate.metal, BFFResidentEpoch.metal, SoupRender.metal
#                                                    ← shaders, laid out FLAT
#
# The shaders are placed directly in Contents/Resources (conventional layout); the
# app ships NO SwiftPM per-target resource bundle. At runtime the app finds them via
# Bundle.main (see Sources/BFFMetal/ShaderResourceLocator.swift), while `swift run`
# and `swift test` keep finding them via Bundle.module. Renderer, evaluator, RNG,
# metrics, LOD, HUD, and scheduling are all unchanged — this only relocates three
# verbatim .metal resources into the conventional place and seals them.
#
# Determinism and provenance are enforced, not assumed. Each invocation builds into
# a fresh, dedicated SwiftPM scratch path (never the repository .build or any prior
# artifact), so the packaged shaders can only have come from *this* build. Exactly
# the three shaders below are packaged, each resolved from an explicit, pinned SwiftPM
# per-target resource bundle path under that fresh scratch build, and each required
# to be byte-identical to its explicit repository source before it is copied.
# Packaging aborts on a missing, duplicated, basename-colliding, stale, or extra
# .metal file — on the build side (unexpected set under the bin dir), on provenance
# (a built resource whose bytes drift from its repository source), and on the bundle
# side (Contents/Resources must end up as exactly those three files and no SwiftPM
# resource bundle). Same inputs -> same layout. The scratch path is removed on both
# success and failure via a scoped trap.
#
# The bundle is ad-hoc code-signed and the signature is verified. No quarantine
# attribute is touched. Command-line arguments still flow through:
#
#   open build/SoupScope.app --args --validation-seconds 8 --programs 4096
#
# macOS + Metal only (needs `swift`, `codesign`, `plutil`). Deterministic: same
# inputs -> same layout.
#
# Usage: Scripts/package-soupscope-app.sh
# Env overrides: CONFIG (default release), BUNDLE_ID, APP_VERSION, BUILD_NUMBER.
#
# The pure file-resolution / verification helpers below are written to be portable
# (bash 3.2, no macOS-only tools) and are covered by Scripts/tests: sourcing this
# script with PACKAGE_SOUPSCOPE_LIB_ONLY=1 defines the helpers without running the
# macOS packaging pipeline.

set -euo pipefail

# ---------------------------------------------------------------------------
# Shader manifest — the single source of truth for what gets packaged.
#
# SwiftPM name of the package (see Package.swift `name:`). A target's `.copy`
# resources land in the per-target bundle "<PackageName>_<TargetName>.bundle" for
# the current build (".resources" on non-Apple hosts; this script is Apple-only).
# ---------------------------------------------------------------------------
PACKAGE_NAME="BFFOracle"

# Exactly the shaders to package, as "basename:owning-SwiftPM-target:repo-source".
# Distinct basenames — one .copy resource per target. The repo-source field is the
# explicit, repository-relative path of the canonical shader source, so provenance
# is pinned rather than derived. Bash 3.2 has no associative arrays, so this is a
# parallel-encoded list; parse it with the ${entry%%:*} / ${rest#*:} idiom below
# (three colon-separated fields; the repo path itself contains no colon).
REQUIRED_SHADERS=(
    "BFFEvaluate.metal:BFFMetal:Sources/BFFMetal/Shaders/BFFEvaluate.metal"
    "BFFResidentEpoch.metal:BFFMetal:Sources/BFFMetal/Shaders/BFFResidentEpoch.metal"
    "SoupRender.metal:SoupScopeApp:Sources/SoupScopeApp/Shaders/SoupRender.metal"
)

# Sorted, newline-separated required basenames — the exact expected set on both
# the build side and inside Contents/Resources.
required_basenames() {
    local entry acc=""
    for entry in "${REQUIRED_SHADERS[@]}"; do
        acc+="${entry%%:*}"$'\n'
    done
    printf '%s' "$acc" | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Determinism helpers (pure; portable; unit-tested).
# ---------------------------------------------------------------------------

# Assert the SwiftPM build produced *exactly* the manifest set of .metal files
# under the bin dir — one per basename, nothing missing, nothing extra, no stale
# leftovers or duplicate copies. Args: <bin_dir>. Returns non-zero on drift.
verify_build_metal_set() {
    local bin_dir="$1"
    local expected actual
    expected=$(required_basenames)
    actual=$(find "$bin_dir" -type f -name '*.metal' -exec basename {} \; \
                 | LC_ALL=C sort)
    if [[ "$actual" != "$expected" ]]; then
        {
            echo "error: SwiftPM build produced an unexpected set of .metal resources."
            echo "  Packaging pins exactly:"
            printf '    %s\n' $expected
            echo "  Found under $bin_dir:"
            if [[ -n "$actual" ]]; then printf '    %s\n' $actual; else echo "    (none)"; fi
            echo "  Resolve the drift (missing / extra / duplicate / stale .metal) first."
        } >&2
        return 1
    fi
}

# Resolve the single unambiguous source path for one required shader, from the
# explicit expected per-target resource bundle for the current build. Requires
# that bundle to exist and to hold exactly one copy of the basename.
# Args: <basename> <target> <bin_dir>. Prints the path; returns non-zero on fail.
resolve_shader_source() {
    local base="$1" target="$2" bin_dir="$3"
    local bundle="$bin_dir/${PACKAGE_NAME}_${target}.bundle"
    if [[ ! -d "$bundle" ]]; then
        echo "error: expected SwiftPM resource bundle for target '$target' not found:" >&2
        echo "         $bundle" >&2
        return 1
    fi
    local matches=() m
    while IFS= read -r m; do
        [[ -n "$m" ]] && matches+=("$m")
    done < <(find "$bundle" -type f -name "$base" | LC_ALL=C sort)
    case "${#matches[@]}" in
        0)
            echo "error: required shader '$base' not present in $bundle" >&2
            return 1 ;;
        1)
            printf '%s\n' "${matches[0]}" ;;
        *)
            echo "error: ambiguous source for '$base' — ${#matches[@]} copies under $bundle:" >&2
            printf '         %s\n' "${matches[@]}" >&2
            return 1 ;;
    esac
}

# Assert a built resource is byte-identical to its explicit repository source, so
# what gets sealed into the bundle provably matches the committed shader (rejects
# stale content sitting under a correctly named path). Both files must exist.
# Args: <basename> <repo_source> <built_source>. Returns non-zero on any mismatch.
verify_source_identity() {
    local base="$1" repo_src="$2" built_src="$3"
    if [[ ! -f "$repo_src" ]]; then
        echo "error: repository source for '$base' not found: $repo_src" >&2
        return 1
    fi
    if [[ ! -f "$built_src" ]]; then
        echo "error: built resource for '$base' not found: $built_src" >&2
        return 1
    fi
    if ! cmp -s "$repo_src" "$built_src"; then
        {
            echo "error: built resource for '$base' is not byte-identical to its"
            echo "       repository source — stale or drifted content, refusing to package."
            echo "         repo source:    $repo_src"
            echo "         built resource: $built_src"
        } >&2
        return 1
    fi
}

# Assert a Contents/Resources directory holds *exactly* the required shader files
# and nothing else — no extra file, no subdirectory, and specifically no leaked
# SwiftPM resource bundle. Args: <resources_dir>. Returns non-zero on mismatch.
verify_packaged_resources() {
    local dir="$1"
    local expected actual entry
    expected=$(required_basenames)
    actual=$(ls -A1 "$dir" | LC_ALL=C sort)
    if [[ "$actual" != "$expected" ]]; then
        {
            echo "error: Contents/Resources is not exactly the required shader set."
            echo "  expected:"; printf '    %s\n' $expected
            echo "  actual:"
            if [[ -n "$actual" ]]; then printf '    %s\n' $actual; else echo "    (empty)"; fi
        } >&2
        return 1
    fi
    # Belt-and-suspenders: reject any directory / SwiftPM resource bundle even if
    # its name somehow matched a required basename.
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ -d "$dir/$entry" ]]; then
            echo "error: unexpected directory in Contents/Resources: '$entry' (no SwiftPM resource bundle allowed)" >&2
            return 1
        fi
        case "$entry" in
            *.bundle|*.resources)
                echo "error: SwiftPM resource bundle leaked into Contents/Resources: '$entry'" >&2
                return 1 ;;
        esac
    done <<< "$actual"
}

# ---------------------------------------------------------------------------
# macOS packaging pipeline.
# ---------------------------------------------------------------------------

# Dedicated SwiftPM scratch path for the current invocation (empty until main
# creates it). A script global so the EXIT trap resolves it after main returns.
PACKAGE_SCRATCH_DIR=""

# Remove the dedicated scratch path, if any. Safe to call when it was never set
# and idempotent; never fails the trap.
_cleanup_scratch() {
    if [[ -n "${PACKAGE_SCRATCH_DIR:-}" && -d "$PACKAGE_SCRATCH_DIR" ]]; then
        rm -rf "$PACKAGE_SCRATCH_DIR"
    fi
    return 0
}

main() {
    local APP_NAME="SoupScope"
    local CONFIG="${CONFIG:-release}"
    local BUNDLE_ID="${BUNDLE_ID:-org.turinggas.soupscope}"
    local APP_VERSION="${APP_VERSION:-1.0}"
    local BUILD_NUMBER="${BUILD_NUMBER:-1}"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "error: packaging a macOS .app requires macOS (Metal host)." >&2
        exit 2
    fi

    local repo_root
    repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    cd "$repo_root"

    # 1. Build into a fresh, dedicated SwiftPM scratch path — never the repository
    #    .build or any prior artifact — so the packaged shaders can only have come
    #    from this build. PACKAGE_SCRATCH_DIR is a script global (not a function
    #    local) so the EXIT trap can remove it on both success and failure; the
    #    caller's default .build is left untouched.
    PACKAGE_SCRATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/soupscope-package.XXXXXX")
    trap _cleanup_scratch EXIT
    echo "==> swift build -c $CONFIG --product $APP_NAME --scratch-path <scratch>"
    swift build -c "$CONFIG" --product "$APP_NAME" --scratch-path "$PACKAGE_SCRATCH_DIR"

    local bin_dir exe
    bin_dir=$(swift build -c "$CONFIG" --scratch-path "$PACKAGE_SCRATCH_DIR" --show-bin-path)
    exe="$bin_dir/$APP_NAME"
    [[ -x "$exe" ]] || { echo "error: built executable not found at $exe" >&2; exit 1; }

    # 2. Assert the build's .metal set is exactly the manifest before touching the
    #    bundle — catches missing / extra / duplicate / stale resources up front.
    verify_build_metal_set "$bin_dir"

    # 3. Fresh conventional .app skeleton.
    local app="$repo_root/build/$APP_NAME.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

    # 4. Executable into Contents/MacOS.
    cp "$exe" "$app/Contents/MacOS/$APP_NAME"

    # 5. Shaders FLAT into Contents/Resources, each resolved from its explicit
    #    expected per-target bundle in the fresh scratch build (exactly one source
    #    per basename), required to be byte-identical to its explicit repository
    #    source, and refusing any destination basename collision.
    local entry base rest target repo_rel repo_src src dst
    for entry in "${REQUIRED_SHADERS[@]}"; do
        base="${entry%%:*}"
        rest="${entry#*:}"
        target="${rest%%:*}"
        repo_rel="${rest#*:}"
        repo_src="$repo_root/$repo_rel"
        if ! src=$(resolve_shader_source "$base" "$target" "$bin_dir"); then
            exit 1
        fi
        if ! verify_source_identity "$base" "$repo_src" "$src"; then
            exit 1
        fi
        dst="$app/Contents/Resources/$base"
        if [[ -e "$dst" ]]; then
            echo "error: basename collision packaging '$base' (already present at $dst)" >&2
            exit 1
        fi
        cp "$src" "$dst"
        echo "    resource: $base  <-  $repo_rel"
    done

    # 6. Assert the sealed result: exactly the three shaders, no SwiftPM bundle.
    verify_packaged_resources "$app/Contents/Resources"

    # 7. Info.plist for a regular windowed app.
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

    # Fail loudly if the plist is malformed.
    plutil -lint "$app/Contents/Info.plist" >/dev/null

    # 8. Ad-hoc sign the whole bundle, then verify strictly. --deep so any nested
    #    signable content is covered; --strict rejects a malformed bundle.
    echo "==> codesign --force --deep --sign - $APP_NAME.app"
    codesign --force --deep --sign - "$app"
    echo "==> codesign --verify --deep --strict"
    codesign --verify --deep --strict "$app"

    echo
    echo "Packaged: $app"
    echo "Run interactively:      open \"$app\""
    echo "Bounded validation run: open \"$app\" --args --validation-seconds 8"
}

# Run the pipeline unless sourced for unit testing (helpers only).
if [[ "${PACKAGE_SOUPSCOPE_LIB_ONLY:-}" != "1" ]]; then
    main "$@"
fi
