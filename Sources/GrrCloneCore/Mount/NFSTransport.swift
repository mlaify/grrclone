import Foundation
import RcloneRC

/// How a connection is exposed to Finder. The seam that lets grrclone swap the
/// underlying mechanism without touching the UI or lifecycle code.
public protocol MountTransport: Sendable {
    var kind: TransportKind { get }
    /// Parameters for `serve/start`.
    func serveParameters(for connection: Connection, cacheRoot: URL) -> [String: JSONValue]
    /// Mount an already-running server. Returns the path now mounted.
    func mount(connection: Connection, server: RcloneRCClient.Server, at mountPoint: URL) async throws
    func unmount(at mountPoint: URL) async throws
}

public enum MountError: Error, LocalizedError {
    case noPort(String)
    case mountFailed(String)
    case unmountFailed(String)
    case mountPointUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noPort(let addr): return "rclone reported an address with no usable port: \(addr)"
        case .mountFailed(let detail): return "Mount failed: \(detail)"
        case .unmountFailed(let detail): return "Unmount failed: \(detail)"
        case .mountPointUnavailable(let detail): return "Mount point unusable: \(detail)"
        }
    }
}

/// Serves the remote over NFS on loopback and mounts it with the built-in NFS client.
///
/// grrclone performs the mount itself instead of calling `rclone nfsmount` or the rc
/// `mount/mount` endpoint. Those pass only `port`, `mountport` and `tcp`, which leaves
/// macOS's default **hard, non-interruptible** mount: when the backend dies, Finder
/// beachballs and processes wedge in uninterruptible sleep. Measured with the options
/// below, a SIGKILLed server instead produces an error after about seven seconds and
/// unmounts cleanly. See docs/benchmarks.md.
public struct NFSTransport: MountTransport {
    public let kind: TransportKind = .nfs

    public init() {}

    /// Only keys from rclone's `vfs` and `nfs` option blocks are valid here. `serve/start`
    /// rejects the whole request with `unknown parameters` if given anything else, so
    /// global flags (`cache_dir`, `transfers`, `checkers`) go on the daemon instead and
    /// FUSE-only options (`attr_timeout`) are not applicable at all.
    public func serveParameters(for connection: Connection, cacheRoot: URL) -> [String: JSONValue] {
        let options = connection.options
        let nfsCache = cacheRoot.appendingPathComponent("nfs/\(connection.id.uuidString)")

        var params: [String: JSONValue] = [
            "type": .string("nfs"),
            "fs": .string(connection.fsSpec),
            // Loopback only, always, and port 0 so the kernel picks a free one. rclone's
            // NFS server implements no authentication whatsoever, so any other bind
            // address would expose the user's entire storage account to the local network.
            "addr": .string("localhost:0"),
            "vfs_cache_mode": .string(options.vfsCacheMode),
            "vfs_cache_max_age": .string(options.vfsCacheMaxAge),
            "vfs_cache_max_size": .string(options.vfsCacheMaxSize),
            "dir_cache_time": .string(options.dirCacheTime),
            "vfs_write_back": .string(options.vfsWriteBack),
            "poll_interval": .string(options.pollInterval),
            "nfs_cache_type": .string(options.nfsCacheType),
            "nfs_cache_dir": .string(nfsCache.path),
        ]
        if options.readOnly { params["read_only"] = .bool(true) }
        return params
    }

    /// The mount options rclone will not give us, and why each is here.
    ///
    /// - `soft`, `intr`, `timeo=600`, `retrans=2`: a dead backend returns an error
    ///   rather than retrying forever. This is what keeps Finder responsive.
    /// - `nolocks`, `locallocks`: rclone's NFS server runs no lock daemon, so anything
    ///   taking an `fcntl` lock — SQLite, Office, Adobe — would otherwise hang waiting
    ///   on a lockd that does not exist.
    /// - `nfc`: macOS filename normalisation, so names round-trip correctly.
    static func mountOptions(port: Int, readOnly: Bool) -> String {
        var options = [
            "port=\(port)", "mountport=\(port)", "tcp",
            "soft", "intr", "timeo=600", "retrans=2",
            "nolocks", "locallocks", "nfc",
            "rsize=131072", "wsize=131072",
        ]
        if readOnly { options.append("rdonly") }
        return options.joined(separator: ",")
    }

