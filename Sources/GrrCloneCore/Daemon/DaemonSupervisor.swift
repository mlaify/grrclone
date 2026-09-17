import Foundation
import RcloneRC

/// Spawns and supervises the single `rclone rcd` process that backs every connection.
///
/// The control channel is a unix socket with 0600 permissions in a 0700 directory, and
/// credentials are random per launch. Nothing is bound to TCP, not even loopback, so the
/// API is not reachable by other users or by anything on the network. `--rc-web-gui` is
/// never passed: it downloads a bundle from GitHub at runtime, which would violate the
/// project's no-phone-home guarantee.
public actor DaemonSupervisor {
    public enum Failure: Error, LocalizedError {
        case binaryNotFound
        case binaryTooOld(found: String, minimum: String)
        case didNotStart(String)
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "No usable rclone binary was found."
            case .binaryTooOld(let found, let minimum):
                return "rclone \(found) is too old. grrclone needs \(minimum) or later, because "
                     + "earlier versions have NFS defects that cause stale file handles, failed "
                     + "file creation, and broken listings of large directories."
            case .didNotStart(let detail):
                return "rclone did not start: \(detail)"
            case .notRunning:
                return "The rclone daemon is not running."
            }
        }
    }

    private let binary: URL
    private let runtimeDirectory: URL
    private let settings: DaemonSettings
    private var process: Process?
    private var client: RcloneRCClient?
    private let pidFile: DaemonPidFile
    private(set) public var socketPath: String?

    public init(binary: URL, settings: DaemonSettings = .init(), runtimeDirectory: URL? = nil) {
        self.binary = binary
        self.settings = settings
        let directory = runtimeDirectory ?? Self.defaultRuntimeDirectory()
        self.runtimeDirectory = directory
        self.pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: directory))
    }

    public static func defaultRuntimeDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("org.mlaify.grrclone", isDirectory: true)
        return base.appendingPathComponent("run", isDirectory: true)
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func requireClient() throws -> RcloneRCClient {
        guard let client, isRunning else { throw Failure.notRunning }
        return client
    }

    // MARK: - Binary discovery

    /// Candidate rclone binaries, most preferred first: an explicit override, then the
    /// copy bundled inside the app, then common Homebrew locations.
    ///
    /// The bundled copy is preferred over Homebrew because behaviour varies a great deal
    /// across rclone releases and the bundled one is pinned and tested. A discovered
    /// binary is still accepted, but only after the version check.
    public static func locateBinary(explicit: URL? = nil,
                                    bundled: URL? = nil,
                                    fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }
        if let bundled { candidates.append(bundled) }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/rclone"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/rclone"))

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() async throws -> RcloneRCClient {
        if let client, isRunning { return client }

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure.binaryNotFound
        }

        let fm = FileManager.default
        try fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        // Reap a daemon left behind by an unclean shutdown before claiming the socket.
        // Skipping this would orphan it: we would delete the socket it is listening on,
        // leaving a live process still serving mounts that nothing can reach or stop.
        if let reaped = await pidFile.reapOrphan() {
            reapedOrphanPID = reaped
        }

        // A unix socket path is capped at 104 bytes on Darwin, so keep the name short.
        let socket = runtimeDirectory.appendingPathComponent("rc.sock").path
        try? fm.removeItem(atPath: socket)

        let user = Self.randomToken()
        let password = Self.randomToken()

        let process = Process()
        process.executableURL = binary
        try? fm.createDirectory(at: settings.cacheDirectory, withIntermediateDirectories: true)

        // transfers, checkers and cache-dir are process-global in rclone; serve/start
        // rejects them as unknown parameters, so they must be set here.
        process.arguments = [
            "rcd",
            "--rc-addr", "unix://\(socket)",
            "--rc-user", user,
            "--rc-pass", password,
            "--cache-dir", settings.cacheDirectory.path,
            "--transfers", String(settings.transfers),
            "--checkers", String(settings.checkers),
            "--log-level", "NOTICE",
            // Never prompt for the config password. An app has no terminal to prompt
            // on, and left to try, rclone does not fail gracefully: the daemon starts,
            // then the first call that reads an encrypted config panics with
            // "Failed to read line: EOF", which says nothing about encryption. With
            // this flag the same call reports "unable to decrypt configuration"
            // instead, which grrclone recognises and answers by asking the user.
            // See ConfigLock.swift.
            "--ask-password=false",
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do { try process.run() }
        catch { throw Failure.didNotStart(error.localizedDescription) }

        self.process = process

        guard await Self.waitForSocket(socket, process: process, timeout: 10) else {
            let detail = String(data: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(),
                                encoding: .utf8) ?? ""
            process.terminate()
            self.process = nil
            throw Failure.didNotStart(detail.isEmpty ? "control socket never appeared" : detail)
        }
        // The socket inherits the directory's protection, but set it explicitly so the
        // guarantee does not depend on the umask in effect at launch.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket)

        let client = RcloneRCClient(socketPath: socket, user: user, password: password)
        let version = try await client.version()
        guard version.meetsMinimum else {
            process.terminate()
            self.process = nil
            let minimum = RcloneRCClient.Version.minimumSupported
            throw Failure.binaryTooOld(found: version.version,
                                       minimum: "\(minimum.0).\(minimum.1).\(minimum.2)")
        }

        try? pidFile.write(pid: process.processIdentifier, socketPath: socket)
        self.client = client
        self.socketPath = socket
        return client
    }

    /// PID of a daemon reaped at startup, if any. Surfaced so callers can report that a
    /// previous run did not shut down cleanly.
    private(set) public var reapedOrphanPID: Int32?

    /// Stop the daemon. Callers must unmount everything first: killing rclone while an
    /// NFS mount it serves is still live leaves the kernel talking to a dead server,
    /// which hangs Finder until the mount is forcibly removed.
    public func stop() async {
        if let client {
            try? await client.quit()
        }
        if let process, process.isRunning {
            // Give core/quit a moment to land before escalating.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning { process.terminate() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        pidFile.clear()
        self.process = nil
        self.client = nil
        self.socketPath = nil
    }

    // MARK: - Helpers

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func waitForSocket(_ path: String, process: Process,
                                      timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false }
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
