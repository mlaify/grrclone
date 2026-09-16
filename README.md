# grrclone

A free, open-source macOS menu-bar app that connects rclone remotes as Finder volumes.

Think Mountain Duck, without the license key, the phone-home, or the kernel extension.

## Status

Early development. Milestone 0 (the performance gate) is complete and passed — see
[docs/benchmarks.md](docs/benchmarks.md). The app itself is not yet usable.

## How it works

grrclone runs a single bundled `rclone` daemon and, for each connection, starts an NFS
server bound to loopback and mounts it with macOS's built-in NFS client. No macFUSE, no
FUSE-T, no kernel extension, no root.

It deliberately does **not** use `rclone nfsmount` or the `mount/mount` remote-control
endpoint. Those hardcode their mount options, leaving a hard NFS mount that wedges
Finder when the backend dies. grrclone issues its own mount call with
`soft,intr,timeo=600,retrans=2,nolocks`, which degrades to an error in about seven
seconds and recovers without a reboot.

## Privacy

- No telemetry, no analytics, no crash reporting.
- No update check unless you turn one on.
- No accounts, no license keys, no gated features.
- The only outbound connections are to the storage providers you configure.
- The bundled rclone is pinned and checksummed at build time, never downloaded at runtime.

## Requirements

macOS 14 or later. rclone 1.74.4 or later (bundled; a Homebrew install can be used
instead). Earlier rclone versions have NFS bugs that cause stale handles, failed file
creation, and broken large-directory listings.

## License

MIT

## Trying the core

The headless harness exercises everything the app will do:

```bash
swift build
.build/debug/grrclonectl doctor        # environment check
.build/debug/grrclonectl remotes       # remotes from rclone.conf
.build/debug/grrclonectl connect dav1 Cloud
.build/debug/grrclonectl mounts        # what grrclone owns, and what it does not
.build/debug/grrclonectl disconnect Cloud
.build/debug/grrclonectl reconcile     # clean up after an unclean shutdown
```

grrclone never unmounts anything it did not create. If you already run rclone by hand,
`mounts` lists your mounts under "does NOT own" and leaves them alone.
