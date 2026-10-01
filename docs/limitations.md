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

## "Server connections interrupted" after five seconds of silence

macOS shows an alert titled "Server connections interrupted". It names the volume and
offers **Ignore** and **Disconnect All**.

It appears far sooner than the two-minute error above. The NFS client marks a server
unresponsive once a request has gone **5 seconds** without a reply
(`sysctl vfs.generic.nfs.client.initialdowndelay`, measured on macOS 27). It shows the
alert from then on until the server answers again. rclone's NFS server replies only when
the storage behind it does, so one slow request to the backend is enough: a big
directory listing, a slow disk, or a slow DNS lookup on the way there.

**Ignore is safe.** Nothing is lost. The volume carries on as soon as the backend
answers, and writes are already in the local cache.

**Disconnect All** force-unmounts the volume. Anything open on it fails. grrclone
notices it is gone and reconnects it at its next check, which happens within five
minutes, on wake, or when you choose Check mounts.

There is no mount option to stop it for a server that is slow but alive. `mutejukebox`
silences a different case, an explicit "try again later" reply that rclone never sends.

**Finding the cause.** The menu marks a volume that is answering slowly. Settings, Logs,
Health decisions records each slow answer, what the probes measured, and whether a
rebuild followed. If the storage's own access log shows requests answered quickly while
the alert fires, the delay is on the way there. In the case that prompted this note it
was DNS: the VPN's first DNS server dropped about one query in three, and each lookup
cost a second or more.

To check yours, first list the DNS servers the Mac is actually using. A VPN usually
replaces them:

```bash
scutil --dns | grep nameserver | sort -u
```

Then test each address it lists, the first one especially, since it is asked first.
Put your storage's host name in place of `your.storage.host`:

```bash
for ns in $(scutil --dns | awk '/nameserver/ {print $3}' | sort -u); do
  lost=0; for i in $(seq 1 20); do dig @$ns your.storage.host +tries=1 +time=1 +noall +stats | grep -q "Query time" || lost=$((lost+1)); done
  echo "$ns lost $lost of 20"
done
```

Any loss above zero is worth fixing, usually by reordering or replacing that server in
the VPN or network settings.

See [#155](https://github.com/mlaify/grrclone/issues/155) and
[#146](https://github.com/mlaify/grrclone/issues/146).

## A stacked, dead mount is hard to remove — and `umount -f` lies about it

macOS lets a mount be placed on top of an existing mount at the same path. A retrying
launchd agent, or repeated sessions of a tool that did not record what it mounted,
can leave the same directory mounted three times over. Only the top layer is
visible; the ones beneath still exist and still have to come off one at a time.

This was observed with three grrclone-fingerprinted NFS mounts stacked on `~/Cloud`,
none of them in grrclone's registry (they predate it). Two things make it worse than
it sounds:

**`diskutil umount force` refuses outright.** DiskArbitration does not handle stacked
NFS well and reports `Unmount failed` without removing anything.

**`umount -f` reports a timeout whether or not it worked.** With the server gone, the
kernel waits for an UNMOUNT reply that never comes, then prints
`Operation timed out`. Sometimes it has unmounted a layer regardless; sometimes it has
not. The message is not evidence either way. **Count the layers after each attempt**
rather than trusting the output:

```bash
mount | grep -cF '/Users/you/Cloud '   # note the trailing space
```

If the count will not go down, the kernel is holding a stale reference and a reboot
clears it faster than anything else will. There is a cleverer route — start any NFS
server on the dead port so the UNMOUNT RPC gets a reply — but it is fiddly enough that
a reboot is the honest recommendation.

grrclone will not remove these for you, because they are not in its registry and it
cannot prove they are not yours. Since 0.7.1 the menu lists a stacked path once with a
`×N` count and the `umount -f` command beside it, and the mount error explains that
what you can see there is another volume — instead of counting the top layer's files
and calling them "existing items". Offering a confirmed one-click cleanup for mounts that carry
grrclone's own fingerprint is tracked as
[#105](https://github.com/mlaify/grrclone/issues/105).

## Apple Silicon only

grrclone is built `arm64` only, and the build asserts it. Intel Macs cannot run it.
This is a decision rather than an oversight: Rosetta is removed in macOS 28, and
carrying a second slice buys nothing for a project that started after Apple Silicon.
