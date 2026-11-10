#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [--user | --destination DIRECTORY] [--no-open]\n' "$0"
}

install_dir=/Applications
open_after_install=yes
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) install_dir="$HOME/Applications" ;;
        --destination)
            if [[ $# -lt 2 || "$2" != /* ]]; then usage >&2; exit 2; fi
            install_dir="$2"
            shift
            ;;
        --no-open) open_after_install=no ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Route Shield requires macOS 13 or later.\n' >&2
    exit 1
fi
macos_version="$(/usr/bin/sw_vers -productVersion)"
if [[ "${macos_version%%.*}" -lt 13 ]]; then
    printf 'Route Shield requires macOS 13 or later (found %s).\n' "$macos_version" >&2
    exit 1
fi
if ! sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null)" ||
   ! /usr/bin/xcrun --find clang++ >/dev/null 2>&1; then
    /usr/bin/xcode-select --install || true
    printf 'Complete the Apple Command Line Tools installation, then run this script again.\n' >&2
    exit 1
fi
if [[ "${sdk_version%%.*}" -lt 13 ]]; then
    printf 'Update Xcode Command Line Tools to a version with the macOS 13 SDK or later.\n' >&2
    exit 1
fi

if ! mkdir -p -- "$install_dir" || [[ ! -w "$install_dir" ]]; then
    printf 'Cannot write to %s. Try ./install.sh --user to install for this account.\n' "$install_dir" >&2
    exit 1
fi
app_name='Route Shield.app'
destination="$install_dir/$app_name"
lock="$install_dir/.route-shield-install.lock"
if ! mkdir -- "$lock"; then
    printf 'Cannot acquire the install lock at %s. If no installation is running, remove the stale lock.\n' "$lock" >&2
    exit 1
fi
stage=''
cleanup() {
    if [[ -n "$stage" ]]; then
        if [[ -d "$stage/previous.app" && ! -e "$destination" && ! -L "$destination" ]]; then
            if ! mv -- "$stage/previous.app" "$destination"; then
                printf 'Previous copy retained at %s/previous.app\n' "$stage" >&2
                rmdir -- "$lock"
                return
            fi
        fi
        rm -rf -- "$stage"
    fi
    rmdir -- "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "$destination" || -L "$destination" ]]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -L "$destination" || "$identifier" != local.vpnguard ]]; then
        printf 'An unrelated item already exists at %s.\n' "$destination" >&2
        exit 1
    fi
fi

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app="$("$project_dir/build.sh")"
stage="$(mktemp -d "$install_dir/.route-shield.XXXXXX")"
/usr/bin/ditto "$app" "$stage/$app_name"
/usr/bin/codesign --verify --strict "$stage/$app_name"
if [[ -d "$destination" ]]; then
    mv -- "$destination" "$stage/previous.app"
fi
mv -- "$stage/$app_name" "$destination"

printf 'Installed: %s\n' "$destination"
if [[ "$open_after_install" == yes ]]; then
    /usr/bin/open "$destination"
fi
