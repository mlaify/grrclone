#!/usr/bin/env bash
#
# Finishes Developer ID setup after you have downloaded the certificate from Apple.
#
# The signing key and request were generated into ~/.config/grrclone-signing, which is
# deliberately outside this repository: the repo is public, and a private key must never
# go near it.
#
# What you do in the browser (this script cannot, and should not, log in as you):
#
#   1. Open https://developer.apple.com/account/resources/certificates/add
#   2. Choose "Developer ID Application"  (NOT "Apple Development" — that one is already
#      installed and cannot sign software for distribution outside the App Store)
#   3. Upload  ~/.config/grrclone-signing/developer-id.csr
#   4. Download the resulting .cer file
#   5. Run:  scripts/install-developer-id.sh ~/Downloads/developerID_application.cer
#
# Only the Account Holder can create a Developer ID certificate, and an account is
# limited in how many it may have, so do not create spares.
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
        echo "An 'Apple Development' or 'Apple Distribution' certificate will not work."
        read -r -p "Continue anyway? [y/N] " reply
        [[ "$reply" == "y" ]] || exit 1
        ;;
esac

# The .p12 bundles certificate and private key together. It is what CI imports, and what
# you should back up — losing the key means the certificate is useless and Apple will not
# reissue the same one.
echo
echo "Creating a .p12 bundle. Choose a strong password; you will need it for CI."
openssl pkcs12 -export \
    -inkey "$KEY" \
    -in "$DIR/developer-id.pem" \
    -out "$DIR/developer-id.p12"
chmod 600 "$DIR/developer-id.p12"

echo
echo "Importing into your login keychain…"
security import "$DIR/developer-id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -T /usr/bin/codesign

echo
echo "Verifying…"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    security find-identity -v -p codesigning | grep "Developer ID Application"
    echo
    echo "Done. Next steps:"
    echo "  - Back up $DIR/developer-id.p12 somewhere safe and offline."
    echo "  - For CI, store it base64-encoded as a repository secret:"
    echo "      base64 -i $DIR/developer-id.p12 | pbcopy"
    echo "  - Notarisation additionally needs an App Store Connect API key (.p8),"
    echo "    created at https://appstoreconnect.apple.com/access/integrations/api"
else
    echo "The identity is not showing up. Open Keychain Access and check the"
    echo "certificate imported alongside its private key."
    exit 1
fi
