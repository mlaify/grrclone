import Foundation

/// Why a volume was rebuilt, left alone, or reported — kept on disk.
///
/// The daemon's log is in memory and holds rclone's view; it says a new NFS server
/// started, never why. On 2026-09-25 CloudVaults was rebuilt while the server's own
/// log showed every request answered in a tenth of a second, and nothing on the Mac
/// could say whether a timer, a wake or a click had done it (#154). This answers
/// that: one line per decision, with the trigger, each probe's result and how long
/// it took, and the upload count that was weighed.
///
/// Only decisions. A healthy pass every five minutes is not written, or the file
/// would be all noise. Your own connects and disconnects are, because "did I click
/// something?" is the first question when a volume changed.
///
/// Nothing sensitive: the volume's display name and mount point, never a remote's
/// configuration, URL or credential.
public actor HealthLog {

    public enum Trigger: Sendable, Equatable, CustomStringConvertible {
        case timer
        case daemonExit
        case menu
        case system(String)
        case user
        case unspecified

        public var description: String {
            switch self {
            case .timer: return "timer"
            case .daemonExit: return "rclone-exited"
            case .menu: return "check-mounts"
            case .system(let why): return why.replacingOccurrences(of: " ", with: "-")
            case .user: return "you"
            case .unspecified: return "other"
            }
        }
    }

    public let fileURL: URL
    private let maxBytes: Int

    /// Default location: `~/Library/Logs/org.mlaify.grrclone/health.log`.
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/org.mlaify.grrclone/health.log")
    }

    /// - Parameter maxBytes: past this the file is moved to `health.1.log`, replacing
    ///   any older one, and a new file begins. Two files at most, so it cannot grow
    ///   without bound.
    public init(fileURL: URL = HealthLog.defaultURL(), maxBytes: Int = 256 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    public func record(_ trigger: Trigger, volume: String, mountPoint: String,
                       outcome: String, detail: String = "", at date: Date = Date()) {
        let stamp = ISO8601DateFormatter().string(from: date)
        var line = "\(stamp)  \(trigger)  \(Self.clean(volume))  \(Self.clean(outcome))  \(Self.clean(mountPoint))"
        if !detail.isEmpty { line += "  — \(Self.clean(detail))" }
        append(line + "\n")
    }

    /// The newest lines, oldest first, at most `limit`.
    public func recent(limit: Int = 50) -> [String] {
        let files = [rotatedURL, fileURL]
        let lines = files.flatMap { url -> [String] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        // By timestamp, not append order. A health pass writes its decisions when it
        // finishes, and a connect you made during it is written at once, so append
        // order can put an earlier decision after a later click (Codex, on review).
        // ISO 8601 in UTC sorts as text; the sort is stable for equal stamps.
        let sorted = lines.enumerated().sorted { a, b in
            let ka = a.element.prefix(while: { $0 != " " }), kb = b.element.prefix(while: { $0 != " " })
            return ka == kb ? a.offset < b.offset : ka < kb
        }.map(\.element)
        return Array(sorted.suffix(limit))
    }

    private var rotatedURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("health.1.log")
    }

    private func append(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? Int, size >= maxBytes {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: fileURL, to: rotatedURL)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// One line per event, whatever a name contains.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}
