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
        case orphanMountsStillLive([String])
        case orphanUndetermined(pid: Int32)

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
            case .orphanUndetermined(let pid):
                return "grrclone recorded a background process (\(pid)) from a previous "
                     + "session and cannot tell whether it is still running, so it will "
                     + "not start a second one. Check with `ps -p \(pid)`: if it is gone, "
                     + "try again; if it is still there, quit it and try again."
            case .orphanMountsStillLive(let paths):
                return "A previous session left \(paths.count) volume(s) mounted that "
                     + "could not be disconnected: \(paths.joined(separator: ", ")). "
                     + "grrclone will not start the background process while those are "
                     + "up, because doing so would leave macOS talking to a storage "
                     + "server that no longer exists. Disconnect them in Finder, or run "
                     + "`diskutil umount force <path>`, then try again."
            }
        }
    }

    private let binary: URL
    private let runtimeDirectory: URL
    private let settings: DaemonSettings
    private var process: Process?
    private var pipes: [Pipe] = []
    /// One per drained pipe; finished when draining stops so the consumer task
    /// ends rather than waiting forever on a pipe nobody reads.
    private var drains: [AsyncStream<Data>.Continuation] = []
    private var drainTasks: [Task<Void, Never>] = []
    /// Counts daemon starts, so each start's log streams have their own identity
    /// and a previous start's still-draining consumer cannot interleave with them.
    private var generation = 0
    private var client: RcloneRCClient?
    private let pidFile: DaemonPidFile
    /// Tracks whether this session ended properly. See `SessionMarker`.
    public let session: SessionMarker
    private(set) public var socketPath: String?

    /// Recent daemon output. Also the thing that keeps rclone from blocking on a full
    /// pipe — see `DaemonLog`.
    public let log = DaemonLog()

    public init(binary: URL, settings: DaemonSettings = .init(), runtimeDirectory: URL? = nil) {
        self.binary = binary
        self.settings = settings
        let directory = runtimeDirectory ?? Self.defaultRuntimeDirectory()
        self.runtimeDirectory = directory
        self.pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: directory))
        self.session = SessionMarker(url: SessionMarker.defaultURL(runtimeDirectory: directory))
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

        // Read the previous session now; begin the new one only once this start has
        // succeeded, at the very end. The first version began it here, and every
        // throw below — an orphan that could not be identified, mounts that would
        // not come down, a binary too old, a socket that never appeared — then
        // left a fresh marker with no mount points in it. The caller never read
        // `previousSession` because start() had thrown, and on the retry the
        // marker said a session had begun and lost nothing: the one reassurance
        // this record exists to withhold, given for a crash that had left local
        // files in a mount point (#117).
        previousSession = session.previousSession()

        // Deal with a daemon left behind by an unclean shutdown before claiming the
        // socket. Skipping this would orphan it: we would delete the socket it is
        // listening on, leaving a live process still serving mounts that nothing can
        // reach or stop.
        //
        // **Unmount before killing.** That orphan is still serving live NFS mounts, and
        // killing it first leaves the kernel talking to a dead server — the exact state
        // `stop()` and `ConnectionManager.shutdown()` go out of their way to avoid.
        // Soft mounts turn that into I/O errors rather than a permanent wedge, which is
        // why it went unnoticed, but errors in Finder and failed in-flight writes are
        // not an acceptable startup experience.
        //
        // The cleanup is injected because the registry of owned mounts belongs a layer
        // up. It runs only when an orphan is actually found, so the ordinary launch
        // pays nothing for it.
        let reapable = await pidFile.reapableOrphan()
        if case .undetermined(let record) = reapable {
            // Refuse rather than guess. We recorded a daemon, cannot establish
            // whether it is still running, and starting anyway would delete the
            // socket it may be listening on — orphaning it permanently, still
            // serving mounts with nothing able to reach or stop it.
            throw Failure.orphanUndetermined(pid: record.pid)
        }
        if case .orphan(let orphan) = reapable {
            let outcome = await orphanCleanup?() ?? .nothingToDo
            orphanMountsUnmounted = outcome.unmounted

            // Reaping is conditional on the cleanup having actually succeeded.
            //
            // Returning only the list of paths we managed to unmount was the first
            // version of this, and it was wrong in the same way the original bug was:
            // a `diskutil` failure, an unreadable registry or an unreadable mount table
            // all collapsed to an empty list, indistinguishable from "there was nothing
            // to do" — and we killed the daemon anyway, straight back into the
            // dead-server state this whole path exists to prevent.
            guard outcome.stillMounted.isEmpty else {
                throw Failure.orphanMountsStillLive(outcome.stillMounted)
            }
            reapedOrphanPID = await pidFile.reap(orphan)
        }

        // A unix socket path is capped at 104 bytes on Darwin, so keep the name short.
        let socket = runtimeDirectory.appendingPathComponent("rc.sock").path
        try? fm.removeItem(atPath: socket)

        let user = try Self.randomToken()
        let password = try Self.randomToken()

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
            "--log-level", settings.logLevel.rawValue,
            // Never prompt for the config password. An app has no terminal to prompt
            // on, and left to try, rclone does not fail gracefully: the daemon starts,
            // then the first call that reads an encrypted config panics with
            // "Failed to read line: EOF", which says nothing about encryption. With
            // this flag the same call reports "unable to decrypt configuration"
            // instead, which grrclone recognises and answers by asking the user.
            // See ConfigLock.swift.
            "--ask-password=false",
        ]
        // Both streams are drained continuously into the log. This is not only so the
        // output can be shown: a process writing to a pipe nobody reads blocks once
        // that pipe fills, which would freeze the daemon and every mount it serves.
        // See DaemonLog.
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        // Each pipe is read in order, by one consumer.
        //
        // The readability handler runs serially per pipe, but the first version
        // spawned a fresh `Task { await log.append(...) }` per chunk, and tasks do
        // not run in the order they were created. Two reads of one sensitive line
        // could therefore reach the log tail first, head second — and the tail,
        // with the credential in it, would be recorded before the head had set the
        // redaction state that drops it. Codex found that on review. An
        // `AsyncStream` fixes the order: `yield` is synchronous, so chunks enter
        // the stream in read order, and a single task per pipe appends them in
        // that order.
        let log = self.log
        generation += 1
        for (pipe, kind) in [(errPipe, DaemonLog.Stream.Kind.stderr), (outPipe, .stdout)] {
            let stream = DaemonLog.Stream(kind: kind, generation: generation)
            let (chunks, feed) = AsyncStream<Data>.makeStream()
            drains.append(feed)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                // Empty means end of file; the handler keeps firing until detached.
                guard !data.isEmpty else { feed.finish(); return }
                feed.yield(data)
            }
            drainTasks.append(Task {
                for await chunk in chunks { await log.append(chunk, from: stream) }
            })
        }

        do { try process.run() }
        catch {
            // The consumers above are already waiting on pipes that will never be
            // written; end them, or every retry after a persistent launch failure
            // leaks two tasks and their streams.
            stopDraining([errPipe, outPipe])
            throw Failure.didNotStart(error.localizedDescription)
        }

        self.process = process

        guard await Self.waitForSocket(socket, process: process, timeout: 10) else {
            // Read the reason from the log rather than the pipe. The handler above
            // already owns the pipe, and draining it here as well would race it for
            // the very bytes that explain the failure.
            let detail = await log.recent.suffix(10).map(\.text).joined(separator: "\n")
            stopDraining([errPipe, outPipe])
            process.terminate()
            self.process = nil
            throw Failure.didNotStart(detail.isEmpty ? "control socket never appeared" : detail)
        }
        self.pipes = [errPipe, outPipe]
        // The socket inherits the directory's protection, but set it explicitly so the
        // guarantee does not depend on the umask in effect at launch.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket)

        // Everything past this point can throw, and a throw that leaves the process
        // running orphans it beyond recovery: the pid file is written only on success,
        // so the *next* launch cannot identify it either, and a caller that retries
        // start() spawns a second daemon on top of the first.
        //
        // This previously guarded only the version-too-old case. A version() call that
        // threw for any other reason — the socket file exists but the daemon is not
        // answering yet, a malformed reply — skipped the cleanup entirely.
        var startedCleanly = false
        defer { if !startedCleanly { abandonPartialStart([errPipe, outPipe], socket: socket) } }

        let client = RcloneRCClient(socketPath: socket, user: user, password: password)
        let version = try await client.version()
        guard version.meetsMinimum else {
            let minimum = RcloneRCClient.Version.minimumSupported
            throw Failure.binaryTooOld(found: version.version,
                                       minimum: "\(minimum.0).\(minimum.1).\(minimum.2)")
        }

        try? pidFile.write(pid: process.processIdentifier, socketPath: socket)
        self.client = client
        self.socketPath = socket
        // Last, after everything that can throw: from here the session is real.
        session.begin()
        startedCleanly = true
        return client
    }

    /// Tear down a start that did not complete, leaving nothing running.
    ///
    /// Synchronous on purpose: it runs from a `defer` on the throwing path, and an
    /// async hop there would let the error escape before the process is gone.
    /// `terminate()` then a SIGKILL backstop is the same escalation `stop()` uses,
    /// minus the wait — there is no client to ask politely with.
    private func abandonPartialStart(_ pipes: [Pipe], socket: String) {
        if let process, process.isRunning {
            process.terminate()
            // rclone has not begun serving anything at this point, so there is no
            // mount to protect and no reason to wait for a graceful exit.
            kill(process.processIdentifier, SIGKILL)
        }
        stopDraining(pipes)
        self.pipes = []
        self.process = nil
        self.client = nil
        self.socketPath = nil
        pidFile.clear()
        try? FileManager.default.removeItem(atPath: socket)
    }

    /// PID of a daemon reaped at startup, if any. Surfaced so callers can report that a
    /// previous run did not shut down cleanly.
    private(set) public var reapedOrphanPID: Int32?

    /// Mountpoints brought down by `orphanCleanup` before the orphan was killed.
    /// Empty on an ordinary launch, because the hook only runs when an orphan exists.
    private(set) public var orphanMountsUnmounted: [String] = []

    /// What an attempt to bring down an orphan's mounts achieved.
    ///
    /// `stillMounted` is the field that matters and the reason this is not just a
    /// list of successes: it must be possible to tell "nothing needed unmounting"
    /// apart from "we tried and failed", because only the first makes it safe to kill
    /// the daemon.
    public struct OrphanCleanupOutcome: Sendable, Equatable {
        public var unmounted: [String]
        public var stillMounted: [String]

        public init(unmounted: [String] = [], stillMounted: [String] = []) {
            self.unmounted = unmounted
            self.stillMounted = stillMounted
        }

        public static let nothingToDo = OrphanCleanupOutcome()
    }

    /// Brings down the mounts an orphaned daemon is serving, before it is killed.
    ///
    /// Set this on every supervisor that might have mounts behind it; a supervisor
    /// without it will kill an orphan out from under live mounts, which is what this
    /// exists to prevent.
    public typealias OrphanCleanup = @Sendable () async -> OrphanCleanupOutcome
    private var orphanCleanup: OrphanCleanup?

    public func setOrphanCleanup(_ cleanup: @escaping OrphanCleanup) {
        self.orphanCleanup = cleanup
    }

    /// The previous session's record when it did not shut down cleanly, else nil.
    private(set) public var previousSession: SessionMarker.Record?

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
        stopDraining(pipes)
        pipes = []
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
        pidFile.clear()
        // Last on this path only: the marker's absence is what says the shutdown was
        // clean, so nothing that can be interrupted may remove it.
        session.clear()
        self.process = nil
        self.client = nil
        self.socketPath = nil
    }

    // MARK: - Helpers

    /// Detach the readability handlers and end their consumers. Left attached they
    /// keep firing against a closed descriptor and hold the closure — and the log —
    /// alive after the daemon has gone; left unfinished, each consumer task waits
    /// forever for a chunk that will never come.
    private func stopDraining(_ pipes: [Pipe]) {
        for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
        for feed in drains { feed.finish() }
        for task in drainTasks { task.cancel() }
        drains = []
        drainTasks = []
    }

    /// Throws rather than degrading. A discarded status here leaves the buffer as the
    /// zeros it was initialised with, so both the rc user and password become the same
    /// fixed string on every launch — silently, with nothing to notice. The 0600 socket
    /// still carries the real access control, but a defence-in-depth layer that fails
    /// open without saying so is worse than not having it.
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.didNotStart("could not generate control-socket credentials")
        }
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
