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
# ARCHS is explicit rather than inherited from whatever the build machine happens to
# be. grrclone is Apple Silicon only by decision, and an incidental property is not a
# decision: building on an Intel Mac, or under Rosetta, would otherwise quietly produce
# an artefact nobody intended to ship.
xcodebuild -project App/grrclone.xcodeproj -scheme grrclone \
  -configuration "$CONFIG" -derivedDataPath build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build 2>&1 \
  | grep -E "(warning|error|note): |^\*\* BUILD"
STATUS=${PIPESTATUS[0]}
set -e
[[ $STATUS -eq 0 ]] || { echo "build failed (exit $STATUS); rerun without the filter to see why"; exit $STATUS; }

APP="build/Build/Products/$CONFIG/grrclone.app"

# Assert the architecture rather than trusting the flag. This is the artefact people
# run, so it is the one worth checking.
SLICES=$(lipo -archs "$APP/Contents/MacOS/grrclone")
if [[ "$SLICES" != "arm64" ]]; then
    echo "expected an arm64-only binary, got: $SLICES" >&2
    exit 1
fi

echo
echo "Built $APP ($SLICES)"
echo "Run with:  open $APP"
