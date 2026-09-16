import SwiftUI
import AppKit
import GrrCloneCore

@main
struct GrrCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("grrclone", systemImage: "externaldrive.badge.icloud") {
            MenuBarView(model: model)
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
///
/// Quit is deferred for the opposite reason: mounts must come down before the rclone
/// daemon dies, or the kernel is left holding NFS mounts whose server no longer exists
/// and Finder hangs until they are forcibly removed.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await AppModel.shared.start()
            await AppModel.shared.connectLoginItems()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        // A mount that refuses to come down must not trap the user in an app that will
        // not quit. Twenty seconds is far longer than a healthy unmount needs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}
