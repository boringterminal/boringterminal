#!/bin/bash

# Real codesign regression checks without touching installed apps or TCC.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/boringterminal-signing.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
app="$test_dir/Boring Terminal.app"
mkdir -p "$app/Contents/MacOS"
cp "$repo_root/assets/Info.plist" "$app/Contents/Info.plist"
printf 'int main(void) { return 0; }\n' > "$test_dir/main.c"
xcrun clang "$test_dir/main.c" -o "$app/Contents/MacOS/boringterminal"
cp "$app/Contents/MacOS/boringterminal" "$app/Contents/MacOS/boringterminald"

/bin/bash "$repo_root/scripts/sign-macos.sh" "$app" -
app_signature="$(codesign --display --verbose=4 "$app" 2>&1)"
helper_signature="$(codesign --display --verbose=4 "$app/Contents/MacOS/boringterminald" 2>&1)"
[[ "$app_signature" == *'Identifier=com.boringterminal.BoringTerminal'* ]]
[[ "$helper_signature" == *'Identifier=com.boringterminal.BoringTerminal.daemon'* ]]
[[ "$app_signature" == *'Signature=adhoc'* ]]
[[ "$helper_signature" == *'Signature=adhoc'* ]]

before="$(shasum -a 256 "$app/Contents/MacOS/boringterminal" "$app/Contents/MacOS/boringterminald")"
if /bin/bash "$repo_root/scripts/sign-macos.sh" "$app" '' > "$test_dir/empty.log" 2>&1; then
    echo 'error: an empty identity unexpectedly succeeded' >&2
    exit 1
fi
if /bin/bash "$repo_root/scripts/sign-macos.sh" "$app" 'Boring Terminal Nonexistent Regression Identity' > "$test_dir/missing.log" 2>&1; then
    echo 'error: a missing identity unexpectedly succeeded' >&2
    exit 1
fi
after="$(shasum -a 256 "$app/Contents/MacOS/boringterminal" "$app/Contents/MacOS/boringterminald")"
[[ "$before" == "$after" ]]
codesign --verify --deep --strict "$app"
echo 'macOS signing regression checks passed (TCC acceptance requires a GUI test).'
