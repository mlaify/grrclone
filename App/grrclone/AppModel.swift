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
    @Published private(set) var foreignMounts: [ForeignMount] = []
    /// Set when the previous session did not shut down cleanly. Stays until the user
    /// dismisses it: a transient status line is the wrong shape for the one case
    /// where their data may actually have been affected.
    @Published private(set) var uncleanShutdown: UncleanShutdownReport?
    /// Set when the list of connections could not be read at launch. Its own
    /// notice, not `lastError`: it names where the user's settings went, and the
    /// startup errors that follow — no rclone, a daemon that will not start —
    /// overwrite `lastError` before it is ever rendered. By the next launch the
    /// original file is already moved and its location gone with it. Stays until
    /// dismissed. Codex found the overwrite on review.
    @Published private(set) var storeRecoveryNotice: String?

    // MARK: Updates

    /// Off unless the user turns it on. grrclone promises no outbound connection
    /// except to the storage they configured; an update check is an exception they
    /// opt into, not one made on their behalf.
    @Published var updateChecksEnabled: Bool = UserDefaults.standard.bool(forKey: "UpdateChecksEnabled") {
        didSet {
            UserDefaults.standard.set(updateChecksEnabled, forKey: "UpdateChecksEnabled")
            if updateChecksEnabled {
                // Ask for the notification permission here and nowhere else. The
                // user has just asked to be told about new versions, so being asked
                // how is expected — unlike a prompt at first launch, before they
                // have asked for anything, which is what trains people to refuse.
                Task {
                    notificationsAuthorised = await notifier.requestPermission()
                }
                startUpdateCheckTimer()
                checkForUpdates()
            } else {
                stopUpdateCheckTimer()
                availableUpdate = nil
            }
        }
    }
    @Published var includePrereleases: Bool = UserDefaults.standard.bool(forKey: "UpdateIncludePrereleases") {
        didSet {
            UserDefaults.standard.set(includePrereleases, forKey: "UpdateIncludePrereleases")
            if updateChecksEnabled { checkForUpdates() }
        }
    }
    @Published private(set) var availableUpdate: AvailableUpdate?

    /// Whether macOS will let us post a notification. Displayed so the Updates tab
    /// can say what state the one permission is in rather than leaving the user to
    /// check System Settings.
    @Published private(set) var notificationsAuthorised = false

    private let notifier = UpdateNotifier()
    private var updateCheckTimer: Task<Void, Never>?
    private static let lastNotifiedKey = "LastNotifiedVersion"

    /// The newest version already announced, so the same one is not announced twice.
    ///
    /// Persisted: an app that runs for weeks and is occasionally restarted would
    /// otherwise re-announce on every launch, which is the behaviour that teaches
    /// people to ignore notifications.
    private var lastNotifiedVersion: ReleaseVersion? {
        get { UserDefaults.standard.string(forKey: Self.lastNotifiedKey).flatMap(ReleaseVersion.init) }
        set { UserDefaults.standard.set(newValue?.description, forKey: Self.lastNotifiedKey) }
    }
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

    /// What the daemon is moving right now. Nil means it could not be asked — which
    /// a progress view must show differently from "nothing is transferring".
    @Published private(set) var transferStats: RcloneRCClient.Stats?
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
        // First of all, before any path that can return early — no rclone, a daemon
        // that will not start, a cancelled password prompt followed by Quit. Each
        // of those used to leave this unsaid, and by the next launch the original
        // file was already moved and its location gone with it (Codex, #113).
        await reportStoreLoadFailure()

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
            // act on stale state — and say what could not be cleared. `stillMounted`
            // was dropped here, so a recorded volume that would not unmount (a dead
            // server, no orphan daemon to name it) went unmentioned and connect-at-
            // login ran straight into its path (#117).
            if let report = try? await manager.reconcileOrphans() {
                if !report.cleaned.isEmpty {
                    status = "Recovered \(report.cleaned.count) mount(s) from a previous session"
                }
                blockedMountPoints = Set(report.stillMounted)
                if report.tableUnreadable {
                    lastError = "grrclone could not read the list of mounted volumes, so it "
                              + "cannot tell whether the \(report.stillMounted.count) volume(s) "
                              + "from the previous session are still up. It will not connect "
                              + "them until it can."
                } else if !report.stillMounted.isEmpty {
                    lastError = "\(report.stillMounted.count) volume(s) from the previous "
                              + "session could not be disconnected: "
                              + report.stillMounted.joined(separator: ", ")
                              + ". Run `umount -f <path>` for each, once per layer, then "
                              + "connect again. They will not be connected at login until then."
                }
            }

            // Reported rather than fixed silently. Recovery already happens — orphans
            // reaped, stale mounts cleared — but an unclean shutdown is the one case
            // where the user's own data may be involved, and they cannot check
            // something nobody told them about.
            if let previous = await supervisor.previousSession {
                // Off the main actor, under a deadline, and never on a path that is
                // still mounted: those are the ones that block for minutes (#118).
                if let table = try? await SystemMounts.current() {
                    uncleanShutdown = await UncleanShutdownReport.inspect(
                        previous, mountedPaths: Set(table.map(\.mountPoint)))
                } else {
                    // Cannot tell which are still mounted, so none can be listed
                    // safely. Unknown, said as unknown.
                    uncleanShutdown = UncleanShutdownReport(
                        previousStart: previous.startedAt, shadowedPaths: [], cleanPaths: [],
                        unreadablePaths: previous.mountPoints)
                }
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
            await adoptRemotesReporting(remotes)

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

    /// Say why every connection is suddenly back at its defaults, and where the
    /// file with the settings went.
    ///
    /// The first thing `start()` does, ahead of every early return. Adoption still
    /// runs when the file was moved aside: an empty menu is not a better outcome
    /// than a working one with a warning on it, and the quarantined file makes the
    /// settings recoverable by hand. When it could *not* be moved, the store
    /// refuses every write, and `adoptRemotesReporting` says so.
    private func reportStoreLoadFailure() async {
        guard let failure = await store.loadFailure else { return }
        if let aside = failure.quarantinedAt {
            storeRecoveryNotice = "grrclone could not read its list of connections "
                      + "(\(failure.reason)). The file was moved to \(aside.path) and "
                      + "your remotes have been set up again with default settings."
        } else {
            storeRecoveryNotice = "grrclone could not read its list of connections "
                      + "(\(failure.reason)) and could not move the file aside, so it "
                      + "will not save anything over it. Repair or move the file, "
                      + "then relaunch."
        }
    }

    func dismissStoreRecoveryNotice() { storeRecoveryNotice = nil }

    /// Adopt, and say so when it could not be saved. A `try?` here meant a remote
    /// that could not be persisted simply never appeared, with nothing to explain
    /// why (#121).
    private func adoptRemotesReporting(_ remotes: [String]) async {
        guard !remotes.isEmpty else { return }
        do { _ = try await store.adoptNewRemotes(remotes) }
        catch { lastError = "Could not save the list of connections: \(error.localizedDescription)" }
    }

    private func finishStartup() async {
        let remotes = (try? await requireClientRemotes()) ?? []
        await adoptRemotesReporting(remotes)

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
        if updateChecksEnabled {
            startUpdateCheckTimer()
            // Ask before the first check, so a release found immediately can still
            // be announced rather than being recorded as told to nobody.
            Task {
                await requestNotificationPermissionIfNeverAsked()
                checkForUpdates()
            }
        }
        startWatchingForBreakage()
        startPollingActivity()
        await startRepairingAfterDaemonExit()
    }

    /// A daemon that dies takes every mount with it; repair without waiting for a
    /// wake or a click (#119). The timer is the backstop for a server that is
    /// alive but wedged.
    private func startRepairingAfterDaemonExit() async {
        guard let manager else { return }
        let report: @Sendable (ConnectionManager.HealthReport) async -> Void = { [weak self] report in
            await MainActor.run {
                guard let self else { return }
                if !report.repaired.isEmpty {
                    self.status = "rclone stopped unexpectedly; reconnected \(report.repaired.count) mount(s)"
                } else if !report.failed.isEmpty {
                    self.status = "\(report.failed.count) mount(s) need attention"
                    self.lastError = report.failed.values.first
                }
            }
            await self?.refresh()
        }
        await manager.installDaemonExitRepair(onRepaired: report)
        await manager.startPeriodicHealthChecks(onRepaired: report)
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
        let paths = report.shadowedPaths
        uncleanShutdown = nil
        // Filesystem work, off the main actor. These paths were listed a moment
        // ago and are not mounted, so this is quick — but not on the UI thread.
        Task.detached {
            var recovered: [String] = []
            var failures: [String] = []
            for path in paths {
                do { recovered.append(try UncleanShutdownReport.recover(path: path).path) }
                catch { failures.append("Could not move \(path): \(error.localizedDescription)") }
            }
            await MainActor.run {
                if let failure = failures.first { self.lastError = failure }
                if !recovered.isEmpty {
                    self.status = "Moved local data aside from \(recovered.count) folder(s)"
                }
            }
        }
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

    /// Refuse a name that would replace an existing remote, and back the
    /// configuration up before anything writes to it.
    ///
    /// Both creation paths go through here, the wizard's own check included:
    /// rclone's `config/create` deletes the existing section first, so a collision
    /// that slipped past the form would cost a remote's credentials (#110). The
    /// backup is the same one deletion takes, for the same reason — this rewrites
    /// the file that holds every credential the user has.
    private func prepareToCreate(_ name: String, client: RcloneRCClient) async throws {
        if let why = RemoteName.refusal(for: name, existing: try await client.listRemotes()) {
            throw RemoteCreationRefusal.nameTaken(why)
        }
        await refreshConfigEncryptionState()
        guard !configPath.isEmpty else { throw RemoteCreationRefusal.noBackup }
        _ = try ConfigBackup.make(configPath: configPath)
    }

    enum RemoteCreationRefusal: Error, LocalizedError {
        case nameTaken(String)
        case noBackup
        var errorDescription: String? {
            switch self {
            case .nameTaken(let why): return why
            case .noBackup:
                return "grrclone could not determine where your rclone configuration "
                     + "lives, so it will not add to it without a backup."
            }
        }
    }

    /// Start configuring a remote that asks questions rather than taking a form.
    func beginConfiguring(name: String, type: String,
                          parameters: [String: String]) async throws -> RcloneRCClient.ConfigStep {
        guard let supervisor else { throw DaemonSupervisor.Failure.notRunning }
        let client = try await supervisor.requireClient()
        try await prepareToCreate(name, client: client)
        return try await client.beginConfiguring(name: name, type: type, parameters: parameters)
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
        if let remotes = try? await client.listRemotes() { await adoptRemotesReporting(remotes) }
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
            try await ConfigEncryption.encrypt(rclone: binary, configPath: configPath,
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

    /// The remotes that already exist, so the wizard can refuse a name up front.
    func existingRemoteNames() async -> [String] {
        guard let supervisor, let client = try? await supervisor.requireClient() else { return [] }
        return (try? await client.listRemotes()) ?? []
    }

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
        try await prepareToCreate(name, client: client)
        try await client.createRemote(name: name, type: type, parameters: parameters)

        await adoptRemotesReporting(try await client.listRemotes())
        await refresh()
        status = "Added \(name)"
    }

    // MARK: - Editing a remote

    /// The remote the edit sheet is open on.
    @Published var editingConnection: Connection?

    func beginEditing(_ connection: Connection) { editingConnection = connection }

    /// A remote's stored settings. Secrets arrive obscured — see `remoteConfig`.
    func remoteConfig(named name: String) async throws -> [String: String] {
        guard let supervisor else { throw DaemonSupervisor.Failure.notRunning }
        return try await supervisor.requireClient().remoteConfig(name: name)
    }

    /// Apply changed settings, then pick the result up.
    ///
    /// A mounted connection keeps serving from the settings it started with — rclone
    /// read them at `serve/start` — so the user is told to reconnect rather than left
    /// to wonder why a corrected endpoint made no difference.
    func updateRemote(named name: String, parameters: [String: String]) async throws {
        guard let supervisor else { throw DaemonSupervisor.Failure.notRunning }
        try await supervisor.requireClient().updateRemote(name: name, parameters: parameters)

        let affected = rows.filter { $0.connection.remote == name && $0.state.isMounted }
        for row in affected { needsRemount.insert(row.id) }
        await refresh()
        status = affected.isEmpty
            ? "Updated \(name)"
            : "Updated \(name) — reconnect for it to take effect"
    }

    // MARK: - Cache

    @Published private(set) var cacheUsage: [UUID: VFSCache.Usage] = [:]
    @Published private(set) var measuringCache = false

    var totalCacheBytes: Int64 { cacheUsage.values.reduce(0) { $0 + $1.bytes } }

    /// Measure on demand rather than on a poll.
    ///
    /// Walking the cache touches every file in it, which for a 20 GB cache is tens of
    /// thousands of `stat` calls. That is fine when someone opens the tab and asks;
    /// it is not something to do every two seconds in the background.
    func refreshCacheUsage() async {
        guard let manager else { return }
        measuringCache = true
        defer { measuringCache = false }
        let connections = rows.map(\.connection)
        cacheUsage = await manager.cacheUsage(for: connections)
    }

    func clearCache(for connection: Connection) async {
        guard let manager else { return }
        do {
            let freed = try await manager.clearCache(for: connection)
            status = "Cleared \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
                   + " from \(connection.displayName)"
            await refreshCacheUsage()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Deleting a remote

    /// The remote the delete sheet is confirming, if it is open.
    @Published var deletingConnection: Connection?
    /// What the cache says is still waiting to upload, for the sheet to show.
    @Published private(set) var deletionPending: PendingUploads?

    /// The other saved connections to the remote being deleted. They go with it,
    /// so the confirmation has to say so before the person confirms — the first
    /// version listed them only in the status afterwards. Codex, on review.
    var siblingsOfDeleting: [Connection] {
        guard let deleting = deletingConnection else { return [] }
        return rows.map(\.connection)
            .filter { $0.id != deleting.id && $0.remote == deleting.remote }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Open the confirmation, and look at the cache while it opens.
    ///
    /// The obstacle is discovered before the user commits rather than after. Making
    /// someone type a remote's name and *then* telling them it cannot be deleted is a
    /// worse experience than showing them the unsent files up front.
    func beginDeleting(_ connection: Connection) {
        deletingConnection = connection
        deletionPending = nil
        Task {
            guard let manager else { return }
            let pending = await manager.pendingUploads(for: connection)
            if deletingConnection?.id == connection.id { deletionPending = pending }
        }
    }

    func cancelDeleting() {
        deletingConnection = nil
        deletionPending = nil
    }

    /// Delete the remote, then forget grrclone's own record of it.
    ///
    /// The store is updated only after rclone's configuration is, so a failure part
    /// way through leaves a connection pointing at a remote that still exists rather
    /// than a remote with nothing pointing at it.
    /// Returns true only when the remote is really gone, so the sheet knows whether
    /// to close. Dismissing regardless would hide the reason: `lastError` renders in
    /// the menu bar, not in Settings, so a failed deletion would look like a silent
    /// no-op from where the user is standing.
    @discardableResult
    func confirmDelete(_ connection: Connection,
                       discardPendingUploads: Bool = false) async -> Bool {
        guard let manager else { return false }

        // Same trap as #79: `configPath` is populated by a refresh that returns early
        // on several paths, and an empty one would send the backup at nothing.
        await refreshConfigEncryptionState()
        guard !configPath.isEmpty else {
            lastError = "grrclone could not determine where your rclone configuration "
                      + "lives, so it will not delete anything from it."
            return false
        }

        status = "Deleting \(connection.displayName)"
        do {
            let outcome = try await manager.deleteRemote(connection,
                                                         configPath: configPath,
                                                         force: discardPendingUploads)
            needsRemount.remove(connection.id)

            // The remote is gone from rclone's configuration by this point, so the
            // deletion has succeeded whatever happens next. But a store write that
            // failed silently would leave a connection pointing at a remote that no
            // longer exists — it survives in memory, disappears on the next launch,
            // and reappears if the file is ever re-read. Say so rather than reporting
            // an unqualified success.
            // Every connection to that remote, not only this one. The others now
            // point at configuration that does not exist; left in the list they would
            // fail to connect forever with an error that names a remote the user
            // just deleted. None of them is mounted — deleteRemote refuses otherwise.
            let siblings = rows.map(\.connection).filter {
                $0.id != connection.id && $0.remote == connection.remote
            }
            var storeWarning = ""
            do {
                // One write for all of them: a failure part way through would
                // otherwise leave some pointing at configuration that is gone.
                try await store.remove(ids: Set([connection.id] + siblings.map(\.id)))
                for sibling in siblings { needsRemount.remove(sibling.id) }
            } catch {
                storeWarning = " grrclone could not update its own list of connections, "
                             + "so \(connection.displayName) may reappear until you "
                             + "restart: \(error.localizedDescription)"
                lastError = storeWarning.trimmingCharacters(in: .whitespaces)
            }

            cancelDeleting()
            await refresh()
            let alsoRemoved = siblings.isEmpty ? ""
                : " Also removed \(siblings.map(\.displayName).joined(separator: ", ")), "
                  + "which used the same remote."
            status = "Deleted \(connection.displayName)." + alsoRemoved
                   + " Configuration backed up to \(outcome.backup.lastPathComponent)."
                   + storeWarning
            return true
        } catch {
            lastError = error.localizedDescription
            status = "Ready"
            return false
        }
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
                let found = try await UpdateChecker()
                    .check(current: current, includePrereleases: prereleases)
                availableUpdate = found
                lastUpdateCheck = Date()
                if let found { await announceIfNew(found) }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Check again once a day for as long as the app runs.
    ///
    /// The check used to happen only at launch, on the toggle, and on Check Now. A
    /// menu bar app runs for weeks, so someone who launched before a release existed
    /// would never hear about it — and the people most likely to be in that position
    /// are exactly the ones who do not think to look.
    private func startUpdateCheckTimer() {
        stopUpdateCheckTimer()
        updateCheckTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(UpdateNotice.checkInterval) * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await MainActor.run { self.checkForUpdates() }
            }
        }
    }

    private func stopUpdateCheckTimer() {
        updateCheckTimer?.cancel()
        updateCheckTimer = nil
    }

    /// Announce an update once, if it is worth announcing.
    private func announceIfNew(_ update: AvailableUpdate) async {
        guard UpdateNotice.shouldNotify(about: update.version,
                                        current: currentVersion,
                                        lastNotified: lastNotifiedVersion) else { return }
        // Record it only if something was actually shown.
        //
        // Enabling checks fires the permission request and the first check as two
        // independent tasks. If GitHub answers while the permission dialog is still
        // on screen, posting fails for want of authorisation — and marking the
        // version as announced anyway means the user grants permission and then
        // never hears about the very release that prompted them to.
        let delivered = await notifier.post(version: update.version,
                                            installation: installation,
                                            pageURL: update.pageURL)
        if delivered { lastNotifiedVersion = update.version }
    }

    /// The exact command to upgrade, for the Copy button.
    ///
    /// `brew update` first, then upgrade.
    ///
    /// An earlier version omitted the update on the grounds that `brew upgrade`
    /// refreshes metadata by itself. It does — but only once per
    /// `HOMEBREW_AUTO_UPDATE_SECS`, which defaults to 24 hours. Since grrclone
    /// checks daily, the common case is someone who used brew earlier that day:
    /// they paste the command, brew reports everything up to date against a stale
    /// tap, and the app looks wrong. Copying two commands costs exactly as much as
    /// copying one.
    var upgradeCommand: String { "brew update && brew upgrade --cask grrclone" }

    func copyUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(upgradeCommand, forType: .string)
        status = "Copied: \(upgradeCommand)"
    }

    /// Ask for the notification permission if macOS has never asked on our behalf.
    ///
    /// The opt-in path asks in its `didSet`, which covers someone turning checks on
    /// today. It does **not** cover the people this feature is for: anyone whose
    /// preference was already true from an earlier version never runs that observer,
    /// because a stored property's `didSet` does not fire during initialisation. They
    /// would have been left with a feature that silently never worked.
    ///
    /// Only when undecided. Asking again after a refusal is how an app becomes
    /// something people mute, and the check still works without it.
    private func requestNotificationPermissionIfNeverAsked() async {
        if await notifier.isUndecided() {
            notificationsAuthorised = await notifier.requestPermission()
        } else {
            await refreshNotificationAuthorisation()
        }
    }

    /// Refresh the permission state without prompting, for the Updates tab.
    func refreshNotificationAuthorisation() async {
        notificationsAuthorised = await notifier.isAuthorised()
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
        foreignMounts = await manager?.foreignLookalikes(under: [mountRoot.path]) ?? []
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
                    // A fresh mount is built from the saved connection, so whatever was
                    // pending is now in force. Clearing this only in `remount()` left
                    // Settings insisting the changes had not taken after an ordinary
                    // disconnect-and-reconnect from the menu.
                    self.needsRemount.remove(connection.id)
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

    /// Whether two versions of a connection differ in anything consumed at mount time.
    ///
    /// `connectAtLogin` is deliberately excluded: it is honoured at the *next* launch
    /// and takes effect the moment it is saved, so flagging it would offer a
    /// disruptive remount for a preference that is already in force.
    static func needsRemountBetween(_ old: Connection, _ new: Connection) -> Bool {
        old.displayName != new.displayName
            || old.remote != new.remote
            || old.path != new.path
            || old.transport != new.transport
            || old.options != new.options
    }

    func update(_ connection: Connection) {
        let previous = rows.first { $0.id == connection.id }
        let wasMounted = previous?.state.isMounted ?? false
        let mountAffecting = previous.map {
            Self.needsRemountBetween($0.connection, connection)
        } ?? false

        Task {
            do {
                try await store.upsert(connection)
                if wasMounted && mountAffecting { needsRemount.insert(connection.id) }
            } catch {
                // A refused save has to be said, or the form shows a name the store
                // did not take and the next connect fails on a path collision.
                lastError = error.localizedDescription
            }
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

            // Refuse if the live mount still owes the provider writes *and* the
            // remount would point somewhere else.
            //
            // Changing the subpath changes `fsSpec`, and `fsSpec` is what names the
            // VFS cache directory. Remounting therefore abandons the old cache: no
            // server serves that filesystem any more, so rclone never resumes those
            // uploads, and they sit on disk indefinitely while Finder reported the
            // files as saved. Nothing else in the app would ever mention it.
            let mounted = await manager.activeConnection(id: connection.id)
            if let mounted, mounted.fsSpec != connection.fsSpec,
               let pending = await manager.pendingUploadsForActiveMount(id: connection.id),
               !pending.isSafeToDiscard {
                let detail = pending.inspectionFailed
                    ? "grrclone could not check whether anything is still uploading from "
                      + "\(mounted.fsSpec)."
                    : "\(pending.count) file(s) saved to \(mounted.fsSpec) have not "
                      + "finished uploading."
                // Put the row back exactly where it was. It is still mounted, at the
                // path it was already at; inventing one here would show the user a
                // location that does not exist.
                let where_ = await manager.activeMountPoint(id: connection.id)
                await MainActor.run {
                    if let where_ {
                        self.setState(.mounted(at: where_), for: connection.id)
                    }
                    self.lastError = detail
                        + " Changing the folder would leave them in a cache nothing "
                        + "uploads from. Wait for them to finish, then remount."
                }
                await self.refresh()
                return
            }

            do {
                try await manager.disconnect(connection.id)
                let root = await MainActor.run { self.mountRoot }
                let mount = try await manager.connect(connection, mountRoot: root)
                await MainActor.run {
                    // This path calls the manager directly rather than going through
                    // `connect(_:)`, so it clears the flag itself. Both places set it
                    // on the same condition: a mount was just built from the saved
                    // connection, so the saved connection is now what is in force.
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
        // Not during teardown: the daemon stopping on purpose is not an exit to
        // repair, and a probe mid-unmount would fight the unmount.
        await manager.stopPeriodicHealthChecks()
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
                let transfers = await manager.transferStats()
                if Task.isCancelled { return }
                await MainActor.run {
                    self.activity = snapshot
                    self.transferStats = transfers
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var currentManager: ConnectionManager? { manager }

    /// At most three transfers, so a large sync does not turn the menu into a log.
    static let visibleTransferLimit = 3

    var visibleTransfers: [RcloneRCClient.Transfer] {
        Array((transferStats?.transferring ?? []).prefix(Self.visibleTransferLimit))
    }

    var hiddenTransferCount: Int? {
        let total = transferStats?.transferring.count ?? 0
        let hidden = total - Self.visibleTransferLimit
        return hidden > 0 ? hidden : nil
    }

    /// Aggregate throughput, or nil when nothing is moving.
    ///
    /// Nil rather than "0 B/s": a zero reads as "stalled", and rclone reports zero
    /// for the moment between finishing one file and starting the next.
    var transferSpeed: String? {
        guard let speed = transferStats?.speed, speed > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    /// One file's progress, as much of it as rclone actually knows.
    ///
    /// Each part is omitted when unknown rather than shown as zero. An ETA of "0s"
    /// on a transfer that has barely started is worse than no ETA, and rclone
    /// genuinely reports null until it has a sample to estimate from.
    static func describe(transfer: RcloneRCClient.Transfer) -> String {
        var parts: [String] = []
        if transfer.size > 0 {
            let done = ByteCountFormatter.string(fromByteCount: Int64(transfer.bytes),
                                                 countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(transfer.size),
                                                  countStyle: .file)
            parts.append("\(done) of \(total)")
        }
        if let eta = transfer.eta, eta > 0 {
            parts.append("\(formatSeconds(eta)) left")
        }
        return parts.joined(separator: " · ")
    }

    /// Compact and rounded. A progress line is glanced at, not read.
    static func formatSeconds(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

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

    /// Offer to disconnect an unrecorded mount that carries grrclone's fingerprint.
    ///
    /// An alert, with Cancel as the default: this is the one place grrclone acts on
    /// a mount its registry does not record, and it does so only because the person
    /// read what it was about to do and said yes. Nothing is killed either way.
    func reclaimForeignMount(_ mount: ForeignMount) {
        guard mount.reclaimable else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = mount.count > 1
            ? "Disconnect \(mount.count) volumes stacked at \(mount.path)?"
            : "Disconnect the volume at \(mount.path)?"
        alert.informativeText = "grrclone did not record making this mount, but its options "
            + "match grrclone's exactly, and it is inside the mount folder — most likely a "
            + "leftover from an earlier version. It will be disconnected the same way a "
            + "connection is. Nothing else is stopped or removed."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Disconnect")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        status = "Disconnecting \(mount.path)"
        let root = mountRoot.path
        Task.detached { [manager] in
            guard let manager else { return }
            do {
                let removed = try await manager.reclaimForeignMount(at: mount.path, under: [root])
                await MainActor.run {
                    self.status = removed == 1 ? "Disconnected \(mount.path)"
                                               : "Disconnected \(removed) volumes at \(mount.path)"
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
            await self.refresh()
        }
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

    /// Mount points reconciliation could not clear at launch. A connection whose
    /// folder is one of these is not connected at login: its path already has a
    /// volume on it, and the attempt would fail — or, before #108, stack.
    @Published private(set) var blockedMountPoints: Set<String> = []

    /// Connect everything marked "connect at login". Runs at launch, after
    /// reconciliation has cleared any stale mounts from a previous session.
    func connectLoginItems() async {
        guard daemonReady else { return }
        for row in rows where row.connection.connectAtLogin && !row.state.isMounted {
            let folder = mountRoot.appendingPathComponent(row.connection.displayName).path
            if blockedMountPoints.contains(folder) { continue }
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
