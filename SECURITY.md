# Security Policy

## Reporting a vulnerability

Please report security issues privately, not as a public issue.

Use GitHub's [private vulnerability reporting](https://github.com/mlaify/grrclone/security/advisories/new)
on this repository. If that is unavailable to you, open an issue saying only that you
have a security report and would like a private channel, with no details.

Please include what an attacker can do, how to reproduce it, and your macOS and rclone
versions. You will get an acknowledgement within a week. This is a small project without
a dedicated security team, so please be patient, and let us agree on disclosure timing
together rather than assuming a fixed window.

## Scope

grrclone runs entirely on the user's own machine. It has no server, no account system,
and no backend. The realistic attack surface is local.

**In scope:**

- Anything that lets another local user or process reach the rclone control socket, or
  read the credentials used to authenticate to it.
- Anything that exposes a user's storage to the network. grrclone's NFS and WebDAV
  servers must bind to loopback only. **rclone's NFS server implements no
  authentication at all**, so a non-loopback bind would publish the user's entire
  storage account to the local network. Report any path that causes one.
- Anything that causes grrclone to unmount, delete, or overwrite data it does not own.
  Ownership is meant to come only from grrclone's own records.
- Credential leakage into logs, crash reports, process arguments, or files readable by
  other users.
- Privilege escalation. grrclone is designed to need no root and installs no privileged
  helper. Any path that gains privilege is a vulnerability.
- Unexpected outbound network connections. grrclone should only ever contact the storage
  providers a user configured.

**Out of scope:**

- Vulnerabilities in rclone itself. Report those to
  [rclone](https://github.com/rclone/rclone/security/policy). If rclone's behaviour
  makes grrclone unsafe as configured, that is in scope here.
- Vulnerabilities in the storage backends you connect to.
- An attacker who already has your user account, your unlocked Mac, or root. grrclone
  cannot defend against that, and does not claim to.
- Denial of service against your own machine by configuring grrclone badly.

## Design notes relevant to security

These are deliberate and may save you time:

- The rclone control API is bound to a **unix socket** with `0600` permissions inside a
  `0700` directory, never to a TCP port, and credentials are random per launch. Nothing
  is reachable over the network, not even loopback.
- `--rc-web-gui` is never passed. It downloads a bundle from GitHub at runtime.
- grrclone runs **unsandboxed** by necessity: it must spawn rclone and invoke
  `/sbin/mount`. It is distributed with Developer ID signing and the hardened runtime
  rather than through the App Store.
- The app **reads** `rclone.conf` but does not write it, so credentials stay under
  rclone's own management.
- No telemetry, no analytics, no crash reporting, and no update check unless a user
  turns one on.

## Supported versions

grrclone is pre-1.0. Only the latest release receives fixes.

grrclone requires **rclone 1.74.4 or later**. Earlier versions have NFS defects that
cause stale file handles, failed file creation, and broken listings of large
directories. Running an older rclone is unsupported.
