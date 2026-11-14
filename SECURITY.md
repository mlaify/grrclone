# Security reporting

This repository follows the
[mlaify organization-wide security reporting policy](https://github.com/mlaify/.github/blob/main/SECURITY.md).
That policy defines the reporting channel, maintainer limits, unsupported environments, and the
absence of payment, rewards, swag, response commitments, or remediation commitments.

Use this repository's **Security** tab and select **Report a vulnerability** for a credible,
confidential vulnerability in grrclone. Use a public issue for ordinary bugs, rclone-provider
compatibility problems, installation failures, feature requests, and documentation corrections.

Include what an attacker can do, safe reproduction steps, and the affected macOS, grrclone, and
rclone versions.

## Scope

grrclone is a macOS application that runs entirely on the user's own machine. It has no server,
account system, or backend. The realistic attack surface is local.

**In scope:**

- A path that lets another local user or process reach the rclone control socket or read its
  authentication credentials.
- A path that exposes a user's storage to the network. grrclone's NFS and WebDAV servers must
  bind to loopback only. rclone's NFS server has no authentication, so a non-loopback bind would
  publish the user's storage account to the local network.
- Unmounting, deleting, or overwriting data grrclone does not own.
- Credential leakage into logs, crash reports, process arguments, or files readable by other
  users.
- Privilege escalation. grrclone is designed to need no root and installs no privileged helper.
- Unexpected outbound network connections. grrclone should contact only storage providers the
  user configured.

**Out of scope:**

- Vulnerabilities in rclone itself. Report those to
  [rclone](https://github.com/rclone/rclone/security/policy). A distinct vulnerability caused by
  grrclone's configuration of rclone remains in scope here.
- Vulnerabilities in configured storage backends.
- An attacker who already controls the user's account, unlocked Mac, or root.
- Denial of service against the user's own machine through an unsafe local configuration.

## Design notes relevant to security

- The rclone control API is bound to a Unix socket with `0600` permissions inside a `0700`
  directory. Credentials are random per launch.
- `--rc-web-gui` is never passed because it downloads a bundle from GitHub at runtime.
- grrclone runs unsandboxed because it must spawn rclone and invoke `/sbin/mount`.
- The app reads `rclone.conf` but does not write it.
- There is no telemetry, analytics, crash reporting, or update check unless a user enables one.

## Supported versions

grrclone is pre-1.0. Only the latest release is considered for fixes.

grrclone requires rclone 1.74.4 or later. Earlier versions are unsupported.
