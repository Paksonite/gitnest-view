#!/usr/bin/env bash
# Builds, signs and installs GitNest View into /Applications (or $INSTALL_DIR),
# replacing the copy there, so Spotlight finds exactly one GitNest View: the
# newest. Quits a running copy first and starts the new one unless NO_OPEN=1.
set -euo pipefail
cd "$(dirname "$0")/.."

dest_dir="${INSTALL_DIR:-/Applications}"
dest="$dest_dir/GitNest View.app"

scripts/build.sh
scripts/sign.sh "build.noindex/GitNest View.app"

if pgrep -xq "GitNest View"; then
  osascript -e 'tell application id "pl.paksonite.gitnest-view" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xq "GitNest View" || break; sleep 0.25; done
  pkill -x "GitNest View" 2>/dev/null || true
fi

rm -rf "$dest"
ditto "build.noindex/GitNest View.app" "$dest"
# Built here, so not quarantined; make sure anyway.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

# Forget copies elsewhere (old build folders), so Launch Services and
# Spotlight point at this one.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for old in build/"GitNest View.app" build/DerivedData/Build/Products/*/"GitNest View.app" \
           build.noindex/"GitNest View.app" build.noindex/DerivedData/Build/Products/*/"GitNest View.app"; do
  [[ -e "$old" ]] && "$lsregister" -u "$old" >/dev/null 2>&1 || true
done
"$lsregister" -f "$dest" >/dev/null 2>&1 || true
mdimport "$dest" >/dev/null 2>&1 || true

echo "Installed $dest ($(defaults read "$dest/Contents/Info" CFBundleShortVersionString) build $(defaults read "$dest/Contents/Info" CFBundleVersion))"
[[ "${NO_OPEN:-}" == 1 ]] || open "$dest"
