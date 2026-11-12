#!/usr/bin/env bash
# Runs the tests: the Go engine, then the app.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"

(cd core && go vet ./... && go test ./...)

xcodegen generate --quiet
xcodebuild \
  -project GitNestView.xcodeproj \
  -scheme GitNestView \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/DerivedData \
  -quiet \
  test || {
  # Quiet output names the failing tests but not why: say why.
  result="$(ls -td build.noindex/DerivedData/Logs/Test/*.xcresult 2>/dev/null | head -1)"
  if [[ -n "$result" ]]; then
    xcrun xcresulttool get test-results summary --path "$result" 2>/dev/null |
      python3 -c 'import sys, json
for failure in json.load(sys.stdin).get("testFailures", []):
    print("FAILED", failure.get("testName"), "|", failure.get("failureText", "")[:1500])' || true
  fi
  exit 1
}
