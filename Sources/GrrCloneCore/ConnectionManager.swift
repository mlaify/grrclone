import Foundation
import RcloneRC

/// Owns the lifecycle of every connection: start the daemon, serve, mount, unmount,
/// reconcile after a crash, and tear down in the one order that is safe.
public actor ConnectionManager {
    public struct ActiveMount: Sendable {
        public let connection: Connection
        public let serverID: String
        public let mountPoint: URL
    }

    private let supervisor: DaemonSupervisor
    private let registry: MountRegistry
    private let cacheRoot: URL
    private let transports: [TransportKind: any MountTransport]
    private var active: [UUID: ActiveMount] = [:]

    public init(supervisor: DaemonSupervisor,
                registry: MountRegistry,
                cacheRoot: URL? = nil,
                transports: [any MountTransport] = [NFSTransport()]) {
        self.supervisor = supervisor
        self.registry = registry
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot()
        self.transports = Dictionary(uniqueKeysWithValues: transports.map { ($0.kind, $0) })
    }

    public static func defaultCacheRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.mlaify.grrclone", isDirectory: true)
    }

    public static func defaultMountRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("grrclone", isDirectory: true)
    }

    public var activeMounts: [ActiveMount] { Array(active.values) }

    // MARK: - Connect

    public func connect(_ connection: Connection,
                        mountRoot: URL? = nil) async throws -> ActiveMount {
        if let existing = active[connection.id] { return existing }

        guard let transport = transports[connection.transport] else {
            throw MountError.mountFailed("No transport available for \(connection.transport.rawValue)")
        }

        let client = try await supervisor.start()
        let root = mountRoot ?? Self.defaultMountRoot()
        let mountPoint = root.appendingPathComponent(connection.displayName, isDirectory: true)

        let params = transport.serveParameters(for: connection, cacheRoot: cacheRoot)
        let server = try await client.startServer(params)

        // Record ownership *before* mounting. If we crash between the mount syscall
        // returning and this write, the registry would not list a mount we do own and
        // reconciliation would leave it stranded.
        try await registry.record(MountRegistry.Entry(
            connectionID: connection.id,
            mountPoint: mountPoint.path,
            transport: connection.transport.rawValue,
            serverID: server.id,
            port: server.port,
            pid: ProcessInfo.processInfo.processIdentifier))

        do {
            try await transport.mount(connection: connection, server: server, at: mountPoint)
        } catch {
            // Do not leave an orphaned server behind on a failed mount.
            try? await client.stopServer(id: server.id)
            try? await registry.forget(mountPoint: mountPoint.path)
            throw error
        }

        let mount = ActiveMount(connection: connection, serverID: server.id, mountPoint: mountPoint)
        active[connection.id] = mount
        return mount
    }

    // MARK: - Disconnect

    /// Unmount, then stop the server. This order is not interchangeable: stopping the
    /// server first leaves the kernel holding a mount whose NFS server no longer exists,
    /// which hangs every process that touches the path, Finder included.
    public func disconnect(_ connectionID: UUID) async throws {
        guard let mount = active[connectionID] else { return }
        guard let transport = transports[mount.connection.transport] else { return }

        try await transport.unmount(at: mount.mountPoint)

        if let client = try? await supervisor.requireClient() {
            try? await client.stopServer(id: mount.serverID)
        }
        try await registry.forget(mountPoint: mount.mountPoint.path)
        active[connectionID] = nil

        Self.removeIfEmpty(mount.mountPoint.path)
    }

    /// Remove a mount point directory we created, but only when it is empty. If an
    /// unmount silently failed, the directory still shows the remote's contents and
    /// deleting it would delete the user's files.
    static func removeIfEmpty(_ path: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        guard contents.filter({ $0 != ".DS_Store" }).isEmpty else { return }
        try? fm.removeItem(atPath: path)
    }

    public struct ShutdownOutcome: Sendable, Equatable {
        /// Uploads still outstanding, or whose state could not be determined.
        public var strandedUploads: Int = 0
        /// Mounts deliberately left up because the deadline ran out.
        public var abandonedMounts: [String] = []
        /// True when the daemon was left running, which happens only when mounts are
        /// still up and killing it would hang Finder.
        public var daemonLeftRunning: Bool = false

        public init(strandedUploads: Int = 0, abandonedMounts: [String] = [],
                    daemonLeftRunning: Bool = false) {
            self.strandedUploads = strandedUploads
            self.abandonedMounts = abandonedMounts
            self.daemonLeftRunning = daemonLeftRunning
        }

        public var isClean: Bool {
            strandedUploads == 0 && abandonedMounts.isEmpty && !daemonLeftRunning
        }
    }

    /// Worst-case seconds a full teardown can take, so a caller can size its own
    /// watchdog instead of guessing.
    public func teardownBudget(drainTimeout: TimeInterval) -> TimeInterval {
        drainTimeout + Double(active.count) * NFSTransport.unmountBudget + Self.daemonStopBudget
    }

    static let daemonStopBudget: TimeInterval = 5

    /// Ordered teardown for app quit, bounded by a deadline it enforces itself.
    ///
    /// Order is not interchangeable. Uploads drain first, because quitting with writes
    /// still queued strands the only copy of a file in a local cache. Mounts come down
    /// next. The daemon dies last, because killing rclone under a live NFS mount leaves
    /// the kernel talking to a dead server and hangs Finder until the mount is forcibly
    /// removed.
    ///
    /// The deadline is enforced here rather than by a watchdog in the caller. An
    /// external timer that fires mid-teardown kills the process between unmounting and
    /// stopping the daemon, which is the one state this ordering exists to avoid. When
    /// time runs out, the remaining mounts are deliberately left up **and the daemon is
    /// left running to serve them** — an orphan the next launch reaps and reconciles,
    /// which is strictly safer than a live mount with no server behind it.
    ///
    /// - Parameter drainTimeout: seconds to wait for uploads. Pass 0 to skip waiting.
    /// - Parameter deadline: total seconds for everything. Defaults to the full budget.
    @discardableResult
    public func shutdown(drainTimeout: TimeInterval = 0,
                         deadline: TimeInterval? = nil,
                         onProgress: (@Sendable (Int) -> Void)? = nil) async -> ShutdownOutcome {
        var outcome = ShutdownOutcome()
        let limit = Date().addingTimeInterval(deadline ?? teardownBudget(drainTimeout: drainTimeout))

        if drainTimeout > 0 {
            let allowed = min(drainTimeout, max(0, limit.timeIntervalSinceNow))
            outcome.strandedUploads = await drainUploads(timeout: allowed, onProgress: onProgress)
        }

        for id in active.keys {
            guard let mount = active[id] else { continue }
            // Only start an unmount that can finish inside the deadline. Beginning one
            // we cannot complete is what leaves the process to be killed mid-teardown.
            guard limit.timeIntervalSinceNow >= NFSTransport.unmountBudget else {
                outcome.abandonedMounts.append(mount.mountPoint.path)
                continue
            }
            do {
                try await disconnect(id)
            } catch {
                outcome.abandonedMounts.append(mount.mountPoint.path)
            }
        }

        if outcome.abandonedMounts.isEmpty {
            await supervisor.stop()
        } else {
            // Leaving the daemon up keeps those mounts working until the next launch
            // reaps it. Stopping it now would wedge Finder on every abandoned path.
            outcome.daemonLeftRunning = true
        }
        return outcome
    }

    // MARK: - Reconciliation

    public struct ReconcileReport: Sendable {
        public var cleaned: [String] = []
        public var stillMounted: [String] = []
        public var skippedNotOurs: [String] = []
    }

    /// Clean up mounts left behind by a previous run that did not shut down cleanly.
    ///
    /// Scoped strictly to paths recorded in `MountRegistry`. The live mount table is
    /// consulted only to check whether a path we already know we own is still mounted.
    /// This matters because a user's own `rclone nfsmount` appears in `mount(8)` exactly
    /// as ours does — same `localhost:/` source, same owner — so any scan that decided
    /// ownership from the mount table would force-unmount the user's volumes, possibly
    /// mid-write. Ownership comes from our own records or not at all.
    public func reconcileOrphans() async throws -> ReconcileReport {
        var report = ReconcileReport()
        let owned = await registry.all
        guard !owned.isEmpty else { return report }

        let table = (try? await SystemMounts.current()) ?? []
        let mountedPaths = Set(table.map(\.mountPoint))

        for entry in owned {
            // Already tracked as live in this session; not an orphan.
            if active.values.contains(where: { $0.mountPoint.path == entry.mountPoint }) { continue }

            guard mountedPaths.contains(entry.mountPoint) else {
                // Recorded but not mounted: the record is simply stale.
                try? await registry.forget(mountPoint: entry.mountPoint)
                report.cleaned.append(entry.mountPoint)
                continue
            }

            let transport = transports[TransportKind(rawValue: entry.transport) ?? .nfs]
                ?? NFSTransport()
            do {
                try await transport.unmount(at: URL(fileURLWithPath: entry.mountPoint))
                try? await registry.forget(mountPoint: entry.mountPoint)
                Self.removeIfEmpty(entry.mountPoint)
                report.cleaned.append(entry.mountPoint)
            } catch {
                report.stillMounted.append(entry.mountPoint)
            }
        }
        return report
    }

    // MARK: - Transfer activity

    public struct Activity: Sendable, Equatable {
        public var perConnection: [UUID: RcloneRCClient.VFSStats] = [:]

        /// Connections whose cache state could not be read — usually because the daemon
        /// is gone. Tracked separately because "we could not ask" is not the same
        /// answer as "nothing is pending", and conflating them makes a safety check
        /// fail open: a daemon that crashed holding queued uploads would report all
        /// clear precisely when it is least true.
        public var unreachable: Set<UUID> = []

        public init(perConnection: [UUID: RcloneRCClient.VFSStats] = [:],
                    unreachable: Set<UUID> = []) {
            self.perConnection = perConnection
            self.unreachable = unreachable
        }

        public var pendingUploads: Int {
            perConnection.values.reduce(0) { $0 + $1.pendingUploads }
        }
        public var erroredFiles: Int {
            perConnection.values.reduce(0) { $0 + $1.erroredFiles }
        }
        public var outOfSpace: Bool {
            perConnection.values.contains { $0.outOfSpace }
        }

        /// True only when every connection answered and none had work outstanding.
        /// This is the one to test before deciding it is safe to quit.
        public var isKnownIdle: Bool { unreachable.isEmpty && pendingUploads == 0 }

        /// At least one connection could not be asked, so its state is unknown.
        public var hasUnknownState: Bool { !unreachable.isEmpty }
    }

    /// Local cache state for every active connection.
    ///
    /// A connection that cannot be queried is recorded in `unreachable` rather than
    /// omitted, so callers can tell silence apart from a confirmed zero.
    public func activity() async -> Activity {
        var activity = Activity()
        guard !active.isEmpty else { return activity }

        guard let client = try? await supervisor.requireClient() else {
            // The daemon is gone. Nothing can be known about any connection's cache.
            activity.unreachable = Set(active.keys)
            return activity
        }
        for mount in active.values {
            if let stats = try? await client.vfsStats(fs: mount.connection.fsSpec) {
                activity.perConnection[mount.connection.id] = stats
            } else {
                activity.unreachable.insert(mount.connection.id)
            }
        }
        return activity
    }

    /// Wait for every pending upload to finish, up to `timeout`.
    ///
    /// This matters because `--vfs-cache-mode full` makes a write return as soon as the
    /// bytes are on local disk. Finder shows the file as saved while nothing has reached
    /// the storage provider. Unmounting and quitting at that moment leaves the only copy
    /// in a local cache the user does not know exists.
    ///
    /// Returns the number of uploads still outstanding: 0 means everything is safely
    /// stored.
    @discardableResult
    public func drainUploads(timeout: TimeInterval = 120,
                             onProgress: (@Sendable (Int) -> Void)? = nil) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = await activity()
            // Only a positive confirmation ends the wait. If the daemon stopped
            // answering we cannot conclude the uploads finished — they are just as
            // likely stuck — so keep waiting until the deadline and report what is
            // still outstanding.
            if snapshot.isKnownIdle { return 0 }
            onProgress?(max(snapshot.pendingUploads, snapshot.unreachable.count))
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let final = await activity()
        return max(final.pendingUploads, final.unreachable.count)
    }

    // MARK: - Health and recovery

    public struct HealthReport: Sendable {
        public var healthy: [UUID] = []
        public var repaired: [UUID] = []
        public var failed: [UUID: String] = [:]
    }

    /// Probe every active mount and repair the ones that have stopped responding.
    ///
    /// Called after the machine wakes and whenever the network path changes. Sleep can
    /// leave a mount present in the kernel but unable to reach its server, in which case
    /// Finder shows a folder that hangs on every access. Detecting that and remounting is
    /// the difference between an app you trust on a laptop and one you restart daily.
    @discardableResult
    public func checkHealth(repair: Bool = true) async -> HealthReport {
        var report = HealthReport()

        for mount in active.values {
            switch await MountHealth.probe(mount.mountPoint) {
            case .healthy:
                report.healthy.append(mount.connection.id)

            case .unresponsive, .gone:
                guard repair else {
                    report.failed[mount.connection.id] = "not responding"
                    continue
                }
                do {
                    try await reconnect(mount)
                    report.repaired.append(mount.connection.id)
                } catch {
                    report.failed[mount.connection.id] = error.localizedDescription
                }
            }
        }
        return report
    }

    /// Tear a broken mount fully down and build it again.
    ///
    /// The old server is stopped rather than reused. Its NFS handle namespace belongs to
    /// a session the kernel has already lost track of, and reattaching to it is what
    /// produces "Stale NFS file handle" on every path.
    private func reconnect(_ mount: ActiveMount) async throws {
        let transport = transports[mount.connection.transport] ?? NFSTransport()

        try? await transport.unmount(at: mount.mountPoint)
        if let client = try? await supervisor.requireClient() {
            try? await client.stopServer(id: mount.serverID)
        }
        try? await registry.forget(mountPoint: mount.mountPoint.path)
        active[mount.connection.id] = nil
        Self.removeIfEmpty(mount.mountPoint.path)

        // Remount where it was, not where the default says.
        //
        // This previously called `connect` with no root, which falls back to
        // `~/grrclone`. On a machine using a configured mount folder — the whole point
        // of that setting — a mount that went unhealthy after sleep or a network change
        // would silently come back somewhere else. Every process holding the old path,
        // every alias and every script would then be pointing at nothing, as the result
        // of a repair the user never asked for and was never told about.
        //
        // Derived from the live mount point rather than remembered separately, so it
        // cannot drift from where the mount actually is.
        _ = try await connect(mount.connection,
                              mountRoot: Self.mountRoot(containing: mount.mountPoint))
    }

    /// The folder a mount point sits in, which is the root it was mounted under.
    ///
    /// Each connection is mounted in a directory of its own beneath the root, so the
    /// root is the parent. Standardised first: a path built from a `~` expansion and
    /// one built from `/Users/...` must compare and rebuild identically.
    static func mountRoot(containing mountPoint: URL) -> URL {
        mountPoint.standardizedFileURL.deletingLastPathComponent()
    }

    /// Paths in the mount table that look like ours but are not recorded as owned.
    /// Reported for diagnostics only — never unmounted. On a machine where the user also
    /// runs rclone by hand, these are their mounts.
    public func foreignLookalikes() async -> [String] {
        let table = (try? await SystemMounts.current()) ?? []
        let owned = Set(await registry.all.map(\.mountPoint))
        return table
            .filter { $0.isLoopbackNFS && !owned.contains($0.mountPoint) }
            .map(\.mountPoint)
    }
}
