import Foundation

/// Typed client for the subset of rclone's remote-control API that grrclone uses.
///
/// Deliberately absent: `mount/mount` and `mount/unmount`. rclone's own mount paths
/// hardcode their NFS mount options, which produces a hard, non-interruptible mount
/// that wedges Finder when the backend dies. grrclone starts a server with
/// `serve/start` and performs the mount itself. See docs/benchmarks.md.
public actor RcloneRCClient {
    private let http: UnixSocketHTTP
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String, user: String, password: String) {
        self.http = UnixSocketHTTP(socketPath: socketPath, user: user, password: password)
    }

    // MARK: - Raw call

    @discardableResult
    public func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let body = try encoder.encode(params)
        let data = try await http.post(path: "/\(method)", body: body)
        guard !data.isEmpty else { return .object([:]) }
        return try decoder.decode(JSONValue.self, from: data)
    }

    // MARK: - Core

    public struct Version: Sendable {
        public let version: String
        /// Parsed `(major, minor, patch)`, for comparing against the minimum we support.
        public let components: (Int, Int, Int)

        /// rclone versions below 1.74.4 have NFS defects that matter to us: missing EOF
        /// flags in READ responses, no `--vfs-handle-caching`, file creation failing for
        /// want of Mknod, ESTALE from unstable inode numbers, and broken listings of
        /// large directories.
        public static let minimumSupported = (1, 74, 4)

        public var meetsMinimum: Bool {
            components >= Version.minimumSupported
        }
    }

    public func version() async throws -> Version {
        let result = try await call("core/version")
        let raw = result["version"]?.stringValue ?? ""
        return Version(version: raw, components: Self.parseVersion(raw))
    }

    /// Parses rclone's `v1.75.1` form. Missing or non-numeric components read as 0, so a
    /// string we cannot parse compares as older than the minimum and is rejected rather
    /// than optimistically accepted.
    static func parseVersion(_ raw: String) -> (Int, Int, Int) {
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let numeric = trimmed.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".").map { Int($0) ?? 0 }
        return (parts.count > 0 ? parts[0] : 0,
                parts.count > 1 ? parts[1] : 0,
                parts.count > 2 ? parts[2] : 0)
    }

    public func quit() async throws {
        // core/quit terminates the daemon, so the response is never delivered. Anything
        // thrown here means the process is going away, which is what we asked for.
        _ = try? await call("core/quit")
    }

    // MARK: - Config

    public func listRemotes() async throws -> [String] {
        let result = try await call("config/listremotes")
        return result["remotes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    /// Remote name to backend type, e.g. `["dav1": "webdav"]`.
    public func remoteTypes() async throws -> [String: String] {
        let result = try await call("config/dump")
        guard let object = result.objectValue else { return [:] }
        return object.compactMapValues { $0["type"]?.stringValue }
    }

    // MARK: - Serve

    public struct Server: Sendable {
        public let id: String
        public let addr: String

        /// The port rclone actually bound. `addr` arrives as `127.0.0.1:64899` or
        /// `[::]:64899`, so take the last colon-separated field.
        public var port: Int? {
            addr.split(separator: ":").last.flatMap { Int($0) }
        }
    }

    public func startServer(_ params: [String: JSONValue]) async throws -> Server {
        let result = try await call("serve/start", params)
        guard let id = result["id"]?.stringValue else {
            throw RcloneRCError.unexpectedResponse("serve/start returned no id")
        }
        return Server(id: id, addr: result["addr"]?.stringValue ?? "")
    }

    public func stopServer(id: String) async throws {
        try await call("serve/stop", ["id": .string(id)])
    }

    public func listServers() async throws -> [Server] {
        let result = try await call("serve/list")
        return result["list"]?.arrayValue?.compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            return Server(id: id, addr: entry["addr"]?.stringValue ?? "")
        } ?? []
    }

    // MARK: - Stats

    public struct Stats: Sendable {
        public let bytes: Int
        public let errors: Int
        public let transferring: Int
        public let speed: Double
    }

    public func stats() async throws -> Stats {
        let result = try await call("core/stats", ["short": .bool(true)])
        return Stats(
            bytes: result["bytes"]?.intValue ?? 0,
            errors: result["errors"]?.intValue ?? 0,
            transferring: result["transferring"]?.arrayValue?.count ?? 0,
            speed: result["speed"]?.doubleValue ?? 0
        )
    }

    /// Files written locally but not yet uploaded. Empty unless `--vfs-cache-mode` is
    /// greater than `off`.
    public func uploadQueue(fs: String) async throws -> [String] {
        let result = try await call("vfs/queue", ["fs": .string(fs)])
        return result["queue"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }
}

public enum RcloneRCError: Error, LocalizedError {
    case unexpectedResponse(String)
    case unsupportedVersion(found: String, minimum: String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let detail):
            return "Unexpected response from rclone: \(detail)"
        case .unsupportedVersion(let found, let minimum):
            return "rclone \(found) is too old. grrclone needs \(minimum) or later, "
                 + "because earlier versions have NFS defects that cause stale handles, "
                 + "failed file creation, and broken large-directory listings."
        }
    }
}
