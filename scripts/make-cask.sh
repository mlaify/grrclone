#!/usr/bin/env bash
#
# Generate the Homebrew cask for a published release.
#
#   scripts/make-cask.sh v0.2.0
#
# Emits packaging/homebrew/grrclone.rb with the real checksum of the published DMG,
# because a cask's sha256 is the only thing standing between a user and whatever the
# download URL happens to serve. Computed from the artefact rather than pasted, so it
# cannot be stale or transcribed wrong.
#
set -euo pipefail

TAG="${1:-}"
[[ -n "$TAG" ]] || { echo "usage: $0 <tag>   e.g. $0 v0.2.0"; exit 1; }
VERSION="${TAG#v}"

case "$VERSION" in
    *-*) echo "refusing to build a cask for the pre-release '$TAG'."
         echo "Homebrew's stable cask tracks final releases; pre-releases need their"
         echo "own cask token (see docs/releasing.md)."
         exit 1 ;;
esac

URL="https://github.com/mlaify/grrclone/releases/download/$TAG/grrclone.dmg"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Fetching $URL"
curl -fsSL "$URL" -o "$TMP/grrclone.dmg"
SHA=$(shasum -a 256 "$TMP/grrclone.dmg" | awk '{print $1}')
echo "sha256 $SHA"

cat > packaging/homebrew/grrclone.rb <<CASK
cask "grrclone" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/mlaify/grrclone/releases/download/v#{version}/grrclone.dmg"
  name "grrclone"
  desc "Menu bar app that mounts rclone remotes as Finder volumes"
  homepage "https://github.com/mlaify/grrclone"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Apple Silicon only, by decision — see docs/progress.md.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "grrclone.app"

  # Deliberately no \`auto_updates true\`.
  #
  # That stanza tells Homebrew an app installs its own updates and to keep out of the
  # way. grrclone does not: it can be asked to *check* GitHub for a new release, but
  # it never replaces its own bundle. Claiming otherwise would make \`brew upgrade\`
  # skip a copy nothing else updates.

  uninstall quit: "org.mlaify.grrclone"

  zap trash: [
    "~/Library/Application Support/org.mlaify.grrclone",
    "~/Library/Caches/org.mlaify.grrclone",
    "~/Library/Preferences/org.mlaify.grrclone.plist",
  ]
end
CASK

echo
echo "Wrote packaging/homebrew/grrclone.rb"
echo
echo "To submit:"
echo "  brew tap --force homebrew/cask"
echo "  cp packaging/homebrew/grrclone.rb \"\$(brew --repository homebrew/cask)/Casks/g/grrclone.rb\""
echo "  brew audit --new --cask grrclone     # must pass before opening a PR"
echo "  brew install --cask grrclone         # install it from the local tap and use it"
echo "  then open a pull request on Homebrew/homebrew-cask"
