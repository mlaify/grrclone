import Foundation

/// Durable record of the mounts grrclone itself created.
///
/// **This type exists for safety, not bookkeeping.** In `mount(8)` output, a mount made
/// by grrclone is indistinguishable from one a user made by hand: both appear as
/// `localhost:/ on /Users/x/Something (nfs, ... mounted by x)`. The development machine
/// for this project runs exactly such a hand-rolled setup, mounting two remotes via a
/// launchd agent.
///
/// A reconciler that force-unmounts every `localhost:/` NFS mount would therefore
/// destroy the user's own volumes, potentially mid-write. So grrclone unmounts a path
/// only if that exact path is recorded here, written before the mount is attempted and
/// removed after a successful unmount. Matching on mount source, port, or process name
/// is never sufficient evidence of ownership.
public actor MountRegistry {
    public struct Entry: Codable, Sendable, Equatable {
        public let connectionID: UUID
        public let mountPoint: String
        public let transport: String
        public let serverID: String?
        public let port: Int?
        public let pid: Int32
        public let createdAt: Date

        public init(connectionID: UUID, mountPoint: String, transport: String,
                    serverID: String?, port: Int?, pid: Int32, createdAt: Date = Date()) {
            self.connectionID = connectionID
            self.mountPoint = mountPoint
            self.transport = transport
            self.serverID = serverID
            self.port = port
            self.pid = pid
            self.createdAt = createdAt
        }
    }

    private let fileURL: URL
    private var entries: [Entry] = []

    /// Set when the registry file exists but could not be read.
    ///
    /// This is not the same as an empty registry, and the difference is the whole
    /// point of the type. An absent file legitimately means "nothing mounted". An
    /// unreadable one means "we do not know what we own" — and since ownership is the
    /// only thing that authorises an unmount, treating it as "nothing" silently
    /// disowns every live mount: `owns()` goes false, `shutdown()` skips them, and
    /// `reconcileOrphans()` returns early on an empty list.
    ///
    /// The realistic trigger is not disk damage but a schema change: add one
    /// non-optional field to `Entry` and every existing record stops decoding.
    private(set) public var loadFailure: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            self.entries = try Self.load(from: fileURL)
        } catch {
            // Keep the unreadable file rather than overwriting it. It is the only
            // record of what might still be mounted, and a human can read JSON.
            self.entries = []
            self.loadFailure = error.localizedDescription
            Self.quarantine(fileURL)
        }
    }

    /// Move an unreadable registry aside so a human can inspect it, and so the next
    /// write starts from a known-empty file instead of failing forever.
    private static func quarantine(_ url: URL) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate]
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp.string(from: Date()))")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("org.mlaify.grrclone", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mounts.json")
    }

    public var all: [Entry] { entries }

    /// Record intent to mount. Called *before* the mount so that a crash between the
    /// mount syscall and the write still leaves a recoverable record.
    public func record(_ entry: Entry) throws {
        entries.removeAll { $0.mountPoint == entry.mountPoint }
        entries.append(entry)
        try persist()
    }

    public func forget(mountPoint: String) throws {
        entries.removeAll { $0.mountPoint == mountPoint }
        try persist()
    }

    public func entry(forMountPoint path: String) -> Entry? {
        entries.first { $0.mountPoint == path }
    }

    public func entry(forConnection id: UUID) -> Entry? {
        entries.first { $0.connectionID == id }
    }

    /// The only sanctioned ownership test. Returns false for anything grrclone did not
    /// record, including a user's own mounts that look identical in `mount(8)`.
    public func owns(mountPoint path: String) -> Bool {
        entries.contains { $0.mountPoint == path }
    }

    // MARK: - Persistence

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        // Atomic, so an interrupted write cannot leave a truncated registry that would
        // make us forget we own a live mount.
        try data.write(to: fileURL, options: .atomic)
    }

    /// Throws when the file exists but cannot be read. Absent is empty; unreadable is
    /// unknown, and the caller must be able to tell them apart.
    private static func load(from url: URL) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Entry].self, from: Data(contentsOf: url))
    }
}
