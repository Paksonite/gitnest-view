#!/usr/bin/env bash
# Clicks through the real app (XCUITest). Takes over the pointer and the
# keyboard while it runs; the Mac must be unlocked. Needs a TEST server:
#
#   GNV_UI_HOST=… GNV_UI_TOKEN=… GNV_UI_WORKDIR=… GNV_UI_WORKSPACE=… GNV_UI_LOGIN=… \
#   GNV_UI_PULL_REPO=… GNV_UI_TF_REPO=… scripts/ui-test.sh [-only-testing:…]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GNV_UI_HOST:?set GNV_UI_HOST}" "${GNV_UI_TOKEN:?set GNV_UI_TOKEN}" "${GNV_UI_WORKDIR:?set GNV_UI_WORKDIR}"
for name in HOST TOKEN WORKDIR WORKSPACE LOGIN PULL_REPO TF_REPO FEATURE_REPO FEATURE_BRANCH RELEASE; do
  key="GNV_UI_$name"
  [[ -n "${!key:-}" ]] && export "TEST_RUNNER_$key=${!key}"
done
mkdir -p build.noindex/ui-tmp
export TEST_RUNNER_GNV_UI_TMP="$PWD/build.noindex/ui-tmp"
xcodegen generate --quiet
xcodebuild -project GitNestView.xcodeproj -scheme GitNestViewUI -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/DerivedData test "$@" || failed=$?
# Pictures of the window at each step, for a look afterwards.
result="$(ls -td build.noindex/DerivedData/Logs/Test/*.xcresult | head -1)"
rm -rf build.noindex/ui-shots
xcrun xcresulttool export attachments --path "$result" --output-path build.noindex/ui-shots >/dev/null 2>&1 || true
echo "pictures: build.noindex/ui-shots"
exit "${failed:-0}"
