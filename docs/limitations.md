# Limitations

Things grrclone cannot fix, written down so they can be pointed at rather than
rediscovered. Each one is a consequence of how rclone's NFS server works, not a defect
in grrclone, and each has been measured rather than assumed.

## File locks are not shared between Macs

Two Macs can open the same file at once and each believe it holds an exclusive lock.

grrclone mounts with `nolocks,locallocks`, which makes macOS satisfy lock requests
locally instead of asking the server. That is not a shortcut: **rclone's NFS server
runs no lock daemon at all**, so without those options anything taking an `fcntl` lock
waits forever on a daemon that will never answer. KeePassXC, Cryptomator, SQLite,
Microsoft Office and Adobe applications all take such locks.

So the choice is between locks that are satisfied locally and an application that
hangs on open. There is no third option: rclone serves NFSv3, and the protocol has no
way to share lock state without a lock daemon.

**What this means in practice.** Take care with anything that relies on locking to
stay consistent — a password database, an encrypted vault, an Office document — if you
use it on more than one Mac. Opening the same KeePass database on two machines will
not be prevented, and neither machine will know about the other.

grrclone says so in a connection's settings rather than leaving it to be discovered.

See [#41](https://github.com/mlaify/grrclone/issues/41).

## `._` files appear next to almost everything

Files named `._something` show up beside nearly every file written through a mount.
They are AppleDouble sidecars, and they hold extended attributes for filesystems that
cannot store them natively.

NFSv3 cannot. `namedattr`, which would let the server hold them, is NFSv4 only, and
rclone serves NFSv3. macOS attaches `com.apple.provenance` to copies, so even a plain
text file with no tags and no quarantine flag gets one — measured, not assumed.

What was tried and does not work:

- **`--no-appledouble`** is a FUSE mount flag. It does not exist on `serve nfs`.
- **Filters.** Serving with `--exclude ".DS_Store" --exclude "._*"` and then writing
  both still put both on the remote, because filters govern what rclone lists and
  reads, not what the VFS writes back.

The related `.DS_Store` problem **is** solved, and differently: macOS can be told not
to write those to network volumes at all, and grrclone offers that switch in Settings.
Verified — with the preference set, opening a mount in Finder produced neither the
file nor its sidecar, where before it produced both immediately.

Removing existing `._` files is a job for rclone itself, from a terminal.

See [#30](https://github.com/mlaify/grrclone/issues/30).

## A dead backend gives an error, not a hang

grrclone mounts with `soft,timeo=600,retrans=2`. When the server stops answering, I/O
fails after about two minutes instead of retrying forever.

That is a trade, not a free win, and it is worth knowing which side you are on. An
application writing a file when the backend disappears gets an error mid-write, and a
database doing that can be left inconsistent.

The alternative is worse. macOS's default for NFS is `hard,nointr`, which is what
`rclone nfsmount` leaves in place because it hardcodes its mount options. Under that,
a dead backend means every process touching the mount — Finder included — blocks in
uninterruptible sleep, recoverable only by rebooting. That is the failure this project
was built to avoid, and it is documented in the logs of the setup grrclone replaced.

**The exposure is smaller than it sounds**, for a reason worth stating. grrclone serves
with `--vfs-cache-mode full`, so writes land in a local cache first and are uploaded in
the background. An application's write usually completes against the cache even when
the network has gone; what fails is the upload, which rclone retries. Measured with a
server killed under a live mount: an error after **7.1 seconds** and a clean recovery
with no reboot. See [benchmarks.md](benchmarks.md).

See [#42](https://github.com/mlaify/grrclone/issues/42).

## Apple Silicon only

grrclone is built `arm64` only, and the build asserts it. Intel Macs cannot run it.
This is a decision rather than an oversight: Rosetta is removed in macOS 28, and
carrying a second slice buys nothing for a project that started after Apple Silicon.
