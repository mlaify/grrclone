cask "grrclone" do
  version "0.3.1"
  sha256 "8cd8a5062938bc3be72d7acb4412eb6d508693f27f0a66cb4b531eade7e4f97f"

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
