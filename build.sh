#!/bin/bash
set -euo pipefail

arch_args=()
case "${1:-}" in
    "") ;;
    --universal) arch_args=(-arch arm64 -arch x86_64) ;;
    *) printf 'Usage: %s [--universal]\n' "$0" >&2; exit 2 ;;
esac

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$project_dir/build"
mkdir -p "$build_dir"
stage="$(mktemp -d "$build_dir/.stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

app="$stage/Route Shield.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$project_dir/src/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/.env.example" "$app/Contents/Resources/.env.example"
cp "$project_dir/assets/RouteShield.icns" "$app/Contents/Resources/RouteShield.icns"
cp -R "$project_dir/src/en.lproj" "$app/Contents/Resources/en.lproj"
cp "$project_dir/LICENSE" "$app/Contents/Resources/LICENSE"

xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "${arch_args[@]+"${arch_args[@]}"}" \
    -framework AppKit -framework ImageIO -framework Network -framework ServiceManagement \
    -framework SystemConfiguration -framework UserNotifications \
    "$project_dir/src/main.mm" -o "$app/Contents/MacOS/VPNGuard"
/usr/bin/codesign --force --sign - "$app"

dest="$build_dir/Route Shield.app"
if [[ -e "$dest" ]]; then
    # Keep the previous build until compilation and signing have succeeded.
    mv -- "$dest" "$stage/previous.app"
fi
if ! mv -- "$app" "$dest"; then
    if [[ -d "$stage/previous.app" ]]; then
        mv -- "$stage/previous.app" "$dest"
    fi
    exit 1
fi
printf '%s\n' "$dest"
