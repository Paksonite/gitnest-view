#!/usr/bin/env bash
# Signs an app bundle (default: build.noindex/GitNest View.app), its engine
# included, with the self-signed GitNest View certificate.
#
# The certificate comes from SIGNING_P12_BASE64 + SIGNING_P12_PASSWORD (CI) or
# from ~/.config/paksonite-gitnest-view/signing.p12 + signing_p12_password
# (local). Without either the app is signed ad hoc, which works, but changes the
# app's identity on every build, so macOS asks again for the Keychain token.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build.noindex/GitNest View.app}"
config_dir="$HOME/.config/paksonite-gitnest-view"
work="$PWD/build.noindex"
keychain="$work/signing.keychain-db"
mkdir -p "$work"

p12=""
if [[ -n "${SIGNING_P12_BASE64:-}" ]]; then
  p12="$work/signing.p12"
  base64 --decode <<<"$SIGNING_P12_BASE64" >"$p12"
  password="$SIGNING_P12_PASSWORD"
elif [[ -f "$config_dir/signing.p12" ]]; then
  p12="$config_dir/signing.p12"
  password="$(cat "$config_dir/signing_p12_password")"
fi

sign_args=(--force --timestamp=none --options runtime)
if [[ -n "$p12" ]]; then
  keychain_password="$(openssl rand -hex 16)"
  rm -f "$keychain"
  security create-keychain -p "$keychain_password" "$keychain"
  # codesign finds the key only when its keychain is in the user search list.
  original_keychains=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    original_keychains+=("${line//\"/}")
  done < <(security list-keychains -d user)
  cleanup() {
    security list-keychains -d user -s "${original_keychains[@]}"
    security delete-keychain "$keychain" 2>/dev/null || true
    rm -f "$work/signing.p12"
  }
  trap cleanup EXIT
  security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null

  # By SHA-1: codesign does not match untrusted (self-signed) identities by name everywhere.
  identity="$(security find-identity -p codesigning "$keychain" | awk '/^ *1\) / { print $2; exit }')"
  if [[ -z "$identity" ]]; then
    security find-identity -p codesigning "$keychain" >&2
    echo "error: no code signing identity in $p12" >&2
    exit 1
  fi
  echo "Signing with certificate $identity"
  sign_args+=(--sign "$identity" --keychain "$keychain")
else
  echo "warning: no signing certificate found, signing ad hoc" >&2
  sign_args+=(--sign -)
fi

# Inside out: the engine and Sparkle (in the order Sparkle documents) first,
# then the app that seals them.
codesign "${sign_args[@]}" "$app/Contents/Helpers/gitnest-core"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$sparkle" ]]; then
  codesign "${sign_args[@]}" "$sparkle/XPCServices/Installer.xpc"
  codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
  codesign "${sign_args[@]}" "$sparkle/Autoupdate"
  codesign "${sign_args[@]}" "$sparkle/Updater.app"
  codesign "${sign_args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
fi
codesign "${sign_args[@]}" --entitlements Config/GitNestView.entitlements "$app"
codesign --verify --strict --deep "$app"
echo "Signed $app"
