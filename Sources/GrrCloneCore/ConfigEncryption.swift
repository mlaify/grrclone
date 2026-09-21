import Foundation
import RcloneRC

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
        case unknownConfigPath
        case cannotReadConfig(String)

        public var errorDescription: String? {
            switch self {
            case .unknownConfigPath:
                return "grrclone could not determine where your rclone configuration "
                     + "lives, so it will not try to encrypt it."
            case .cannotReadConfig(let path):
                return "Could not read \(path), so grrclone cannot tell whether it is "
                     + "already encrypted."
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
    /// Nil when the file cannot be read at all.
    ///
    /// "Unreadable" is not "plaintext". Answering a question the UI presents as a
    /// security state with a confident `false` means offering to encrypt a
    /// configuration that may already be encrypted, on no evidence. Compare
    /// `ConnectionManager.Activity.unreachable`, which exists so "we could not ask"
    /// is never reported as "nothing pending".
    public static func encryptionState(configPath: String) -> Bool? {
        guard !configPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: configPath) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256),
              let text = String(data: head ?? Data(), encoding: .utf8) else { return nil }
        return text.contains("RCLONE_ENCRYPT_V0") || text.contains("Encrypted rclone configuration")
    }

    /// Convenience for the paths that genuinely only care whether it is *known* to be
    /// encrypted. An unknown answer is false here, so never use this to decide that
    /// encrypting is safe — use `encryptionState` and handle nil.
    public static func isEncrypted(configPath: String) -> Bool {
        encryptionState(configPath: configPath) == true
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
    ///
    /// Async, and bounded. The process is driven from a Dispatch thread under a
    /// deadline, so a caller on the main actor is never blocked by it, and an
    /// rclone that asks an unexpected question on stdin — which this would wait on
    /// forever — is terminated and reported instead (#118).
    public static func encrypt(rclone: URL, configPath: String, password: String,
                               timeout: TimeInterval = 60) async throws {
        // Refuse rather than guess. An empty path would become `rclone --config ""`,
        // which aims a real password at an unintended target; an unreadable one means
        // we cannot know whether we are about to double-encrypt. See #79, #80.
        guard !configPath.isEmpty else { throw Failure.unknownConfigPath }
        guard let encrypted = encryptionState(configPath: configPath) else {
            throw Failure.cannotReadConfig(configPath)
        }
        guard !encrypted else { throw Failure.alreadyEncrypted }

        let process = Process()
        process.executableURL = rclone
        process.arguments = ["--config", configPath, "config", "encryption", "set"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        // Exit is observed through a handler installed *before* `run()`, signalling
        // a semaphore, never through `waitUntilExit()`. The first async version
        // called `waitUntilExit()` from the Dispatch thread `Deadline` runs work on,
        // and under the full test suite — other tests' child processes coming and
        // going — it intermittently never returned, so a two-second encryption hit
        // the sixty-second deadline. Not reproducible in isolation, which is the
        // signature of a run-loop-on-a-worker-thread problem. A handler and a
        // semaphore have no run loop to be starved of.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Asked for twice: once to set, once to confirm.
        let answer = Data("\(password)\n\(password)\n".utf8)
        let finished: (status: Int32, detail: String)? = await Deadline.run(seconds: timeout) {
            input.fileHandleForWriting.write(answer)
            try? input.fileHandleForWriting.close()
            // Read to EOF first: the child's stdout closes at exit, and reading before
            // waiting means a chatty child cannot block on a full pipe.
            let detail = String(data: (try? output.fileHandleForReading.readToEnd()) ?? Data(),
                                encoding: .utf8) ?? ""
            guard exited.wait(timeout: .now() + timeout) == .success else { return nil }
            return (process.terminationStatus, detail)
        } ?? nil
        guard let finished else {
            process.terminate()
            throw Failure.commandFailed("rclone did not finish within \(Int(timeout))s")
        }

        guard finished.status == 0 else {
            throw Failure.commandFailed(finished.detail.isEmpty ? "exit \(finished.status)" : finished.detail)
        }

        // Check the file rather than the exit status. An encryption step that reports
        // success and leaves the credentials readable is the worst outcome available
        // here, because the user would believe they were protected.
        guard isEncrypted(configPath: configPath) else { throw Failure.didNotTake }
    }
}
