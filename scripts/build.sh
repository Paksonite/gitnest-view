#!/usr/bin/env bash
# Builds "GitNest View.app" (Apple silicon) into build.noindex/.
#
# Everything the build makes lives in build.noindex/: Spotlight skips folders
# ending in .noindex, so only the installed app (scripts/install.sh) turns up
# when you search for GitNest.
#
# VERSION sets CFBundleShortVersionString (default: MARKETING_VERSION in project.yml).
# BUILD_NUMBER sets CFBundleVersion (default: commit count).
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-Release}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
version_args=(CURRENT_PROJECT_VERSION="$build_number")
[[ -n "${VERSION:-}" ]] && version_args+=(MARKETING_VERSION="$VERSION")

xcodegen generate --quiet
xcodebuild \
  -project GitNestView.xcodeproj \
  -scheme GitNestView \
  -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build.noindex/DerivedData \
  "${version_args[@]}" \
  -quiet \
  build

rm -rf "build.noindex/GitNest View.app"
ditto "build.noindex/DerivedData/Build/Products/$configuration/GitNest View.app" "build.noindex/GitNest View.app"
echo "Built build.noindex/GitNest View.app ($configuration, build $build_number)"
