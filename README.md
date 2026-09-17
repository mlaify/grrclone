# grrclone

A free, open-source macOS menu bar app that connects [rclone](https://rclone.org)
remotes as Finder volumes.

No licence key. No phone-home. No kernel extension. No root.

<p align="center">
  <img src="docs/images/menu.png" alt="The grrclone menu, listing connected remotes" width="420">
</p>

## Why this exists

Because the options were bad. There are very few rclone GUIs for macOS, the few that
exist mostly cost money, several phone home, and the rest are some combination of
incomplete, awkward and buggy. Paying a licence fee to mount a drive you already own,
using a tool that is already free, is a strange place to end up.

So grrclone is the app that should have existed: it mounts your remotes, it stays out
of the way, it asks for nothing, and it tells no one.

## Install

```bash
brew install --cask mlaify/tap/grrclone
```

Or download the latest DMG from
[Releases](https://github.com/mlaify/grrclone/releases) and drag it to Applications.
Either way it is signed and notarised, so Gatekeeper opens it without argument.

Apple Silicon only. Requires macOS 14 or later.

<details>
<summary>Why a tap rather than plain <code>brew install --cask grrclone</code></summary>

homebrew-cask requires a project to be "notable" — 75 stars, or 30 forks, or 30
watchers. grrclone has none of those yet, and Homebrew is one of the ways people
would find it, so the requirement is circular for something new. The cask passes
audit; only that rule fails. It will go to homebrew-cask unchanged once the bar is
met.

Homebrew owns installs: `brew upgrade --cask grrclone`. grrclone can be asked to
*check* for new releases, but it never replaces its own bundle — two updaters owning
one app is how a self-updating copy gets silently downgraded by the next upgrade.
Release candidates are not served by the cask; they come from the releases page.

</details>

It appears in the menu bar with no Dock icon, finds the remotes already in your
`rclone.conf`, and lists them.

<p align="center">
  <img src="docs/images/settings.png" alt="grrclone settings" width="520">
</p>

## What it does

Auto-discovers your rclone remotes, connects and disconnects them, reconnects at login,
and repairs mounts after sleep or a network change. Per-connection settings for the
mount name, read-only and cache size. Tears mounts down in the right order when you
quit, so Finder never hangs on a dead server.

Mounts land in a folder of your choosing — `~/grrclone` by default, and settable in
Settings, so grrclone can take over the paths an existing setup already uses.

**Encrypted `rclone.conf`.** If your config is encrypted, grrclone asks for the
password and can remember it in your keychain.

**A bandwidth limit**, applied to the running transfer immediately — no restart, no
remounting.

**A log viewer**, so a failed mount can be diagnosed without a terminal. Passwords and
credentials in URLs are removed before anything is shown.

**Survives a bad shutdown.** A folder with nothing mounted on it is left unwritable,
so a crash cannot leave a directory that silently swallows files the next mount would
hide. If it finds any, it says so and offers to move them somewhere safe rather than
merging them anywhere.

## How it works, and why that matters

grrclone runs one bundled `rclone` daemon, starts an NFS server on loopback per
connection, and **performs the mount itself**.

That last part is the whole design. It deliberately avoids `rclone nfsmount` and the
`mount/mount` endpoint, because both hardcode their mount options and leave you with
macOS's default **hard, non-interruptible** mount — so when the backend dies, Finder
beachballs and processes wedge until you reboot. grrclone mounts with:

```
soft,intr,timeo=600,retrans=2,nolocks,locallocks,nfc,rsize=131072,wsize=131072
```

Measured with the server killed under a live mount: an error after **7.1 seconds** and
a clean recovery, no reboot. `nolocks` is there because rclone's NFS server runs no lock
daemon, so anything taking a file lock — SQLite, Office, Adobe — would otherwise hang
waiting on a daemon that does not exist.

Throughput against a real WebDAV remote over the internet:

| | `rclone copy` | through the mount |
|---|---|---|
| Cold read | 15.0 MB/s | 9.2 MB/s |
| Write, end to end | 15.3 MB/s | 11.9 MB/s |
| List 1,000 entries | 1.79 s | 0.64 s |

Method and full numbers in [docs/benchmarks.md](docs/benchmarks.md).

## It will not touch your existing mounts

If you already run rclone yourself, grrclone leaves your mounts strictly alone.

That is enforced, not promised. In the kernel's mount table a hand-rolled
`rclone nfsmount` is indistinguishable from grrclone's own — same `localhost:/` source,
same owner — so grrclone only ever unmounts paths recorded in its own registry. The menu
lists what it can see but does not own under "Not managed by grrclone", so the boundary
is visible.

## Privacy

- No telemetry, no analytics, no crash reporting.
- No update check unless you turn one on. When you do, grrclone asks GitHub which
  releases exist and nothing else — no version, no machine details, no identifier —
  and it never downloads or installs anything on its own.
- No accounts, no licence keys, no gated features.
- The only outbound connections are to the storage providers you configure.
- The rclone control API is bound to a unix socket with `0600` permissions and random
  per-launch credentials. Nothing listens on the network, not even loopback.
- The bundled rclone is pinned and checksummed at build time, never downloaded at
  runtime.

grrclone **reads** your `rclone.conf` but never writes it, so your command-line setup
keeps working exactly as before. A CI check fails the build if any of this regresses.

## Building it yourself

```bash
brew install xcodegen
swift scripts/make-icon.swift                 # the icon is generated, not committed
iconutil -c icns build/AppIcon.iconset -o App/grrclone/Resources/AppIcon.icns
scripts/fetch-rclone.sh                       # pinned and checksummed
scripts/build-app.sh
```

The icon and the bundled rclone are both generated rather than committed, so a fresh
clone needs those two steps before the app will build.

The logic lives in Swift packages that build and test without Xcode, and `grrclonectl`
drives them from a terminal:

```bash
swift build && swift test

.build/debug/grrclonectl doctor              # environment check
.build/debug/grrclonectl remotes             # remotes from rclone.conf
.build/debug/grrclonectl connect dav1 Cloud  # serve and mount
.build/debug/grrclonectl mounts              # what it owns, and what it does not
.build/debug/grrclonectl recovery-test dav1  # kill the server, verify self-repair
```

rclone 1.74.4 is the minimum, and releases bundle a pinned copy. Earlier versions have
NFS defects that cause stale file handles, failed file creation and broken listings of
large directories.

## More

- [docs/benchmarks.md](docs/benchmarks.md) — why NFS, the numbers, and the defects found
  along the way
- [docs/progress.md](docs/progress.md) — what is done, what is next, decisions taken
- [CONTRIBUTING.md](CONTRIBUTING.md) — including the rules that are not negotiable
- [SECURITY.md](SECURITY.md)

## Prior art

[Mountain Duck](https://mountainduck.io) is the app to beat and is genuinely good — it
is also proprietary and paid. [macsh](https://github.com/AyonPal/macsh) is the closest
open-source relative. [Rclone Browser](https://github.com/kapitainsky/RcloneBrowser) was
the classic and is no longer maintained.

## Licence

[MIT](LICENSE). grrclone is not affiliated with the rclone project.
