import XCTest
@testable import GrrCloneCore

final class ReleaseVersionTests: XCTestCase {

    func testParsesTagsWithAndWithoutTheVPrefix() {
        XCTAssertEqual(ReleaseVersion("v0.2.0")?.description, "0.2.0")
        XCTAssertEqual(ReleaseVersion("0.2.0")?.description, "0.2.0")
        XCTAssertEqual(ReleaseVersion("v1.10.3")?.minor, 10)
    }

    func testParsesPrereleases() {
        let v = ReleaseVersion("v0.2.0-rc1")
        XCTAssertEqual(v?.description, "0.2.0-rc1")
        XCTAssertTrue(v?.isPrerelease ?? false)
    }

    func testRejectsNonsense() {
        XCTAssertNil(ReleaseVersion("latest"))
        XCTAssertNil(ReleaseVersion("v"))
        XCTAssertNil(ReleaseVersion(""))
    }

    /// The ordering that matters most: a pre-release sorts below the release it
    /// precedes. Backwards, and someone on 0.2.0 would be offered an "upgrade" to
    /// 0.2.0-rc1 — the exact situation this project is in right now.
    func testAPrereleaseSortsBelowItsFinalRelease() {
        XCTAssertLessThan(ReleaseVersion("v0.2.0-rc1")!, ReleaseVersion("v0.2.0")!)
        XCTAssertGreaterThan(ReleaseVersion("v0.2.0")!, ReleaseVersion("v0.2.0-rc1")!)
    }

    func testOrdersNormalVersions() {
        XCTAssertLessThan(ReleaseVersion("v0.1.0")!, ReleaseVersion("v0.2.0")!)
        XCTAssertLessThan(ReleaseVersion("v0.2.0")!, ReleaseVersion("v0.2.1")!)
        XCTAssertLessThan(ReleaseVersion("v0.9.0")!, ReleaseVersion("v1.0.0")!)
    }

    /// rc2 must beat rc1, and rc10 must beat rc9 — a plain string compare gets the
    /// second one wrong.
    func testOrdersPrereleasesNumerically() {
        XCTAssertLessThan(ReleaseVersion("v0.2.0-rc1")!, ReleaseVersion("v0.2.0-rc2")!)
        XCTAssertLessThan(ReleaseVersion("v0.2.0-rc9")!, ReleaseVersion("v0.2.0-rc10")!)
    }

    func testAMissingPatchIsZero() {
        XCTAssertEqual(ReleaseVersion("v1.2")?.patch, 0)
    }
}

final class UpdateSelectionTests: XCTestCase {

    /// Shaped like the real GitHub releases payload.
    private func payload(_ entries: [(tag: String, pre: Bool, draft: Bool)]) -> Data {
        let objects = entries.map { e in
            """
            {"tag_name":"\(e.tag)","prerelease":\(e.pre),"draft":\(e.draft),
             "html_url":"https://github.com/mlaify/grrclone/releases/tag/\(e.tag)",
             "published_at":"2026-09-17T14:08:07Z"}
            """
        }
        return Data("[\(objects.joined(separator: ","))]".utf8)
    }

    private let current = ReleaseVersion("0.2.0")!

    func testOffersNothingWhenAlreadyCurrent() {
        let data = payload([("v0.2.0", false, false), ("v0.1.0", false, false)])
        XCTAssertNil(UpdateChecker.newestUpdate(in: data, current: current,
                                                includePrereleases: false))
    }

    func testOffersANewerRelease() {
        let data = payload([("v0.3.0", false, false), ("v0.2.0", false, false)])
        let update = UpdateChecker.newestUpdate(in: data, current: current,
                                                includePrereleases: false)
        XCTAssertEqual(update?.version.description, "0.3.0")
    }

    /// Someone who has not opted in must never be shown a release candidate.
    func testIgnoresPrereleasesUnlessAskedFor() {
        let data = payload([("v0.3.0-rc1", true, false), ("v0.2.0", false, false)])
        XCTAssertNil(UpdateChecker.newestUpdate(in: data, current: current,
                                                includePrereleases: false))

        let opted = UpdateChecker.newestUpdate(in: data, current: current,
                                               includePrereleases: true)
        XCTAssertEqual(opted?.version.description, "0.3.0-rc1")
        XCTAssertTrue(opted?.isPrerelease ?? false)
    }

    /// A draft release has no public page; offering one sends the user to a 404.
    func testIgnoresDrafts() {
        let data = payload([("v0.4.0", false, true), ("v0.3.0", false, false)])
        XCTAssertEqual(UpdateChecker.newestUpdate(in: data, current: current,
                                                  includePrereleases: false)?
                        .version.description, "0.3.0")
    }

    /// Releases do not arrive in any guaranteed order.
    func testPicksTheNewestRegardlessOfListOrder() {
        let data = payload([("v0.2.1", false, false), ("v0.4.0", false, false),
                            ("v0.3.0", false, false)])
        XCTAssertEqual(UpdateChecker.newestUpdate(in: data, current: current,
                                                  includePrereleases: false)?
                        .version.description, "0.4.0")
    }

    /// Someone running a release candidate should be offered the final release.
    func testOffersTheFinalReleaseToSomeoneOnARC() {
        let data = payload([("v0.2.0", false, false)])
        let update = UpdateChecker.newestUpdate(in: data,
                                                current: ReleaseVersion("0.2.0-rc1")!,
                                                includePrereleases: false)
        XCTAssertEqual(update?.version.description, "0.2.0")
    }

    /// Someone on a newer pre-release must not be dragged backwards to the last final.
    func testDoesNotOfferAnOlderFinalReleaseToSomeoneAhead() {
        let data = payload([("v0.2.0", false, false)])
        XCTAssertNil(UpdateChecker.newestUpdate(in: data,
                                                current: ReleaseVersion("0.3.0-rc1")!,
                                                includePrereleases: true))
    }

    func testTolleratesGarbageEntries() {
        let data = Data(#"[{"tag_name":"nightly","prerelease":false,"draft":false,"html_url":"x"}]"#.utf8)
        XCTAssertNil(UpdateChecker.newestUpdate(in: data, current: current,
                                                includePrereleases: true))
    }

    func testTolleratesAnEmptyOrBrokenBody() {
        XCTAssertNil(UpdateChecker.newestUpdate(in: Data("[]".utf8), current: current,
                                                includePrereleases: true))
        XCTAssertNil(UpdateChecker.newestUpdate(in: Data("not json".utf8), current: current,
                                                includePrereleases: true))
    }
}

final class InstallationKindTests: XCTestCase {

    func testDetectsAHomebrewInstallFromTheCaskroom() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brew-\(UUID().uuidString)")
        let caskroom = root.appendingPathComponent("Caskroom/grrclone")
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(InstallationKind.detect(prefixes: [root.path]), .homebrew)
    }

    func testReportsDirectWhenThereIsNoCask() {
        let missing = NSTemporaryDirectory() + "/definitely-not-homebrew-\(UUID().uuidString)"
        XCTAssertEqual(InstallationKind.detect(prefixes: [missing]), .direct)
    }

    /// A Caskroom for some other application must not be mistaken for ours.
    func testAnotherCaskDoesNotCount() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Caskroom/firefox"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(InstallationKind.detect(prefixes: [root.path]), .direct)
    }
}
