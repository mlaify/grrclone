# Releasing

Tagging builds, signs, notarises and publishes a DMG. The workflow runs the same
`scripts/release.sh` used locally, so a release from CI and one from a laptop are the
same artefact produced the same way.

**Bump `MARKETING_VERSION` in `App/project.yml` first**, in its own commit. The tag is
only a label: nothing else makes the app report the version you are releasing, so
without this the About box, Finder's Get Info and every crash report would still name
the previous one. The workflow now checks the two agree and fails before signing
anything if they do not, so this is enforced rather than remembered.

```bash
git tag -s v0.1.0 -m "grrclone 0.1.0"
git push origin v0.1.0
```

A pre-release suffix belongs to the tag alone: `v0.2.0-rc1` and `v0.2.0` both expect
`MARKETING_VERSION` to be `0.2.0`.

`workflow_dispatch` can rebuild an existing tag. The tag must match `v<version>`; the
workflow refuses anything else rather than interpolating a free-text field into a git
ref or a shell command.

**Launch a dispatch from the tag, not from a branch.** GitHub offers tags in the same
"Use workflow from" dropdown as branches. The build honours the tag you type into the
input, but the provenance attestation takes its source commit from the *event* — so a
rebuild of v0.1.0 started from `main` would publish v0.1.0's DMG carrying provenance
naming `main`'s HEAD. That attestation would be cryptographically valid and factually
wrong, which is worse than none, so the workflow refuses when the two disagree.

## One-time setup

The workflow needs six secrets in a repository **environment named `release`**, not in
plain repository secrets. An environment can require a reviewer before the job starts,
which matters here: this is the only job that can read the signing certificate.

Settings → Environments → New environment → `release`.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of `~/.config/grrclone-signing/developer-id.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the password set when that `.p12` was exported |
| `MACOS_SIGN_IDENTITY_SHA1` | contents of `~/.config/grrclone-signing/identity` |
| `KEYCHAIN_PASSWORD` | any strong string; it only protects a throwaway CI keychain |
| `APPSTORE_API_KEY_P8` | base64 of the App Store Connect `AuthKey_XXXXXXXXXX.p8` |
| `APPSTORE_API_KEY_ID` | the ten characters from that filename |
| `APPSTORE_API_ISSUER` | the issuer UUID from App Store Connect → Users and Access → Integrations. **Not** the Team ID |

Generating the two base64 values:

```bash
base64 -i ~/.config/grrclone-signing/developer-id.p12 | pbcopy   # then paste
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

Produce the `.p12` with **`scripts/export-p12.sh`**, never a bare `openssl pkcs12
-export`. OpenSSL 3 defaults to a SHA-256 MAC, which macOS cannot read, and reports as:

```
SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
```

The password is not the problem. The script writes a SHA-1 MAC with 3DES and then
proves the file imports into a throwaway keychain before you upload it — a check added
after an unverified `.p12` reached a repository secret and failed a release.

## What the workflow does, and why

- **Tag pushes only, never `pull_request`.** The job can read the signing certificate,
  and a pull request from a fork must never be able to run it.
- **An ephemeral keychain**, deleted in an `always()` step. Importing into the runner's
  default keychain would leave the private key in the image cache if the job failed
  before cleanup.
- **`security set-key-partition-list`** after import. Without it `codesign` blocks on a
  UI prompt nobody can answer and the job hangs until it times out.
- **Both the app and the disk image are notarised and stapled.** Each needs its own
  ticket: stapling the app keeps it trusted once dragged out of the image, stapling the
  image satisfies Gatekeeper before anything is copied.
- **The final check applies a quarantine attribute before asking `spctl`.** Assessing a
  local file can pass something a real download would not; this is what caught an
  unsigned disk image that notarisation alone had made look fine.

## Build provenance

