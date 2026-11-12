#!/usr/bin/env bash
# Builds the Go engine (core/) to the path given as $1, or build/gitnest-core.
# Xcode runs it as a build phase to put the engine inside the app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-$PWD/build/gitnest-core}"

# Xcode's PATH has no Homebrew.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
command -v go >/dev/null || { echo "error: Go is not installed (brew install go)" >&2; exit 1; }

version="${MARKETING_VERSION:-dev}"
mkdir -p "$(dirname "$out")"
(cd core && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
  go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$out" ./cmd/gitnest-core)
# Go's linker signs ad hoc; sign again so the engine carries the app's
# identity when a real one is used (EXPANDED_CODE_SIGN_IDENTITY is set by Xcode).
codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$out"
