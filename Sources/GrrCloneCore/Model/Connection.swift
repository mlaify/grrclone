import Foundation

/// A remote the user has configured for mounting, plus how they want it mounted.
public struct Connection: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// The rclone remote name, without the trailing colon. e.g. `dav1`.
    public var remote: String
    /// Optional subpath within the remote. Empty means the whole remote.
    public var path: String
    /// Display name, also used as the mount directory name.
    public var displayName: String
    public var transport: TransportKind
    public var options: MountOptions
    public var connectAtLogin: Bool

    public init(id: UUID = UUID(), remote: String, path: String = "",
                displayName: String? = nil, transport: TransportKind = .nfs,
                options: MountOptions = .init(), connectAtLogin: Bool = false) {
        self.id = id
        self.remote = remote
        self.path = path
        self.displayName = displayName ?? remote
        self.transport = transport
        self.options = options
        self.connectAtLogin = connectAtLogin
    }

    /// The `remote:path` string rclone expects.
    public var fsSpec: String {
        path.isEmpty ? "\(remote):" : "\(remote):\(path)"
    }

    // MARK: - Validation

    /// Keep a connection name usable as a single folder name.
    ///
    /// The name *is* the folder the remote is mounted in, so a separator in it creates
    /// nested directories — and then the mount point no longer has the shape the rest
    /// of the code assumes, which is how a repair could put a volume back one level
    /// deeper than it found it. Neither `.` nor `..` is a usable folder either.
    ///
    /// Replaced rather than rejected, and the caller shows the result, so the user
    /// sees what was saved instead of being told off.
    public static func sanitisedName(_ raw: String, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return fallback }
        return cleaned
    }

    /// The identity of a folder name as the filesystem sees it.
    ///
    /// macOS volumes are case-insensitive by default and normalise Unicode, so
    /// `Cloud` and `cloud`, or `Café` composed and decomposed, are one directory.
    /// A collision check that compares strings exactly lets two connections resolve
    /// to one folder; this is the key every such check compares instead. It errs
    /// towards refusing: on a case-sensitive volume two names differing only in
    /// case would be distinct folders, and grrclone still treats them as one,
    /// because the cost of that is a renamed connection and the cost of the other
    /// mistake is a stacked mount (#112, Codex review).
    public static func folderKey(_ name: String) -> String {
        // Unicode case folding, not `lowercased()`: `ſ` (long s) lowercases to
        // itself but folds to `s`, so `ſhare` and `Share` are one folder on a
        // case-insensitive volume and were two to a lowercase key. Codex again.
        name.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// Keep a subpath usable as the right-hand side of `remote:path`.
    ///
    /// rclone takes everything after the colon literally:
    ///
    /// - A **leading slash** is removed. `remote:/folder` is an absolute path, which
    ///   some backends accept and others reject outright.
    /// - A **trailing slash** is removed, so the preview does not read `remote:x/`,
    ///   which looks like a mistake.
    /// - `..` and `.` components are dropped. rclone does not resolve them, so a path
    ///   containing one silently points at a directory that does not exist rather
    ///   than at the parent.
    ///
    /// **Colons are kept.** An earlier version stripped them, on the reasoning that
    /// `remote:a:b` would parse as a different remote. That reasoning is wrong:
    /// rclone splits on the *first* colon only, so `dav1:reports:2026` is the
    /// `reports:2026` directory of `dav1`. Verified directly —
    /// `rclone lsf "loc:/tmp/x/reports:2026"` lists that directory's contents. A
    /// backend that allows a colon in a directory name is entitled to have one, and
    /// silently stripping it mounted somewhere else.
    ///
    /// Trimmed rather than refused: none of these is worth rejecting the input over,
    /// and the caller shows what was actually saved.
    public static func sanitisedPath(_ raw: String) -> String {
        let components = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
        return components.joined(separator: "/")
    }
}

