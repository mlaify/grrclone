import Foundation

/// Deciding whether to tell someone about an update, and how often.
///
/// Separate from the delivery mechanism so the rules can be tested without a
/// notification centre, an app bundle, or a human to grant permission.
///
/// The rules exist because the failure mode of a background check is nagging. An
/// app that re-announces the same version every day teaches people to dismiss it
/// without reading, and then the one announcement that mattered goes the same way.
public enum UpdateNotice {

    /// How often to ask GitHub while the app is running.
    ///
    /// Daily. The app is a menu bar item that can run for weeks, so checking only
    /// at launch means someone who started it before a release existed never hears
    /// about it — which is the whole gap this closes. More often than daily would
    /// be contacting a third party more than the user's benefit justifies.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Whether to post a notification for `version`, given what was last announced.
    ///
    /// - Parameters:
    ///   - version: the update just found.
    ///   - current: the running version.
    ///   - lastNotified: the newest version already announced, if any.
    ///
    /// Announce only a version newer than both. Comparing against `lastNotified`
    /// alone would re-announce after a downgrade; comparing against `current` alone
    /// would re-announce the same version on every check.
    public static func shouldNotify(about version: ReleaseVersion,
                                    current: ReleaseVersion,
                                    lastNotified: ReleaseVersion?) -> Bool {
        guard version > current else { return false }
        guard let lastNotified else { return true }
        return version > lastNotified
    }

    /// The text of the notification.
    ///
    /// Says what to do, because "an update is available" leaves the reader to work
    /// out how — and for a Homebrew install the answer is a command they will not
    /// guess. The two cases genuinely differ, so they are not one string with a
    /// substitution.
    ///
    /// **`brew update` first, deliberately.** `brew upgrade` does refresh metadata
    /// on its own, but only once per `HOMEBREW_AUTO_UPDATE_SECS` — 24 hours by
    /// default. grrclone checks daily, so the likely case is a user who ran some
    /// brew command recently, pastes the command, and is told everything is up to
    /// date while this app insists otherwise. The app then looks wrong about the
    /// one thing it was trying to be helpful about. The explicit update costs
    /// nothing when it is copied rather than typed.
    ///
    /// Not to be confused with `brew autoupdate`, a separate tap that installs a
    /// launchd agent to run brew on a schedule. That is not present by default and
    /// grrclone does not assume it.
    public static func body(for version: ReleaseVersion, installation: InstallationKind) -> String {
        switch installation {
        case .homebrew:
            return "Run brew update && brew upgrade --cask grrclone to install it."
        case .direct, .unknown:
            return "Open the release page to download it."
        }
    }

    public static func title(for version: ReleaseVersion) -> String {
        "grrclone \(version.description) is available"
    }
}
