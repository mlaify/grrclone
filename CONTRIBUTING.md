# Contributing to grrclone

Thanks for considering it. grrclone is a small project with a narrow purpose: connect
rclone remotes as Finder volumes on macOS, for free, without a license key, without
telemetry, and without a kernel extension.

## Before you start

Open an issue before writing a large change. The project deliberately keeps a small
surface, and the fastest way to have work rejected is to build something outside it.

**In scope:** mounting, connection lifecycle, reliability, Finder integration, the menu
bar experience, packaging, accessibility, documentation.

**Out of scope, for now:** a file browser, sync and bisync jobs, anything that edits the
user's `rclone.conf` beyond adding remotes they asked for, and any backend-specific
special casing. rclone handles backends; grrclone handles mounting.

## Development setup

You need macOS 14 or later, Xcode 16 or later, and rclone 1.74.4 or later.

```bash
brew install rclone xcodegen
git clone https://github.com/mlaify/grrclone.git
cd grrclone
swift test              # core logic, no Xcode needed
scripts/build-app.sh    # builds grrclone.app
```

The core is plain Swift packages, so most work needs no Xcode project at all. Only the
app target does, and it is generated from `App/project.yml` by XcodeGen. **Do not commit
`grrclone.xcodeproj`** — it is generated and gitignored.

`grrclonectl` is a headless harness for the core. Use it to exercise mounting without the
UI in the way:

```bash
.build/debug/grrclonectl doctor
.build/debug/grrclonectl connect myremote Test
.build/debug/grrclonectl mounts
.build/debug/grrclonectl recovery-test myremote
```

## Rules that are not negotiable

These come from defects that have already bitten this project. Please read
[docs/benchmarks.md](docs/benchmarks.md) before touching mounting code.

**1. Never unmount anything grrclone did not create.** Ownership comes from
`MountRegistry` and nothing else. A user's own `rclone nfsmount` is indistinguishable
from grrclone's in the mount table — same `localhost:/` source, same owner — so matching
on source, port, or process name is never evidence. Getting this wrong force-unmounts
someone's volume, possibly mid-write.

**2. Never block the main actor on anything touching a mount.** `mount`, `diskutil`,
`stat` and friends can block for a long time against a wedged NFS mount. Everything goes
through `Deadline` or `Shell`, off the main actor.

**3. Do not use a task group as a timeout.** It does not work. A task group waits for
every child to finish, and `cancelAll()` cannot resume a task blocked in an
uninterruptible syscall. Use `Deadline`, which runs blocking work on a thread that can
genuinely be abandoned.

**4. Unmount before stopping a server, always.** Killing rclone under a live NFS mount
leaves the kernel talking to a dead server and hangs Finder until the mount is forcibly
removed.

**5. No phone-home.** No telemetry, no analytics, no crash reporting, no update check
that is not explicitly opt-in, and nothing downloaded at runtime. A pull request that
adds an outbound connection to anywhere other than a user-configured storage provider
will be declined. This is the project's reason to exist.

**6. Never write to the user's `rclone.conf` except through rclone's own config API, and
only for changes the user asked for.** People rely on that file from the command line.

## Testing

```bash
swift test
```

Every bug fix needs a regression test. Concentrate tests on the paths where a mistake
destroys data rather than merely failing: ownership scoping, mount point safety, timeout
behaviour, and mount option construction.

Integration tests that actually mount something need a real remote, so they live in
`grrclonectl` rather than the unit suite. If you change mounting, run:

```bash
.build/debug/grrclonectl recovery-test <your-remote>
```

and confirm it ends with `RESULT: recovery works`, leaves no mount behind, and leaves no
rclone process running.

## Style

Follow the surrounding code. A few local conventions:

- Comments explain **why**, especially where the obvious approach is wrong. Several
  comments in this codebase exist because the obvious approach was tried and failed;
  please do not delete them.
- Prefer clear names over short ones.
- User-facing strings are plain sentences. Say what happened and what it means, not an
  error code.

## Commits and pull requests

Write commit messages that explain the reasoning, not just the change. If you fixed a
subtle bug, say what the wrong behaviour was and how it presented.

Keep pull requests focused. One concern per PR.

## Reporting bugs

Include your macOS version, `rclone version`, which remote backend you are using, and
what `grrclonectl mounts` prints. If a mount is stuck, `mount | grep localhost` and the
output of `grrclonectl doctor` help a great deal.

Do not include the contents of your `rclone.conf`. It holds credentials.

## Security

Do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).

## Licence

Contributions are accepted under the [MIT Licence](LICENSE), the same terms as the
project. By submitting a pull request you agree your work may be distributed under it.
