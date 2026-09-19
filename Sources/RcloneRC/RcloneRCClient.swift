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
    public func call(_ method: String, _ params: [String: JSONValue] = [:],
                     timeout: TimeInterval? = nil) async throws -> JSONValue {
        let body = try encoder.encode(params)
        let data = try await http.post(path: "/\(method)", body: body, timeoutOverride: timeout)
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

    /// One file rclone is moving right now.
    ///
    /// Field names captured from a live `core/stats` during a real transfer, not
    /// taken from documentation: `name`, `size`, `bytes`, `speed`, `speedAvg`,
    /// `percentage`, `eta`, `group`, `srcFs`, `dstFs`. `eta` is null until rclone has
    /// enough of a sample to estimate, so it is optional here rather than defaulted
    /// to zero — "unknown" and "no time left" are very different things to show.
    public struct Transfer: Sendable, Equatable, Identifiable {
        public let name: String
        public let size: Int
        public let bytes: Int
        public let speed: Double
        public let eta: Int?
        /// rclone's own job grouping, and the filesystem the bytes come from.
        /// Carried solely to tell two transfers of the same path apart.
        public let group: String
        public let srcFs: String

        /// Unique across simultaneous transfers, which `name` is not.
        ///
        /// `core/stats` is daemon-wide, so two mounted remotes uploading the same
        /// relative path — `Documents/notes.md` from each of two accounts — both
        /// arrive as `notes.md`. Identifying rows by name alone gives `ForEach`
        /// duplicate ids, and SwiftUI then reuses or drops rows and shows one
        /// transfer's progress against the other's name.
        public var id: String { "\(group)|\(srcFs)|\(name)" }

        /// Nil when rclone has not reported a size, rather than a misleading 0%.
        public var fraction: Double? {
            guard size > 0 else { return nil }
            return min(1, Double(bytes) / Double(size))
        }

        public init(name: String, size: Int, bytes: Int, speed: Double, eta: Int?,
                    group: String = "", srcFs: String = "") {
            self.name = name
            self.size = size
            self.bytes = bytes
            self.speed = speed
            self.eta = eta
            self.group = group
            self.srcFs = srcFs
        }
    }

    public struct Stats: Sendable, Equatable {
        public let bytes: Int
        public let totalBytes: Int
        public let errors: Int
        public let speed: Double
        public let eta: Int?
        /// Files in flight. Empty when nothing is moving — rclone omits the key
        /// entirely at rest.
        public let transferring: [Transfer]

        public var isActive: Bool { !transferring.isEmpty }

        public init(bytes: Int = 0, totalBytes: Int = 0, errors: Int = 0,
                    speed: Double = 0, eta: Int? = nil, transferring: [Transfer] = []) {
            self.bytes = bytes
            self.totalBytes = totalBytes
            self.errors = errors
            self.speed = speed
            self.eta = eta
            self.transferring = transferring
        }
    }

    /// Aggregate transfer state, and the per-file detail behind it.
    ///
    /// Deliberately **not** `short: true`. That flag omits the `transferring` array
    /// altogether — verified against a live daemon — so the previous version of this
    /// function counted `transferring` and could only ever report zero. It had no
    /// callers, which is the only reason that never showed up as a bug.
    public func stats() async throws -> Stats {
        Self.parseStats(try await call("core/stats"))
    }

    /// Split out so tests exercise the function the client actually uses.
    ///
    /// Re-implementing this parse inside a test would prove only that the test
    /// agrees with itself: `stats()` could go back to `short: true` — dropping the
    /// `transferring` array entirely — and every assertion would still pass.
    static func parseStats(_ result: JSONValue) -> Stats {
        let transfers = (result["transferring"]?.arrayValue ?? []).compactMap {
            entry -> Transfer? in
            guard let name = entry["name"]?.stringValue else { return nil }
            return Transfer(name: name,
                            size: entry["size"]?.intValue ?? 0,
                            bytes: entry["bytes"]?.intValue ?? 0,
                            speed: entry["speed"]?.doubleValue ?? 0,
                            eta: entry["eta"]?.intValue,
                            group: entry["group"]?.stringValue ?? "",
                            srcFs: entry["srcFs"]?.stringValue ?? "")
        }
        return Stats(
            bytes: result["bytes"]?.intValue ?? 0,
            totalBytes: result["totalBytes"]?.intValue ?? 0,
            errors: result["errors"]?.intValue ?? 0,
            speed: result["speed"]?.doubleValue ?? 0,
            eta: result["eta"]?.intValue,
            transferring: transfers
        )
    }

    /// Files written locally but not yet uploaded. Empty unless `--vfs-cache-mode` is
    /// greater than `off`.
    public func uploadQueue(fs: String) async throws -> [String] {
        let result = try await call("vfs/queue", ["fs": .string(fs)])
        return result["queue"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    /// State of one connection's local write cache.
    ///
    /// This is the authoritative answer to "is it safe to quit?". With
    /// `--vfs-cache-mode full` a write returns as soon as the bytes are on local disk, so
    /// a file can look saved in Finder while nothing has reached the storage provider yet.
    public struct VFSStats: Sendable, Equatable {
        public let uploadsQueued: Int
        public let uploadsInProgress: Int
        public let erroredFiles: Int
        public let bytesUsed: Int
        public let cachedFiles: Int
        public let outOfSpace: Bool

        public init(uploadsQueued: Int, uploadsInProgress: Int, erroredFiles: Int,
                    bytesUsed: Int, cachedFiles: Int, outOfSpace: Bool) {
            self.uploadsQueued = uploadsQueued
            self.uploadsInProgress = uploadsInProgress
            self.erroredFiles = erroredFiles
            self.bytesUsed = bytesUsed
            self.cachedFiles = cachedFiles
            self.outOfSpace = outOfSpace
        }

        /// Both matter. A file already uploading is no safer to quit on than one still
        /// queued, and counting only the queue reports zero while bytes are in flight.
        public var pendingUploads: Int { uploadsQueued + uploadsInProgress }
        public var hasUnfinishedWork: Bool { pendingUploads > 0 }
    }

    /// `vfs/stats` rather than `vfs/queue`: the queue endpoint reports only items waiting
    /// to start, so a file actively uploading shows an empty queue and the caller
    /// concludes, wrongly, that everything is safely stored.
    public func vfsStats(fs: String) async throws -> VFSStats {
        let result = try await call("vfs/stats", ["fs": .string(fs)])
        let cache = result["diskCache"]
        return VFSStats(
            uploadsQueued: cache?["uploadsQueued"]?.intValue ?? 0,
            uploadsInProgress: cache?["uploadsInProgress"]?.intValue ?? 0,
            erroredFiles: cache?["erroredFiles"]?.intValue ?? 0,
            bytesUsed: cache?["bytesUsed"]?.intValue ?? 0,
            cachedFiles: cache?["files"]?.intValue ?? 0,
            outOfSpace: cache?["outOfSpace"]?.boolValue ?? false)
    }
}

public enum RcloneRCError: Error, LocalizedError {
    case unexpectedResponse(String)
    case unsupportedVersion(found: String, minimum: String)
    /// The configuration file is encrypted and no password has been supplied.
    case configLocked
    /// A password was supplied for an encrypted config and did not decrypt it.
    ///
    /// Determined by reading the config afterwards, not from the response to
    /// `config/unlock`, which reports success either way. See `ConfigLock.swift`.
    case configPasswordRejected

    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let detail):
            return "Unexpected response from rclone: \(detail)"
        case .unsupportedVersion(let found, let minimum):
            return "rclone \(found) is too old. grrclone needs \(minimum) or later, "
                 + "because earlier versions have NFS defects that cause stale handles, "
                 + "failed file creation, and broken large-directory listings."
        case .configLocked:
            return "Your rclone configuration is encrypted. Enter its password to continue."
        case .configPasswordRejected:
            return "That password did not decrypt the rclone configuration."
        }
    }
}
