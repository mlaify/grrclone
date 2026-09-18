import Foundation

/// A timestamped copy of `rclone.conf`, taken before grrclone causes it to be
/// rewritten.
///
/// `config/delete` rewrites the whole file, not just the section being removed. The
/// measured behaviour is good — other remotes survive byte-for-byte and an encrypted
/// file stays encrypted — but "rclone rewrites the file that holds every credential
/// you own" is worth a copy regardless. A full disk or a crash mid-write is a
/// different failure from a refusal, and it is the one with no way back.
///
/// The backup sits beside the original rather than in a grrclone directory, so it is
/// findable by someone who has lost their config and is looking where the config
/// lives, not reading this source.
public enum ConfigBackup {

    public enum Failure: Error, LocalizedError {
        case sourceUnreadable(String)
        case copyFailed(String)
        case verificationFailed

        public var errorDescription: String? {
            switch self {
            case .sourceUnreadable(let path):
                return "Could not read \(path) to back it up."
            case .copyFailed(let detail):
                return "Could not back up the configuration: \(detail)"
            case .verificationFailed:
                return "The configuration backup did not match the original, so "
                     + "grrclone stopped rather than continue without one."
            }
        }
    }

    /// Copy `configPath` alongside itself and prove the copy is faithful.
    ///
    /// Verified by comparing bytes, not by trusting the copy to have succeeded. A
    /// backup nobody checked is a belief, and the moment it matters is the moment
    /// nobody can check it any more.
    @discardableResult
    public static func make(configPath: String,
                            now: Date = Date(),
                            fileManager: FileManager = .default) throws -> URL {
        let source = URL(fileURLWithPath: configPath)
        guard let original = try? Data(contentsOf: source) else {
            throw Failure.sourceUnreadable(configPath)
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        stamp.timeZone = .current
        let name = "\(source.lastPathComponent).grrclone-backup-\(stamp.string(from: now))"

        var destination = source.deletingLastPathComponent().appendingPathComponent(name)
        var attempt = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = source.deletingLastPathComponent()
                .appendingPathComponent("\(name)-\(attempt)")
            attempt += 1
        }

        do {
            try original.write(to: destination, options: .atomic)
        } catch {
            throw Failure.copyFailed(error.localizedDescription)
        }

        // An encrypted config is opaque, so there is nothing sensible to validate
        // about its *contents*. Byte equality is the strongest claim available and
        // the only one that matters: this file can restore the original.
        guard let written = try? Data(contentsOf: destination), written == original else {
            throw Failure.verificationFailed
        }

        // The original's permissions matter here. rclone writes 0600 and a backup of
        // a credential file must not be more readable than the thing it copies.
        if let mode = try? fileManager.attributesOfItem(atPath: source.path)[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: mode],
                                           ofItemAtPath: destination.path)
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: destination.path)
        }

        return destination
    }
}
