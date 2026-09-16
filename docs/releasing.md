# Releasing

Tagging builds, signs, notarises and publishes a DMG. The workflow runs the same
`scripts/release.sh` used locally, so a release from CI and one from a laptop are the
same artefact produced the same way.

```bash
git tag -s v0.1.0 -m "grrclone 0.1.0"
git push origin v0.1.0
```

`workflow_dispatch` can rebuild an existing tag. The tag must match `v<version>`; the
workflow refuses anything else rather than interpolating a free-text field into a git
ref or a shell command.

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
