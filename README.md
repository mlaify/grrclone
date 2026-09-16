# grrclone

A free, open-source macOS menu bar app that connects [rclone](https://rclone.org)
remotes as Finder volumes.

Like Mountain Duck, without the licence key, the phone-home, or the kernel extension.

```
┌─ grrclone ──────────────────┐
│ Ready                       │
├─────────────────────────────┤
│ ● Cloud        ~/grrclone/… │  Disconnect
│ ○ Vaults       Not connected│  Connect
├─────────────────────────────┤
│ Settings…  Check mounts  Quit│
└─────────────────────────────┘
```

## Status

**Pre-release.** It runs and mounts remotes reliably today, but there is no signed
build yet, so you have to build it yourself.

| | |
|---|---|
| Works | Auto-discovery of your rclone remotes, connect and disconnect, connect at login, per-connection settings, recovery from sleep and network changes, recovery from an unclean shutdown, ordered teardown on quit |
| Not yet | Signed and notarised releases, Homebrew cask, transfer queue window, add-remote wizard, bandwidth limits, encrypted `rclone.conf` support |

## Why

Mounting cloud storage in Finder on macOS has had three unappealing options: pay for a
proprietary app, install a kernel extension, or run rclone by hand from a shell script.

grrclone is the fourth. It uses rclone's NFS server over loopback and mounts it with
macOS's built-in NFS client, so there is no macFUSE, no FUSE-T, no kernel extension, and
no root.

## How it works

grrclone runs a single bundled `rclone` daemon and, for each connection, starts an NFS
server bound to loopback, then mounts it itself.

That last part matters. grrclone deliberately does **not** use `rclone nfsmount` or the
`mount/mount` control endpoint, because both hardcode their mount options to `port`,
`mountport` and `tcp`. That leaves macOS's default **hard, non-interruptible** mount, so
when the backend dies Finder beachballs and processes wedge until you reboot.

grrclone issues its own mount call:

```
soft,intr,timeo=600,retrans=2,nolocks,locallocks,nfc,rsize=131072,wsize=131072
```

Measured with a server killed under a live mount: an error after **7.1 seconds**, and a
clean recovery with no reboot. `nolocks` is there because rclone's NFS server runs no
lock daemon, so anything taking a file lock — SQLite, Office, Adobe — would otherwise
hang waiting on a daemon that does not exist.

Performance, against a real WebDAV remote over the internet:

| | `rclone copy` | through the mount |
|---|---|---|
| Cold read | 15.0 MB/s | 9.2 MB/s |
| Write, end to end | 15.3 MB/s | 11.9 MB/s |
| List 1,000 entries | 1.79 s | 0.64 s |

Full method and numbers in [docs/benchmarks.md](docs/benchmarks.md).

## It will not touch your existing mounts

If you already run rclone yourself, grrclone leaves your mounts strictly alone.

This is not a nicety, it is enforced. In the kernel's mount table a hand-rolled
`rclone nfsmount` is indistinguishable from grrclone's own — same `localhost:/` source,
same owner — so grrclone only ever unmounts paths recorded in its own registry. The
menu lists anything it can see but does not own under "Not managed by grrclone", so the
boundary is visible rather than merely promised.

## Privacy

- No telemetry, no analytics, no crash reporting.
- No update check unless you turn one on.
- No accounts, no licence keys, no gated features.
- The only outbound connections are to the storage providers you configure.
- The rclone control API is bound to a unix socket with `0600` permissions and random
  per-launch credentials. Nothing listens on the network, not even loopback.
- The bundled rclone is pinned and checksummed at build time, never downloaded at
  runtime.

grrclone **reads** your `rclone.conf` but never writes it, so your command-line setup
keeps working exactly as before.

## Requirements

- macOS 14 or later
- rclone 1.74.4 or later

That version floor is deliberate. Earlier rclone releases have NFS defects that cause
stale file handles, failed file creation, and broken listings of large directories.
Releases will bundle a pinned rclone; a Homebrew install can be used instead.

## Building

```bash
brew install rclone xcodegen
scripts/build-app.sh
open build/Build/Products/Debug/grrclone.app
```

It appears in the menu bar with no Dock icon, finds the remotes already in your
`rclone.conf`, and lists them. Mounts land in `~/grrclone/<name>`.

## The core, without the app

All the logic lives in Swift packages that build and test with no Xcode project, and
`grrclonectl` drives them from a terminal:

```bash
swift build
swift test

.build/debug/grrclonectl doctor              # environment check
.build/debug/grrclonectl remotes             # remotes from rclone.conf
.build/debug/grrclonectl connect dav1 Cloud  # serve and mount
.build/debug/grrclonectl mounts              # what it owns, and what it does not
.build/debug/grrclonectl disconnect Cloud
.build/debug/grrclonectl reconcile           # clean up after an unclean shutdown
.build/debug/grrclonectl recovery-test dav1  # kill the server, verify self-repair
```

## Documentation

- [docs/benchmarks.md](docs/benchmarks.md) — why NFS, the numbers, and the defects found
  along the way
- [docs/progress.md](docs/progress.md) — what is done, what is next, and decisions taken
- [CONTRIBUTING.md](CONTRIBUTING.md) — including rules that are not negotiable
- [SECURITY.md](SECURITY.md)

## Prior art

[Mountain Duck](https://mountainduck.io) is the app to beat, and is genuinely good.
[macsh](https://github.com/AyonPal/macsh) is the closest open-source relative and worth
reading. [Rclone Browser](https://github.com/kapitainsky/RcloneBrowser) was the classic
and is no longer maintained. None of the current open-source options combine a native
menu bar app, no third-party drivers, signed builds, and no phone-home.

## Licence

[MIT](LICENSE).

grrclone is not affiliated with the rclone project.
