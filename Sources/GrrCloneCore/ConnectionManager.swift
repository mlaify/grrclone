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

    /// Ordered teardown for app quit. Every mount comes down before the daemon does.
    public func shutdown() async {
        for id in active.keys {
            try? await disconnect(id)
        }
        await supervisor.stop()
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

        _ = try await connect(mount.connection)
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
