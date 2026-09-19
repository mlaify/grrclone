import XCTest
@testable import GrrCloneCore

/// When to announce an update, and when to stay quiet.
///
/// The failure mode of a background check is nagging. An app that re-announces the
/// same version every day teaches people to dismiss it unread, and then the one
/// announcement that mattered is dismissed the same way. These rules exist to make
/// that impossible rather than unlikely.
final class UpdateNoticeTests: XCTestCase {

    private func v(_ s: String) -> ReleaseVersion { ReleaseVersion(s)! }

    func testANewerVersionIsAnnouncedWhenNothingHasBeen() {
        XCTAssertTrue(UpdateNotice.shouldNotify(about: v("0.7.0"),
                                                current: v("0.6.1"),
                                                lastNotified: nil))
    }

    /// The one that matters. Checking daily means this decision is made ~365 times
    /// a year for the same release.
    func testTheSameVersionIsNotAnnouncedTwice() {
        XCTAssertFalse(UpdateNotice.shouldNotify(about: v("0.7.0"),
                                                 current: v("0.6.1"),
                                                 lastNotified: v("0.7.0")))
    }

    func testANewerVersionIsAnnouncedAfterAnEarlierOne() {
        XCTAssertTrue(UpdateNotice.shouldNotify(about: v("0.8.0"),
                                                current: v("0.6.1"),
                                                lastNotified: v("0.7.0")))
    }

    /// Nothing to say when already current — including when the user upgraded to
    /// the very version we announced.
    func testNothingIsAnnouncedOnceInstalled() {
        XCTAssertFalse(UpdateNotice.shouldNotify(about: v("0.7.0"),
                                                 current: v("0.7.0"),
                                                 lastNotified: v("0.7.0")))
        XCTAssertFalse(UpdateNotice.shouldNotify(about: v("0.6.0"),
                                                 current: v("0.7.0"),
                                                 lastNotified: nil))
    }

    /// Comparing only against `lastNotified` would re-announce after a downgrade;
    /// comparing only against `current` would re-announce daily. Both bounds are
    /// load-bearing, and this is the case that needs both.
    func testADowngradeDoesNotResurrectAnOldAnnouncement() {
        // The user rolled back to 0.5.0 having already been told about 0.7.0.
        // 0.7.0 is newer than current, but it has been announced, so stay quiet.
        XCTAssertFalse(UpdateNotice.shouldNotify(about: v("0.7.0"),
                                                 current: v("0.5.0"),
                                                 lastNotified: v("0.7.0")))
    }

    /// A pre-release sorts below the release it precedes, so someone running
    /// 0.7.0 must not be told 0.7.0-rc1 is available.
    func testAPreReleaseIsNotOfferedToSomeoneOnTheRelease() {
        XCTAssertFalse(UpdateNotice.shouldNotify(about: v("0.7.0-rc1"),
                                                 current: v("0.7.0"),
                                                 lastNotified: nil))
        XCTAssertTrue(UpdateNotice.shouldNotify(about: v("0.7.0-rc1"),
                                                current: v("0.6.1"),
                                                lastNotified: nil))
    }

    // MARK: - What it says

    /// "An update is available" leaves the reader to work out how, and for a
    /// Homebrew install the answer is a command they will not guess.
    /// The command refreshes the tap explicitly.
    ///
    /// This test previously asserted the opposite, on the reasoning that `brew
    /// upgrade` refreshes metadata by itself. It does — but only once per
    /// `HOMEBREW_AUTO_UPDATE_SECS`, 24 hours by default. grrclone checks daily, so
    /// the common case is someone who used brew earlier the same day: they run the
    /// command, brew reports everything up to date against a stale tap, and this
    /// app looks wrong about the one thing it was trying to help with.
    func testHomebrewIsToldToRefreshTheTapFirst() {
        let text = UpdateNotice.body(for: v("0.7.0"), installation: .homebrew)
        XCTAssertTrue(text.contains("brew update && brew upgrade --cask grrclone"), text)
    }

    func testADirectInstallIsNotToldToRunBrew() {
        let text = UpdateNotice.body(for: v("0.7.0"), installation: .direct)
        XCTAssertFalse(text.contains("brew"),
                       "someone who downloaded a DMG has no brew command to run")
    }

    func testTitleNamesTheVersion() {
        XCTAssertTrue(UpdateNotice.title(for: v("0.7.0")).contains("0.7.0"))
    }

    /// Daily. Often enough that a release is found within a day, rare enough that
    /// contacting a third party stays proportionate to the benefit.
    func testTheCheckIntervalIsDaily() {
        XCTAssertEqual(UpdateNotice.checkInterval, 24 * 60 * 60)
    }
}
