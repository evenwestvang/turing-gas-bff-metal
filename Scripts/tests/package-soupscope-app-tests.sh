#!/usr/bin/env bash
# Portable coverage for the packaging-determinism helpers in
# Scripts/package-soupscope-app.sh.
#
# This exercises the pure file-resolution / verification logic only — no swift,
# codesign, or plutil — so it runs on any host (incl. Linux CI). It sources the
# packaging script with PACKAGE_SOUPSCOPE_LIB_ONLY=1, which defines the helpers
# and the shader manifest WITHOUT running the macOS packaging pipeline, then
# drives them against synthetic bin-dir / bundle fixtures laid out the way the
# macOS build does (<Package>_<Target>.bundle/Contents/Resources/<shader>).
#
# Usage: Scripts/tests/package-soupscope-app-tests.sh

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/../package-soupscope-app.sh"

PACKAGE_SOUPSCOPE_LIB_ONLY=1 source "$script"

# The sourced script enables `set -e`; the harness deliberately drives helpers to
# failure and inspects their exit codes, so turn errexit back off here.
set +e

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok   - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL - %s\n' "$1"; }

# Assert a command succeeds (exit 0).
expect_ok() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc (expected success)"; fi
}
# Assert a command fails (non-zero exit).
expect_fail() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then bad "$desc (expected failure)"; else ok "$desc"; fi
}
# Assert a command succeeds AND prints exactly the expected stdout.
expect_stdout() {
    local desc="$1" want="$2"; shift 2
    local got status
    got=$("$@" 2>/dev/null); status=$?
    if [[ "$status" -eq 0 && "$got" == "$want" ]]; then
        ok "$desc"
    else
        bad "$desc (status=$status, got='$got', want='$want')"
    fi
}

# Build a canonical, valid bin dir: exactly the two required shaders, one each,
# in the pinned per-target bundle path. Echoes the bin dir.
make_good_bindir() {
    local root
    root=$(mktemp -d)
    mkdir -p "$root/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources"
    mkdir -p "$root/${PACKAGE_NAME}_SoupScopeApp.bundle/Contents/Resources"
    printf 'evaluate\n' > "$root/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources/BFFEvaluate.metal"
    printf 'render\n'   > "$root/${PACKAGE_NAME}_SoupScopeApp.bundle/Contents/Resources/SoupRender.metal"
    printf '%s' "$root"
}

# Build a valid, sealed Contents/Resources (exactly the two shaders). Echoes it.
make_good_resources() {
    local root
    root=$(mktemp -d)
    printf 'evaluate\n' > "$root/BFFEvaluate.metal"
    printf 'render\n'   > "$root/SoupRender.metal"
    printf '%s' "$root"
}

echo "manifest"
expect_stdout "required_basenames is exactly the two shaders, sorted" \
    $'BFFEvaluate.metal\nSoupRender.metal' required_basenames

echo "resolve_shader_source"
bindir=$(make_good_bindir)
expect_stdout "resolves BFFEvaluate from BFFMetal bundle" \
    "$bindir/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources/BFFEvaluate.metal" \
    resolve_shader_source "BFFEvaluate.metal" "BFFMetal" "$bindir"
expect_stdout "resolves SoupRender from SoupScopeApp bundle" \
    "$bindir/${PACKAGE_NAME}_SoupScopeApp.bundle/Contents/Resources/SoupRender.metal" \
    resolve_shader_source "SoupRender.metal" "SoupScopeApp" "$bindir"
expect_fail "fails when the expected per-target bundle is absent" \
    resolve_shader_source "SoupRender.metal" "NoSuchTarget" "$bindir"

# Missing basename inside an existing bundle.
missing=$(mktemp -d)
mkdir -p "$missing/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources"
expect_fail "fails when the required basename is missing from its bundle" \
    resolve_shader_source "BFFEvaluate.metal" "BFFMetal" "$missing"

# Ambiguous: two copies of the same basename inside one bundle.
dup=$(mktemp -d)
mkdir -p "$dup/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources" \
         "$dup/${PACKAGE_NAME}_BFFMetal.bundle/other"
printf 'a\n' > "$dup/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources/BFFEvaluate.metal"
printf 'b\n' > "$dup/${PACKAGE_NAME}_BFFMetal.bundle/other/BFFEvaluate.metal"
expect_fail "fails on an ambiguous (duplicated) source in one bundle" \
    resolve_shader_source "BFFEvaluate.metal" "BFFMetal" "$dup"

echo "verify_build_metal_set"
good=$(make_good_bindir)
expect_ok "accepts exactly the manifest set" verify_build_metal_set "$good"

