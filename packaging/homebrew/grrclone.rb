cask "grrclone" do
  version "0.7.1"
  sha256 "412857ae9669756bceb10c3de51e39dfac59e666cc1ac0f38fbee806da6c14ff"

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

  # Deliberately no `auto_updates true`.
  #
  # That stanza tells Homebrew an app installs its own updates and to keep out of the
  # way. grrclone does not: it can be asked to *check* GitHub for a new release, but
  # it never replaces its own bundle. Claiming otherwise would make `brew upgrade`
  # skip a copy nothing else updates.

  uninstall quit: "org.mlaify.grrclone"

  zap trash: [
    "~/Library/Application Support/org.mlaify.grrclone",
    "~/Library/Caches/org.mlaify.grrclone",
    "~/Library/Preferences/org.mlaify.grrclone.plist",
  ]
end
