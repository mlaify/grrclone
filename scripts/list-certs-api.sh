#!/usr/bin/env bash
#
# List every certificate on the account, with serial numbers, via the App Store Connect
# API. Apple's web portal shows only name, type and dates, which is useless when two
# certificates share a name — this does not have that problem.
#
#   scripts/list-certs-api.sh <issuer-uuid> [path/to/AuthKey_XXXXXXXXXX.p8]
#
# The issuer UUID is on App Store Connect → Users and Access → Integrations, at the top
# of the App Store Connect API page. It is not the Team ID. The key id is the ten
# characters in the .p8 filename.
#
# Read-only. It never revokes anything: revocation is irreversible, and the whole reason
# this script exists is that it was previously impossible to be sure which certificate
# was which.
#
set -euo pipefail

ISSUER="${1:-}"
KEY_PATH="${2:-}"

if [[ -z "$ISSUER" ]]; then
    echo "usage: $0 <issuer-uuid> [path/to/AuthKey_XXXXXXXXXX.p8]"
    echo
    echo "Find the issuer UUID at:"
    echo "  https://appstoreconnect.apple.com/access/integrations/api"
    exit 1
fi

if [[ -z "$KEY_PATH" ]]; then
    KEY_PATH=$(ls -1 "$HOME"/Downloads/AuthKey_*.p8 2>/dev/null | head -1 || true)
    [[ -n "$KEY_PATH" ]] || { echo "No AuthKey_*.p8 found; pass its path."; exit 1; }
fi
[[ -f "$KEY_PATH" ]] || { echo "No such key: $KEY_PATH"; exit 1; }

KEY_ID=$(basename "$KEY_PATH" | sed -E 's/^AuthKey_(.+)\.p8$/\1/')
echo "Using key $KEY_ID"

PINNED=""
PIN_FILE="$HOME/.config/grrclone-signing/identity"
[[ -f "$PIN_FILE" ]] && PINNED="$(tr -d '[:space:]' < "$PIN_FILE" | tr '[:lower:]' '[:upper:]')"

python3 - "$ISSUER" "$KEY_ID" "$KEY_PATH" "$PINNED" <<'PY'
import base64, hashlib, json, sys, time, urllib.request
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives import hashes

issuer, key_id, key_path, pinned = sys.argv[1:5]

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

# App Store Connect wants an ES256 JWT. PyJWT is not always installed, so it is built
# by hand here: the signature must be raw r||s, not the DER that sign() returns.
header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
payload = {"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 600,
           "aud": "appstoreconnect-v1"}
signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}"

key = serialization.load_pem_private_key(open(key_path, "rb").read(), password=None)
der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
r, s = decode_dss_signature(der)
token = f"{signing_input}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"

req = urllib.request.Request(
    "https://api.appstoreconnect.apple.com/v1/certificates?limit=200",
    headers={"Authorization": f"Bearer {token}"})
try:
    data = json.load(urllib.request.urlopen(req, timeout=30))
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"API error {e.code}: {body[:400]}")
    if e.code == 401:
        print("\n401 usually means the issuer UUID is wrong, or the key lacks the")
        print("Developer role. Check both on the App Store Connect API page.")
    raise SystemExit(1)

certs = data.get("data", [])
print(f"\n{len(certs)} certificate(s) on the account\n")

for c in certs:
    a = c["attributes"]
    # Apple returns the DER, base64-encoded. Hashing it gives the same SHA-1 the
    # keychain and codesign use, which is what ties an API record to a local identity.
    fp = ""
    if a.get("certificateContent"):
        fp = hashlib.sha1(base64.b64decode(a["certificateContent"])).hexdigest().upper()

    tag = ""
    if pinned and fp == pinned:
        tag = "   <-- KEEP: the one grrclone signs with"
    elif pinned and a.get("certificateType") == "DEVELOPER_ID_APPLICATION":
        tag = "   <-- SPARE: safe to revoke"

    print(f"{a.get('certificateType')}{tag}")
    print(f"  name       {a.get('name')}")
    print(f"  serial     {a.get('serialNumber')}")
    print(f"  expires    {a.get('expirationDate')}")
    print(f"  sha1       {fp or '(not returned)'}")
    # This id is what appears in the portal URL when a certificate is opened, which is
    # how you find the right row in a list that shows no other distinguishing detail.
    print(f"  id         {c['id']}")
    print(f"  portal     https://developer.apple.com/account/resources/certificates/"
          f"list?certificateId={c['id']}")
    print()
PY
