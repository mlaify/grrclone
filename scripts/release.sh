#!/usr/bin/env bash
#
# Build, sign, notarise and staple a distributable grrclone.dmg.
#
#   scripts/release.sh
#
# Requires a Developer ID certificate (scripts/install-developer-id.sh) and a stored
# notarytool profile:
#
#   xcrun notarytool store-credentials AC_NOTARY \
#       --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
#
# The issuer UUID is on the App Store Connect API page under Users and Access →
# Integrations. It is not the Team ID.
#
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${GRRCLONE_NOTARY_PROFILE:-AC_NOTARY}"
APP="build/Build/Products/Release/grrclone.app"
DMG="build/grrclone.dmg"
STAGE="build/dmg-stage"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "Build"
scripts/build-app.sh release >/dev/null
echo "  $APP"

step "Sign"
scripts/sign-app.sh "$APP" | sed 's/^/  /'

step "Notarise the app"
# The app is notarised before going into the disk image, and the image is notarised
# again afterwards. Both carry their own ticket: stapling the app means it stays
# trusted once dragged out, and stapling the image means Gatekeeper is satisfied
# before anything is copied anywhere.
ditto -c -k --keepParent "$APP" build/grrclone-app.zip
xcrun notarytool submit build/grrclone-app.zip \
    --keychain-profile "$PROFILE" --wait --timeout 30m | sed 's/^/  /'
xcrun stapler staple "$APP" | tail -1 | sed 's/^/  /'

step "Build the disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# A symlink to /Applications is what makes the window a drag-to-install target.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "grrclone" -srcfolder "$STAGE" -ov -format UDZO "$DMG" \
    | grep -E "created:" | sed 's/^/  /'
rm -rf "$STAGE"

step "Notarise the disk image"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$PROFILE" --wait --timeout 30m | sed 's/^/  /'
xcrun stapler staple "$DMG" | tail -1 | sed 's/^/  /'

step "Verify as a user's Mac would"
# spctl is the assessment Gatekeeper itself performs. "Notarized Developer ID" is the
# only source value that opens without a warning on a machine that has never seen the
# app before.
spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/  /'
xcrun stapler validate "$DMG" | tail -1 | sed 's/^/  /'

step "Done"
ls -lh "$DMG" | awk '{print "  " $9 "  " $5}'
echo
echo "  Verify a download on another Mac with:"
echo "    spctl -a -vvv -t open --context context:primary-signature $DMG"
