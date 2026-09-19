import SwiftUI
import AppKit
import UserNotifications
import GrrCloneCore

@main
struct GrrCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    /// What the menu bar icon says without being opened.
    ///
    /// The icon is the only surface a user sees every day — the menu is shut most
    /// of the time and Settings is opened once. So it is where an available update
    /// has to appear, or the people who never think to check never find out.
    private var iconName: String {
        if model.pendingUploads > 0 { return "externaldrive.badge.timemachine" }
        if model.availableUpdate != nil { return "externaldrive.badge.plus" }
        return "externaldrive.badge.icloud"
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // The icon carries state, because the menu is closed most of the time and a
            // pending upload is exactly the thing a user needs to notice before they
            // close the lid.
            // Pending uploads outrank an update: one is about to lose data if the
            // lid closes, the other can wait a week. An update is marked only when
            // nothing more urgent is competing for the same eight points of icon.
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Owns launch and quit.
///
/// Startup deliberately does **not** live in the menu's `.task`. A `MenuBarExtra` with
/// the window style does not build its content view until the user clicks the icon, so
/// anything attached there would not run until then — leaving orphaned mounts from a
/// previous session unreconciled and "connect at login" not connecting until someone
/// opened the menu. Both were observed before this moved here.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// `reply(toApplicationShouldTerminate:)` must be sent exactly once. Two callers can
    /// race for it — the teardown and the watchdog — and the second call would arrive
    /// after termination is already under way.
    private var terminationAnswered = false

    /// Retained deliberately. `UNUserNotificationCenter.delegate` is a weak
    /// reference, so a delegate created and assigned inline is deallocated
    /// immediately and both callbacks silently never fire — which is exactly what
    /// happened when this class was written and never wired up at all.
    private let notificationDelegate = UpdateNotificationDelegate()

    /// Reopening a menu bar app — double-clicking it in Finder, or opening it again
    /// while it is already running — otherwise does nothing at all, which reads as the
    /// app being broken. Showing Settings is the useful interpretation, and it is the
    /// only window grrclone has.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.open()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything touches the mount registry or the daemon pid file. A second
        // instance reaching DaemonSupervisor.start() reaps the first instance's rclone
        // daemon, leaving its mounts backed by a dead server and hanging Finder.
        guard SingleInstance.acquire() else {
            NSApp.terminate(nil)
            return
        }

        // Must be set before any notification is delivered, or a click on one does
        // nothing and a notification arriving while the menu is open is swallowed.
        UNUserNotificationCenter.current().delegate = notificationDelegate

        // A test affordance, because this is otherwise unverifiable: the menu bar
        // popover closes the instant anything else takes focus, so UI automation
        // cannot reach the Settings button inside it. This opens the same code path
        // without a click. Harmless in a shipped build — it does nothing unless the
        // variable is set.
        if ProcessInfo.processInfo.environment["GRRCLONE_OPEN_SETTINGS_AT_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SettingsWindow.open() }
        }
        // `start()` owns connecting the login items, because it is not the only path
        // that reaches a usable state: unlocking an encrypted config after cancelling
        // the prompt gets there too, and calling it from here as well would leave two
        // owners of the same step.
        Task { @MainActor in
            await AppModel.shared.start()
        }
    }

    /// Quit always defers, then decides asynchronously.
    ///
    /// It has to. Deciding here and now would mean reading the polled upload count,
    /// which lags by up to two seconds — long enough for a file copied in Finder and
    /// followed straight by Cmd-Q to look like nothing at all, skipping the drain
    /// entirely. rclone is asked directly instead, which a synchronous delegate
    /// callback cannot do.
    ///
    /// Cancelling is therefore expressed by replying `false` rather than returning
    /// `.terminateCancel`, because the answer is not known when this returns.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let model = AppModel.shared
            let snapshot = await model.currentActivity()

            if !snapshot.isKnownIdle,
               case .cancel = Self.askAboutPendingUploads(snapshot) {
                self.answerTermination(false)
                return
            }

            let drainTimeout: TimeInterval = snapshot.isKnownIdle ? 0 : 120

            // Sized from the real budget rather than a guess. The previous fixed 150s
            // was shorter than a worst-case teardown, so it could fire between
            // unmounting a volume and stopping the daemon — the one state the ordering
            // exists to avoid. `shutdown` also enforces this deadline internally, so
            // this is a backstop for the backstop.
            let budget = await model.teardownBudget(drainTimeout: drainTimeout)
            self.armWatchdog(after: budget + 30)

            let outcome = await model.shutdown(drainTimeout: drainTimeout)
            if !outcome.isClean { Self.reportUncleanShutdown(outcome) }
            self.answerTermination(true)
        }

        return .terminateLater
    }

    private func armWatchdog(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.answerTermination(true)
        }
    }

    private func answerTermination(_ shouldTerminate: Bool) {
        guard !terminationAnswered else { return }
        terminationAnswered = true
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    private enum PendingChoice { case waitAndQuit, cancel }

    @MainActor
    private static func askAboutPendingUploads(
        _ activity: ConnectionManager.Activity
    ) -> PendingChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning

        if activity.hasUnknownState {
            // An unreachable daemon is reported honestly rather than as "all clear".
            // Reading silence as zero is what makes a safety check fail open, and it
            // would fail open in precisely the situation that strands files.
            alert.messageText = "grrclone cannot confirm your uploads finished"
            alert.informativeText = """
                The rclone process is not responding, so there is no way to tell whether \
                recent changes reached your storage provider.

                Anything unsent stays in the local cache and is retried the next time you \
                connect. Nothing is lost, but it may not be on the server yet.
                """
        } else {
            let count = activity.pendingUploads
            alert.messageText = count == 1
                ? "One file has not finished uploading"
                : "\(count) files have not finished uploading"
            alert.informativeText = """
                These files are saved on this Mac but have not reached your storage \
                provider yet. grrclone can wait for them to finish before quitting.

                If you quit now, they stay in the local cache and are retried the next \
                time you connect. They will not be lost, but they will not be on the \
                server either.
                """
        }

        alert.addButton(withTitle: "Wait and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .waitAndQuit : .cancel
    }

    @MainActor
    private static func reportUncleanShutdown(_ outcome: ConnectionManager.ShutdownOutcome) {
        var lines: [String] = []

        if outcome.strandedUploads > 0 {
            lines.append(outcome.strandedUploads == 1
                ? "One upload did not finish. It stays in the local cache and is retried the next time you connect."
                : "\(outcome.strandedUploads) uploads did not finish. They stay in the local cache and are retried the next time you connect.")
        }
        if !outcome.abandonedMounts.isEmpty {
            let names = outcome.abandonedMounts
                .map { ($0 as NSString).lastPathComponent }
                .joined(separator: ", ")
            lines.append("""
                These volumes were left connected because disconnecting them was taking \
                too long: \(names). They keep working, and grrclone tidies them up the \
                next time it starts.
                """)
        }
        guard !lines.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "grrclone did not shut down completely"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