public enum TransportKind: String, Codable, Sendable, CaseIterable {
    /// `rclone serve nfs` on loopback, mounted by us with hardened options. The only
    /// transport that ships.
    case nfs

    /// Anything we no longer implement decodes as `nfs` rather than failing.
    ///
    /// `webdav-netfs` was built, measured against NFS and dropped (#27), but stored
    /// connections and hand-edited files still carry the string. Decoding it to a case
    /// with no transport behind it produced a connection that threw "No transport
    /// available" forever, with no UI to change it back — while `reconcileOrphans()`
    /// coerced the same value to `.nfs`, so the two paths disagreed about what the
    /// stored value meant.
    ///
    /// Coercing here settles it in one place, and the next save rewrites the file with
    /// the current value.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TransportKind(rawValue: raw) ?? .nfs
    }
}

/// Per-connection tunables. These map onto rclone's `vfs` and `nfs` option blocks, the
/// only two that `serve/start` accepts per server.
///
/// Notably absent: `attr_timeout`, `transfers` and `checkers`. The first belongs to
/// rclone's `mount` block and applies only to FUSE mounts, so it does nothing for an
/// NFS server. The latter two are process-global and live on `DaemonSettings`.
/// Passing any of them to `serve/start` is rejected outright with
/// `unknown parameters`.
public struct MountOptions: Codable, Sendable, Equatable {
    public var readOnly: Bool
    public var vfsCacheMode: String
    public var vfsCacheMaxAge: String
    public var vfsCacheMaxSize: String
    public var dirCacheTime: String
    public var vfsWriteBack: String
    public var pollInterval: String
    /// `disk` keeps NFS file handles valid across an rclone restart, which is what stops
    /// Finder reporting "Stale NFS file handle" as a permissions error. `symlink` is
    /// Linux-only and must never be offered here.
    public var nfsCacheType: String

    public init(readOnly: Bool = false,
                vfsCacheMode: String = "full",
                vfsCacheMaxAge: String = "24h",
                vfsCacheMaxSize: String = "20G",
                dirCacheTime: String = "30s",
                vfsWriteBack: String = "5s",
                pollInterval: String = "1m",
                nfsCacheType: String = "disk") {
        self.readOnly = readOnly
        self.vfsCacheMode = vfsCacheMode
        self.vfsCacheMaxAge = vfsCacheMaxAge
        self.vfsCacheMaxSize = vfsCacheMaxSize
        self.dirCacheTime = dirCacheTime
        self.vfsWriteBack = vfsWriteBack
        self.pollInterval = pollInterval
        self.nfsCacheType = nfsCacheType
    }
}

/// Process-wide rclone settings. These are command-line flags on the daemon because
/// rclone treats them as global, not per-server.
public struct DaemonSettings: Codable, Sendable, Equatable {
    /// How much the daemon says.
    ///
    /// `NOTICE` is the default because a quiet log is a readable one, and rclone at
    /// `INFO` narrates every file operation. `DEBUG` exists for diagnosing a specific
    /// failure and is not somewhere to leave a machine: it is loud, and it is the
    /// level at which rclone prints request detail that can include credentials.
    /// `DaemonLog` redacts what it recognises, but the less that is written the less
    /// there is to get wrong.
    public enum LogLevel: String, Codable, Sendable, CaseIterable {
        case error = "ERROR"
        case notice = "NOTICE"
        case info = "INFO"
        case debug = "DEBUG"
    }

    public var logLevel: LogLevel
    public var transfers: Int
    public var checkers: Int
    /// Root for rclone's own caches. rclone namespaces per remote beneath this itself.
    public var cacheDirectory: URL

    public init(transfers: Int = 8, checkers: Int = 16, cacheDirectory: URL? = nil,
                logLevel: LogLevel = .notice) {
        self.transfers = transfers
        self.checkers = checkers
        self.logLevel = logLevel
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.mlaify.grrclone", isDirectory: true)
    }
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case mounted(at: URL)
    case failed(String)

    public var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }
}
