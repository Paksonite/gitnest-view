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
  test