Every release carries a [Sigstore](https://www.sigstore.dev)-signed provenance
statement, logged publicly to Rekor, binding the DMG's SHA-256 to the repository,
commit, workflow and runner that produced it. Anyone can check it without trusting
us or this document:

```bash
gh attestation verify grrclone.dmg --repo mlaify/grrclone
```

It answers a different question from notarisation, and neither replaces the other.
Notarisation says Apple scanned a build signed by our Developer ID; provenance says
*which commit and which workflow* produced that exact file. A stolen signing
certificate defeats the first and not the second.

The step runs before the publish step and against the same file it uploads, so the
digest attested is by construction the digest released. Attesting afterwards would
leave a window in which the two could differ.

It needs `id-token: write` (for the OIDC token Sigstore signs with) and
`attestations: write` on the workflow. Both are at the top of `release.yml`; the job
is already restricted to tag pushes.

## Verifying a published release

```bash
xattr -w com.apple.quarantine "0083;00000000;Safari;" ~/Downloads/grrclone.dmg
spctl -a -vvv -t open --context context:primary-signature ~/Downloads/grrclone.dmg
```

`source=Notarized Developer ID` is the answer you want. Anything else means a user
sees a warning.

## The certificate expires 2027-02-01

Sooner than the usual five years, most likely capped by the membership renewal date.
Builds signed after it expires will not be trusted, so renew before then and update
`MACOS_CERTIFICATE_P12` and `MACOS_SIGN_IDENTITY_SHA1`.

## Homebrew, and why the app does not update itself

Two updaters cannot own one app bundle, and pretending otherwise is how people end up
downgraded.

Homebrew records the version it installed. An app that replaces its own bundle makes
that record a lie: `brew list --cask grrclone` reports the old version, and the next
`brew upgrade` cheerfully reinstalls over the top — which downgrades anyone who had
moved ahead, and is especially likely for someone running a pre-release.

Homebrew has a stanza for apps that do update themselves, `auto_updates true`, which
makes `brew upgrade` leave them alone unless run with `--greedy`. **grrclone's cask
deliberately does not use it**, because grrclone genuinely does not install its own
updates:

- It can be asked to *check* GitHub for a new release. That is off by default and is
  the only outbound connection it makes that is not to the user's own storage.
- It never downloads or installs a new version. Doing that means verifying a signature
  on a downloaded bundle and swapping a running app — a large attack surface to add to
  a program that mounts your storage, and work Homebrew already does properly.

So the division is clean: **Homebrew installs, grrclone informs.** The Updates tab
detects a Homebrew installation from the Caskroom and says `brew upgrade --cask
grrclone` instead of offering a download.

### For users who will never run a command

grrclone does not install its own updates, and that is settled — see #97 for the
design that was considered and the reasons against it. The gap it leaves is real
though: someone who never opens the app and never runs brew hears nothing.

Two things close most of it, in order of how little they ask of the user:

1. **`brew autoupdate`** — a third-party tap, not part of Homebrew, that installs a
   launchd agent to run `brew update` and optionally `brew upgrade` on a schedule:

   ```bash
   brew tap domt4/autoupdate
   brew autoupdate start --upgrade
   ```

   The only mechanism here that works with grrclone closed. Two caveats to state
   whenever recommending it: the tap must be added first — the subcommand does not
   exist on a stock install — and `--upgrade` upgrades **everything** Homebrew
   manages, not just grrclone.
2. **grrclone's own notification** — asks GitHub once a day while running, marks the
   menu bar icon, and posts a notification. Reaches anyone whose app is running,
   which for a login item is most people, but not someone who quit it.

Neither replaces the other and neither is on by default.

### Pre-releases

One cask serves one channel; there is no per-user opt-in to pre-releases within a
cask. The Homebrew convention is a second cask with its own token — `firefox@beta`,
`iterm2@beta` — so a pre-release channel would be `grrclone@pre`, submitted and
versioned separately.

Until that exists, a Homebrew user who turns on "Include pre-releases" is told what it
means: the check will find release candidates, but installing one means downloading it
from the releases page, and that replaces the copy Homebrew is tracking. The app says
so rather than letting them discover it from a surprising `brew upgrade`.

`scripts/make-cask.sh <tag>` generates the cask with the real checksum of the
published DMG, and refuses pre-release tags for exactly this reason.
