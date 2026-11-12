#!/usr/bin/env bash
# Downloads Sparkle's command line tools (pinned and checksum-verified) and prints their directory.
set -euo pipefail
cd "$(dirname "$0")/.."

version=2.10.0
sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
dir="build.noindex/sparkle-tools/$version"

if [[ ! -x "$dir/bin/sign_update" ]]; then
  archive="$(mktemp)"
  trap 'rm -f "$archive"' EXIT
  curl -fsSL -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
  echo "$sha256  $archive" | shasum -a 256 -c - >/dev/null
  mkdir -p "$dir"
  tar -xf "$archive" -C "$dir" bin
fi
echo "$PWD/$dir/bin"
