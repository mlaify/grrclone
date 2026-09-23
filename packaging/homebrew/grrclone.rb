cask "grrclone" do
  version "0.9.3"
  sha256 "43f8cff10e26f84be2a7dab74a5f4be3f54d4adacf877d40c1a3b50d30a0b321"

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
