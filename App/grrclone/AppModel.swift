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
    /// Set when the previous session did not shut down cleanly. Stays until the user
    /// dismisses it: a transient status line is the wrong shape for the one case
    /// where their data may actually have been affected.
    @Published private(set) var uncleanShutdown: UncleanShutdownReport?

    // MARK: Updates

    /// Off unless the user turns it on. grrclone promises no outbound connection
    /// except to the storage they configured; an update check is an exception they
    /// opt into, not one made on their behalf.
    @Published var updateChecksEnabled: Bool = UserDefaults.standard.bool(forKey: "UpdateChecksEnabled") {
        didSet {
            UserDefaults.standard.set(updateChecksEnabled, forKey: "UpdateChecksEnabled")
            if updateChecksEnabled { checkForUpdates() } else { availableUpdate = nil }
        }
    }
    @Published var includePrereleases: Bool = UserDefaults.standard.bool(forKey: "UpdateIncludePrereleases") {
        didSet {
            UserDefaults.standard.set(includePrereleases, forKey: "UpdateIncludePrereleases")
            if updateChecksEnabled { checkForUpdates() }
        }
    }
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var updateCheckInProgress = false

    /// Whether `rclone.conf` on disk is encrypted. Drives the offer to encrypt it,
    /// and the honesty of what the wizard says about where passwords go.
    /// Nil when it could not be determined. The UI must say "unknown" rather than
    /// asserting a security state it does not know — see ConfigEncryption.
    @Published private(set) var configIsEncryptedOnDisk: Bool?
    @Published private(set) var configPath: String = ""

    /// How this copy was installed, which decides who may update it.
    let installation = InstallationKind.detect()

    var currentVersion: ReleaseVersion {
        ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                       as? String ?? "0.0.0") ?? ReleaseVersion("0.0.0")!
    }
    @Published var lastError: String?
    @Published private(set) var activity = ConnectionManager.Activity()
    /// True when the user's rclone config is encrypted, which enables the
    /// configuration section in Settings.
    @Published private(set) var configIsEncrypted = false
    @Published private(set) var hasSavedConfigPassword = false
    /// True when the config is encrypted and still locked, because the user cancelled
    /// the prompt. Drives the "Unlock Configuration" item in the menu, so cancelling is
    /// recoverable without restarting the app.
    @Published private(set) var configLocked = false

    /// The daemon-wide transfer limit, in rclone's own syntax. Empty means unlimited.
    ///
    /// Stored as what rclone reports rather than what was typed: `1M` comes back as
    /// `1Mi`, so keeping the typed form would show a value the daemon is not using.
    @Published private(set) var bandwidthLimit: String = ""
    /// Recent daemon output, refreshed while the Logs tab is open.
    @Published private(set) var logLines: [DaemonLog.Line] = []
    @Published private(set) var logLevel: DaemonSettings.LogLevel = AppModel.loadLogLevel()
    private static let logLevelKey = "DaemonLogLevel"
    private static let bandwidthKey = "BandwidthLimit"
    private var configPasswordStore: ConfigPasswordStore?

    private var activityPoller: Task<Void, Never>?
    private let systemEvents = SystemEvents()
    private let store = ConnectionStore()
    private let registry = MountRegistry(fileURL: MountRegistry.defaultURL())
    private var manager: ConnectionManager?
    private var supervisor: DaemonSupervisor?

    /// Where connections are mounted. Configurable because the default is not always
    /// right: a machine migrating from a hand-rolled setup already has established
    /// paths, and documentation, scripts and muscle memory point at them.
    @Published var mountRoot: URL = AppModel.loadMountRoot() {
        didSet { UserDefaults.standard.set(mountRoot.path, forKey: Self.mountRootKey) }
    }

    private static let mountRootKey = "MountRoot"

    private static func loadMountRoot() -> URL {
        if let path = UserDefaults.standard.string(forKey: mountRootKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return ConnectionManager.defaultMountRoot()
    }

    // MARK: - Startup

    func start() async {
        guard let binary = DaemonSupervisor.locateBinary(bundled: Self.bundledRcloneURL()) else {
            status = "rclone not found"
            lastError = "No rclone binary was found. Install rclone, or use a build that bundles it."
            return
        }

        let supervisor = DaemonSupervisor(
            binary: binary, settings: DaemonSettings(logLevel: Self.loadLogLevel()))
        let manager = ConnectionManager(supervisor: supervisor, registry: registry)
        self.supervisor = supervisor
        self.manager = manager

        // Before anything starts: teach the supervisor to bring our mounts down before
        // it kills a daemon left over from an unclean shutdown. Killing it first leaves
        // the kernel talking to a dead NFS server.
        await manager.installOrphanCleanup()

        do {
            let client = try await supervisor.start()

            // Clear anything a previous unclean shutdown left behind before the user can
            // act on stale state.
            if let report = try? await manager.reconcileOrphans(), !report.cleaned.isEmpty {
                status = "Recovered \(report.cleaned.count) mount(s) from a previous session"
            }

            // Reported rather than fixed silently. Recovery already happens — orphans
            // reaped, stale mounts cleared — but an unclean shutdown is the one case
            // where the user's own data may be involved, and they cannot check
            // something nobody told them about.
            if let previous = await supervisor.previousSession {
                uncleanShutdown = UncleanShutdownReport.inspect(previous)
            }

            // An encrypted config fails here, not at daemon start: rclone starts
            // happily and only objects when something reads the config.
            guard try await unlockConfigIfNeeded(client) else {
                status = "Configuration locked"
                configLocked = true
                daemonReady = true
                ConfigPasswordPrompt.explainCancelled()
                return
            }

            let remotes = try await client.listRemotes()
            _ = try? await store.adoptNewRemotes(remotes)

            daemonReady = true
            await finishStartup()
        } catch {
            status = "rclone failed to start"
            lastError = error.localizedDescription
        }
    }

    /// True when the config is readable, false when the user declined to unlock it.
    ///
    /// The flow, in the order it has to happen:
    ///
    /// 1. Try to read the config. Unencrypted configs take this path and stop here, so
    ///    nobody without an encrypted config ever sees a password prompt.
    /// 2. If it is locked, try a password saved in the keychain. A returning user with
    ///    a saved password is never prompted.
    /// 3. A saved password that no longer works is **deleted**, not kept and retried
    ///    at every launch. Someone who changes their config password would otherwise
    ///    be prompted forever with a stale password silently failing first.
    /// 4. Otherwise ask, and keep asking while the password is wrong, until it works or
    ///    the user cancels.
    @discardableResult
    private func unlockConfigIfNeeded(_ client: RcloneRCClient) async throws -> Bool {
        guard await client.isConfigLocked() else { return true }

        let path = (try? await client.configPaths().config) ?? "your rclone configuration"
        let passwords = ConfigPasswordStore(configPath: path)
        self.configPasswordStore = passwords

        hasSavedConfigPassword = passwords.hasSavedPassword

        if let saved = passwords.load() {
            do {
                try await client.unlockConfig(password: saved)
                configIsEncrypted = true
                configLocked = false
                return true
            } catch RcloneRCError.configPasswordRejected {
                // Stale. Remove it rather than failing silently at every launch.
                //
                // The published flag has to follow. Leaving it true after the item is
                // gone makes Settings claim the password is saved and offer to forget
                // something that no longer exists, while the next launch prompts again
                // — the app contradicting itself about the one thing the user asked it
                // to remember. A deletion that fails is reported rather than hidden,
                // because then the stale item really is still there.
                do {
                    try passwords.forget()
                    hasSavedConfigPassword = false
                } catch {
                    lastError = "Could not remove the saved configuration password: "
                             + error.localizedDescription
                    hasSavedConfigPassword = passwords.hasSavedPassword
                }
            }
        }

        var retrying = false
        while true {
            guard let response = ConfigPasswordPrompt.ask(configPath: path, retrying: retrying)
            else { return false }

            do {
                try await client.unlockConfig(password: response.password)
            } catch RcloneRCError.configPasswordRejected {
                retrying = true
                continue
            }

            if response.shouldSave {
                // A failure to save is worth saying out loud: the user asked not to be
                // prompted again, and silently ignoring that is a small betrayal.
                do {
                    try passwords.save(response.password)
                    hasSavedConfigPassword = true
                } catch {
                    lastError = "Could not save the password: \(error.localizedDescription)"
                }
            }
            configIsEncrypted = true
            configLocked = false
            return true
        }
    }

    /// Everything that has to happen once the config can actually be read.
    ///
    /// Factored out because there are two ways to arrive here. Cancelling the password
    /// prompt returns from `start()` early, and `connectLoginItems()` — called by the
    /// app delegate immediately after `start()` — then runs against an empty list. If
    /// unlocking later only refreshed the rows, the app would sit there with nothing
    /// connected at login, no activity reporting, and no wake or network self-healing,
    /// until it was restarted. The user would have no way to know that unlocking had
    /// left them in a lesser state than launching unlocked.
    ///
    /// Idempotent: the watchers must not be started twice if this runs again.
    private var startupCompleted = false

    private func finishStartup() async {
        let remotes = (try? await requireClientRemotes()) ?? []
        if !remotes.isEmpty { _ = try? await store.adoptNewRemotes(remotes) }

        status = "Ready"
        await refresh()

        guard !startupCompleted else { return }
        startupCompleted = true

        // Reapply the saved limit. It lives in the daemon, not on disk, so a restart
        // — including one caused by a crash — silently returns to unlimited unless it
        // is set again here.
        await applySavedBandwidthLimit()

        await connectLoginItems()
        await refreshConfigEncryptionState()
        if updateChecksEnabled { checkForUpdates() }
        startWatchingForBreakage()
        startPollingActivity()
    }

    private func requireClientRemotes() async throws -> [String] {
        guard let supervisor else { return [] }
        return try await supervisor.requireClient().listRemotes()
    }

    /// Prompt for the password again after the user cancelled, from the menu.
    func unlockConfiguration() async {
        guard let supervisor, let client = try? await supervisor.requireClient() else { return }
        do {
            guard try await unlockConfigIfNeeded(client) else { return }
            await finishStartup()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Logs

    private static func loadLogLevel() -> DaemonSettings.LogLevel {
        guard let raw = UserDefaults.standard.string(forKey: logLevelKey),
              let level = DaemonSettings.LogLevel(rawValue: raw)
        else { return .notice }
        return level
    }

    /// Pull the latest daemon output into the published list.
    func refreshLogs() async {
        guard let supervisor else { return }
        logLines = await supervisor.log.recent
    }

    /// Change verbosity on the running daemon.
    ///
    /// Applied through the rc API rather than by restarting: a restart would unmount
    /// every volume, which is an absurd price for looking at a log, and would very
    /// likely destroy the transient failure being diagnosed. The launch flag is
    /// updated too, so the choice survives the next start.
    func setLogLevel(_ level: DaemonSettings.LogLevel) {
        logLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: Self.logLevelKey)
        Task {
            guard let supervisor, let client = try? await supervisor.requireClient() else { return }
            do { try await client.setLogLevel(level.rawValue) }
            catch { lastError = "Could not change the log level: \(error.localizedDescription)" }
        }
    }

    func clearLogs() {
        Task {
            await supervisor?.log.clear()
            await refreshLogs()
        }
    }

    // MARK: - Bandwidth

    /// Push the saved limit into a freshly started daemon.
    private func applySavedBandwidthLimit() async {
        let saved = UserDefaults.standard.string(forKey: Self.bandwidthKey) ?? ""
        guard !saved.isEmpty, saved != "off" else {
            bandwidthLimit = ""
            return
        }
        do {
            try await setBandwidthLimit(saved)
        } catch {
            // Worth saying out loud: the user set a limit and it is not in force.
            lastError = "Could not apply the saved bandwidth limit: \(error.localizedDescription)"
        }
    }

    /// Set the limit, and record what rclone actually applied.
    ///
    /// An invalid rate is rejected by rclone and the previous limit stays in force, so
    /// a typo throttles nothing unexpectedly — but the user still has to be told, or
    /// they will believe a limit is active that is not.
    func setBandwidthLimit(_ rate: String) async throws {
        guard let supervisor else { return }
        let client = try await supervisor.requireClient()
        let applied = try await client.setBandwidthLimit(rate)

        bandwidthLimit = applied.isLimited ? applied.rate : ""
        UserDefaults.standard.set(bandwidthLimit, forKey: Self.bandwidthKey)
    }

    /// Wrapper for the UI, which cannot throw.
    func updateBandwidthLimit(_ rate: String) {
        Task {
            do { try await setBandwidthLimit(rate) }
            catch { lastError = error.localizedDescription }
        }
    }

    /// Move data written into a mountpoint while nothing was mounted there.
    ///
    /// Moved, never merged: grrclone cannot know whether these files are newer than
    /// what is on the server, and guessing wrong overwrites the wrong copy.
    func recoverShadowedData() {
        guard let report = uncleanShutdown else { return }
        var recovered: [String] = []
        for path in report.shadowedPaths {
            do { recovered.append(try UncleanShutdownReport.recover(path: path).path) }
            catch { lastError = "Could not move \(path): \(error.localizedDescription)" }
        }
        if !recovered.isEmpty {
            status = "Moved local data aside from \(recovered.count) folder(s)"
        }
        uncleanShutdown = nil
    }

    func dismissUncleanShutdown() { uncleanShutdown = nil }

    /// Set when the user asks to add a remote.
    ///
    /// The wizard is presented by the Settings window rather than by the menu, because
    /// the menu bar popover closes the moment anything takes focus — including a click
    /// in the wizard's own search field. A sheet on the popover therefore vanishes as
    /// soon as it is used. Settings is a real window and does not.
    @Published var showAddRemote = false

    // MARK: - Interactive remote setup

    /// Start configuring a remote that asks questions rather than taking a form.
    func beginConfiguring(name: String, type: String,
                          parameters: [String: String]) async throws -> RcloneRCClient.ConfigStep {
        guard let supervisor else { throw DaemonSupervisor.Failure.notRunning }
        return try await supervisor.requireClient()
            .beginConfiguring(name: name, type: type, parameters: parameters)
    }

    func continueConfiguring(name: String, state: String,
                             answer: String) async throws -> RcloneRCClient.ConfigStep {
        guard let supervisor else { throw DaemonSupervisor.Failure.notRunning }
        return try await supervisor.requireClient()
            .continueConfiguring(name: name, state: state, answer: answer)
    }

    /// Pick up a remote created by the interactive flow.
    func adoptNewRemotes() async {
        guard let supervisor, let client = try? await supervisor.requireClient() else { return }
        _ = try? await store.adoptNewRemotes(try await client.listRemotes())
        await refresh()
    }

    /// Remove a remote left half-built by an abandoned flow.
    func discardRemote(named name: String) async {
        guard let supervisor, let client = try? await supervisor.requireClient() else { return }
        try? await client.deleteRemote(name: name)
    }

    // MARK: - Configuration encryption

    /// Look at the file, not the daemon.
    ///
    /// A running daemon that has already been given the password answers questions
    /// about the config perfectly well, so its behaviour says nothing about what is
    /// sitting on disk.
    func refreshConfigEncryptionState() async {
        guard let supervisor, let client = try? await supervisor.requireClient() else { return }
        guard let path = try? await client.configPaths().config, !path.isEmpty else { return }
        configPath = path
        configIsEncryptedOnDisk = ConfigEncryption.encryptionState(configPath: path)
    }

    /// Encrypt the configuration, then hand the password to the running daemon.
    ///
    /// The unlock matters: the daemon keeps working from its in-memory copy, so
    /// nothing breaks immediately, and the failure would only appear later when
    /// something made it re-read the file. Verified against a live daemon — mounts
    /// stay up throughout.
    func encryptConfiguration(password: String, remember: Bool) async {
        guard let supervisor, let client = try? await supervisor.requireClient() else { return }
        guard let binary = DaemonSupervisor.locateBinary(bundled: Self.bundledRcloneURL()) else {
            lastError = "No rclone binary was found."
            return
        }

        // Ask again rather than trusting whatever the last refresh left behind.
        // `configPath` starts empty and `refreshConfigEncryptionState()` returns early
        // on several paths, so it can still be "" here — which became
        // `rclone --config ""`, aiming a real password at an unintended target and
        // then reporting that encryption silently failed.
        await refreshConfigEncryptionState()
        guard !configPath.isEmpty else {
            lastError = ConfigEncryption.Failure.unknownConfigPath.localizedDescription
            return
        }

        do {
            try ConfigEncryption.encrypt(rclone: binary, configPath: configPath,
                                         password: password)
            try await client.unlockConfig(password: password)

            configIsEncryptedOnDisk = true
            configIsEncrypted = true

            if remember {
                let store = ConfigPasswordStore(configPath: configPath)
                configPasswordStore = store
                do {
                    try store.save(password)
                    hasSavedConfigPassword = true
                } catch {
                    lastError = "Encrypted, but the password could not be saved: "
                              + error.localizedDescription
                }
            }
            status = "Configuration encrypted"
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Remotes

    /// The backends rclone supports, asked of the daemon rather than listed here.
    func availableProviders() async throws -> [RcloneRCClient.Provider] {
        guard let supervisor else { return [] }
        return try await supervisor.requireClient().providers()
    }

    /// Create a remote and pick it up straight away.
    ///
    /// grrclone otherwise only reads `rclone.conf` at startup, so a remote created
    /// here would not appear until relaunch — which looks like the wizard failed.
    func createRemote(name: String, type: String, parameters: [String: String]) async throws {
        guard let supervisor else { return }
        let client = try await supervisor.requireClient()
        try await client.createRemote(name: name, type: type, parameters: parameters)

        _ = try? await store.adoptNewRemotes(try await client.listRemotes())
        await refresh()
        status = "Added \(name)"
    }

    // MARK: - Updates

    /// Ask GitHub whether a newer release exists.
    ///
    /// Checks only — nothing is downloaded or installed. Self-installing means
    /// verifying a signature on a downloaded bundle and swapping a running app: a
    /// large attack surface to add to a program that mounts your storage, and for
    /// Homebrew users it is work Homebrew already does properly.
    func checkForUpdates() {
        // The gate lives here, not only at the call sites.
        //
        // It was previously applied by each caller, and "Check Now" did not apply it,
        // so the app would contact GitHub with the preference switched off. Three call
        // sites and one of them already wrong is how a promise erodes: the next timer
        // or retry path would have been the fourth.
        guard updateChecksEnabled else { return }
        guard !updateCheckInProgress else { return }
        updateCheckInProgress = true

        let current = currentVersion
        let prereleases = includePrereleases
        Task {
            defer { updateCheckInProgress = false }
            do {
                availableUpdate = try await UpdateChecker()
                    .check(current: current, includePrereleases: prereleases)
                lastUpdateCheck = Date()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Open the release page. Deliberately not "install" — see `checkForUpdates`.
    func openReleasePage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.pageURL)
    }

    func dismissUpdate() { availableUpdate = nil }

    /// Dismiss the error shown in the menu.
    func clearLastError() { lastError = nil }

    /// Forget a saved config password. Exposed in Settings so the choice to remember it
    /// is reversible without opening Keychain Access.
    func forgetConfigPassword() {
        guard let configPasswordStore else { return }
        do {
            try configPasswordStore.forget()
            hasSavedConfigPassword = false
        } catch {
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
                let root = await MainActor.run { self.mountRoot }
                let mount = try await manager.connect(connection, mountRoot: root)
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

    /// Connections whose saved settings are not the ones currently in force, because
    /// they were edited while mounted.
    ///
    /// `displayName`, `readOnly` and the cache size are all consumed at `connect()`
    /// time, so editing a live connection changed nothing and said nothing. The
    /// read-only case is the one that matters: the user believes a safety setting is
    /// active on a volume that is still accepting writes.
    @Published private(set) var needsRemount: Set<UUID> = []

    func update(_ connection: Connection) {
        let wasMounted = rows.first { $0.id == connection.id }?.state.isMounted ?? false
        Task {
            try? await store.upsert(connection)
            if wasMounted { needsRemount.insert(connection.id) }
            await refresh()
        }
    }

    /// Apply pending edits by taking the connection down and bringing it back up.
    ///
    /// Explicit rather than automatic: a remount interrupts whatever is reading the
    /// volume, and doing that without being asked is its own surprise.
    func remount(_ connection: Connection) {
        setState(.connecting, for: connection.id)
        Task.detached { [manager] in
            guard let manager else { return }
            do {
                try await manager.disconnect(connection.id)
                let root = await MainActor.run { self.mountRoot }
                let mount = try await manager.connect(connection, mountRoot: root)
                await MainActor.run {
                    self.needsRemount.remove(connection.id)
                    self.setState(.mounted(at: mount.mountPoint), for: connection.id)
                    self.status = "Remounted \(connection.displayName)"
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
