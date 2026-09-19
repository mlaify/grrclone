# Changelog

All notable changes to grrclone are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
grrclone uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries describe what changed for a person using the app. The longer reasoning — why a
thing was built the way it was, and what was tried and rejected — lives in
[docs/progress.md](docs/progress.md).

## [Unreleased]

### Fixed

- grrclone no longer starts a second background process when it cannot tell whether
  one from a previous session is still running. It used to treat "could not check"
  as "nothing there", which could leave the old process running and unreachable,
  still serving your volumes with nothing able to stop it.

## [0.6.0] - 2026-09-19

### Added

- **Edit an existing remote** from its page in Settings — a rotated key or a changed
  password no longer means deleting the connection and building it again. Password
  fields start empty and change only if you type a new one; grrclone does not know
  your existing password and does not pretend to.
  ([#83](https://github.com/mlaify/grrclone/issues/83))
- **Transfer progress in the menu** — what is uploading, how far along, how fast, and
  how long is left, instead of only a count.
  ([#81](https://github.com/mlaify/grrclone/issues/81))
- **Mount one folder of a remote** instead of all of it, from the connection's page in
  Settings. Leave it empty for the whole remote.
  ([#82](https://github.com/mlaify/grrclone/issues/82))
- **A Cache tab in Settings**, showing how much disk each remote's cache is using and
  offering to clear it. Clearing is refused while the remote is connected, while
  anything is still uploading, or when the cache cannot be read — a file that has not
  reached the provider exists only there.
  ([#84](https://github.com/mlaify/grrclone/issues/84))

## [0.4.0] - 2026-09-18

### Added

- **Delete a remote**, from its page in Settings. grrclone refuses while any file is
  still waiting to upload — the local cache holds the only copy of those — disconnects
  the volume first, and copies your rclone configuration alongside itself before
  changing it. Your files on the storage provider are never touched, and the
  confirmation says so before anything else.
  ([#69](https://github.com/mlaify/grrclone/issues/69))

### Fixed

- A daemon left behind by a crash is no longer killed before the volumes it is serving
  are unmounted. It was killed first, which left macOS talking to a storage server that
  no longer existed: for a few seconds after launch, anything touching those folders got
  an I/O error and writes in flight failed.
  ([#71](https://github.com/mlaify/grrclone/issues/71))
- If a crashed session's volumes cannot be disconnected at startup, grrclone now
  refuses to start and names them, rather than killing the background process anyway
  and leaving those volumes connected to nothing.
  ([#71](https://github.com/mlaify/grrclone/issues/71))
- A failed start no longer leaves an rclone process running that nothing can find or
  stop, and that a retry would stack a second copy on top of.
  ([#72](https://github.com/mlaify/grrclone/issues/72))
- The log viewer now removes `Authorization` headers, cookies and AWS request
  signatures. Previously an OAuth token or a base64 username and password could survive
  into a log the user was invited to copy into a bug report.
  ([#73](https://github.com/mlaify/grrclone/issues/73))
- grrclone refuses to start rather than fall back to predictable control-socket
  credentials if the system cannot supply random bytes.
  ([#74](https://github.com/mlaify/grrclone/issues/74))
- A damaged record of which volumes grrclone mounted is now reported and set aside,
  instead of being read as "grrclone mounted nothing" — which would have left those
  volumes connected with nothing behind them after quitting.
  ([#75](https://github.com/mlaify/grrclone/issues/75))
- Disconnecting no longer leaves a volume showing as connected when it has actually been
  unmounted, which also stopped grrclone leaving rclone running after it quit.
  ([#76](https://github.com/mlaify/grrclone/issues/76))
- Changing a connection's name, read-only setting or cache size while it is mounted now
  says the change is saved but not yet in force, and offers to remount. It used to look
  saved and do nothing — so **Read only** could appear to be on for a volume that was
  still accepting writes. ([#77](https://github.com/mlaify/grrclone/issues/77))
- A connection saved by an older version with the retired WebDAV transport now loads
  normally instead of being permanently unable to connect.
  ([#78](https://github.com/mlaify/grrclone/issues/78))
- Encrypting the configuration now refuses when grrclone cannot tell where the
  configuration lives, rather than running the command against nothing and reporting a
  confusing failure. ([#79](https://github.com/mlaify/grrclone/issues/79))
- Settings no longer claims the configuration is unencrypted when it simply could not
  read it. It says so instead. ([#80](https://github.com/mlaify/grrclone/issues/80))

## [0.3.2] - 2026-09-18

### Changed

- Every explanatory line in Settings cut to one line or less. The text was accurate and
  nobody was reading it.

## [0.3.1] - 2026-09-17

### Fixed

- The add-remote wizard was unusable in the shipped build. Clicking the provider search
  box closed the window, and the provider list came back empty. Two unrelated causes,
  both invisible to the tests.

## [0.3.0] - 2026-09-17

### Added

- An add-remote wizard, so a new remote no longer needs `rclone config` in a terminal.
  The form is generated from rclone itself — 69 providers, 968 options — rather than
  hand-written per backend.
- OAuth backends complete their sign-in in the browser, with no terminal.
- An offer to encrypt `rclone.conf`, with the password optionally kept in the keychain.

### Changed

- The interface no longer implies that stored remote credentials are encrypted. They are
  obscured, which `rclone reveal` undoes in one step, and nothing said so where anyone
  would see it.

### Documented

- That a soft mount turns a dead backend into an I/O error after roughly two minutes,
  rather than hanging forever.
- What grrclone cannot fix: file locks are local to one Mac, and AppleDouble `._` files
  appear on remotes.

## [0.2.0] - 2026-09-17

### Added

- Encrypted `rclone.conf` support, with the password optionally in the keychain.
- A configurable mount folder, so grrclone can take over the paths an existing setup
  already uses.
- A bandwidth limit for all transfers, applied immediately without a restart.
- A log viewer, with the detail level changeable while running.
- Opt-in update checks, with a pre-release channel. Off unless you turn them on.

### Fixed

- The menu drew its connection rows behind the footer, so the list of mounts was the one
  thing you could not see.
- A mountpoint left behind by a crash accepted writes that then vanished when the volume
  came back over the top of them.

## [0.1.0] - 2026-09-17

First release. Signed, notarised, and installable from a Homebrew tap or a DMG.

- Finds the remotes already in `rclone.conf` and mounts them as Finder volumes.
- Connects and disconnects, reconnects at login, and repairs mounts after sleep or a
  network change.
- Tears mounts down in the right order at quit, so Finder never hangs on a dead server.

[Unreleased]: https://github.com/mlaify/grrclone/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/mlaify/grrclone/compare/v0.4.0...v0.6.0
[0.4.0]: https://github.com/mlaify/grrclone/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/mlaify/grrclone/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/mlaify/grrclone/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mlaify/grrclone/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mlaify/grrclone/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mlaify/grrclone/releases/tag/v0.1.0
