#!/usr/bin/env bash
# Build grrclone.app. Debug by default; pass `release` for a Release build.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
[[ "$CONFIG" == "release" ]] && CONFIG=Release

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }

( cd App && xcodegen generate )
xcodebuild -project App/grrclone.xcodeproj -scheme grrclone \
  -configuration "$CONFIG" -derivedDataPath build build

APP="build/Build/Products/$CONFIG/grrclone.app"
echo
echo "Built $APP"
echo "Run with:  open $APP"
