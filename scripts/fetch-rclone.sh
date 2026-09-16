#!/usr/bin/env bash
#
# Fetch a pinned rclone and build a universal binary for bundling into grrclone.app.
#
#   scripts/fetch-rclone.sh
#
# This is a **build-time** download, pinned by version and verified against checksums
# recorded in this file. grrclone never downloads anything at runtime — that guarantee
# is enforced by scripts/check-privacy.sh and is the reason the version is pinned here
# rather than resolved from "latest".
#
# To update: change RCLONE_VERSION, put the new digests from
# https://github.com/rclone/rclone/releases/download/<version>/SHA256SUMS into the two
# variables below, and re-run. Never take the digests from the same download you are
# verifying; that verifies nothing.
#
set -euo pipefail
cd "$(dirname "$0")/.."

RCLONE_VERSION="v1.75.1"
SHA256_ARM64="c61d7a371c62bcbbe882c3423aa4b8bf63485c248dd0f692997b8f0c3f6d0c6f"
SHA256_AMD64="29253d0288b8fbbac46baad6e5f6add6cb01d462c79f10805bbd4631c4cdf82c"

# Below this, rclone has NFS defects that matter: missing EOF flags in READ responses,
# no --vfs-handle-caching, file creation failing for want of Mknod, ESTALE from
# unstable inode numbers, and broken listings of large directories.
MINIMUM="1.74.4"

DEST="App/grrclone/Resources/rclone"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

version_at_least() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

if ! version_at_least "${RCLONE_VERSION#v}" "$MINIMUM"; then
    echo "Pinned version ${RCLONE_VERSION} is below the ${MINIMUM} floor."
    exit 1
fi

fetch() { # arch expected-sha256
    local arch="$1" expected="$2"
    local zip="rclone-${RCLONE_VERSION}-osx-${arch}.zip"
    local url="https://github.com/rclone/rclone/releases/download/${RCLONE_VERSION}/${zip}"

    echo "  downloading ${arch}…"
    curl -fsSL "$url" -o "$WORK/$zip"

    local actual
    actual="$(shasum -a 256 "$WORK/$zip" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "  CHECKSUM MISMATCH for $zip"
        echo "    expected $expected"
        echo "    got      $actual"
        exit 1
    fi
    echo "  ${arch} checksum ok"

    ( cd "$WORK" && unzip -qq "$zip" )
    mv "$WORK/rclone-${RCLONE_VERSION}-osx-${arch}/rclone" "$WORK/rclone-${arch}"
}

echo "Fetching rclone ${RCLONE_VERSION}"
fetch arm64 "$SHA256_ARM64"
fetch amd64 "$SHA256_AMD64"

echo "Creating a universal binary…"
mkdir -p "$(dirname "$DEST")"
# lipo first, sign later, and sign the fat result exactly once. Signing each slice and
# then combining them produces a binary that verifies locally but fails notarisation.
lipo -create -output "$DEST" "$WORK/rclone-arm64" "$WORK/rclone-amd64"
chmod +x "$DEST"

echo
lipo -info "$DEST" | sed 's/^/  /'
"$DEST" version | head -1 | sed 's/^/  /'
echo "  $(du -h "$DEST" | awk '{print $1}')"

echo
echo "Bundled at $DEST (gitignored — it is a build artefact, not source)."
echo "scripts/sign-app.sh re-signs it with our own Team ID, which Gatekeeper requires:"
echo "upstream's signature carries a different team and fails the consistency check."
