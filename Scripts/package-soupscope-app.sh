#!/usr/bin/env bash
# Package the SoupScope SwiftPM executable as a conventional macOS .app bundle:
#
#   SoupScope.app/
#     Contents/
#       Info.plist
#       MacOS/SoupScope           ← the SwiftPM-built executable
#       Resources/BFFEvaluate.metal, SoupRender.metal  ← shaders, laid out FLAT
#
# The shaders are placed directly in Contents/Resources (conventional layout); the
# app ships NO SwiftPM per-target resource bundle. At runtime the app finds them via
# Bundle.main (see Sources/BFFMetal/ShaderResourceLocator.swift), while `swift run`
# and `swift test` keep finding them via Bundle.module. Renderer, evaluator, RNG,
# metrics, LOD, HUD, and scheduling are all unchanged — this only relocates two
# verbatim .metal resources into the conventional place and seals them.
#
# Determinism is enforced, not assumed. Exactly the two shaders below are packaged,
# each resolved from an explicit, pinned SwiftPM per-target resource bundle path for
# the *current* build. Packaging aborts on a missing, duplicated, basename-colliding,
# stale, or extra .metal file — on the build side (unexpected set under the bin dir)
# and on the bundle side (Contents/Resources must end up as exactly those two files
# and no SwiftPM resource bundle). Same inputs -> same layout.
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

# Exactly the shaders to package, as "basename:owning-SwiftPM-target". Distinct
# basenames — one .copy resource per target. Bash 3.2 has no associative arrays,
# so this is a parallel-encoded list parsed with ${entry%%:*} / ${entry##*:}.
REQUIRED_SHADERS=(
    "BFFEvaluate.metal:BFFMetal"
    "SoupRender.metal:SoupScopeApp"
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

    # 1. Build the product. This also compiles the two `.copy` shader resources
    #    into per-target resource bundles under the SwiftPM bin directory.
    echo "==> swift build -c $CONFIG --product $APP_NAME"
    swift build -c "$CONFIG" --product "$APP_NAME"

    local bin_dir exe
    bin_dir=$(swift build -c "$CONFIG" --show-bin-path)
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
    #    expected per-target bundle (exactly one source per basename), refusing
    #    any destination basename collision.
    local entry base target src dst
    for entry in "${REQUIRED_SHADERS[@]}"; do
        base="${entry%%:*}"
        target="${entry##*:}"
        if ! src=$(resolve_shader_source "$base" "$target" "$bin_dir"); then
            exit 1
        fi
        dst="$app/Contents/Resources/$base"
        if [[ -e "$dst" ]]; then
            echo "error: basename collision packaging '$base' (already present at $dst)" >&2
            exit 1
        fi
        cp "$src" "$dst"
        echo "    resource: $base  <-  ${src#$repo_root/}"
    done

    # 6. Assert the sealed result: exactly the two shaders, no SwiftPM bundle.
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
