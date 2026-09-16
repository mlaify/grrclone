#!/usr/bin/env bash
# Build grrclone.app. Debug by default; pass `release` for a Release build.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
[[ "$CONFIG" == "release" ]] && CONFIG=Release

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }

( cd App && xcodegen generate >/dev/null )

# xcodebuild's default output is thousands of lines of compiler invocations. Keep only
# what a human needs: warnings, errors, and the verdict.
set +e
xcodebuild -project App/grrclone.xcodeproj -scheme grrclone \
  -configuration "$CONFIG" -derivedDataPath build build 2>&1 \
  | grep -E "(warning|error|note): |^\*\* BUILD"
STATUS=${PIPESTATUS[0]}
set -e
[[ $STATUS -eq 0 ]] || { echo "build failed (exit $STATUS); rerun without the filter to see why"; exit $STATUS; }

APP="build/Build/Products/$CONFIG/grrclone.app"
echo
echo "Built $APP"
echo "Run with:  open $APP"