# Missing one shader.
onlyone=$(mktemp -d)
mkdir -p "$onlyone/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources"
printf 'x\n' > "$onlyone/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources/BFFEvaluate.metal"
expect_fail "rejects a missing shader" verify_build_metal_set "$onlyone"

# Extra, unexpected .metal.
extra=$(make_good_bindir)
mkdir -p "$extra/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources"
printf 'x\n' > "$extra/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources/Stray.metal"
expect_fail "rejects an extra .metal file" verify_build_metal_set "$extra"

# Stale/duplicate copy of a required shader elsewhere under the bin dir.
stale=$(make_good_bindir)
mkdir -p "$stale/stale-leftover"
printf 'old\n' > "$stale/stale-leftover/BFFEvaluate.metal"
expect_fail "rejects a duplicate/stale .metal elsewhere under bin" \
    verify_build_metal_set "$stale"

echo "verify_packaged_resources"
res=$(make_good_resources)
expect_ok "accepts exactly the two sealed shaders" verify_packaged_resources "$res"

# Extra file.
resx=$(make_good_resources)
printf 'oops\n' > "$resx/README.txt"
expect_fail "rejects an extra file in Contents/Resources" \
    verify_packaged_resources "$resx"

# Missing file.
resm=$(mktemp -d)
printf 'evaluate\n' > "$resm/BFFEvaluate.metal"
expect_fail "rejects a missing shader in Contents/Resources" \
    verify_packaged_resources "$resm"

# Leaked SwiftPM resource bundle.
resb=$(make_good_resources)
mkdir -p "$resb/${PACKAGE_NAME}_BFFMetal.bundle"
expect_fail "rejects a leaked SwiftPM resource bundle" \
    verify_packaged_resources "$resb"

# A subdirectory (even if named like a shader) is rejected.
resd=$(make_good_resources)
mkdir -p "$resd/Extra.metal"
expect_fail "rejects a subdirectory in Contents/Resources" \
    verify_packaged_resources "$resd"

echo "verify_source_identity"
idroot=$(mktemp -d)
printf 'evaluate\n' > "$idroot/repo-BFFEvaluate.metal"
printf 'evaluate\n' > "$idroot/built-BFFEvaluate.metal"
expect_ok "accepts a byte-identical built resource" \
    verify_source_identity "BFFEvaluate.metal" \
        "$idroot/repo-BFFEvaluate.metal" "$idroot/built-BFFEvaluate.metal"

# Same name, drifted bytes.
printf 'evaluate-DRIFTED\n' > "$idroot/built-BFFEvaluate.metal"
expect_fail "rejects a built resource whose bytes differ from the repo source" \
    verify_source_identity "BFFEvaluate.metal" \
        "$idroot/repo-BFFEvaluate.metal" "$idroot/built-BFFEvaluate.metal"

# Missing repository source / missing built resource.
expect_fail "rejects a missing repository source" \
    verify_source_identity "BFFEvaluate.metal" \
        "$idroot/does-not-exist.metal" "$idroot/repo-BFFEvaluate.metal"
expect_fail "rejects a missing built resource" \
    verify_source_identity "BFFEvaluate.metal" \
        "$idroot/repo-BFFEvaluate.metal" "$idroot/does-not-exist.metal"

echo "stale content in a correctly named expected bundle"
# A bundle that is correctly named and structured — resolve_shader_source finds it
# without complaint — but whose shader bytes are stale relative to the repository
# source. Name/layout checks pass; only the byte-identity gate rejects it.
stalebin=$(make_good_bindir)
reposrc=$(mktemp -d)
printf 'evaluate\n' > "$reposrc/BFFEvaluate.metal"
stalefile="$stalebin/${PACKAGE_NAME}_BFFMetal.bundle/Contents/Resources/BFFEvaluate.metal"

expect_ok "correctly named bundle still resolves and its build set is valid" \
    verify_build_metal_set "$stalebin"
expect_stdout "resolve still succeeds for the correctly named shader" \
    "$stalefile" resolve_shader_source "BFFEvaluate.metal" "BFFMetal" "$stalebin"

printf 'evaluate-STALE\n' > "$stalefile"
resolved=$(resolve_shader_source "BFFEvaluate.metal" "BFFMetal" "$stalebin")
expect_fail "stale bytes under a correct name are rejected by the identity gate" \
    verify_source_identity "BFFEvaluate.metal" "$reposrc/BFFEvaluate.metal" "$resolved"

printf 'evaluate\n' > "$stalefile"
resolved=$(resolve_shader_source "BFFEvaluate.metal" "BFFMetal" "$stalebin")
expect_ok "restoring byte-identical content passes the identity gate" \
    verify_source_identity "BFFEvaluate.metal" "$reposrc/BFFEvaluate.metal" "$resolved"

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
