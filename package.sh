#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app="$("$project_dir/build.sh" --universal)"
/usr/bin/codesign --verify --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
archive="Route-Shield-v${version}-macOS-universal.zip"
build_dir="$(dirname -- "$app")"
stage="$(mktemp -d "$build_dir/.package.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$archive"
(
    cd -- "$stage"
    /usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
)
mv -f -- "$stage/$archive" "$stage/$archive.sha256" "$build_dir"
printf '%s\n' "$build_dir/$archive" "$build_dir/$archive.sha256"
