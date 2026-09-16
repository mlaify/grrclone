#!/usr/bin/env bash
#
# Sign grrclone.app with a Developer ID certificate, ready for notarisation.
#
#   scripts/build-app.sh release
#   scripts/sign-app.sh
#
# Set GRRCLONE_SIGN_IDENTITY to a certificate SHA-1 hash to choose a specific one.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Build/Products/Release/grrclone.app}"
ENTITLEMENTS="App/grrclone/Resources/grrclone.entitlements"

[[ -d "$APP" ]] || { echo "No app at $APP. Run scripts/build-app.sh release first."; exit 1; }

# Resolve the identity to a hash, never a name.
#
# Two certificates can share the exact same common name — an account with a spare
# Developer ID has this — and `codesign -s "<name>"` then fails outright with
# "ambiguous". A hash is unique, so this works regardless.
if [[ -n "${GRRCLONE_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$GRRCLONE_SIGN_IDENTITY"
else
    mapfile -t HASHES < <(security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | awk '{print $2}')

    case "${#HASHES[@]}" in
        0)  echo "No Developer ID Application certificate found."
            echo "Run scripts/install-developer-id.sh first."
            exit 1 ;;
        1)  IDENTITY="${HASHES[0]}" ;;
        *)  echo "More than one Developer ID Application certificate is installed:"
            security find-identity -v -p codesigning | grep "Developer ID Application" | sed 's/^/  /'
            echo
            echo "Pick one and re-run with it, for example:"
            echo "  GRRCLONE_SIGN_IDENTITY=${HASHES[0]} $0"
            echo
            echo "Revoking the spare at Apple and deleting it from Keychain Access will"
            echo "make this unnecessary."
            exit 1 ;;
    esac
fi

echo "Signing with $IDENTITY"
security find-certificate -c "Developer ID Application" -p 2>/dev/null >/dev/null || true

# Sign inside-out, and never with --deep.
#
# --deep is deprecated for signing and actively harmful: it applies the outer bundle's
# entitlements to every nested binary, which invalidates anything that needs its own.
# It remains fine for *verification*, which is why it appears below with --verify.
sign() {
    local target="$1"; shift
    echo "  $(basename "$target")"
    codesign --force --timestamp --options runtime -s "$IDENTITY" "$@" "$target"
}

# Nested executables and frameworks first, outermost bundle last.
while IFS= read -r -d '' nested; do
    sign "$nested"
done < <(find "$APP/Contents" \
            \( -name "*.dylib" -o -name "*.framework" -o -path "*/Contents/MacOS/*" \) \
            -type f -not -path "$APP/Contents/MacOS/grrclone" -print0 2>/dev/null)

# The bundled rclone, once we ship one, must be re-signed with our own Team ID:
# upstream's signature carries a different team and fails Gatekeeper's consistency check.
if [[ -f "$APP/Contents/Resources/rclone" ]]; then
    sign "$APP/Contents/Resources/rclone"
fi

sign "$APP" --entitlements "$ENTITLEMENTS"

echo
echo "Verifying…"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags" | sed 's/^/  /'

echo
# spctl assesses as Gatekeeper would. Before notarisation it is expected to reject the
# app: the signature is valid, but the notarisation ticket does not exist yet.
if spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/  /' | grep -q accepted; then
    echo
    echo "Gatekeeper accepts it."
else
    echo
    echo "Gatekeeper rejects it, which is expected until the app is notarised."
fi

echo
echo "Next: notarise it."
echo "  ditto -c -k --keepParent \"$APP\" build/grrclone.zip"
echo "  xcrun notarytool submit build/grrclone.zip --keychain-profile AC_NOTARY --wait"
echo "  xcrun stapler staple \"$APP\""
echo
echo "AC_NOTARY is stored once with an App Store Connect API key:"
echo "  xcrun notarytool store-credentials AC_NOTARY --key AuthKey_XXXX.p8 \\"
echo "      --key-id <KEY_ID> --issuer <ISSUER_UUID>"
