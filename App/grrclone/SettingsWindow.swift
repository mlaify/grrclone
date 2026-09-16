import AppKit
import SwiftUI

/// Opens the Settings window from the menu bar.
///
/// `@Environment(\.openSettings)` alone does not work here, and the failure is silent:
/// the button appears to do nothing at all.
///
/// Two things conspire. grrclone is an accessory app (`LSUIElement`), so it is not the
/// active application while its menu bar popover is showing, and opening a window from
/// an inactive accessory app puts it behind everything with no way to reach it. And the
/// popover itself stays up, covering whatever did appear.
///
/// So the order matters: dismiss the popover, activate the app, then open the window,
/// then explicitly bring it to the front. Each step is load-bearing.
@MainActor
enum SettingsWindow {

    static func open() {
        open(attempt: 0)
    }

    private static func open(attempt: Int) {
        // Dismiss the menu bar popover first. It is a panel that floats above normal
        // windows, so leaving it up hides the Settings window behind it.
        dismissMenuBarPopover()

        // An accessory app must activate before it can show a window the user can see.
        NSApp.activate(ignoringOtherApps: true)

        // Invoke the app's own Settings menu item rather than sending its action.
        //
        // `NSApp.sendAction(Selector(("showSettingsWindow:")))` looks like the obvious
        // approach and is widely suggested, but it does not work here: it returns
        // **true**, so it appears to have succeeded, and no window is created. Verified
        // directly — in one running instance the menu item opened Settings while
        // sendAction on the same selector produced nothing but a status-bar window.
        //
        // Performing the menu item runs exactly the code path that does work.
        if !performSettingsMenuItem() {
            // The main menu is built by SwiftUI after launch, so a call made early
            // enough finds nothing to perform. Retry briefly before giving up rather
            // than failing silently, which is the behaviour this whole type exists to
            // eliminate.
            guard attempt < 20 else {
                _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                open(attempt: attempt + 1)
            }
            return
        }

        // Opening is not the same as being frontmost. Without this the window can
        // appear behind the app that had focus a moment ago.
        bringSettingsToFront()
    }

    /// Find and perform the Settings item in the app's own menu.
    ///
    /// Matched by action selector first, because the title is localised and matching
    /// "Settings" would fail on a non-English system. The title check is only a
    /// fallback for both the current and pre-Ventura spellings.
    private static func performSettingsMenuItem() -> Bool {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return false }

        let wanted: Set<String> = ["showSettingsWindow:", "showPreferencesWindow:",
                                   "orderFrontPreferencesPanel:"]
        for (index, item) in appMenu.items.enumerated() {
            let matchesAction = item.action.map { wanted.contains(NSStringFromSelector($0)) } ?? false
            let matchesTitle = item.title.hasPrefix("Settings") || item.title.hasPrefix("Preferences")
            if matchesAction || matchesTitle {
                appMenu.performActionForItem(at: index)
                return true
            }
        }
        return false
    }

    /// The popover is an `NSPanel` owned by the status item. Closing every visible
    /// panel is blunt but correct here: grrclone has no other panels.
    private static func dismissMenuBarPopover() {
        for window in NSApp.windows where window is NSPanel && window.isVisible {
            window.close()
        }
    }

    /// Show the window the action just created.
    ///
    /// This is not optional tidying. `showSettingsWindow:` returns true and the window
    /// appears in `NSApp.windows`, but it is *not ordered on screen* — observed
    /// directly: the action succeeded, the window count went to 1, and the user saw
    /// nothing. Something has to order it front.
    ///
    /// It is also not there immediately, so this retries briefly rather than looking
    /// once. An earlier version required `isVisible`, which is false at exactly the
    /// moment it matters, so it matched nothing and silently did nothing at all.
    private static func bringSettingsToFront(attempt: Int = 0) {
        guard let window = settingsWindow() else {
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bringSettingsToFront(attempt: attempt + 1)
            }
            return
        }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Identifying the Settings window is awkward: SwiftUI gives it no stable
    /// identifier and its title is localised, so it is found by elimination. The menu
    /// bar popover and the status item are panels; the settings window is the only
    /// ordinary window grrclone ever has.
    ///
    /// Deliberately does not filter on `isVisible` — the window is invisible until it
    /// is ordered front, which is the very thing being arranged here.
    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            !(window is NSPanel) && window.contentViewController != nil
        }
    }
}
