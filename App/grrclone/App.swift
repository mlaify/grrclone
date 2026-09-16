import SwiftUI
import AppKit
import GrrCloneCore

@main
struct GrrCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // The icon carries state, because the menu is closed most of the time and a
            // pending upload is exactly the thing a user needs to notice before they
            // close the lid.
            Image(systemName: model.pendingUploads > 0
                  ? "externaldrive.badge.timemachine"
                  : "externaldrive.badge.icloud")
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await AppModel.shared.start()
            await AppModel.shared.connectLoginItems()
        }
    }

    /// Quit is deferred, for two separate reasons that both end in lost work.
    ///
    /// Uploads first: with `--vfs-cache-mode full` a write returns as soon as the bytes
    /// reach local disk, so Finder can show a file as saved while nothing has reached the
    /// storage provider. Quitting then strands the only copy in a cache the user does not
    /// know exists. If anything is pending, they are asked rather than surprised.
    ///
    /// Mounts second: killing rclone under a live NFS mount leaves the kernel talking to
    /// a dead server, which hangs Finder until the mount is forcibly removed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = AppModel.shared.pendingUploads

        if pending > 0, case .cancel = askAboutPendingUploads(count: pending) {
            return .terminateCancel
        }
        // Waiting is capped: a provider that has gone away must not make the app
        // unquittable. Past the cap the files stay in the cache and are retried on the
        // next launch.
        let drainTimeout: TimeInterval = pending > 0 ? 120 : 0

        Task { @MainActor in
            let stranded = await AppModel.shared.shutdown(drainTimeout: drainTimeout)
            if stranded > 0 { Self.warnAboutStrandedUploads(count: stranded) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        // Absolute backstop. A mount that refuses to come down must not trap the user in
        // an app that will not quit. Comfortably longer than the drain cap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    private enum PendingChoice { case waitAndQuit, cancel }

    private func askAboutPendingUploads(count: Int) -> PendingChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? "One file has not finished uploading"
            : "\(count) files have not finished uploading"
        alert.informativeText = """
            These files are saved on this Mac but have not reached your storage provider \
            yet. grrclone can wait for them to finish before quitting.

            If you quit now, they stay in the local cache and are retried the next time \
            you connect. They will not be lost, but they will not be on the server either.
            """
        alert.addButton(withTitle: "Wait and Quit")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .waitAndQuit : .cancel
    }

    @MainActor
    private static func warnAboutStrandedUploads(count: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? "One upload did not finish"
            : "\(count) uploads did not finish"
        alert.informativeText = """
            The files are still in grrclone's local cache and will be retried the next \
            time you connect this remote. Check your network connection.
            """
        alert.addButton(withTitle: "Quit Anyway")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
