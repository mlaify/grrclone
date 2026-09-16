import Foundation
import SwiftUI
import AppKit
import GrrCloneCore
import RcloneRC

/// Bridges the actor-based core to SwiftUI.
///
/// Every operation that touches a mount runs on a detached task. That is a hard rule,
/// not a style preference: `/sbin/mount`, `diskutil` and even `stat` can block for a
/// long time against a wedged NFS mount, and doing any of it on the main actor produces
/// exactly the beachball this project exists to avoid.
@MainActor
final class AppModel: ObservableObject {

    /// Shared because both the SwiftUI scene and the app delegate need it, and startup
    /// must be driven from the delegate rather than from a view that may never appear.
    static let shared = AppModel()

    struct Row: Identifiable, Equatable {
        let connection: Connection
        var state: ConnectionState
        var id: UUID { connection.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var status: String = "Starting"
    @Published private(set) var daemonReady = false
    @Published private(set) var foreignMounts: [String] = []
    @Published var lastError: String?
    @Published private(set) var activity = ConnectionManager.Activity()

    private var activityPoller: Task<Void, Never>?
    private let systemEvents = SystemEvents()
    private let store = ConnectionStore()
    private let registry = MountRegistry(fileURL: MountRegistry.defaultURL())
    private var manager: ConnectionManager?
    private var supervisor: DaemonSupervisor?

    var mountRoot: URL { ConnectionManager.defaultMountRoot() }

    // MARK: - Startup

    func start() async {
        guard let binary = DaemonSupervisor.locateBinary(bundled: Self.bundledRcloneURL()) else {
            status = "rclone not found"
            lastError = "No rclone binary was found. Install rclone, or use a build that bundles it."
            return
        }

        let supervisor = DaemonSupervisor(binary: binary)
        let manager = ConnectionManager(supervisor: supervisor, registry: registry)
        self.supervisor = supervisor
        self.manager = manager

        do {
            let client = try await supervisor.start()

            // Clear anything a previous unclean shutdown left behind before the user can
            // act on stale state.
            if let report = try? await manager.reconcileOrphans(), !report.cleaned.isEmpty {
                status = "Recovered \(report.cleaned.count) mount(s) from a previous session"
            }

            let remotes = try await client.listRemotes()
            _ = try? await store.adoptNewRemotes(remotes)

            daemonReady = true
            status = "Ready"
            await refresh()
            startWatchingForBreakage()
            startPollingActivity()
        } catch {
            status = "rclone failed to start"
            lastError = error.localizedDescription
        }
    }

    /// Located inside the app bundle when present. A bundled copy is preferred over a
    /// Homebrew install because rclone's NFS behaviour varies across releases and the
    /// bundled one is pinned and tested.
    private static func bundledRcloneURL() -> URL? {
        Bundle.main.url(forResource: "rclone", withExtension: nil)
    }

    // MARK: - Refresh

    func refresh() async {
        let connections = await store.all
        let active = await manager?.activeMounts ?? []
        let activeByID = Dictionary(uniqueKeysWithValues: active.map { ($0.connection.id, $0) })

        var updated: [Row] = []
        for connection in connections {
            if let mount = activeByID[connection.id] {
                updated.append(Row(connection: connection, state: .mounted(at: mount.mountPoint)))
            } else if let existing = rows.first(where: { $0.id == connection.id }),
                      case .connecting = existing.state {
                updated.append(existing)
            } else {
                updated.append(Row(connection: connection, state: .disconnected))
            }
        }
        rows = updated.sorted { $0.connection.displayName < $1.connection.displayName }
        foreignMounts = await manager?.foreignLookalikes() ?? []
    }

    // MARK: - Actions

    func toggle(_ connection: Connection) {
        guard let row = rows.first(where: { $0.id == connection.id }) else { return }
        if row.state.isMounted {
            disconnect(connection)
        } else {
            connect(connection)
        }
    }

    func connect(_ connection: Connection) {
        setState(.connecting, for: connection.id)
        Task.detached { [manager] in
            do {
                guard let manager else { return }
                let mount = try await manager.connect(connection)
                await MainActor.run {
                    self.setState(.mounted(at: mount.mountPoint), for: connection.id)
                    self.status = "Connected \(connection.displayName)"
                }
            } catch {
                await MainActor.run {
                    self.setState(.failed(error.localizedDescription), for: connection.id)
                    self.lastError = error.localizedDescription
                    self.status = "Failed to connect \(connection.displayName)"
                }
            }
            await self.refresh()
        }
    }

    func disconnect(_ connection: Connection) {
        setState(.connecting, for: connection.id)
        Task.detached { [manager] in
            do {
                try await manager?.disconnect(connection.id)
                await MainActor.run {
                    self.setState(.disconnected, for: connection.id)
                    self.status = "Disconnected \(connection.displayName)"
                }
            } catch {
                await MainActor.run {
                    self.setState(.failed(error.localizedDescription), for: connection.id)
                    self.lastError = error.localizedDescription
                }
            }
            await self.refresh()
        }
    }

    func reveal(_ connection: Connection) {
        guard let row = rows.first(where: { $0.id == connection.id }),
              case .mounted(let url) = row.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func update(_ connection: Connection) {
        Task {
            try? await store.upsert(connection)
            await refresh()
        }
    }

    /// Ordered teardown, run before the app exits. Mounts come down before the daemon,
    /// because killing rclone under a live NFS mount leaves the kernel talking to a dead
    /// server and hangs Finder until the mount is forcibly removed.
    /// - Parameter drainTimeout: seconds to wait for uploads before unmounting. Zero
    ///   skips the wait, for a user who was told what was pending and chose to quit.
    @discardableResult
    func shutdown(drainTimeout: TimeInterval = 0) async -> ConnectionManager.ShutdownOutcome {
        status = "Disconnecting"
        activityPoller?.cancel()
        activityPoller = nil
        guard let manager else { return .init() }
        return await manager.shutdown(drainTimeout: drainTimeout) { pending in
            Task { @MainActor in self.status = "Finishing uploads (\(pending) left)" }
        }
    }

    /// Worst case for a full teardown, so the caller can size its watchdog from the
    /// real budget rather than a guess.
    func teardownBudget(drainTimeout: TimeInterval) async -> TimeInterval {
        guard let manager else { return 5 }
        return await manager.teardownBudget(drainTimeout: drainTimeout)
    }

    /// Sleep and network changes break mounts without reporting an error anywhere: the
    /// mount stays in the table but stops responding, and Finder hangs on it. Probe and
    /// repair when either happens.
    private func startWatchingForBreakage() {
        systemEvents.start { [weak self] reason in
            guard let self else { return }
            self.status = "Checking mounts after \(reason)"
            Task.detached { [manager] in
                // Waking is not instantaneous; give the network a moment to settle
                // before deciding a mount is broken.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let report = await manager?.checkHealth() else { return }
                await MainActor.run {
                    if !report.repaired.isEmpty {
                        self.status = "Reconnected \(report.repaired.count) mount(s)"
                    } else if !report.failed.isEmpty {
                        self.status = "\(report.failed.count) mount(s) need attention"
                        self.lastError = report.failed.values.first
                    } else {
                        self.status = "Ready"
                    }
                }
                await self.refresh()
            }
        }
    }

    /// Poll local cache state so pending uploads are visible, and so quitting can warn
    /// about them. Two seconds is frequent enough to feel live without being noisy.
    private func startPollingActivity() {
        activityPoller?.cancel()
        // The handle is retained so shutdown can stop it. Without that, the loop keeps
        // running after the daemon is gone and overwrites the published activity with
        // the empty snapshot an unreachable daemon returns — clearing the menu's
        // pending-upload notice at the exact moment it matters most.
        activityPoller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let manager = await self.currentManager else { return }
                let snapshot = await manager.activity()
                if Task.isCancelled { return }
                await MainActor.run { self.activity = snapshot }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var currentManager: ConnectionManager? { manager }

    /// Last polled count, for display only. Up to two seconds stale, so it must never
    /// be the basis of a safety decision — use `currentActivity()` for that.
    var pendingUploads: Int { activity.pendingUploads }

    /// Ask rclone right now rather than trusting the poll.
    ///
    /// The quit path needs this: a file copied in Finder and followed immediately by
    /// Cmd-Q lands inside the two-second polling gap, so the cached count still reads
    /// zero and the drain would be skipped entirely — the precise case this feature
    /// exists to catch.
    func currentActivity() async -> ConnectionManager.Activity {
        guard let manager else { return ConnectionManager.Activity() }
        let snapshot = await manager.activity()
        activity = snapshot
        return snapshot
    }

    /// Probe now, on demand, from the menu.
    func checkHealthNow() {
        status = "Checking mounts"
        Task.detached { [manager] in
            guard let report = await manager?.checkHealth() else { return }
            await MainActor.run {
                self.status = report.failed.isEmpty
                    ? "All \(report.healthy.count + report.repaired.count) mount(s) healthy"
                    : "\(report.failed.count) mount(s) need attention"
            }
            await self.refresh()
        }
    }

    /// Connect everything marked "connect at login". Runs at launch, after
    /// reconciliation has cleared any stale mounts from a previous session.
    func connectLoginItems() async {
        guard daemonReady else { return }
        for row in rows where row.connection.connectAtLogin && !row.state.isMounted {
            connect(row.connection)
        }
    }

    private func setState(_ state: ConnectionState, for id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }
}

extension ConnectionState {
    var symbolName: String {
        switch self {
        case .disconnected: return "circle"
        case .connecting: return "circle.dotted"
        case .mounted: return "circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .mounted: return .green
        case .failed: return .red
        }
    }

    var describedForMenu: String {
        switch self {
        case .disconnected: return "Not connected"
        case .connecting: return "Working…"
        case .mounted(let url): return url.path
        case .failed(let message): return message
        }
    }
}
