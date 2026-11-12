# Releasing

Releases are free: no Apple Developer Program. The app is signed with a
self-signed certificate (a stable identity, not notarized), shipped as a DMG
on GitHub Releases, installed with Homebrew and updated with Sparkle — the
same way as Paksonite/messenger.

## Publish a release

```bash
git tag v0.2.0
git push origin v0.2.0
```

`.github/workflows/release.yml` then:

1. runs the engine's and the app's tests,
2. builds the app (Apple silicon) with `VERSION=0.2.0` and
   `CFBundleVersion` = commit count,
3. signs it with the release certificate (`scripts/sign.sh`), the engine
   and Sparkle's parts included,
4. packs `GitNest-View-0.2.0.dmg` (`scripts/package.sh`),
5. writes `appcast.xml` with the DMG's EdDSA signature (`scripts/appcast.sh`),
6. creates the GitHub release with the DMG and `appcast.xml`,
7. updates `Casks/gitnest-view.rb` in Paksonite/homebrew-tap
   (`scripts/update-cask.sh`).

Tags with a hyphen (`v0.2.0-beta.1`) become pre-releases: they skip the
cask, and Sparkle ignores them because its feed is the latest full release.

## How users get it

```bash
brew trust paksonite/tap        # once: newer Homebrew refuses untrusted third-party taps
brew install --cask paksonite/tap/gitnest-view
```

The cask removes the quarantine flag after installing, so Gatekeeper does
not block the non-notarized app. A DMG downloaded by hand needs a one-time
"Open Anyway" in System Settings → Privacy & Security.

Sparkle checks
`https://github.com/Paksonite/gitnest-view/releases/latest/download/appcast.xml`
once a day; **GitNest View → Check for Updates…** checks right away. The cask
has `auto_updates true`, so `brew upgrade` leaves updating to Sparkle.

## Keys and secrets

| Secret | What | Local copy |
|---|---|---|
| `SIGNING_P12_BASE64` | Base64 of the self-signed code signing certificate + key (`.p12`) | `~/.config/paksonite-gitnest-view/signing.p12` |
| `SIGNING_P12_PASSWORD` | Password of the `.p12` | `~/.config/paksonite-gitnest-view/signing_p12_password` |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key (base64 seed) | `~/.config/paksonite-gitnest-view/sparkle_private_key` |
| `HOMEBREW_TAP_TOKEN` | Token with write access to Paksonite/homebrew-tap | the same as gitnest's and messenger's |

Set them once:

```bash
base64 -i ~/.config/paksonite-gitnest-view/signing.p12 | gh secret set SIGNING_P12_BASE64 -R Paksonite/gitnest-view
gh secret set SIGNING_P12_PASSWORD -R Paksonite/gitnest-view < ~/.config/paksonite-gitnest-view/signing_p12_password
gh secret set SPARKLE_ED_PRIVATE_KEY -R Paksonite/gitnest-view < ~/.config/paksonite-gitnest-view/sparkle_private_key
```

**Back up the certificate and the Sparkle key** (e.g. in a password manager).
Losing either means existing installs can no longer verify updates:

- Sparkle installs only updates whose DMG is signed with the key matching
  `SUPublicEDKey` in `Config/Info.plist`.
- macOS (the Keychain item with the access token, notification permission)
  and Sparkle expect the new app to have the same code signing identity:
  `certificate root = H"8ebce6aa4a4675e045ddd54e22b874371cf8bf6d"`.

The certificate is valid until November 2036. Because it has no Apple Team
ID, `Config/GitNestView.entitlements` disables library validation;
otherwise the hardened runtime refuses to load Sparkle.framework.

## Local release build

```bash
VERSION=0.2.0 scripts/build.sh
scripts/sign.sh                 # uses ~/.config/paksonite-gitnest-view/signing.p12
scripts/package.sh              # → build.noindex/GitNest-View-0.2.0.dmg
scripts/appcast.sh build.noindex/GitNest-View-0.2.0.dmg
DRY_RUN=1 scripts/update-cask.sh build.noindex/GitNest-View-0.2.0.dmg  # prints the cask
```

For daily use, `scripts/install.sh` builds, signs and replaces
`/Applications/GitNest View.app`; build output stays in `build.noindex/`,
which Spotlight does not index, so a search for GitNest finds only the
installed app.
