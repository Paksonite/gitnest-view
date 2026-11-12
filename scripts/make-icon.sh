#!/usr/bin/env bash
# Renders the app icon and the in-app logo from design/*.svg into the asset
# catalog. Needs resvg (brew install resvg). Run after changing the artwork.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v resvg >/dev/null || { echo "error: resvg is not installed (brew install resvg)" >&2; exit 1; }

icons=Resources/Assets.xcassets/AppIcon.appiconset
for size in 16 32 64 128 256 512 1024; do
  resvg --width "$size" --height "$size" design/AppIcon.svg "$icons/icon_$size.png"
done
cp design/Logo.svg Resources/Assets.xcassets/Logo.imageset/Logo.svg
echo "Rendered $icons and the logo"
