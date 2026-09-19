# Project progress

A running record of what is done, what is next, and which decisions are settled.
Update this at the end of each working session.

Last updated: 2026-09-19.

## Where things stand

**v0.7.1 is released**, and installable two ways:

```bash
brew install --cask mlaify/tap/grrclone
```

or the DMG from [Releases](https://github.com/mlaify/grrclone/releases). Both are
signed, notarised and stapled; Gatekeeper accepts them on a machine that has never
seen the app. The maintainer runs it daily, having retired a hand-rolled launchd
`nfsmount` agent for it.

291 tests. CI runs build, test and the privacy script on every pull request; CodeQL
runs on main and weekly, and covers the app target as well as the packages — which it
did not before, and which was proved rather than assumed.

| Milestone | State |
|---|---|
| M0 — performance gate | **Done.** NFS passed; see [benchmarks.md](benchmarks.md) |
| M1 — headless core | **Done.** Verified end to end against real remotes |
| M2 — menu bar app | **Done.** Connects, disconnects, connects at login |
| M3 — robustness and release | **Done.** Self-healing, quit safety, CI, and a notarised DMG |
| M4 — reach | **Done**, bar one item. Homebrew tap, add-remote wizard with OAuth; WebDAV transport built and rejected; homebrew-cask upstream blocked on notability |
| v0.1.0 | **Released** 2026-09-17 |
| v0.2.0 | **Released** 2026-09-17 |
| v0.3.0 | **Released** 2026-09-17 |
| v0.3.1 | **Released** 2026-09-17 |
| v0.3.2 | **Released** 2026-09-18 |
| v0.4.0 | **Released** 2026-09-18 |
| v0.6.0 | **Released** 2026-09-19 |
| v0.6.1 | **Released** 2026-09-19 |
| v0.7.0 | **Released** 2026-09-19 |
| v0.7.1 | **Released** 2026-09-19 |
| v0.8.0 | **In progress** — the safety fixes from the 2026-09-19 review |
| v0.9.0 | Planned — robustness and polish |

## Releases

### v0.7.1 — 2026-09-19

Two fixes that came out of one screenshot of a real machine, both about grrclone
being honest with the person in front of it.

A freshly upgraded copy no longer quits itself when launched while the previous copy
is still disconnecting. `SingleInstance` refused on sight of another copy, and its own
docstring named the upgrade as the case where that is wrong — a quit can drain uploads
for minutes, so "the new version is broken" was really "it gave up too early". It
waits now, with the deadline derived from the real teardown budgets after a test
caught the first guess being shorter than a single unmount, and only briefly for a
copy at the same path so a double-click on the running app is not stalled for six
minutes.

When a mount point cannot be used because something is *already mounted* there, the
menu says so and names `umount -f`, instead of counting that volume's files and
telling you to move them. That was observed live: three NFS mounts stacked on
`~/Cloud`, none in the registry, reported as "582 existing items" that did not exist.
The command was first placed at the end of an error capped at three lines — the
fourth line — so the fix in one PR was invisible until Codex checked the next. It now
sits beside the `×N` count where it persists. The app also stopped recommending
`diskutil umount force`, which refuses stacked NFS; that too was learned the hard way.

`docs/limitations.md` records why stacked dead mounts are hard and that `umount -f`
saying "Operation timed out" is evidence of nothing.

### v0.7.0 — 2026-09-19

About being told an update exists without having to go looking, and about proving
where a build came from.

grrclone now asks GitHub once a day while running rather than only at launch — a
menu bar app runs for weeks, so the old behaviour meant anyone who started it before
a release never heard about it. An available update marks the menu bar icon, the one
surface people see daily, and posts a notification.

That notification is the app's **one permission**, asked when the user turns checks
on rather than at first launch, and declining costs nothing else. Someone whose
preference was already on from an earlier version is asked at launch instead — a
stored property's `didSet` does not fire during initialisation, so they would
otherwise have had a feature that silently never worked.

Releases now carry a Sigstore-signed provenance attestation, logged to a public
transparency log, binding the DMG's digest to the commit and workflow that built it.
That is a different guarantee from notarisation and one a stolen signing certificate
would not defeat.

**Self-installing updates were considered and rejected** — the design is in #97. The
verification chain was tractable; the cost was not. grrclone currently cannot install
code, which is a property worth keeping in an unsandboxed program that mounts your
storage, and Sparkle would have had to be taught to wait for an ordered teardown that
can legitimately run for minutes. For anyone who wants updates to simply happen,
`brew autoupdate` does it with no new attack surface in this app.

Two corrections worth recording. The upgrade command grrclone shows now runs
`brew update` first: `brew upgrade` refreshes on its own only once every 24 hours,
so a user who had run brew earlier the same day would be told they were current
against a stale tap while this app said otherwise. And `brew autoupdate` is a
separate tap entirely, not a built-in — conflating the two is what produced the
wrong command in the first place.

### v0.6.1 — 2026-09-19

One fix, found by chasing a flaky test rather than reported.

`isOurDaemon` ran `/bin/ps` and collapsed every failure — including a timeout —
into "not our daemon". Both callers treat that as a stale record: clear it, delete
the socket, start a fresh daemon. So a `ps` that was merely slow would orphan a
live daemon permanently, still serving mounts with nothing able to reach or stop
it. Exactly the failure `DaemonPidFile` exists to prevent, caused by the check
meant to prevent it — and the same `try?`-swallows-uncertainty shape as the 0.4.0
audit cluster, in code written after that audit.

Identification now has three states. "Unknown" keeps the record and makes startup
refuse, naming the PID, because proceeding is what does the damage.

Diagnosed from the timing: the failing test took 10.6 seconds, which is the 5s
`ps` timeout plus the 5s wait in its own assertion. Two earlier guesses at the
cause were disproved by testing before the arithmetic pointed at the real one.

### v0.6.0 — 2026-09-19

Four features, and the first release since 0.1.0 that is about reach rather than
repair.

- **Edit a remote.** A rotated key or changed password no longer means deleting the
  connection and rebuilding it. Password fields start empty: `config/dump` returns
  the *obscured* secret, which `rclone reveal` undoes in one step, so showing it
  would be showing dots that are not the password and cannot be corrected into one.
- **Transfer progress**, with the file, how far along, how fast and how long is
  left, rather than only a count.
- **Mount one folder** of a remote instead of all of it.
- **A Cache tab**, showing what each remote's cache is using and offering to clear
  it — refused while the remote is connected, while anything is still uploading, or
  when the cache cannot be read.

Two things worth recording, both found by driving rclone rather than reading about
it. `core/stats` with `short: true` omits the `transferring` array entirely, so
the existing unused helper could only ever report zero transfers. And rclone decides
whether to obscure a value by *trying to reveal it first* — so a literal password
that happens to be valid obscured text gets revealed instead of obscured, storing
something the user never typed. `updateRemote` forces `obscure`, and a test pins
the misfire so a future rclone fix is noticed rather than silently worked around.

The version skips 0.5.0: the milestone was numbered before the audit work landed as
0.4.0, and renumbering issues after the fact is worse than a gap.

### v0.4.0 — 2026-09-18

Almost entirely correctness and security work, on paths that can lose data. It came
out of a full-codebase audit rather than from use, which is worth saying: none of
these were reported, and two of them had shipped.

Fixed, in order of how badly they could have gone:

- A daemon left behind by a crash was killed **before** the volumes it was serving
  were unmounted, leaving macOS talking to a storage server that no longer existed.
  `soft,intr` bounded it to I/O errors rather than a wedge, which is exactly why it
  went unnoticed through two releases.
- A damaged record of which volumes grrclone had mounted read as "we mounted
  nothing", silently disowning live mounts so that quitting left them connected to
  nothing. The realistic trigger was not disk damage but adding a field to the record.
- The log viewer did not redact `Authorization` headers, cookies or AWS signatures, so
  an OAuth token could survive into a log a user was invited to copy into a bug report.
- **Read only** could appear to be on for a volume that was still accepting writes,
  because settings edited while mounted were saved and never applied.
- A discarded `SecRandomCopyBytes` status would have made both control-socket
  credentials a fixed string.
- Settings claimed the configuration was unencrypted when it had merely failed to read
  it.

Added: deleting a remote, with the four ways that can lose data each closed —
unfinished uploads, teardown ordering, the configuration rewrite, and the keychain
entry that must not be touched. And `CHANGELOG.md`, updated per pull request rather
than reconstructed at release time.

The README now states the four things no other rclone GUI does, all of which already
existed and none of which were being claimed: registry-based mount ownership, the
hardened mount options, redaction on ingest, and a CI-enforced privacy guarantee.

### v0.3.2 — 2026-09-18

Changed: every explanatory line in Settings was cut to one line or less. The text was
accurate and nobody was reading it.

### v0.3.1 — 2026-09-17

Fixed: the add-remote wizard was unusable in the shipped build. Two independent causes,
both invisible in tests. A sheet presented from a `MenuBarExtra` popover dismissed the
popover, taking the sheet with it — so the provider dropdown closed the moment it was
clicked. And rclone chunks large rc replies; `config/providers` is large, and the unix
socket client assumed `Connection: close` meant EOF always delimited the body, so the
provider list arrived truncated. The wizard now opens in the Settings window, and the
client decodes chunked transfer encoding.

### v0.3.0 — 2026-09-17

Added: an add-remote wizard generated from the rc `config/providers` endpoint — 69
providers, 968 options, no hand-written per-backend forms. OAuth backends complete in
the browser without a terminal, driven through rclone's own interactive config state
machine. An offer to encrypt `rclone.conf`, with the password optionally in the
keychain.

Changed: the UI no longer implies stored credentials are encrypted. `rclone obscure` is
obfuscation, not encryption, and said so nowhere the user would see it.

Documented: that `soft` trades a hang for an I/O error after roughly two minutes, and
what grrclone cannot fix — local-only locks, AppleDouble sidecars. WebDAV/NetFS was
built, measured against NFS, and dropped; the reasoning is recorded so it is not
rebuilt.

### v0.2.0 — 2026-09-17

Added: encrypted `rclone.conf` support, with the password optionally in the keychain;
a configurable mount folder; a daemon-wide bandwidth limit applied without a restart;
a log viewer with the detail level changeable while running; opt-in update checks with
a pre-release channel.

Fixed: the menu drew its connection rows behind the footer, so the list of mounts was
the one thing you could not see; errors were published to a property no view read, so
every failure was silent; self-healing returned a repaired volume to the default
folder rather than the configured one; an unmounted mountpoint accepted writes the
next mount would hide; rclone's output went to a pipe nothing drained, and a full pipe
blocks the writer; unclean shutdowns are now reported with an offer to move stranded
local files aside.

Distribution: a Homebrew cask, served from `mlaify/homebrew-tap`.

### v0.1.0 — 2026-09-17

The first stable release. Mounts, unmounts, self-heals, and tears down in the right
order. Signed, notarised, and distributable.

## Done

### M0 — the performance gate (2026-09-16)

The one risk that could have killed the approach. Forum reports had `nfsmount` at
25 kB/s against 50 MB/s for `rclone copy`. Not reproducible on rclone 1.75.1: cold reads
run at 61% of baseline and end-to-end writes at 78%, with directory listings faster than
`rclone lsjson`. Gate passed, NFS is the transport.

### M1 — headless core (2026-09-16)

`RcloneRC` (rc API client over a unix socket) and `GrrCloneCore` (daemon supervision,
mount transports, ownership registry, connection lifecycle), plus `grrclonectl` to drive
them without a UI.

### M2 — menu bar app (2026-09-16)

SwiftUI `MenuBarExtra` over the core, generated by XcodeGen so no `.xcodeproj` is
tracked. Auto-discovers remotes, connects and disconnects, connects at login, per-
connection settings, ordered teardown on quit.

### M3, part 1 — self-healing mounts (2026-09-16)

Watches for wake from sleep, network return and volume unmount, probes every mount, and
rebuilds the ones that stopped responding. A mount whose server is killed is detected in
5.3 s, torn down and rebuilt, and verifies healthy.

### M3, part 2 — transfer visibility and quit safety (2026-09-16)

Closes a data-safety gap. With `--vfs-cache-mode full` a write returns as soon as the
bytes reach local disk, so Finder shows a file as saved while nothing has reached the
provider. Quitting then strands the only copy in a cache the user does not know exists.

Pending uploads are now polled from `vfs/stats`, shown in the menu, and reflected in the
menu bar icon. Quitting with uploads outstanding asks rather than surprises, waits up to
120 s, and says so if anything is still unfinished. Measured: a 64 MB write shows as
pending immediately and drains in 9.6 s.

`vfs/stats` rather than `vfs/queue` is deliberate. The queue endpoint lists only items
waiting to *start*, so a file actively uploading shows an empty queue and the caller
concludes, wrongly, that everything is stored.

### Encrypted configurations (2026-09-17)

An encrypted `rclone.conf` did not merely fail, it failed unintelligibly. The daemon
started normally and the first call that read the config returned
`panic received: fatal error: Failed to read line: EOF` — rclone trying to prompt for
a password on a terminal the app does not have. Nothing in that mentions encryption,
so the app reported an internal error and the user had no way to know what was wrong.

grrclone now launches the daemon with `--ask-password=false`, which turns that panic
into a legible `unable to decrypt configuration`, recognises it, and asks for the
password. The password can be saved in the keychain, and a saved password that stops
working is deleted rather than retried at every launch.

### Bandwidth limit (2026-09-17)

`core/bwlimit`, set from Settings and reapplied to the daemon at every start — the
limit lives in the running process, so without that a crash or restart silently
returns to unlimited.

The documentation for that endpoint is wrong in two ways, both found by exercising it
rather than reading it. A rate comes back in IEC units, so `1M` is reported as `1Mi`
and anything comparing what was typed against what was applied sees a change that did
not happen. And the documented example claims an `up:down` pair reports only the
upload half; 1.75.1 returns the whole pair, so reading `bytesPerSecond` alone would
have reported the download limit as equal to the upload one.

Invalid input is rejected with the previous limit left in force, which is the right
way round: a typo cannot accidentally unthrottle a connection.

Also `grrclonectl bwlimit`, and rc errors are now readable — the raw JSON body used
to be shown verbatim, which was tolerable in a log and is not in a menu.

### Unclean shutdown safety (2026-09-17)

An audit of the hand-rolled setup grrclone replaced raised four problems. Three
applied here, checked against the code rather than assumed.

**A mountpoint left behind by a crash accepted writes** ([#40]). Anything written to
a connection's folder while nothing was mounted landed on the local disk, looked
saved, and was hidden by the next mount. A clean disconnect already removed the
folder, so the exposure was after a crash or force quit — exactly when nobody is
watching. Mountpoints are now `0500` while unmounted. Measured: a `touch` inside
fails, mounting over it still works, writing *through* the mount is unaffected
because permissions come from the server, and unmounting reverts with no extra work.

**Unclean shutdowns are now reported, not just repaired.** Orphaned daemons were
already reaped and stale mounts cleared, behind a status line that scrolls away.
That is the right amount of noise for cleanup that cost nothing, and the wrong amount
when the user's own data may be involved. A session marker records what was mounted;
if the next launch finds it, grrclone says so and offers to move any local files
aside into a folder named `(recovered …)`. Moved, never merged: grrclone cannot know
whether the local copy or the remote one is newer, and guessing overwrites the wrong
one.

**Locks are local only** ([#41]). `nolocks,locallocks` is what stops anything taking
an `fcntl` lock hanging forever on a lock daemon rclone does not run. The cost is
that two Macs can each hold an "exclusive" lock on the same KeePass database. There
is no fix available — rclone's NFS server has no distributed locking — so the fix is
saying so in connection settings, where someone keeping a vault on a remote will
see it, instead of only in benchmarks.md.

The fourth, a spinning launchd loop, does not apply: grrclone has no launchd loop. It
is a long-running app with an `SMAppService` login item, so there is no `KeepAlive`
restart cycle.

[#40]: https://github.com/mlaify/grrclone/issues/40
[#41]: https://github.com/mlaify/grrclone/issues/41
### Log viewer (2026-09-17)

Recent daemon output in a Settings tab, with the detail level changeable at runtime.

It fixes a hang as much as it adds a feature. rclone's output went to a `Pipe` that
nothing read, and a process writing to a full pipe blocks — demonstrated directly: a
child writing 20,000 lines to an undrained pipe was still stuck five seconds later. At
`NOTICE` that buffer takes a long time to fill, which is why it had not bitten yet, but
a daemon having a bad day is exactly when it logs most, and freezing it takes every
mount with it.

The level is changed through `options/set` rather than by restarting. `--log-level` is
a launch flag, but restarting the daemon to turn on verbose logging would unmount every
volume — an absurd price for looking at a log, and a good way to destroy the transient
failure being diagnosed.

Redaction happens on the way in, so a credential is never held in memory in the clear.
That code was wrong at first in a way worth recording: it matched `--rc-pass VALUE`, and
rclone actually echoes `"--rc-pass" "VALUE"` with every argument quoted, so nothing
matched and the control-socket credentials went into the log in plain text. The test
had been written from imagination rather than from real output, so it passed. It now
uses a line captured verbatim from rclone 1.75.1, and the redaction is confirmed
against a live daemon.

### Update checks, and who owns the app bundle (2026-09-17)

An opt-in check against the GitHub releases API, with a pre-release channel, and the
Homebrew cask that goes with it.

The design question was not how to check for updates but **who is allowed to install
them**. Homebrew records the version it installed; an app that replaces its own bundle
makes that record a lie, and the next `brew upgrade` reinstalls over the top —
downgrading anyone who had moved ahead, which is most likely for someone running a
pre-release. Homebrew's `auto_updates true` exists for apps that self-update, and
grrclone's cask deliberately does not use it, because grrclone deliberately does not
self-update.

So: **Homebrew installs, grrclone informs.** The app detects a Homebrew installation
from the Caskroom — not by running `brew`, which a GUI app may not be able to find —
and says `brew upgrade --cask grrclone` instead of offering a download. Checking is
still offered, because knowing a release exists costs nothing; it is installing that
needs one owner.

Pre-releases cannot come from the stable cask at all. One cask serves one channel, so
a pre-release channel means a second cask token, the way `firefox@beta` does.
`scripts/make-cask.sh` refuses pre-release tags rather than generating something that
would fight the stable cask.

Nothing is ever downloaded or installed by the app. Verifying a signature on a
downloaded bundle and swapping a running app is a large attack surface to add to a
program that mounts your storage, and it is work Homebrew already does properly.

### The security review found the check that could not fail — again

A security pass over the update checker turned up three things, and the worst was in
the assertion written to protect it.

The App Transport Security check scanned `App/project.yml App/*.plist`. There is no
plist directly under `App/` — the real one is `App/grrclone/Resources/Info.plist` — so
the glob matched nothing and the check reported ok having audited only half of what it
named. It had been "verified" by injecting a violation, but the injection went into
`project.yml`, the path that worked. **Testing one input of a check is not testing the
check.** It now names both files explicitly and fails when a file it audits is missing,
because a check that cannot find its target knows nothing, and nothing must not read as
fine.

The opt-in gate lived at each call site rather than in `checkForUpdates()`, and "Check
Now" did not apply it — so the app would contact GitHub with the preference switched
off. Three call sites, one already wrong. The gate now lives in the function.

Response handling used `if let` for both the origin check and the status check, which
accepted a reply whose origin or status could not be established. Both fail closed now.

The part the review found clean is the part that mattered most: the release page URL is
built locally from the repository and tag rather than taken from the response's
`html_url`, and the tag is constrained to characters that cannot smuggle a scheme,
authority, traversal or query. The worst a fully hostile response can do is name a tag
that does not exist, which is a 404.

### The privacy checks were weaker than they looked

Adding the first outbound connection that is not to the user's own storage meant
reading the privacy script properly, and it had three faults.

It **only scanned committed files** — `git ls-files` — so the entire update checker
was invisible to it while being written. The one moment you most want that check to be
honest is while writing the file it should be examining.

Its download rule named `download` and `dataTask`, and the update checker uses
`data(for:)`. It passed by using an API the rule had not heard of. The rule now matches
the artefact rather than the call.

A new rule asserting updates are off by default silently never fired, because it was
written before being tested. All three rules were then checked by injecting the thing
each forbids and watching them trip.

### WebDAV/NetFS, built and rejected (2026-09-17)

The second `MountTransport` implementation existed for one reason: volume semantics.
NFS mounts land as directories; WebDAV through NetFS was supposed to land as a real
volume with an eject button in the Finder sidebar.

It was built, and it worked — a real remote mounted through grrclone's own stack, read
and write, no privileged helper, no prompt. Then the justification was measured:

| Mount | ejectable | removable | local | browsable |
|---|---|---|---|---|
| `~/Cloud` (NFS) | false | false | false | true |
| `~/grrclone/VolTest` (WebDAV/NetFS) | false | false | false | true |
| `/Volumes/EjectTest` (WebDAV/NetFS) | false | false | false | true |

`volumeIsEjectable` is false in every case, including directly under `/Volumes`. Both
transports already register as non-local browsable volumes. So the trade was slower
transfers — `webdavfs` stages whole files and degrades on large directories — for no
advantage anyone could demonstrate.

Dropped, and [#27](https://github.com/mlaify/grrclone/issues/27) closed with the
implementation notes, because the findings are the valuable part:

- NetFS's option constants import into Swift as `String`, not `CFString`
- `NetFSMountURLSync`'s mountpath is a **container**, not the mount point: it appends
  the URL's last path component
- `serve/start` rejects a nested `vfs` block; the nested form is `vfsOpt`, and flat
  `vfs_cache_mode` keys are what works

The honest cost: `MountTransport` still has one implementation, so the seam remains
unproven. Better an unproven seam than a second implementation nobody should choose.

## Next

Each item is also a [GitHub issue](https://github.com/mlaify/grrclone/issues), which is
the unit of work — but the backlog is recorded here too, so this file remains a
complete account of the project without needing GitHub open.

Issues are grouped into milestones. Release milestones are closed once the release
ships, so they read as history; the two non-release milestones never close, because the
things in them are not waiting on us.

| Milestone | Holds | State |
|---|---|---|
| `v0.2.0` | Bandwidth limit, log viewer, opt-in update checks, crash-left-mountpoint fix | closed, shipped 2026-09-17 |
| `v0.3.0` | Add-remote wizard, OAuth without a terminal, config encryption offer, soft-mount docs | closed, shipped 2026-09-17 |
| `v0.4.0` | Audit fixes, delete a remote, the changelog | closed, shipped 2026-09-18 |
| `v0.5.0` | Transfer visibility, remote editing, cache control — shipped as 0.6.0 | closed |
| `v0.7.0` | Daily update check, one permission, build provenance | closed, shipped 2026-09-19 |
| `v0.8.0` | The 2026-09-19 review's safety fixes, and reclaiming fingerprinted mounts | open |
| `v0.9.0` | Daemon exit detection, wizard hygiene, store honesty, arm64-only rclone | open |
| `Blocked on adoption` | Ready to do, gated on something outside the code | never closes |
| `Known limitations` | Documented, deliberately not fixed | never closes |

### The 2026-09-19 review

A full read of the tree after 0.7.1 — every source file, the workflows and the
scripts — looking for gaps rather than for the bug of the day. It filed fifteen
issues, and the shape of them is the finding: **almost every one is a `try?` or a
`?? []` in the mount core turning "could not tell" into "fine"**, the same family
#71–#80 belonged to, in places that audit did not reach. Two were verified against
the bundled rclone before filing rather than inferred, and both were real.

**v0.8.0 — fix before anything else, in roughly this order.**

- **Debug logs carried remote passwords** ([#109](https://github.com/mlaify/grrclone/issues/109)).
  rclone traces every rc call at DEBUG, `parameters:map[pass:PLAINTEXT …]` included,
  and the redaction knew neither the key nor the form. Caught `configPassword:` only
  because it contains the word "password". Fixed in #123: the payload of every
  `config/*` call is removed, not a value.
- **Mounting over an existing mount** ([#108](https://github.com/mlaify/grrclone/issues/108)).
  The refusal keyed on visible entries, so a dead mount whose listing returns EIO, or
  an empty one, got a new layer on top. This is the mechanism behind the three
  stacked mounts on the maintainer's `~/Cloud` that day.
- **Adding a remote with an existing name replaces it** ([#110](https://github.com/mlaify/grrclone/issues/110)).
  Verified: rclone's `config/create` deletes the section first; the wizard never
  checked. No backup is taken on create.
- **Health repair disowns a mount it could not unmount** ([#111](https://github.com/mlaify/grrclone/issues/111)).
  `reconnect()` forgets the registry entry whether or not the unmount succeeded —
  `disconnect()` gets this right and the two disagree.
- **Duplicate names disown a live mount** ([#112](https://github.com/mlaify/grrclone/issues/112)),
  **an unreadable `connections.json` is overwritten** ([#113](https://github.com/mlaify/grrclone/issues/113)),
  **a whole-remote cache purge takes a mounted subpath twin's cache with it**
  ([#114](https://github.com/mlaify/grrclone/issues/114)), **a failed mount-table read
  authorises killing the orphan daemon** ([#115](https://github.com/mlaify/grrclone/issues/115)),
  **unmount success is never confirmed against the table**
  ([#116](https://github.com/mlaify/grrclone/issues/116)), **startup drops
  `stillMounted` and erases the crash record if `start()` throws**
  ([#117](https://github.com/mlaify/grrclone/issues/117)), and **blocking work on the
  main actor against paths that may be wedged mounts**
  ([#118](https://github.com/mlaify/grrclone/issues/118)).
- **Reclaim unrecorded mounts that carry our fingerprint**
  ([#105](https://github.com/mlaify/grrclone/issues/105)) — an offer, gated on the
  exact option string, `localhost:/` source, a path under the mount root, and explicit
  confirmation; unmount only, never kill a daemon.

**v0.9.0 — after the core is honest again.** Detect the daemon exiting and probe on
a timer instead of only on wake ([#119](https://github.com/mlaify/grrclone/issues/119));
stop the wizard writing every advanced default into `rclone.conf`
([#120](https://github.com/mlaify/grrclone/issues/120)); stop edits reporting saved
when the store write failed ([#121](https://github.com/mlaify/grrclone/issues/121));
bundle an arm64 rclone for an arm64-only app
([#122](https://github.com/mlaify/grrclone/issues/122)).

What came through clean: the release workflow, provenance attestation, signing
scripts, privacy script and CodeQL setup — the only note against them is #122.

**Still waiting on something outside the code:** homebrew-cask submission
([#28](https://github.com/mlaify/grrclone/issues/28)) on notability alone, and
`/Volumes` mounts ([#85](https://github.com/mlaify/grrclone/issues/85)) on whether
anyone asks for a privileged helper.

Known limitations with no fix available are filed under `Known limitations` so they can
be pointed at rather than re-investigated each time someone notices them:

- **Locks are local only** ([#41](https://github.com/mlaify/grrclone/issues/41)).
  `nolocks,locallocks` is what stops anything taking an `fcntl` lock hanging forever on
  a lock daemon rclone does not run. The price is that two Macs can each hold an
  "exclusive" lock on the same KeePass database. rclone's NFS server offers no
  distributed locking, so the honest response is the warning now shown in connection
  settings.
- **AppleDouble `._` sidecars** ([#30](https://github.com/mlaify/grrclone/issues/30)).
  NFSv3 cannot store extended attributes and macOS attaches `com.apple.provenance` to
  every copy, so a sidecar appears beside almost every file. `--no-appledouble` is a
  FUSE flag that does not exist on `serve nfs`, and filters govern what rclone reads,
  not what the VFS writes back. The related `.DS_Store` problem **is** solved, in
  Settings.
- **WebDAV/NetFS as an option** ([#27](https://github.com/mlaify/grrclone/issues/27)).
  Built, measured, rejected — it bought nothing NFS does not already give
  (`volumeIsEjectable=false` either way). Filed here rather than reopened when someone
  next wonders whether it would help.

## Settled decisions

Do not re-litigate these without new evidence. Reasoning is in
[benchmarks.md](benchmarks.md).

| Decision | Why |
|---|---|
| NFS is the only transport | WebDAV/NetFS was built and measured: slower, and no volume advantage that survives checking |
| Apple Silicon only, no universal binary | Intel Macs are on the way out; carrying a second slice buys nothing |
| NFS over loopback, not macFUSE or FUSE-T | No kernel extension, no third-party install, no root |
| `serve/start` plus our own `mount` call | `nfsmount` and `mount/mount` hardcode options, giving a hard mount that wedges Finder |
| `soft,intr,timeo=600,retrans=2,nolocks,locallocks,nfc` | Turns a dead backend into an error in ~7 s instead of a hang |
| `--nfs-cache-type disk` | No measurable cost, and keeps NFS handles valid across an rclone restart. `symlink` is Linux-only |
| rclone ≥ 1.74.4 | Earlier versions have NFS defects causing stale handles, failed file creation, broken large listings |
| Control API on a unix socket, never TCP | Filesystem permissions; nothing reachable over the network |
| Mount under `$HOME`, not `/Volumes` | `/Volumes` needs root to create the directory. A privileged helper is deferred |
| The mount root is configurable | A machine migrating from a hand-rolled setup already has paths that docs, scripts and habit point at |
| Unsandboxed, Developer ID, not App Store | Must spawn rclone and invoke `/sbin/mount` |
| Read `rclone.conf`, never write it | People depend on it from the command line |
| One daemon, N servers | Unified stats and teardown. Tradeoff: a crash drops all mounts, handled by reconciliation |
| Ownership from our registry only | A user's own mounts are indistinguishable in the mount table |
| Sign by certificate hash, not name | Two certificates can share a common name, and `codesign -s "<name>"` then fails as ambiguous |

## Known issues


- **Two Developer ID Application certificates exist**, issued six minutes apart and
  sharing a common name, so `codesign -s "<name>"` fails as ambiguous.

  This is permanent, not a temporary mess. Apple's portal offers no self-service
  revocation for Developer ID certificates, deliberately: revoking one invalidates
  every application ever signed with it, so it needs Developer Support. The spare
  (serial `017FF9B649C90630`) simply stays.

  Signing is therefore pinned by hash in `~/.config/grrclone-signing/identity`, which
  is the permanent answer rather than a workaround, and is good practice anyway: builds
  are reproducible, and a missing certificate fails loudly instead of silently signing
  with whatever else is in the keychain.

  **Done on the development machine**: the spare was deleted from the keychain, so
  `codesign` is no longer ambiguous there. The certificate remains valid on the account
  and simply goes unused. Any new machine will see it again if that keychain is
  restored from a backup, which is another reason the pin stays.
- **The Developer ID certificate expires 2027-02-01**, much sooner than the usual five
  years, which normally means it is capped by the membership renewal date. Worth
  confirming before relying on it for a release cycle.

- **Quit safety is only as good as what it can observe.** Three defects here all had
  the same shape and were fixed together: a check that cannot see a problem must say
  so, not report success. See the session log for 2026-09-16 (fixes).

- **`._` sidecars are uploaded to remotes, and cannot be prevented.** `.DS_Store` is
  solved — Settings has a toggle for the macOS `DSDontWriteNetworkStores` preference,
  verified to stop both the file and its sidecar appearing. The `._` files are not.

  They hold extended attributes for filesystems that cannot store them natively.
  NFSv3 cannot, and rclone serves NFSv3; `namedattr`, which would let the server hold
  them, is NFSv4 only. So macOS writes one beside essentially every file: it attaches
  `com.apple.provenance` to copies, so even a plain text file with no tags and no
  quarantine flag gets a sidecar. Measured, not assumed.

  Everything plausible has been ruled out by testing, not by reading:
  `--no-appledouble` and `--no-applexattr` are FUSE mount flags that do not exist on
  `serve nfs`; `--exclude ".DS_Store" --exclude "._*"` does not stop writes reaching
  the remote, because filters govern what rclone lists and reads, not what the VFS
  writes back; and `mount_nfs`'s `namedattr` needs NFSv4.

  A scan-and-delete feature was built and then removed: it is a treadmill, not a fix,
  and it is the one place the app would delete files it did not create. Anyone who
  wants a one-off clean-up can do it with rclone directly, which is the right tool:

  ```
  rclone delete <remote>: --include "._*" --include ".DS_Store" --dry-run
  ```

  Drop `--dry-run` once the list looks right.

## Deferred, deliberately

- **Privileged helper for `/Volumes` mounts**, which would give real volume semantics
  with an eject button. Wanted, but it adds an admin prompt and a security surface.
- **File Provider extension**, which is what Mountain Duck actually uses. It would give
  dataless placeholder files and a Locations sidebar entry. Large piece of work, and the
  extension cannot spawn rclone, so it would need `librclone` linked in statically.
- **File browser** and **sync/bisync jobs.** Out of scope; rclone does these well.

## Open questions

- Should `/Volumes` mounting arrive before or after the first public release? It is the
  most visible gap against Mountain Duck.
- Is one daemon for all connections right? It is simpler, but one rclone crash drops
  every mount at once. Per-connection daemons would isolate failures at the cost of
  memory and complexity.
(The WebDAV/NetFS question is settled — built, measured, rejected. See the entry under
[Known limitations](#next) and the 2026-09-17 session note below.)

## Hard-won lessons

Recorded because each cost real time and each is easy to repeat.

1. **A task group is not a timeout.** It does not return until every child finishes, and
   `cancelAll()` cannot resume a task blocked in an uninterruptible syscall. The timeout
   fires and the group hangs anyway. Use `Deadline`.
2. **A mount can be in the kernel's table and completely dead.** Liveness needs a probe
   that actually reaches the server.
3. **Listing a directory does not reach the server.** The NFS client answers from cache.
   Probe with a random, uncacheable name.
4. **Returning quickly does not mean healthy.** After a soft mount gives up, calls
   fast-fail with `ETIMEDOUT` or `ESTALE`. Check `errno`.
5. **Never `pkill -f` a pattern that could match your own command line.** A test did
   exactly this and killed the shell running it.
6. **`serve/start` accepts only the `vfs` and `nfs` option blocks.** Global flags
   (`cache_dir`, `transfers`, `checkers`) and FUSE-only ones (`attr_timeout`) are
   rejected, and they fail the whole request.
7. **A `MenuBarExtra` with the window style does not build its content until clicked.**
   Startup attached there never runs. It belongs in the app delegate.
9. **`vfs/queue` does not mean "uploads pending".** It lists only items waiting to
   start, so a file actively uploading shows an empty queue. `vfs/stats` reports both
   `uploadsQueued` and `uploadsInProgress`; safety checks need the sum.
10. **A multi-line boolean inside a SwiftUI ViewBuilder is misparsed** as a trailing
   closure. Hoist it into a computed property.
11. **A safety check must fail closed.** Three separate bugs in the quit path all read
   "cannot tell" as "nothing wrong": a cached count two seconds stale, an unreachable
   daemon returning an empty snapshot, and a watchdog shorter than the work it guarded.
   Any of them silently skipped the protection. Model "unknown" as its own state.
12. **Never filter a build script's output without checking its exit status.** A
   `grep` over the log hid a hard failure twice here: the script had aborted on an
   undefined variable, and the summary looked plausible enough to believe.
13. **macOS ships bash 3.2, so `mapfile` does not exist.** A branch using it aborted
   with "command not found" on every stock Mac, and went unnoticed for days because
   the common path short-circuited around it. Prefer `while IFS= read -r` loops, and
   test the branch that normally does not run.
14. **Verify that a check can fail, not just that it passes.** Three of four CI checks
   were broken in ways that still reported success on a clean tree.
15. **Fixing a generator does not fix what it already generated.** The PKCS#12 export
   was corrected, but the bad file it had already written stayed on disk, went into a
   repository secret, and failed a release hours later. When a producer is fixed,
   regenerate its output or verify what exists.
16. **`notarytool --keychain` needs a path, not a name**, and `security create-keychain`
   puts a bare name in `~/Library/Keychains` with a `-db` suffix. Create the keychain
   at an absolute `.keychain-db` path and use that one string everywhere. Note also
   that `notarytool submit` reads its stored profile from the *default* keychain unless
   told otherwise, so a throwaway keychain must be passed to every invocation.
17. **A second app instance is not harmless when instances share state.** Two copies
   of grrclone both supervise a daemon recorded in one pid file, so the newcomer's
   orphan cleanup reaps the running instance's daemon and strands its mounts. Any app
   with a singleton resource needs an explicit guard; relying on Finder to activate an
   existing copy does not hold across two different bundles.
18. **`NSApp.sendAction` can return `true` and do nothing.** `showSettingsWindow:`
   reported success while creating no window. A return value is not evidence; check
   for the effect.
19. **The CodeQL tracer runs its job under Rosetta**, so `brew install` fails with
   "Cannot install under Rosetta 2 in ARM default prefix". Prefix with `arch -arm64`.
8. **Benchmark the cold path.** With `--vfs-cache-mode full`, a second read never
   touches the network and a write returns before the upload starts. The first
   measurements read 3200 MB/s and meant nothing.

## Session log

Newest first. One entry per working session, recording what changed and what was
learned, so the reasoning survives even when the code moves on.

### A test written from imagination proves only that the code agrees with it

`DaemonLog`'s redaction was tested against an invented log line, `--rc-pass VALUE`.
The code matched that shape, the test passed, and the real line — `"--rc-pass"
"VALUE"`, every argument quoted — matched nothing, so the daemon's credentials were
written to the log in clear text. The bug was found by looking at actual `DEBUG`
output, not by testing harder.

Where the input comes from something else, capture a real sample and test against
that. This is the same lesson as the privacy checks that had never been observed to
fail, arriving from the other direction.

### 2026-09-17 (encrypted configs) — a panic made legible

Support for an encrypted `rclone.conf`, and two findings that changed the design.

- Reproduced the actual failure before designing anything, against a throwaway
  encrypted config. The important part was not that it failed but *how*: an
  unexplained panic about reading a line, with no mention of encryption.
- `config/unlock` reports success for a wrong password, so unlocking is verified by
  reading the config afterwards.
- The keychain item does not get the protection an earlier version claimed; the code
  and its documentation were corrected to match what macOS actually does.
- Verified the change does not disturb an unencrypted config: the real config still
  lists its remotes with `--ask-password=false` in place, and no prompt appears.
- 49 tests pass, up from 42. The lock classifier was checked by breaking it
  deliberately and confirming the tests trip.

### `config/unlock` does not say whether the password was right

It returns HTTP 200 and `{}` for a wrong password exactly as it does for a correct
one. Verified against rclone 1.75.1. Trusting the response would have reported success
and then failed on the next call with an error the user could not connect to what they
had just typed — and saved a wrong password to the keychain to fail again at every
launch. `unlockConfig` therefore verifies by reading the config afterwards, and it is
that read which decides.

### The legacy keychain silently ignores `kSecAttrAccessible`

`ConfigPasswordStore` first set `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and said
in a comment that the password was unreadable while the Mac was locked. It was not. The
modern data protection keychain honours that attribute, but reaching it needs the
`keychain-access-groups` entitlement, which a Developer ID app cannot carry without an
embedded provisioning profile — `SecItemAdd` fails with `-34018`. Items therefore land
in the legacy file keychain, which stored no such attribute at all.

The test caught it only because it read the attributes back instead of trusting that
the write meant what it said. A security property that is asserted in a comment and
never verified is not a property. The documentation now describes what the store
actually provides.

### 2026-09-17 — v0.1.0, and a real migration

The release, and the change that made it worth having.

- **Made the mount root configurable** (#20). It was hardcoded to `~/grrclone`, which
  meant adopting grrclone was a migration rather than a swap: a machine already
  mounting at `~/Cloud` and `~/CloudVaults` has docs, scripts and habit pointing at
  those paths. Settings > General now exposes the folder, persisted under `MountRoot`.
  Changing it deliberately does not move live mounts; disconnect and reconnect applies
  it.
- **Migrated the maintainer's machine off its launchd agent.** The old
  `xyz.matthewd.rclone-mounts` plist was unloaded and parked as `.disabled-20260916`.
  grrclone now serves both remotes at their original paths — verified by directory
  listings, mount options (`soft intr locallocks nfc`) and a write that round-tripped
  to the server. The old script, fixed to use serve+mount with safe options instead of
  `nfsmount`, went into the `interserver` repo for machines not yet running grrclone.
- **Tagged and released v0.1.0.** Verified against the downloaded artifact rather than
  the green check: staple validates, `spctl` reports `Notarized Developer ID` for both
  the DMG and the app, `codesign --verify --deep --strict` passes, and the bundled
  rclone carries our team ID.
- **Confirmed the release is Apple Silicon only, and that this is intended.**
  Verification showed the app binary is `arm64` while the bundled rclone is universal.
  Raised as a defect; the maintainer's decision is that Intel Macs are going away and
  are not worth carrying, so it is now a settled scope decision rather than a gap.
- **Cleared the CI debt.** Code scanning and the `code_scanning` ruleset condition are
  both gone, so pull requests no longer need an admin override for a check nothing
  produces. Two leftover local `probe` tags were deleted; they had never been pushed.

### 2026-09-16 (icon) — an angry cloud

The app has an icon: an angry storm cloud in rclone's own blue, generated by
`scripts/make-icon.swift` rather than checked in as a binary, so the design is
reviewable in a diff and every size is drawn from geometry instead of resampled.

That last part is not pedantry. 16pt is a different design problem, not a smaller
version of the same one: below 32pt the icon drops the lightning bolt and the eyes and
keeps only the scowl, because two heavy diagonals are the only part of an expression
that survives at that size. Downsampling the 512pt artwork produced mush.

A first attempt redrew rclone's three-arrow trefoil with a scowl. It read as an insect
at 256pt and as spaghetti at 16pt, and was abandoned. Only rclone's colours are reused;
the shapes are original. Their logo is credited to a named designer and the project
publishes no trademark policy, so reproducing the mark itself would be the wrong call
for a public repository.

### 2026-09-16 (self-contained) — rclone bundled

`scripts/fetch-rclone.sh` pins rclone v1.75.1, verifies both architectures against the
digests published with the release, and `lipo`s them into a universal binary the app
bundles. The result is a 69 MB DMG that needs nothing installed: verified by mounting a
quarantined copy and confirming the app launches its own `Contents/Resources/rclone`
rather than Homebrew's.

Order matters when combining: `lipo` first and sign the fat result once. Signing each
slice and then combining produces a binary that verifies locally but fails notarisation.
Upstream ships rclone ad-hoc signed with no team identifier, so re-signing with our own
Developer ID is required for Gatekeeper's team consistency check.

The disk image now gets its own signature as well as a stapled ticket. Without one,
`spctl -a -t open` on a downloaded file reports "rejected: no usable signature" even
though the app inside is notarised — the user is warned about the very thing they
double-click first. Caught by simulating a download with the quarantine attribute,
which is worth doing for every release.

### 2026-09-16 (release) — signed, notarised, distributable

grrclone now builds into a notarised DMG that Gatekeeper accepts:
`source=Notarized Developer ID`. `scripts/release.sh` does build, sign, notarise,
staple, package, notarise again and staple again, then verifies the result the way a
user's Mac would.

Both the app and the disk image are notarised and stapled separately. Each needs its
own ticket: stapling the app keeps it trusted once dragged out of the image, and
stapling the image satisfies Gatekeeper before anything is copied anywhere.

Two things went wrong getting the certificate installed, both worth remembering.
Homebrew's OpenSSL 3 writes PKCS#12 with a SHA-256 MAC that macOS Security rejects,
reporting it as a wrong password when the password was correct — the keychain takes the
key and certificate directly and needs no password at all. And the account held two
Developer ID certificates with identical common names, which makes `codesign -s
"<name>"` fail as ambiguous and sign nothing; signing is pinned to a hash instead.

### 2026-09-16 (fixes) — quit safety made honest

A code review of the quit path found three defects that were one mistake wearing three
hats: each made the safety check report success when it simply could not tell.

- The quit decision read a polled count up to two seconds stale, so a file copied in
  Finder and followed straight by Cmd-Q looked like nothing pending, skipping both the
  warning and the drain. rclone is now asked directly at quit, which required deferring
  the terminate decision and replying `false` to cancel.
- `activity()` returned an empty snapshot when the daemon was unreachable, which every
  caller read as "nothing pending". A daemon that crashed holding queued uploads
  reported all clear. `Activity` now tracks `unreachable` separately, and `isKnownIdle`
  requires a positive answer from every connection.
- The 150 s quit watchdog was shorter than a worst-case teardown (~350 s with two wedged
  mounts), so it could fire between unmounting a volume and stopping the daemon — the
  one state the teardown ordering exists to prevent. `shutdown` now enforces its own
  deadline: when time runs out it leaves the remaining mounts up *and the daemon running
  to serve them*, an orphan the next launch reaps, which is strictly safer than a live
  mount with no server behind it.

Two smaller ones from the same review: the activity poller had no cancellable handle and
kept overwriting published state after shutdown, and `reply(toApplicationShouldTerminate:)`
could be sent twice.

The missing adversarial test now exists in both forms. `grrclonectl quit-safety-test`
queues a 96 MB upload, kills the daemon under it, and asserts we report unknown rather
than safe; unit tests cover the same semantics. Observed output after the fix:
`pending=0 unknown=true isKnownIdle=false` — the pending count alone would still have
said "safe".

### 2026-09-16 (later) — public, with CI

- Repository made public. The decision was taken knowingly: the commit history carries
  the author's work email and, in four early commits, a macOS username and home paths.
  Publishing is effectively irreversible, so this was confirmed rather than assumed.
- CI added: `swift test`, an unsigned app build, and a privacy check that enforces the
  no-phone-home guarantee as a build failure rather than a review convention.
- CodeQL was added, then removed at the maintainer's request. Swift analysis took over
  ten minutes per run and needed two environment workarounds before it would build the
  app target at all.
- Both pull requests merged with an admin override, because the ruleset requires a
  review the sole author cannot give.

An automated review on the CI pull request found four real defects in the new checks,
all confirmed and fixed. Worth recording, because three of them made a check *look*
like it worked:

1. `| grep … || true` discarded every xcodebuild failure, and the follow-up `test -d`
   was no substitute, since Xcode creates the `.app` directory early enough to survive
   a failed build.
2. CodeQL's autobuild compiled only the SwiftPM targets, so everything under
   `App/grrclone` went unscanned.
3. Stripping `//` comments also ate the rest of any URL, so `"https://mixpanel.com/x"`
   became `"https:` and the analytics check silently missed it. A live false negative.
4. The loopback rule enumerated bad bind forms instead of requiring good ones, missing
   `[::]:0`, LAN addresses, and anything built by interpolation.

The lesson generalises: a check that has never been observed to fail is not known to
work. Every rule in `scripts/check-privacy.sh` now has a verified failing case.

### 2026-09-16 — from empty directory to working app

Started with an empty repository and a question: is a free, open-source Mountain Duck
alternative feasible?

- Surveyed the prior art and found a real gap. Nothing open source combines a native
  menu bar app, no third-party drivers, signed builds and no phone-home.
- Ran the performance gate before writing any app code. NFS passed, so the approach
  held. Two first-draft design assumptions were wrong and were corrected before they
  cost anything: `--nfs-cache-type symlink` cannot work on macOS, and `rclone nfsmount`
  hardcodes mount options in a way that hangs Finder.
- Built the core, the menu bar app and self-healing mounts.
- Found and fixed eight defects along the way, listed under Hard-won lessons above.
  The timeout bug was the most serious: the app hung outright, and the mechanism meant
  to prevent hangs was itself the cause.
- Published to a private repository with the standard community documents, sanitised
  ahead of an eventual public release.

Open at the end of the session: signing and notarisation, which needs a Developer ID
Application certificate.
