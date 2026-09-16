#!/usr/bin/env bash
#
# Export the signing certificate and key as a .p12 that macOS can actually import,
# and prove it before handing it over.
#
#   scripts/export-p12.sh
#
# Needed for CI, which has no keychain to import from. Local signing does not use a
# .p12 at all — install-developer-id.sh puts the key and certificate straight into the
# keychain, which needs no password.
#
# Why this exists as its own script: OpenSSL 3 writes PKCS#12 with a SHA-256 MAC, and
# macOS Security cannot read it. The failure is reported as
#
#   SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
#
# which blames the password when the password is fine. That cost a failed release: the
# .p12 was generated before the export was fixed, and nothing re-checked it, so the
# broken file sat in a repository secret until CI tried to use it.
#
set -euo pipefail

DIR="$HOME/.config/grrclone-signing"
KEY="$DIR/developer-id.key"
PEM="$DIR/developer-id.pem"
OUT="$DIR/developer-id.p12"

[[ -f "$KEY" ]] || { echo "No private key at $KEY"; exit 1; }
[[ -f "$PEM" ]] || { echo "No certificate at $PEM. Run install-developer-id.sh first."; exit 1; }

echo "Exporting $(openssl x509 -in "$PEM" -noout -subject | sed 's/^subject=//')"
echo
echo "Choose a strong password. You will need it as the MACOS_CERTIFICATE_PASSWORD secret."

# SHA-1 MAC and 3DES, which is what macOS and the GitHub runner can both read.
openssl pkcs12 -export \
    -inkey "$KEY" \
    -in "$PEM" \
    -out "$OUT" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
chmod 600 "$OUT"

MAC=$(openssl pkcs12 -in "$OUT" -info -noout -passin pass:deliberately-wrong 2>&1 \
        | grep -iE '^MAC:' || true)
echo
echo "  $MAC"
case "$MAC" in
    *sha1*) ;;
    *)  echo
        echo "This .p12 does not use a SHA-1 MAC, so macOS will refuse to import it."
        echo "Check that openssl accepted -macalg."
        exit 1 ;;
esac

# Prove it imports rather than assuming. This is the step whose absence let a broken
# .p12 reach a repository secret and fail a release.
echo
echo "Verifying macOS can import it…"
read -r -s -p "  re-enter the password to test the import: " PW; echo
TEST_KEYCHAIN="/tmp/grrclone-p12-verify-$$.keychain"
security create-keychain -p verify "$TEST_KEYCHAIN" >/dev/null 2>&1
if security import "$OUT" -k "$TEST_KEYCHAIN" -P "$PW" -A >/dev/null 2>&1; then
    echo "  imported cleanly"
else
    security delete-keychain "$TEST_KEYCHAIN" >/dev/null 2>&1 || true
    echo "  FAILED to import. Either the password was mistyped, or the algorithms are"
    echo "  still wrong. Do not upload this file as a secret."
    exit 1
fi
security delete-keychain "$TEST_KEYCHAIN" >/dev/null 2>&1 || true

echo
echo "Wrote $OUT"
echo
echo "For CI, update these two secrets in the 'release' environment:"
echo "  MACOS_CERTIFICATE_P12       base64 -i $OUT | pbcopy"
echo "  MACOS_CERTIFICATE_PASSWORD  the password you just chose"
echo
echo "Back the file up somewhere offline too. Apple cannot reissue a key it never held."
