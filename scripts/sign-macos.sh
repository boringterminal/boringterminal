#!/bin/bash

# Keep local builds and universal packaging on the same signing policy.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <Boring Terminal.app> [codesign-identity|-]" >&2
    exit 1
fi

app_path="$1"
identity="${2--}"
if [[ -z "$identity" ]]; then
    echo "error: signing identity is empty; use '-' explicitly for ad-hoc signing" >&2
    exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
if [[ "$bundle_id" != "com.boringterminal.BoringTerminal" ]]; then
    echo "error: refusing to sign a bundle with an unexpected identifier: $bundle_id" >&2
    exit 1
fi
for executable in boringterminald boringterminal; do
    [[ -f "$app_path/Contents/MacOS/$executable" ]] || {
        echo "error: missing bundled executable: $executable" >&2
        exit 1
    }
done

sign_args=(--force --sign "$identity")
if [[ "$identity" == "-" ]]; then
    sign_args+=(--timestamp=none)
else
    sign_args+=(--timestamp)
fi

# Sign nested code first, then seal the bundle. A requested certificate that
# cannot sign is an error; falling back to '-' would reintroduce identity churn.
/usr/bin/codesign "${sign_args[@]}" --identifier "$bundle_id.daemon" \
    "$app_path/Contents/MacOS/boringterminald"
/usr/bin/codesign "${sign_args[@]}" --identifier "$bundle_id" \
    "$app_path/Contents/MacOS/boringterminal"
/usr/bin/codesign "${sign_args[@]}" --identifier "$bundle_id" "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
