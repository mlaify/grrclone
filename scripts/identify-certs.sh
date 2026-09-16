#!/usr/bin/env bash
#
# Work out which certificate in Apple's developer portal is which.
#
# The portal lists certificates by name, type and date only — no serial number, no
# fingerprint. When two share a common name, as duplicate Developer ID certificates do,
# the web page gives you nothing to tell them apart. Downloading them does.
#
#   1. Open https://developer.apple.com/account/resources/certificates/list
#   2. Download BOTH certificates of the same name (click each, then Download).
#      They will land as developerID_application.cer, developerID_application-2.cer, …
#   3. scripts/identify-certs.sh ~/Downloads/developerID_application*.cer
#
# Each file is hashed and compared against the identity grrclone signs with, so the
# spare is named explicitly rather than guessed.
#
# Note that a spare cannot be removed from the account: Apple offers no self-service
# revocation for Developer ID certificates, deliberately, since revoking one would
# invalidate every application ever signed with it. The practical remedy is local —
# `scripts/remove-spare-cert.sh <hash>` clears it from the keychain so `codesign` stops
# being ambiguous — plus pinning the identity, which is good practice regardless.
#
set -euo pipefail

PIN_FILE="$HOME/.config/grrclone-signing/identity"
PINNED=""
[[ -f "$PIN_FILE" ]] && PINNED="$(tr -d '[:space:]' < "$PIN_FILE" | tr '[:lower:]' '[:upper:]')"

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <downloaded .cer files…>"
    echo
    echo "Download every certificate of the same name from:"
    echo "  https://developer.apple.com/account/resources/certificates/list"
    echo
    if [[ -n "$PINNED" ]]; then
        echo "The one grrclone signs with is $PINNED"
    fi
    exit 1
fi

# Apple's portal shows a creation date, so print it prominently: combined with the
# download order it is usually enough to find the right row again in the browser.
printf '\n%s\n\n' "Comparing $# certificate(s) against the pinned signing identity"

for f in "$@"; do
    [[ -f "$f" ]] || { echo "skipping missing $f"; continue; }

    pem=$(openssl x509 -inform DER -in "$f" 2>/dev/null || openssl x509 -in "$f" 2>/dev/null) \
        || { echo "$(basename "$f"): not a certificate"; continue; }

    subject=$(echo "$pem" | openssl x509 -noout -subject | sed 's/^subject=//')
    serial=$(echo "$pem" | openssl x509 -noout -serial | cut -d= -f2)
    created=$(echo "$pem" | openssl x509 -noout -startdate | cut -d= -f2)
    expires=$(echo "$pem" | openssl x509 -noout -enddate | cut -d= -f2)
    fp=$(echo "$pem" | openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')

    if [[ -n "$PINNED" && "$fp" == "$PINNED" ]]; then
        verdict=$'\033[32mKEEP\033[0m   — this is the one grrclone signs with'
    elif [[ -n "$PINNED" ]]; then
        verdict=$'\033[31mSPARE\033[0m  — revoke this one in the portal'
    else
        verdict="unknown (no pinned identity set)"
    fi

    installed="not installed locally"
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$fp"; then
        installed="installed, private key present"
    fi

    printf '%s\n' "$(basename "$f")"
    printf '  %b\n' "$verdict"
    printf '  created  %s\n' "$created"
    printf '  expires  %s\n' "$expires"
    printf '  serial   %s\n' "$serial"
    printf '  sha1     %s\n' "$fp"
    printf '  keychain %s\n' "$installed"
    printf '  subject  %s\n\n' "$subject"
done

cat <<'NEXT'
A spare cannot be removed from the account — Apple has no self-service revocation for
Developer ID, since revoking one invalidates everything ever signed with it. What you
can do is clear it from this machine so codesign stops being ambiguous:

  scripts/remove-spare-cert.sh <the SPARE sha1 above>

Pinning the signing identity handles the rest, and is worth keeping either way.
NEXT
