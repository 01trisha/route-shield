#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app="$("$project_dir/build.sh" --universal)"
/usr/bin/codesign --verify --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
basename="Route-Shield-v${version}-macOS-universal"
archive="$basename.zip"
image="$basename.dmg"
build_dir="$(dirname -- "$app")"
stage="$(mktemp -d "$build_dir/.package.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/$archive"
image_contents="$stage/image"
mkdir -- "$image_contents"
/usr/bin/ditto "$app" "$image_contents/Route Shield.app"
ln -s /Applications "$image_contents/Applications"
/usr/bin/hdiutil create -srcfolder "$image_contents" -volname "Route Shield" \
    -fs HFS+ -format UDZO "$stage/$image" >/dev/null

artifacts=("$archive" "$archive.sha256" "$image" "$image.sha256")
(
    cd -- "$stage"
    /usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
    /usr/bin/shasum -a 256 "$image" > "$image.sha256"
    mv -f -- "${artifacts[@]}" "$build_dir"
)
for artifact in "${artifacts[@]}"; do
    printf '%s\n' "$build_dir/$artifact"
done
