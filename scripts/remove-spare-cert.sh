#!/usr/bin/env bash
#
# Remove a superfluous Developer ID certificate from the login keychain.
#
# This only cleans up locally. **Revoke the certificate at Apple first**, at
# https://developer.apple.com/account/resources/certificates/list — otherwise it keeps
# occupying one of the account's limited Developer ID slots even though nothing can use
# it any more.
#
# Do it in that order on purpose. If you revoke the wrong certificate at Apple, having
# the other one still in the keychain is what lets you recover. Deleting the private key
# first removes that option, and Apple will not reissue a key it never had.
#
#   scripts/remove-spare-cert.sh <sha1-hash-of-the-certificate-to-remove>
#
set -euo pipefail

HASH="${1:-}"
PIN_FILE="$HOME/.config/grrclone-signing/identity"

if [[ -z "$HASH" ]]; then
    echo "usage: $0 <sha1 hash of the certificate to remove>"
    echo
    echo "Installed Developer ID certificates:"
    security find-identity -v -p codesigning | grep "Developer ID Application" | sed 's/^/  /' || true
    if [[ -f "$PIN_FILE" ]]; then
        echo
        echo "Pinned (the one grrclone signs with — do NOT remove this):"
        sed 's/^/  /' "$PIN_FILE"
    fi
    exit 1
fi

HASH=$(echo "$HASH" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]')

# Refuse to delete the certificate builds depend on. A typo here costs a private key.
if [[ -f "$PIN_FILE" ]]; then
    PINNED=$(tr -d '[:space:]' < "$PIN_FILE" | tr '[:lower:]' '[:upper:]')
    if [[ "$HASH" == "$PINNED" ]]; then
        echo "Refusing: $HASH is the pinned signing identity in $PIN_FILE."
        echo "That is the certificate grrclone signs with, not a spare."
        exit 1
    fi
fi

if ! security find-identity -v -p codesigning | grep -q "$HASH"; then
    echo "No installed signing identity with hash $HASH."
    exit 1
fi

echo "About to remove this certificate and its private key from the login keychain:"
security find-identity -v -p codesigning | grep "$HASH" | sed 's/^/  /'
echo
echo "This is irreversible. The private key cannot be recovered or reissued."
echo "Confirm you have already revoked this certificate at Apple."
read -r -p "Type the last 4 characters of the hash to confirm: " reply

if [[ "${HASH: -4}" != "$(echo "$reply" | tr '[:lower:]' '[:upper:]')" ]]; then
    echo "Did not match. Nothing was removed."
    exit 1
fi

security delete-identity -Z "$HASH" "$HOME/Library/Keychains/login.keychain-db"

echo
echo "Remaining Developer ID certificates:"
security find-identity -v -p codesigning | grep "Developer ID Application" | sed 's/^/  /' || echo "  none"
