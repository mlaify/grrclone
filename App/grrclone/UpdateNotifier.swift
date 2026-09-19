import Foundation
import UserNotifications
import AppKit
import GrrCloneCore

/// Posts a macOS notification when an update is found.
///
/// **This is the one permission grrclone asks for**, and it is asked once.
///
/// Normally at the moment the user turns update checks on, because that is where
/// the request explains itself: they have just asked to be told about new versions,
/// so being asked how is expected. A prompt at first launch, before the user has
/// asked for anything, is what trains people to click Don't Allow.
///
/// The exception is someone whose preference was already on from an earlier
/// version. A stored property's `didSet` does not fire during initialisation, so
/// they never pass through the opt-in path and would be left with a feature that
/// silently never worked. They are asked at launch instead — once, and only if
/// macOS has never asked on our behalf.
///
/// Declining is a real answer and costs nothing else: the check still runs, the
/// menu bar icon still marks an available update, and Settings still shows it.
@MainActor
final class UpdateNotifier {

    /// Clicking the notification opens the release page, so the category needs an
    /// identifier the delegate can recognise.
    static let categoryIdentifier = "org.mlaify.grrclone.update"

    private let centre = UNUserNotificationCenter.current()

    /// Ask, once, at the moment the user opts in.
    ///
    /// Returns whether notifications may be posted. A refusal is not an error and
    /// is not retried: asking again after someone said no is how an app becomes
    /// something people mute.
    @discardableResult
    func requestPermission() async -> Bool {
        // `.alert` only. No badge — the app has no Dock icon to badge — and no
        // sound, because an update is not urgent enough to interrupt anything.
        (try? await centre.requestAuthorization(options: [.alert])) ?? false
    }

    /// Whether macOS has never asked on our behalf.
    ///
    /// Distinguishes "has not been asked" from "was asked and said no". Only the
    /// first is worth prompting for; re-asking after a refusal is how an app
    /// becomes something people mute.
    func isUndecided() async -> Bool {
        await centre.notificationSettings().authorizationStatus == .notDetermined
    }

    /// Whether the user has already granted it, without prompting.
    func isAuthorised() async -> Bool {
        let settings = await centre.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Returns whether a notification was actually delivered.
    ///
    /// The caller records which version it has announced, and must only do so when
    /// something was really shown. Recording regardless means a version announced
    /// while permission was still pending is marked as told and never mentioned
    /// again — the user grants permission and hears nothing about the release that
    /// prompted them to.
    @discardableResult
    func post(version: ReleaseVersion, installation: InstallationKind,
              pageURL: URL) async -> Bool {
        guard await isAuthorised() else { return false }

        let content = UNMutableNotificationContent()
        content.title = UpdateNotice.title(for: version)
        content.body = UpdateNotice.body(for: version, installation: installation)
        content.categoryIdentifier = Self.categoryIdentifier
        // The URL is built locally by `UpdateChecker.releasePageURL`, never taken
        // from GitHub's response, so it is safe to carry here and open on a click.
        content.userInfo = ["pageURL": pageURL.absoluteString]

        // nil trigger delivers immediately.
        let request = UNNotificationRequest(identifier: "update-\(version.description)",
                                            content: content, trigger: nil)
        do {
            try await centre.add(request)
            return true
        } catch {
            return false
        }
    }
}

/// Opens the release page when the notification is clicked.
///
/// The URL is re-validated here rather than trusted from `userInfo`. Nothing
/// hostile can realistically write to our own notification payload, but the cost of
/// checking is a string comparison and the cost of being wrong is opening an
/// arbitrary URL from a click.
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier
                == UpdateNotifier.categoryIdentifier,
              let raw = response.notification.request.content.userInfo["pageURL"] as? String,
              let url = URL(string: raw),
              url.scheme == "https",
              url.host == "github.com"
        else { return }

        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    /// Show it even when grrclone is frontmost. A menu bar app is "frontmost"
    /// whenever its menu is open, which would otherwise swallow the notification at
    /// the exact moment the user is looking at the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
