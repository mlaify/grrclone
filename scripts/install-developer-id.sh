#!/usr/bin/env bash
#
# Finishes Developer ID setup after you have downloaded the certificate from Apple.
#
# The signing key and request live in ~/.config/grrclone-signing, deliberately outside
# this repository: the repo is public, and a private key must never go near it.
#
# What you do in the browser (this script cannot, and should not, sign in as you):
#
#   1. Open https://developer.apple.com/account/resources/certificates/add
#   2. Choose "Developer ID Application"  (NOT "Apple Development" — that one cannot
#      sign software for distribution outside the App Store)
#   3. Upload  ~/.config/grrclone-signing/developer-id.csr
#   4. Download the resulting .cer file
#   5. Run:  scripts/install-developer-id.sh ~/Downloads/developerID_application.cer
#
# Only the Account Holder can create a Developer ID certificate, and an account may hold
# only a limited number, so do not create spares. If you already have one, reuse it
# rather than issuing another — two certificates with the same name make `codesign -s`
# ambiguous, which is a real failure mode and not merely untidy.
#
set -euo pipefail

CERT="${1:-}"
DIR="$HOME/.config/grrclone-signing"
KEY="$DIR/developer-id.key"

if [[ -z "$CERT" ]]; then
    echo "usage: $0 <downloaded .cer file>"
    echo
    echo "Get the .cer by uploading this request to Apple:"
    echo "  $DIR/developer-id.csr"
    echo "  https://developer.apple.com/account/resources/certificates/add"
    exit 1
fi

[[ -f "$CERT" ]] || { echo "No such file: $CERT"; exit 1; }
[[ -f "$KEY"  ]] || { echo "Missing private key at $KEY. Was the CSR generated elsewhere?"; exit 1; }

echo "Converting Apple's DER certificate to PEM…"
openssl x509 -inform DER -in "$CERT" -out "$DIR/developer-id.pem" 2>/dev/null \
    || cp "$CERT" "$DIR/developer-id.pem"   # already PEM

SUBJECT=$(openssl x509 -in "$DIR/developer-id.pem" -noout -subject)
echo "  $SUBJECT"

case "$SUBJECT" in
    *"Developer ID Application"*) ;;
    *)  echo
        echo "WARNING: this does not look like a Developer ID Application certificate."
        echo "Notarisation and distribution outside the App Store need that exact type."
        read -r -p "Continue anyway? [y/N] " reply
        [[ "$reply" == "y" ]] || exit 1
        ;;
esac

# Install into the keychain from the key and certificate directly.
#
# Not via a .p12, which is how this first went wrong: Homebrew's OpenSSL 3 writes
# PKCS#12 with a SHA-256 MAC, and macOS Security rejects it with "MAC verification
# failed during PKCS12 import (wrong password?)" — a misleading message, since the
# password was correct. Importing the two files needs no password at all.
echo
echo "Installing into your login keychain…"
security import "$KEY" -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign -T /usr/bin/security 2>&1 | sed 's/^/  /' || true
security import "$DIR/developer-id.pem" -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign -T /usr/bin/security 2>&1 | sed 's/^/  /' || true

# A .p12 is still wanted for CI, which has no keychain to import from. Written with
# SHA-1 MAC and 3DES so macOS and the GitHub runner can both read it.
echo
echo "Now a .p12 for CI. Choose a strong password; you will need it as a repo secret."
echo "(Press Ctrl-C to skip if you are not setting up CI yet.)"
openssl pkcs12 -export \
    -inkey "$KEY" \
    -in "$DIR/developer-id.pem" \
    -out "$DIR/developer-id.p12" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
chmod 600 "$DIR/developer-id.p12"

echo
echo "Verifying…"
MATCHES=$(security find-identity -v -p codesigning | grep -c "Developer ID Application" || true)
security find-identity -v -p codesigning | grep "Developer ID Application" || true

if [[ "$MATCHES" -eq 0 ]]; then
    echo
    echo "The identity is not showing up. Open Keychain Access and check that the"
    echo "certificate imported alongside its private key."
    exit 1
fi

if [[ "$MATCHES" -gt 1 ]]; then
    cat <<'WARN'

NOTE: more than one Developer ID Application certificate is installed.

`codesign -s "Developer ID Application: …"` will fail with "ambiguous" when two share a
name. scripts/sign-app.sh therefore signs by certificate hash, so builds still work.

Consider revoking the spare in the Apple Developer portal to free the slot, and deleting
it from Keychain Access. Check which is which before deleting: the one matching this
setup is the certificate whose fingerprint is printed below.
WARN
    echo
    echo "  this setup's certificate:"
    openssl x509 -in "$DIR/developer-id.pem" -noout -fingerprint -sha1 | sed 's/^/  /'
fi

echo
echo "Done. Next:"
echo "  - Back up $DIR/developer-id.p12 somewhere safe and offline. If the private key"
echo "    is lost the certificate is useless, and Apple will not reissue the same one."
echo "  - Sign a build:  scripts/sign-app.sh"
echo "  - Notarisation additionally needs an App Store Connect API key (.p8) from"
echo "    https://appstoreconnect.apple.com/access/integrations/api"
