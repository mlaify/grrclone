import Foundation

/// Unlocking an encrypted `rclone.conf`.
///
/// rclone can encrypt its configuration file. When it is encrypted, rclone wants the
/// password on a terminal — and a menu bar app has no terminal, which produces two
/// distinct failures depending on how the daemon was launched. Both were reproduced
/// against rclone 1.75.1 before this was written:
///
/// 1. **Left to prompt**, with stdin not a terminal, the *daemon starts normally* and
///    then panics on the first call that reads the config:
///    `panic received: fatal error: Failed to read line: EOF`. Nothing in that message
///    mentions encryption, so the app reported an internal error and the user had no
///    way to know their config simply needed a password.
/// 2. **With `--ask-password=false`**, the same call fails with a legible
///    `unable to decrypt configuration and not allowed to ask for password`.
///
/// grrclone therefore always passes `--ask-password=false` — see `DaemonSupervisor` —
/// which turns an opaque panic into a condition this file can recognise and act on.
///
/// The password is then supplied over the rc API with `config/unlock`.
extension RcloneRCClient {

    /// Paths rclone is actually using. Works while the config is still locked, which is
    /// what makes it usable for finding the config file before it can be read.
    public struct ConfigPaths: Sendable, Equatable {
        public let config: String
        public let cache: String
        public let temp: String
    }

    public func configPaths() async throws -> ConfigPaths {
        let result = try await call("config/paths")
        return ConfigPaths(config: result["config"]?.stringValue ?? "",
                           cache: result["cache"]?.stringValue ?? "",
                           temp: result["temp"]?.stringValue ?? "")
    }

    /// Whether the config can be read right now.
    ///
    /// Probing with a real call is the only reliable test. There is no endpoint that
    /// reports lock state, and the file being encrypted on disk does not mean this
    /// daemon is locked out of it — a password supplied earlier in the session stays
    /// in effect.
    public func isConfigLocked() async -> Bool {
        do {
            _ = try await listRemotes()
            return false
        } catch {
            return Self.isLockedError(error)
        }
    }

    /// Supply the password for an encrypted config.
    ///
    /// **`config/unlock` does not report whether the password was right.** Verified
    /// against rclone 1.75.1: a wrong password returns HTTP 200 and an empty object,
    /// exactly as a correct one does. Taking that at face value would have the app
    /// report success and then fail on the next call with an error the user could not
    /// connect to what they just typed — and, worse, save a wrong password to the
    /// Keychain and reuse it at every launch.
    ///
    /// So the result is verified by reading the config afterwards, and it is that read
    /// which decides. A rejected password throws `configPasswordRejected`.
    ///
    /// Safe to call when already unlocked: a later wrong password does not re-lock a
    /// config that is already open (also verified).
    public func unlockConfig(password: String) async throws {
        _ = try await call("config/unlock", ["configPassword": .string(password)])

        do {
            _ = try await listRemotes()
        } catch {
            if Self.isLockedError(error) { throw RcloneRCError.configPasswordRejected }
            throw error
        }
    }

    /// Recognise the failure that means "the config is encrypted and I cannot read it".
    ///
    /// Matched on the message because rclone reports this as a generic HTTP 500 with no
    /// machine-readable code. Both observed forms are matched, not only the one produced
    /// by our own launch flags: a user running a Homebrew rclone under a wrapper that
    /// re-enables prompting would otherwise hit the panic form and get no explanation.
    public static func isLockedError(_ error: Error) -> Bool {
        let text = "\(error)".lowercased() + " " + (error.localizedDescription).lowercased()
        if text.contains("unable to decrypt configuration") { return true }
        // The panic form. Qualified by "config", since a bare EOF could be anything.
        if text.contains("failed to read line: eof") && text.contains("config") { return true }
        return false
    }
}
