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

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.connections = (try? Self.load(from: url)) ?? []
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
