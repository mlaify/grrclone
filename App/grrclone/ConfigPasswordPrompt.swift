import AppKit

/// Asks for the password to an encrypted `rclone.conf`.
///
/// An `NSAlert` rather than a SwiftUI sheet or window, for the same reason
/// `SettingsWindow` has to work as hard as it does: grrclone is an accessory app with
/// no main window, and presenting SwiftUI windows from one is unreliable enough that
/// this project has already lost a day to it. An alert is presented by AppKit itself,
/// comes to the front when the app is activated, and cannot end up behind another
/// application with no way to reach it.
///
/// This runs before the app is usable at all — without the password there are no
/// remotes to show — so a modal prompt is also the honest shape for it.
@MainActor
enum ConfigPasswordPrompt {

    struct Response {
        let password: String
        let shouldSave: Bool
    }

    /// Returns nil if the user cancels.
    ///
    /// - Parameters:
    ///   - configPath: shown to the user, so they can tell which config is being
    ///     unlocked when they have more than one.
    ///   - retrying: true when a previous attempt was rejected, which changes the
    ///     wording from a request into a correction.
    static func ask(configPath: String, retrying: Bool = false) -> Response? {
        let alert = NSAlert()
        alert.alertStyle = retrying ? .warning : .informational
        alert.messageText = retrying
            ? "That password did not work"
            : "Your rclone configuration is encrypted"
        alert.informativeText = retrying
            ? "Try again, or cancel to start grrclone without your remotes.\n\n\(configPath)"
            : """
              Enter its password so grrclone can read your remotes. Without it, no \
              remotes can be listed or mounted.

              \(configPath)
              """

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 26, width: 300, height: 24))
        field.placeholderString = "Configuration password"

        let save = NSButton(checkboxWithTitle: "Remember in my keychain", target: nil, action: nil)
        save.frame = NSRect(x: 0, y: 0, width: 300, height: 18)
        // Off by default. Saving the key to every remote the user has is their decision
        // to make deliberately, not one to slip past them as a pre-ticked box.
        save.state = .off

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        accessory.addSubview(field)
        accessory.addSubview(save)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")

        // An accessory app is not active while its menu bar popover is up, and an alert
        // from an inactive app can open behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Response(password: field.stringValue, shouldSave: save.state == .on)
    }

    /// Tells the user their remotes are unavailable, after they cancel.
    ///
    /// Shown because the alternative is an app that silently lists nothing, which looks
    /// like a failure to find their config rather than a choice they just made.
    static func explainCancelled() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "grrclone is running without your remotes"
        alert.informativeText = """
            Your configuration stays locked until you enter its password. Choose \
            "Unlock Configuration" from the menu to try again.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
