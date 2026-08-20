#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

for tool in zig lipo codesign hdiutil shasum xcrun; do
    command -v "$tool" >/dev/null || {
        echo "error: required tool not found: $tool" >&2
        exit 1
    }
done

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "$sdk_path/System/Library/Frameworks" ]] || {
    echo "error: xcrun returned an invalid macOS SDK: $sdk_path" >&2
    exit 1
}

version="$(sed -n 's/^pub const semantic = "\([^"]*\)";$/\1/p' src/version.zig)"
zon_version="$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' build.zig.zon)"
plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' assets/Info.plist)"

if [[ -z "$version" || "$version" != "$zon_version" || "$version" != "$plist_version" ]]; then
    echo "error: release versions disagree" >&2
    echo "  src/version.zig: ${version:-<missing>}" >&2
    echo "  build.zig.zon: ${zon_version:-<missing>}" >&2
    echo "  Info.plist: ${plist_version:-<missing>}" >&2
    exit 1
fi

check_only=false
if [[ "${1:-}" == "--check" ]]; then
    check_only=true
    shift
fi

if [[ $# -gt 1 ]]; then
    echo "usage: $0 [--check] [v<VERSION>|VERSION]" >&2
    exit 1
fi
if [[ $# -eq 1 && "${1#v}" != "$version" ]]; then
    echo "error: requested version ${1#v} does not match source version $version" >&2
    exit 1
fi

if $check_only; then
    echo "Release version $version is consistent."
    exit 0
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/boringterminal-release.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

arm_prefix="$work_dir/arm64"
x86_prefix="$work_dir/x86_64"
stage_dir="$work_dir/stage"
dmg_source="$work_dir/dmg"
release_dir="$repo_root/zig-out/release"
app_name="Boring Terminal.app"
artifact_name="Boring-Terminal-v${version}-macos-universal.dmg"

echo "Building Boring Terminal $version for Apple Silicon..."
zig build \
    -Dtarget=aarch64-macos.13.0 \
    -Doptimize=ReleaseSafe \
    --sysroot "$sdk_path" \
    --prefix "$arm_prefix"

echo "Building Boring Terminal $version for Intel..."
zig build \
    -Dtarget=x86_64-macos.13.0 \
    -Doptimize=ReleaseSafe \
    --sysroot "$sdk_path" \
    --prefix "$x86_prefix"

mkdir -p "$stage_dir" "$dmg_source" "$release_dir"
/usr/bin/ditto "$arm_prefix/$app_name" "$stage_dir/$app_name"

for executable in boringterminal boringterminald; do
    lipo -create \
        "$arm_prefix/$app_name/Contents/MacOS/$executable" \
        "$x86_prefix/$app_name/Contents/MacOS/$executable" \
        -output "$stage_dir/$app_name/Contents/MacOS/$executable"
    slices="$(lipo -archs "$stage_dir/$app_name/Contents/MacOS/$executable")"
    [[ "$slices" == *arm64* && "$slices" == *x86_64* ]] || {
        echo "error: $executable is not universal: $slices" >&2
        exit 1
    }
    codesign --force --sign - --timestamp=none \
        "$stage_dir/$app_name/Contents/MacOS/$executable"
done

codesign --force --sign - --timestamp=none "$stage_dir/$app_name"
codesign --verify --deep --strict --verbose=2 "$stage_dir/$app_name"

/usr/bin/ditto "$stage_dir/$app_name" "$dmg_source/$app_name"
/usr/bin/ditto "$repo_root/LICENSE" "$dmg_source/LICENSE"
ln -s /Applications "$dmg_source/Applications"

artifact_path="$release_dir/$artifact_name"
hdiutil create \
    -volname "Boring Terminal" \
    -fs HFS+ \
    -srcfolder "$dmg_source" \
    -ov \
    -format UDZO \
    "$artifact_path"

(
    cd "$release_dir"
    LC_ALL=C LANG=C shasum -a 256 "$artifact_name" > "$artifact_name.sha256"
)

echo "Created $artifact_path"
echo "Created $artifact_path.sha256"
