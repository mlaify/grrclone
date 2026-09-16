# M0 benchmark — the NFS transport gate

**Verdict: PASS. NFS is the default transport.**

Run 2026-09-16, rclone v1.75.1, macOS 27.0 (Darwin 27.0.0, arm64), against a real
WebDAV remote over the internet. 256 MB test file, 1,000-entry directory.
Reproduce with `scripts/bench.sh dav1: 256M`.

## Why this gate existed

Forum reports had `nfsmount` on macOS at 25 kB/s against 50 MB/s for `rclone copy`,
a 2000x gap that would have made the whole approach unusable. That is not reproducible
on 1.75.1. The fixes in 1.74.0 (`--vfs-handle-caching`, EOF flag in READ responses)
and 1.74.4 (stable inode numbers, Seekdir offsets) appear to have closed it, which is
why the plan sets a hard floor of 1.74.4.

## Results

| Metric | Baseline (`rclone copy`) | NFS mount, `disk` | NFS mount, `memory` | Ratio |
|---|---|---|---|---|
| Cold read | 15.0 MB/s | **9.2 MB/s** | 9.7 MB/s | 61% |
| Write, end to end | 15.3 MB/s | **11.9 MB/s** | 8.6 MB/s | 78% |
| List 1,000 entries, cold | 1.79 s | **0.64 s** | 0.65 s | 2.8x faster |
| List 1,000 entries, warm | — | 0.03 s | 0.03 s | — |

Roughly 60 to 80 percent of raw rclone throughput, and directory listing through the
mount beats `rclone lsjson` because the VFS directory cache absorbs it. That is an
acceptable price for Finder integration.

## Crash behaviour — the reason for the custom mount options

`rclone nfsmount` hardcodes its mount options to `port`, `mountport`, `tcp`, leaving a
**hard, non-interruptible** mount. grrclone issues its own mount call instead:

```
soft,intr,timeo=600,retrans=2,nolocks,locallocks,nfc,rsize=131072,wsize=131072
```

With the server `SIGKILL`ed underneath a live mount:

- `ls` on the dead mount returned an error after **7.1 s** instead of hanging forever.
- `diskutil umount force` recovered it with **no reboot**.

This is the single strongest argument for not using `nfsmount` or the rc `mount/mount`
endpoint.

## `--nfs-cache-type`: use `disk`

No throughput penalty was observed against `memory`. The write difference (11.9 vs
8.6 MB/s) is most likely WebDAV upload variance rather than a real effect, so the
honest claim is *no measurable cost*, not *faster*. Since `disk` is what lets NFS file
handles survive an rclone restart — avoiding `Stale NFS file handle` on every path —
it is free insurance. `symlink` is Linux-only and not an option here.

## Methodology notes, learned the hard way

The first run produced 3200 MB/s reads and 492 MB/s writes, which is nonsense. With
`--vfs-cache-mode full`:

1. **A repeat read never touches the network.** Reporting best-of-three measured the
   local cache. Only the cold read counts, so the cache is purged between variants.
2. **`dd` returns before the upload starts.** It only measures the copy into the VFS
   cache. The real number is `dd` plus draining the upload queue, confirmed by polling
   the backend directly with `lsjson` until the size matches.
3. **A shared cache directory contaminates the next variant.** Each variant gets its
   own, purged first.

Anyone re-running this should keep those three properties intact or the numbers will
be meaningless again.

## Hazard discovered: reconciliation must be scoped by ownership

The host already runs a hand-rolled launchd agent (`~/.local/bin/rclone-mounts.sh`,
`xyz.matthewd.rclone-mounts.plist`) mounting two remotes at `~/Cloud` and
`~/CloudVaults` via `rclone nfsmount`. In `/sbin/mount` output these are
indistinguishable from grrclone's own mounts: both are `localhost:/` NFS mounts owned
by the same user.

The stale-mount reconciler as originally planned — force-unmount anything whose source
is `localhost:/` — **would have destroyed the user's existing mounts.** macsh has the
same latent bug in a milder form.

**Correction, binding on M1:** the reconciler must only ever touch mountpoints
grrclone itself created, tracked in its own state file at
`~/Library/Application Support/org.mlaify.grrclone/mounts.json`, written before the
mount and cleared after a successful unmount. The `/sbin/mount` scan is used solely to
confirm that a path we already believe we own is still mounted. Matching on source,
port, or process name alone is never sufficient.

## Defaults adopted from the existing setup

The hand-rolled script's flags are good and become grrclone's defaults:

```
--vfs-cache-mode full --vfs-cache-max-age 24h --vfs-cache-max-size 20G
--dir-cache-time 30s --vfs-write-back 5s --transfers 8 --checkers 16
--attr-timeout 1s
```
