#!/usr/bin/env bash
# Writes build.noindex/appcast.xml describing one release DMG, with its
# Sparkle EdDSA signature.
# Usage: scripts/appcast.sh build.noindex/GitNest-View-<version>.dmg
#
# The private key comes from SPARKLE_ED_PRIVATE_KEY (CI) or
# ~/.config/paksonite-gitnest-view/sparkle_private_key (local).
set -euo pipefail
cd "$(dirname "$0")/.."

dmg="$1"
plist="build.noindex/GitNest View.app/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
version="$(read_plist CFBundleShortVersionString)"
build="$(read_plist CFBundleVersion)"
minimum_os="$(read_plist LSMinimumSystemVersion)"
repository="${GITHUB_REPOSITORY:-Paksonite/gitnest-view}"
# DOWNLOAD_BASE_URL overrides where the DMG is served from, e.g. a local server for update tests.
base_url="${DOWNLOAD_BASE_URL:-https://github.com/$repository/releases/download/v$version}"
url="$base_url/$(basename "$dmg")"

key_file="$HOME/.config/paksonite-gitnest-view/sparkle_private_key"
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  key_file="$(mktemp)"
  trap 'rm -f "$key_file"' EXIT
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" >"$key_file"
fi

tools="$(scripts/sparkle-tools.sh)"
# Prints: sparkle:edSignature="..." length="..."
enclosure_attributes="$("$tools/sign_update" --ed-key-file "$key_file" "$dmg")"

cat >build.noindex/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>GitNest View</title>
    <item>
      <title>GitNest View $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum_os</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$repository/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="$url" type="application/octet-stream" $enclosure_attributes/>
    </item>
  </channel>
</rss>
XML
echo build.noindex/appcast.xml
