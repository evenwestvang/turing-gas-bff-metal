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

set -euo pipefail

APP_NAME="SoupScope"
CONFIG="${CONFIG:-release}"
BUNDLE_ID="${BUNDLE_ID:-org.turinggas.soupscope}"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: packaging a macOS .app requires macOS (Metal host)." >&2
    exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# 1. Build the product. This also compiles the two `.copy` shader resources into
#    per-target resource bundles under the SwiftPM bin directory.
echo "==> swift build -c $CONFIG --product $APP_NAME"
swift build -c "$CONFIG" --product "$APP_NAME"

bin_dir=$(swift build -c "$CONFIG" --show-bin-path)
exe="$bin_dir/$APP_NAME"
[[ -x "$exe" ]] || { echo "error: built executable not found at $exe" >&2; exit 1; }

# 2. Fresh conventional .app skeleton.
app="$repo_root/build/$APP_NAME.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# 3. Executable into Contents/MacOS.
cp "$exe" "$app/Contents/MacOS/$APP_NAME"

# 4. Shaders FLAT into Contents/Resources, taken from exactly what the build
#    produced (the .metal files inside the per-target resource bundles), regardless
#    of how SwiftPM structured those bundles. Filenames are unique across targets.
found=0
while IFS= read -r metal; do
    cp "$metal" "$app/Contents/Resources/"
    echo "    resource: $(basename "$metal")"
    found=$((found + 1))
done < <(find "$bin_dir" -name '*.metal' -type f | sort)

if [[ "$found" -eq 0 ]]; then
    echo "error: no .metal resources found under $bin_dir; nothing to bundle." >&2
    exit 1
fi

# 5. Info.plist for a regular windowed app.
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

# 6. Ad-hoc sign the whole bundle, then verify strictly. --deep so any nested
#    signable content is covered; --strict rejects a malformed bundle.
echo "==> codesign --force --deep --sign - $APP_NAME.app"
codesign --force --deep --sign - "$app"
echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict "$app"

echo
echo "Packaged: $app"
echo "Run interactively:      open \"$app\""
echo "Bounded validation run: open \"$app\" --args --validation-seconds 8"
