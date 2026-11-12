#!/usr/bin/env bash
# Packs the signed build.noindex/GitNest View.app into
# build.noindex/GitNest-View-<version>.dmg and prints its path.
set -euo pipefail
cd "$(dirname "$0")/.."

app="build.noindex/GitNest View.app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
dmg="build.noindex/GitNest-View-$version.dmg"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/GitNest View.app"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create -volname "GitNest View" -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$dmg" >/dev/null
echo "$dmg"
