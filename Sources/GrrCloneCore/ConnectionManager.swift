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

    /// Filesystems with a mount in progress.
    ///
    /// Keyed by `fsSpec`, not by connection id, and tracked separately from `active`
    /// because `connect` records into `active` only *after* `serve/start` and the
    /// mount have both returned. Between those points a connection is serving files
    /// and appears in neither place, which is long enough for something else to
    /// decide its cache is idle.
    private var connecting: Set<String> = []

    public init(supervisor: DaemonSupervisor,
                registry: MountRegistry,
                cacheRoot: URL? = nil,
                transports: [any MountTransport] = [NFSTransport()]) {
        self.supervisor = supervisor
        self.registry = registry
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot()
        self.transports = Dictionary(uniqueKeysWithValues: transports.map { ($0.kind, $0) })
    }

    /// Teach the supervisor to bring our mounts down before it kills an orphaned
    /// daemon.
    ///
    /// Call once, after construction and before the first `start()`. Without it the
    /// supervisor kills the orphan out from under live mounts and the kernel is left
    /// talking to a dead NFS server. It is wired here rather than left to each caller
    /// because `start()` is reached from a dozen places and one missed call site
    /// reintroduces the bug silently.
    ///
    /// Weak so the supervisor holding this closure does not keep the manager alive.
    public func installOrphanCleanup() async {
        await supervisor.setOrphanCleanup { [weak self] in
            // A manager that has gone away cannot vouch for anything, so it must not
            // report a clean sweep. `.nothingToDo` would authorise the kill.
            guard let self else { return .init(stillMounted: ["<unknown>"]) }
            return await self.unmountRecordedMounts()
        }
    }

    /// Unmount every mount the registry records as ours and is still in the mount
    /// table, reporting both what came down and what would not.
    ///
    /// Used both by startup reconciliation and, crucially, as the orphan cleanup that
    /// runs before a leftover daemon is killed. Needs no daemon of its own: ownership
    /// comes from the registry and the unmount goes through `diskutil`.
    ///
    /// A thrown error is reported as "everything might still be mounted" rather than
    /// swallowed into an empty success. The caller uses this to decide whether killing
    /// the daemon is safe, so an unreadable registry or mount table must not look like
    /// a clean sweep.
    public func unmountRecordedMounts() async -> DaemonSupervisor.OrphanCleanupOutcome {
        do {
            let report = try await reconcileOrphans()
            return .init(unmounted: report.cleaned, stillMounted: report.stillMounted)
        } catch {
            let owned = await registry.all.map(\.mountPoint)
            return .init(unmounted: [], stillMounted: owned)
        }
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

    /// The connection as it was when mounted, which is not necessarily the one saved
    /// in the store. Needed to reason about the cache the *live* mount is using.
    public func activeConnection(id: UUID) -> Connection? { active[id]?.connection }

    /// Where a live mount actually is, so a caller restoring UI state after a refused
    /// operation can name the real path instead of inventing one.
    public func activeMountPoint(id: UUID) -> URL? { active[id]?.mountPoint }

    /// Unsent writes in the cache belonging to a mount as it is currently serving.
    ///
    /// Distinct from `pendingUploads(for:)`, which asks about a connection's *saved*
    /// `fsSpec`. When the two differ — the subpath was edited but not yet remounted —
    /// they name different cache directories, and it is the live one that holds work
    /// nothing else will finish.
    public func pendingUploadsForActiveMount(id: UUID) async -> PendingUploads? {
        guard let mounted = active[id]?.connection else { return nil }
        guard let root = try? await rcloneCacheRoot() else {
            return PendingUploads(inspectionFailed: true)
        }
        return VFSCache.pendingUploads(cacheRoot: root, fsSpec: mounted.fsSpec)
    }

    // MARK: - Connect

    public func connect(_ connection: Connection,
                        mountRoot: URL? = nil) async throws -> ActiveMount {
        if let existing = active[connection.id] { return existing }

        guard let transport = transports[connection.transport] else {
            throw MountError.mountFailed("No transport available for \(connection.transport.rawValue)")
        }

        let client = try await supervisor.start()

        connecting.insert(connection.fsSpec)
        defer { connecting.remove(connection.fsSpec) }

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
        await recordLiveMounts()
        return mount
    }

    // MARK: - Disconnect

    /// Unmount, then stop the server. This order is not interchangeable: stopping the
    /// server first leaves the kernel holding a mount whose NFS server no longer exists,
    /// which hangs every process that touches the path, Finder included.
    public func disconnect(_ connectionID: UUID) async throws {
        guard let mount = active[connectionID] else { return }
        guard let transport = transports[mount.connection.transport] else { return }

        // The unmount is the step that can fail meaningfully. If it throws we keep the
        // connection active and the registry entry intact, because the mount is still
        // up and we still own it.
        try await transport.unmount(at: mount.mountPoint)

        if let client = try? await supervisor.requireClient() {
            try? await client.stopServer(id: mount.serverID)
        }

        // Past here the mount is down, so in-memory state must follow regardless of
        // whether the registry write succeeds. Letting a failed `forget()` throw
        // before this line left the connection marked active with nothing mounted:
        // the UI kept showing it connected, and at quit `shutdown()` tried to unmount
        // it again, failed, and left the daemon running for a mount that no longer
        // existed.
        active[connectionID] = nil
        await recordLiveMounts()
        Self.removeIfEmpty(mount.mountPoint.path)

        // Reported, not swallowed: a stale entry means the next launch will try to
        // unmount a path that is already gone. Harmless, but the user should not have
        // to infer it.
        try await registry.forget(mountPoint: mount.mountPoint.path)
    }

    /// Remove a mount point directory we created, but only when it is empty. If an
    /// unmount silently failed, the directory still shows the remote's contents and
    /// deleting it would delete the user's files.
    /// Keep the session marker's list of live mountpoints current.
    ///
    /// Written after every change rather than at shutdown, because the case it exists
    /// for is the one where shutdown never runs.
    private func recordLiveMounts() async {
        let paths = active.values.map(\.mountPoint.path).sorted()
        supervisor.session.update(mountPoints: paths)
    }

    /// Remove an empty mountpoint, or protect it if it has to stay.
    ///
    /// Removing it is the better outcome: a path that does not exist cannot silently
    /// swallow a write. When it cannot be removed — it still holds something, or the
    /// filesystem refuses — leave it unwritable rather than leaving a trap.
    static func removeIfEmpty(_ path: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        guard contents.filter({ $0 != ".DS_Store" }).isEmpty else {
            try? NFSTransport.protectWhileUnmounted(URL(fileURLWithPath: path))
            return
        }
        // Remove needs write permission on the directory itself.
        try? NFSTransport.unprotect(URL(fileURLWithPath: path))
        if (try? fm.removeItem(atPath: path)) == nil {
            try? NFSTransport.protectWhileUnmounted(URL(fileURLWithPath: path))
        }
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

    // MARK: - Cache

    public enum CacheRefusal: Error, LocalizedError {
        case pendingUploads(files: [String])
        case cacheUnreadable
        case stillMounted

        public var errorDescription: String? {
            switch self {
            case .pendingUploads(let files):
                let sample = files.prefix(3).joined(separator: ", ")
                let more = files.count > 3 ? ", and \(files.count - 3) more" : ""
                return "\(files.count) file(s) have not finished uploading: "
                     + "\(sample)\(more). The only copy of those is in this cache, so "
                     + "grrclone will not clear it. Let the uploads finish and try again."
            case .cacheUnreadable:
                return "grrclone could not read this cache, so it cannot tell whether "
                     + "anything is still waiting to upload. It will not clear a cache "
                     + "it cannot account for."
            case .stillMounted:
                return "Disconnect this remote before clearing its cache. rclone is "
                     + "serving files from it, and deleting them underneath a live "
                     + "mount produces read errors in Finder. If another connection "
                     + "points at the same remote and folder, they share one cache, "
                     + "so that one has to be disconnected too."
            }
        }
    }

    /// Disk used by each connection's cache, and whether it can be reclaimed.
    public func cacheUsage(for connections: [Connection]) async -> [UUID: VFSCache.Usage] {
        guard let root = try? await rcloneCacheRoot() else {
            // Unknown, not zero. Reporting zero would invite a purge of something we
            // cannot see.
            return Dictionary(uniqueKeysWithValues: connections.map {
                ($0.id, VFSCache.Usage(pending: PendingUploads(inspectionFailed: true)))
            })
        }
        var result: [UUID: VFSCache.Usage] = [:]
        for connection in connections {
            result[connection.id] = VFSCache.usage(cacheRoot: root, fsSpec: connection.fsSpec)
        }
        return result
    }

    /// Whether anything is serving this filesystem right now.
    ///
    /// By `fsSpec`, never by connection id. The cache directory is named from
    /// `fsSpec`, so two stored connections pointing at the same remote and subpath
    /// — the same remote added twice, or one connection duplicated to mount it
    /// somewhere else — share one cache. Checking the id alone would let a
    /// disconnected connection clear the cache its mounted twin is reading from.
    ///
    /// Includes mounts still being established, which are in neither `active` nor
    /// the mount table yet.
    func isServing(fsSpec: String) -> Bool {
        active.values.contains { $0.connection.fsSpec == fsSpec } || connecting.contains(fsSpec)
    }

    /// Reclaim a connection's cache.
    ///
    /// Three refusals, and none of them is skippable — unlike deletion, where a user
    /// who has been shown the list can choose to discard it. There is no equivalent
    /// reason to force this: the point of clearing a cache is to free disk, and
    /// losing an unsent file to free disk is never the trade anyone wanted.
    ///
    /// Refuses while mounted because rclone is serving from these files; deleting
    /// them underneath a live mount produces read errors rather than a clean re-fetch.
    @discardableResult
    public func clearCache(for connection: Connection) async throws -> Int64 {
        guard !isServing(fsSpec: connection.fsSpec) else { throw CacheRefusal.stillMounted }

        let root = try await rcloneCacheRoot()
        let usage = VFSCache.usage(cacheRoot: root, fsSpec: connection.fsSpec)

        if usage.pending.inspectionFailed { throw CacheRefusal.cacheUnreadable }
        guard usage.pending.dirtyFiles.isEmpty else {
            throw CacheRefusal.pendingUploads(files: usage.pending.dirtyFiles)
        }

        try VFSCache.purge(cacheRoot: root, fsSpec: connection.fsSpec)
        return usage.bytes
    }

    // MARK: - Deleting a remote

    /// Why a deletion was refused, or what it achieved.
    public enum DeletionRefusal: Error, LocalizedError {
        case pendingUploads(files: [String])
        case cacheUnreadable
        case noSuchRemote(String)
        case stillMounted(String)

        public var errorDescription: String? {
            switch self {
            case .pendingUploads(let files):
                let sample = files.prefix(3).joined(separator: ", ")
                let more = files.count > 3 ? ", and \(files.count - 3) more" : ""
                return "\(files.count) file(s) saved to this remote have not finished "
                     + "uploading yet: \(sample)\(more). Deleting now would lose them, "
                     + "because the only copy is in the local cache. Connect the remote "
                     + "and wait for uploads to finish, then try again."
            case .cacheUnreadable:
                return "grrclone could not read this remote's local cache, so it cannot "
                     + "tell whether anything is still waiting to upload. It will not "
                     + "delete a cache it cannot account for."
            case .noSuchRemote(let name):
                return "There is no remote called \(name) in your rclone configuration."
            case .stillMounted(let path):
                return "\(path) could not be disconnected, so the remote was not "
                     + "deleted. Nothing has been changed."
            }
        }
    }

    public struct DeletionOutcome: Sendable, Equatable {
        /// Where the configuration was copied before it was rewritten.
        public var backup: URL
        /// The mountpoint taken down on the way, if it was connected.
        public var unmounted: String?
        /// True when the local cache was removed.
        public var cachePurged: Bool
    }

    /// Where rclone keeps its VFS cache, asked of the daemon.
    ///
    /// **Not `self.cacheRoot`.** That is grrclone's own root, passed to `serve/start`
    /// for the NFS handle cache. rclone's VFS cache lives under its `--cache-dir`,
    /// which is set from `DaemonSettings` and is a different value that merely happens
    /// to default to the same path. Reading the wrong one would report "nothing
    /// pending" for a cache full of unsent writes — a fail-open on the check that
    /// protects the user's data, hidden behind two settings that agree today.
    ///
    /// `config/paths` is the authority, so the two cannot drift.
    private func rcloneCacheRoot() async throws -> URL {
        let client = try await supervisor.requireClient()
        let paths = try await client.configPaths()
        guard !paths.cache.isEmpty else { throw DeletionRefusal.cacheUnreadable }
        return URL(fileURLWithPath: paths.cache)
    }

    /// What deleting this remote would refuse on, without doing anything.
    ///
    /// Exposed so the confirmation dialog can show the real obstacle before the user
    /// commits, rather than letting them type a name and then be told no.
    public func pendingUploads(for connection: Connection) async -> PendingUploads {
        guard let root = try? await rcloneCacheRoot() else {
            return PendingUploads(inspectionFailed: true)
        }
        return VFSCache.pendingUploads(cacheRoot: root, fsSpec: connection.fsSpec)
    }

    /// Remove a remote from rclone's configuration, and grrclone's cache of it.
    ///
    /// The order is the same one every other teardown path in this type uses, for the
    /// same reasons, and it is not interchangeable:
    ///
    /// 1. **Refuse if anything is still uploading.** `--vfs-cache-mode full` returns
    ///    from a write as soon as the bytes are on local disk, so the cache can hold
    ///    the only copy of a file. This is the step that protects the user's own work,
    ///    and it fails closed: a cache that cannot be read counts as "unknown", not
    ///    "empty".
    /// 2. **Unmount, then stop the server** — via `disconnect`, rather than
    ///    reimplemented here. Stopping the server first leaves the kernel talking to a
    ///    dead NFS server and hangs Finder.
    /// 3. **Back up `rclone.conf`.** Taken here and not earlier: nothing above this
    ///    line writes to that file, so an earlier copy would only litter backups for
    ///    deletions that were refused.
    /// 4. **Delete the remote**, then the local cache.
    ///
    /// The keychain is deliberately untouched. It holds the password for the
    /// *configuration file*, keyed by config path — not this remote's credentials.
    /// Removing it because the last remote went away would lock the user out of a
    /// config they still have. See #56.
    ///
    /// - Parameter force: skip only the pending-upload refusal, for a user who has
    ///   been shown the list and chosen to discard it. Nothing else is skippable.
    public func deleteRemote(_ connection: Connection,
                             configPath: String,
                             force: Bool = false) async throws -> DeletionOutcome {
        let client = try await supervisor.requireClient()

        // Fail before touching anything if the remote is not there. This also avoids
        // leaving a backup behind for a deletion that was never possible.
        let remotes = try await client.listRemotes()
        guard remotes.contains(connection.remote) else {
            throw DeletionRefusal.noSuchRemote(connection.remote)
        }

        let cacheRoot = try await rcloneCacheRoot()

        if !force {
            let pending = VFSCache.pendingUploads(cacheRoot: cacheRoot,
                                                  fsSpec: connection.fsSpec)
            if pending.inspectionFailed { throw DeletionRefusal.cacheUnreadable }
            if !pending.dirtyFiles.isEmpty {
                throw DeletionRefusal.pendingUploads(files: pending.dirtyFiles)
            }
        }

        var unmounted: String?
        if let mount = active[connection.id] {
            let path = mount.mountPoint.path
            do {
                try await disconnect(connection.id)
            } catch {
                // Leave everything as it was. A remote whose volume is still mounted
                // must keep its configuration, or the mount has no server to go back
                // to and no way to be recreated.
                throw DeletionRefusal.stillMounted(path)
            }
            unmounted = path

            // Scan again now the volume is down.
            //
            // The first scan happened while the mount was live, so a write could land
            // between it and the unmount and be dirty by the time we get here — and
            // the purge below would then delete its only copy. Nothing can write to
            // the remote any more at this point, so this answer is the one that holds.
            //
            // Aborting here is safe and leaves the user better off than proceeding:
            // the remote is still configured and its cache is untouched, so the write
            // survives and reconnecting will upload it. Only the mount was lost.
            if !force {
                let after = VFSCache.pendingUploads(cacheRoot: cacheRoot,
                                                    fsSpec: connection.fsSpec)
                if after.inspectionFailed { throw DeletionRefusal.cacheUnreadable }
                if !after.dirtyFiles.isEmpty {
                    throw DeletionRefusal.pendingUploads(files: after.dirtyFiles)
                }
            }
        }

        let backup = try ConfigBackup.make(configPath: configPath)
        try await client.deleteRemote(name: connection.remote)

        // Last, and allowed to fail without failing the deletion. The remote is gone
        // from the configuration by this point; a cache directory that could not be
        // removed is disk space, not a correctness problem, and reporting the whole
        // operation as failed would be wrong.
        var purged = true
        do {
            try VFSCache.purge(cacheRoot: cacheRoot, fsSpec: connection.fsSpec)
        } catch {
            purged = false
        }

        return DeletionOutcome(backup: backup, unmounted: unmounted, cachePurged: purged)
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
        await recordLiveMounts()
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
                              mountRoot: Self.mountRoot(containing: mount.mountPoint,
                                                        displayName: mount.connection.displayName))
    }

    /// The root a mount point was mounted under: its path with the connection's own
    /// folder removed.
    ///
    /// Not simply the parent directory. A display name may contain a separator —
    /// `prepareMountPoint` creates intermediate directories, so `team/docs` really does
    /// mount at `<root>/team/docs` — and taking the parent would call `<root>/team` the
    /// root. Reconnecting would then append the whole name again and land at
    /// `<root>/team/team/docs`, which is the drift this function exists to prevent,
    /// reintroduced one level down.
    ///
    /// So remove exactly as many components as the name contributed. Standardised
    /// first, since a path built from a `~` expansion and one built from `/Users/…`
    /// must compare and rebuild identically.
    static func mountRoot(containing mountPoint: URL, displayName: String) -> URL {
        let depth = max(displayName.split(separator: "/").filter { !$0.isEmpty }.count, 1)
        var root = mountPoint.standardizedFileURL
        for _ in 0..<depth { root = root.deletingLastPathComponent() }
        return root
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
