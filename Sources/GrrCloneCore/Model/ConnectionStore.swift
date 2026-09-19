import Foundation

/// Persists the user's connections.
///
/// Deliberately separate from `rclone.conf`: that file holds credentials and is shared
/// with the rclone CLI, so grrclone reads it but never writes it. A user's existing
/// rclone setup must keep working exactly as before, whether or not this app is
/// installed. Everything here is grrclone's own presentation state.
public actor ConnectionStore {
    private let fileURL: URL
    private var connections: [Connection]

    /// Set when the file exists but could not be read, with where it was moved.
    ///
    /// Not the same as an empty store, and the difference matters more here than
    /// it looks. An earlier version read an undecodable file as `[]`; startup then
    /// adopted every remote in rclone.conf as a fresh connection and persisted,
    /// **overwriting the file it could not read**. Every saved mount name, subpath,
    /// read-only flag and connect-at-login setting was gone, and nothing said so.
    /// The realistic trigger is a schema change, not disk damage — one new
    /// non-optional field on `Connection` and every existing record stops decoding
    /// (#113). Same lesson as `MountRegistry.loadFailure`, applied here.
    public struct LoadFailure: Sendable, Equatable {
        public let reason: String
        /// Where the unreadable file now sits, so a person can read it — it is JSON
        /// — and restore what they had.
        public let quarantinedAt: URL
    }
    private(set) public var loadFailure: LoadFailure?

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        do {
            self.connections = try Self.load(from: url)
        } catch {
            self.connections = []
            let aside = Self.quarantine(url)
            self.loadFailure = LoadFailure(reason: error.localizedDescription, quarantinedAt: aside)
        }
    }

    /// Move an unreadable store aside rather than overwrite it. The next write
    /// starts from a known-empty file; the old one stays for a human to recover.
    private static func quarantine(_ url: URL) -> URL {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp.string(from: Date()))")
        try? FileManager.default.moveItem(at: url, to: aside)
        return aside
    }

    /// Why a save was refused.
    public enum Conflict: Error, LocalizedError, Equatable {
        /// The display name is the mount folder, and two connections must never
        /// resolve to the same one: the second to connect would overwrite the
        /// first's ownership record and, on the failure that follows, forget it
        /// (#112).
        case displayNameTaken(String, by: String)

        public var errorDescription: String? {
            switch self {
            case .displayNameTaken(let name, let other):
                return "The name \"\(name)\" is already used by the connection for "
                     + "\(other). Each connection needs its own, because the name is "
                     + "also its mount folder."
            }
        }
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("org.mlaify.grrclone", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("connections.json")
    }

    public var all: [Connection] { connections }

    public func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    public func upsert(_ connection: Connection) throws {
        if let clash = connections.first(where: {
            $0.id != connection.id && $0.displayName == connection.displayName
        }) {
            throw Conflict.displayNameTaken(connection.displayName, by: clash.remote)
        }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        try persist()
    }

    public func remove(id: UUID) throws {
        connections.removeAll { $0.id == id }
        try persist()
    }

    /// Create a connection for every remote in rclone.conf that does not have one yet,
    /// so a first launch is immediately useful rather than empty.
    ///
    /// A display name that collides with an existing one is suffixed, because the name
    /// becomes a directory under the mount root and two connections must never resolve
    /// to the same mount point.
    @discardableResult
    public func adoptNewRemotes(_ remoteNames: [String]) throws -> [Connection] {
        let known = Set(connections.map(\.remote))
        var added: [Connection] = []

        for name in remoteNames where !known.contains(name) {
            let connection = Connection(remote: name,
                                        displayName: uniqueDisplayName(for: name))
            connections.append(connection)
            added.append(connection)
        }
        if !added.isEmpty { try persist() }
        return added
    }

    func uniqueDisplayName(for base: String) -> String {
        let taken = Set(connections.map(\.displayName))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Persistence

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(connections).write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) throws -> [Connection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Connection].self, from: Data(contentsOf: url))
    }
}