    public func mount(connection: Connection, server: RcloneRCClient.Server,
                      at mountPoint: URL) async throws {
        guard let port = server.port, port > 0 else {
            throw MountError.noPort(server.addr)
        }
        try Self.prepareMountPoint(mountPoint)

        let options = Self.mountOptions(port: port, readOnly: connection.options.readOnly)
        let result = try await Shell.run(
            "/sbin/mount",
            ["-t", "nfs", "-o", options, "localhost:/", mountPoint.path],
            timeout: 30)

        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(detail.isEmpty ? "exit \(result.status)" : detail)
        }
    }

    /// Seconds one unmount can take in the worst case: both attempts timing out, plus
    /// the slack `Shell.run` allows for draining pipes after it kills a process.
    ///
    /// Exposed so callers can budget a teardown instead of guessing. Guessing is what
    /// let the app's quit backstop fire mid-unmount.
    public static let unmountBudget: TimeInterval =
        attemptTimeout * 2 + Shell.pipeDrainSlack * 2

    static let attemptTimeout: TimeInterval = 60

    public func unmount(at mountPoint: URL) async throws {
        // diskutil goes through DiskArbitration, which can dislodge a mount that plain
        // umount cannot. Note `umount -l` is Linux-only and unavailable here.
        let forced = try? await Shell.run(
            "/usr/sbin/diskutil", ["umount", "force", mountPoint.path],
            timeout: Self.attemptTimeout)
        if forced?.succeeded == true { return }

        let fallback = try await Shell.run("/sbin/umount", ["-f", mountPoint.path],
                                           timeout: Self.attemptTimeout)
        guard fallback.succeeded else {
            let detail = fallback.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.unmountFailed(detail.isEmpty ? "exit \(fallback.status)" : detail)
        }
    }

    /// The mount point must exist and be an empty directory. Refusing to mount over a
    /// non-empty directory is deliberate: doing so hides the user's files for as long as
    /// the mount lasts, and they look deleted.
    static func prepareMountPoint(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MountError.mountPointUnavailable("\(url.path) exists and is not a directory")
            }
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            let meaningful = contents.filter { $0 != ".DS_Store" }
            guard meaningful.isEmpty else {
                throw MountError.mountPointUnavailable(
                    "\(url.path) is not empty. Mounting there would hide \(meaningful.count) existing item(s).")
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        try? protectWhileUnmounted(url)
    }

    /// Make a mountpoint unwritable while nothing is mounted on it.
    ///
    /// An empty directory sitting where a volume used to be is a trap: anything
    /// written there lands on the local disk, looks saved, and then disappears the
    /// moment the mount comes back over the top of it. grrclone removes the directory
    /// on a clean disconnect, so the exposure is after a crash or a force quit — which
    /// is exactly when the user is least likely to notice.
    ///
    /// `0500` closes it, and costs nothing in either direction. Measured against a
    /// real rclone NFS server:
    ///
    /// - a `touch` inside the empty directory fails with `Permission denied`
    /// - mounting over it still succeeds and the remote lists normally
    /// - writing *through* the mount works, because the mounted filesystem's
    ///   permissions come from the server, not from the directory underneath
    /// - unmounting reverts to the protected directory with no extra work
    ///
    /// Read and execute are kept so the path can still be inspected and so Finder can
    /// show it; only writing is refused.
    public static func protectWhileUnmounted(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: url.path)
    }

    /// Restore ordinary permissions, for a directory about to be removed or handed
    /// back to the user.
    public static func unprotect(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }
}
