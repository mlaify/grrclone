# Migrating from a hand-rolled rclone mount

If you already mount rclone remotes with a launchd agent and a shell script, grrclone
can take over **without moving your mount points**. Your paths, your remotes and your
`rclone.conf` stay as they are.

This was written from doing it. There are two setups it covers, and **the teardown
differs**, so check which one you have before following anything below:

| | How to tell | Teardown |
|---|---|---|
| **`nfsmount`** | the script calls `rclone nfsmount` | `launchctl unload`; `umount` may hang |
| **serve + mount** | the script calls `rclone serve nfs` and `/sbin/mount` | `launchctl bootout`; unmount is clean |

The second is what `interserver`'s `clients/macos/install.sh` installs, and it has an
uninstaller — `clients/macos/uninstall.sh` — which does the whole teardown in the
right order and checks for unfinished uploads first. **If you have that setup, run it
and skip to step 3.**

## Before you start

**Check the Mac can run grrclone.** Apple Silicon and macOS 14 or later.

```bash
uname -m            # must print arm64
sw_vers -productVersion
```

If `uname -m` prints `x86_64`, stop — grrclone does not run on Intel, and the existing
setup is the right thing to keep.

**Check nothing is mid-upload.** The old script stages writes in a VFS cache and
uploads them in the background, so a file you saved a minute ago may not be on the
server yet. Unmounting takes the cache with it.

Do not count files in the cache — in `full` mode it holds everything that has been
*read* as well as everything waiting to be *written*, so it looks alarming when nothing
is wrong. rclone records the answer itself: each cached file has a JSON companion with
a `Dirty` flag, and `true` means the server has not got those changes yet.

```bash
# the interserver setup
grep -rl '"Dirty": true' ~/Library/Caches/rclone-mounts/*/vfsMeta 2>/dev/null

# the older nfsmount setup
grep -rl '"Dirty": true' ~/Library/Caches/rclone/vfs/*/vfsMeta 2>/dev/null
```

No output means everything written locally has reached the server. If there is output,
leave the mounts up for a few minutes and look again.

## 1. Find what is actually there

Do not assume it matches another machine.

```bash
ls ~/Library/LaunchAgents/ | grep -i rclone
cat ~/.local/bin/rclone-mounts.sh 2>/dev/null
mount | grep -i nfs
rclone listremotes
```

Note the **remote names** and the **mount paths** the script uses. You will reproduce
both in grrclone, and getting them wrong is the difference between a swap and a
migration.

## 2. Stop the old setup

Stop the agent first, or launchd will restart the script the moment you unmount —
`KeepAlive` is set, with a fifteen second throttle.

Which command depends on how it was loaded. `bootout` is right for anything installed
with `bootstrap`, which is what the interserver installer uses; `unload` is the older
form. Trying both is harmless:

```bash
launchctl bootout "gui/$(id -u)/xyz.matthewd.rclone-mounts" 2>/dev/null \
  || launchctl unload ~/Library/LaunchAgents/xyz.matthewd.rclone-mounts.plist
```

Move the plist aside rather than deleting it, so this is reversible:

```bash
mv ~/Library/LaunchAgents/xyz.matthewd.rclone-mounts.plist \
   ~/Library/LaunchAgents/xyz.matthewd.rclone-mounts.plist.disabled-$(date +%Y%m%d)
cp ~/.local/bin/rclone-mounts.sh ~/.local/bin/rclone-mounts.sh.backup-$(date +%Y%m%d)
```

Then unmount:

```bash
umount ~/Cloud ~/CloudVaults
```

If that hangs or reports "resource busy", you are on the `nfsmount` variant: it
produces a **hard, non-interruptible** mount, so a wedged backend blocks `umount`
indefinitely. The serve + mount variant already uses soft mounts and should unmount
cleanly. Either way, force it:

```bash
diskutil umount force ~/Cloud
diskutil umount force ~/CloudVaults
```

Then stop the rclone servers — **after** the unmount, never before. Killing rclone
while a mount it serves is still live leaves the kernel talking to a dead server, which
is what wedges Finder.

```bash
pkill -f 'rclone serve nfs'
```

Confirm nothing is left:

```bash
mount | grep -c localhost   # expect 0
pgrep -fl rclone            # expect nothing
```

## 3. Install grrclone

```bash
brew install --cask mlaify/tap/grrclone
open -a grrclone
```

It appears in the menu bar with no Dock icon and lists the remotes it finds in
`rclone.conf`. It **reads** that file and never writes it, so the command line setup
keeps working exactly as before.

## 4. Put the mounts back where they were

Two settings, and the order does not matter.

**The mount folder.** Settings → General → Mount folder → Change… By default
connections are mounted under `~/grrclone`. To reproduce `~/Cloud` and
`~/CloudVaults`, choose your **home folder**.

**The connection names.** Settings → Connections. The name is also the folder name, so
`dav1` must be renamed to `Cloud` and `vaults` to `CloudVaults`. Press Apply.

Then connect each one from the menu, and turn on **Connect at login** in its settings
so they come back after a reboot — that is what the launchd agent used to do.

## 5. Verify

```bash
mount | grep 'on /Users'
ls ~/Cloud | head
ls ~/CloudVaults | head
```

Expect both paths mounted, and both listing their contents.

Now check the mount options, which is the substantive difference from the old setup.
Use `nfsstat -m`, **not** `mount` — `mount` prints only `nfs, nodev, nosuid` and tells
you nothing about whether the mount is soft:

```bash
nfsstat -m
```

Look for `soft`, `intr`, `locallocks` and `nfc` on the `NFS parameters:` line:

```
NFS parameters: tcp,port=50247,mountport=50247,soft,intr,locallocks,
                rsize=131072,wsize=131072,timeo=600,retrans=2,nfc
```

`soft` with `timeo=600,retrans=2` means a dead backend returns an error after about
two minutes instead of hanging Finder until you reboot. The old `rclone nfsmount`
setup could not set these — it hardcodes its option list — which is why a dead server
used to wedge the machine.

Round-trip a file to be sure writes reach the server:

```bash
date > ~/Cloud/migration-test.txt
sleep 10
cat ~/Cloud/migration-test.txt && rm ~/Cloud/migration-test.txt
```

## 6. Once you are happy

Leave the disabled plist and the script backup alone for a week or so. If something is
wrong, reverting is `launchctl load` on the renamed plist after quitting grrclone.

## What changes, and what does not

**Does not change:** your remotes, your `rclone.conf`, your mount paths, your files.

**Changes for the better:** mounts are soft and interruptible, so a dead backend cannot
wedge Finder; mounts repair themselves after sleep and network changes; an unmounted
folder is left unwritable, so nothing can write into it and be hidden by the next
mount; an unclean shutdown is reported rather than silently cleaned up.

**Worth knowing:** file locks are satisfied locally. Two Macs can each believe they
hold an exclusive lock on the same file, so take care with a KeePass database or a
Cryptomator vault opened in two places. This was true of the old setup too — it is a
limitation of what rclone's NFS server can offer, not a regression — but grrclone says
so in connection settings rather than leaving you to find out.

## If the Mac cannot run grrclone

Intel Macs, or anyone not ready to switch, should still replace `rclone nfsmount` with
a serve-and-mount script that sets safe options. The hard-mount problem is worth
fixing regardless of which client you use.
