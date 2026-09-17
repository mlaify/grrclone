import Foundation

/// Turning on encryption for `rclone.conf`.
///
/// Worth being precise about what this protects, because the surrounding features
/// invite the wrong conclusion. grrclone shows a `SecureField` for a remote's
/// password and has a keychain feature, and a reasonable person concludes the two are
/// connected. They are not.
///
/// Remote credentials live in `rclone.conf` *obscured*, which is obfuscation and not
/// encryption — `rclone reveal <value>` returns the original in one step. So on a
/// machine with an unencrypted config, every remote password, S3 key and OAuth token
/// is readable by anything that can read the file: any process running as that user,
/// any backup, any folder-syncing tool that happens to include `~/.config`.
///
/// Encrypting the config is what makes those credentials actually protected, and the
/// keychain then holds the one password that opens it. Until then, the keychain
/// feature guards something the user does not have.
public enum ConfigEncryption {

    public enum Failure: Error, LocalizedError {
        case alreadyEncrypted
        case commandFailed(String)
        case didNotTake

        public var errorDescription: String? {
            switch self {
            case .alreadyEncrypted:
                return "That configuration is already encrypted."
            case .commandFailed(let detail):
                return "rclone could not encrypt the configuration: \(detail)"
            case .didNotTake:
                return "rclone reported success but the configuration is still readable."
            }
        }
    }

    /// Whether the file on disk is encrypted.
    ///
    /// Read from the file rather than asked of the daemon: a running daemon that has
    /// already been given the password answers questions about the config perfectly
    /// well, so its behaviour says nothing about what is on disk.
    public static func isEncrypted(configPath: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: configPath) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return text.contains("RCLONE_ENCRYPT_V0") || text.contains("Encrypted rclone configuration")
    }

    /// Encrypt the configuration with a new password.
    ///
    /// There is no rc endpoint for this — `config/unlock` exists, nothing sets
    /// encryption — so it runs `rclone config encryption set`, which asks for the new
    /// password twice on stdin.
    ///
    /// Safe to do with mounts up: verified against a live daemon, which kept answering
    /// from its in-memory copy and did not drop anything. The caller should still hand
    /// the password to the running daemon afterwards, so a later re-read does not fail.
    public static func encrypt(rclone: URL, configPath: String, password: String) throws {
        guard !isEncrypted(configPath: configPath) else { throw Failure.alreadyEncrypted }

        let process = Process()
        process.executableURL = rclone
        process.arguments = ["--config", configPath, "config", "encryption", "set"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()

        // Asked for twice: once to set, once to confirm.
        let answer = Data("\(password)\n\(password)\n".utf8)
        input.fileHandleForWriting.write(answer)
        try? input.fileHandleForWriting.close()

        let detail = String(data: (try? output.fileHandleForReading.readToEnd()) ?? Data(),
                            encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.commandFailed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }

        // Check the file rather than the exit status. An encryption step that reports
        // success and leaves the credentials readable is the worst outcome available
        // here, because the user would believe they were protected.
        guard isEncrypted(configPath: configPath) else { throw Failure.didNotTake }
    }
}
