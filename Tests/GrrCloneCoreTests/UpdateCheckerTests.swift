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

/// The update check is the only thing grrclone does that is influenced by a remote
/// party. These tests treat the GitHub response as hostile, because a compromised
/// account, a tampered reply, or simply a typo upstream should not be able to do
/// anything worse than produce a 404.
final class UpdateSecurityTests: XCTestCase {

    // MARK: The release page URL is built, not received

    /// The payload's own `html_url` must be ignored entirely. It is the only field
    /// that could turn a bad response into an action, since the app opens it.
    func testTheResponseCannotChooseWhichURLIsOpened() {
        let hostile = Data(#"""
            [{"tag_name":"v9.9.9","prerelease":false,"draft":false,
              "html_url":"https://evil.example.com/pwn",
              "published_at":"2026-09-17T00:00:00Z"}]
            """#.utf8)

        let update = UpdateChecker.newestUpdate(in: hostile,
                                                current: ReleaseVersion("0.2.0")!,
                                                includePrereleases: false)
        XCTAssertEqual(update?.pageURL.host, "github.com",
                       "the page URL must be constructed, never taken from the reply")
        XCTAssertEqual(update?.pageURL.absoluteString,
                       "https://github.com/mlaify/grrclone/releases/tag/v9.9.9")
    }

    /// A tag is attacker-influenced text that ends up in a URL path.
    func testTagsThatCouldEscapeTheURLAreRejected() {
        let nasty = [
            "../../../../evil",                  // path traversal
            "v1.0.0/../../../other/repo",        // traversal mid-tag
            "v1.0.0?redirect=evil.example.com",  // query smuggling
            "v1.0.0#fragment",
            "v1.0.0 with spaces",
            "javascript:alert(1)",
            "https://evil.example.com",
            "v1.0.0\nSet-Cookie: x",             // control characters
            String(repeating: "v1.0.0", count: 50),
        ]
        for tag in nasty {
            XCTAssertNil(UpdateChecker.releasePageURL(repository: "mlaify/grrclone", tag: tag),
                         "should have rejected tag: \(tag)")
        }
    }

    func testOrdinaryTagsAreAccepted() {
        for tag in ["v0.2.0", "v0.2.0-rc1", "0.2.0", "v1.10.3-beta.2"] {
            let url = UpdateChecker.releasePageURL(repository: "mlaify/grrclone", tag: tag)
            XCTAssertNotNil(url, "should have accepted: \(tag)")
            XCTAssertEqual(url?.scheme, "https")
            XCTAssertEqual(url?.host, "github.com")
        }
    }

    /// Whatever a release claims, the URL is always https to github.com.
    func testEveryProducedURLIsHTTPSToGitHub() {
        let data = Data(#"""
            [{"tag_name":"v9.9.9","prerelease":false,"draft":false,
              "html_url":"http://insecure.example.com/x"}]
            """#.utf8)
        let update = UpdateChecker.newestUpdate(in: data, current: ReleaseVersion("0.1.0")!,
                                                includePrereleases: true)
        XCTAssertEqual(update?.pageURL.scheme, "https")
        XCTAssertFalse(update?.pageURL.absoluteString.contains("insecure") ?? true)
    }

    // MARK: The request itself

    /// No cleartext, ever. A plain-http endpoint is interceptable by anyone on the
    /// path, and App Transport Security would refuse it anyway — but the URL should
    /// not be asking.
    func testTheAPIEndpointIsHTTPS() {
        let checker = UpdateChecker()
        XCTAssertEqual(checker.releasesURL.scheme, "https")
        XCTAssertEqual(checker.releasesURL.host, "api.github.com")
    }

    /// The host the reply must come from is pinned to a constant, so a refactor
    /// cannot quietly widen it.
    func testTheExpectedHostIsGitHubsAPI() {
        XCTAssertEqual(UpdateChecker.apiHost, "api.github.com")
    }

    // MARK: Nothing is downloaded

    /// The strongest guarantee here is structural: there is no code path that fetches
    /// a binary, so there is no signature to verify and no bundle to swap. If that
    /// ever changes, this test is the thing that should start failing.
    func testTheCheckerContainsNoDownloadPath() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/GrrCloneCoreTests/UpdateCheckerTests.swift",
                                  with: "Sources/GrrCloneCore/UpdateChecker.swift"),
                                encoding: .utf8)
        for forbidden in ["downloadTask", "download(for:", "download(from:",
                          ".dmg", ".zip", "NSTask", "Process("] {
            XCTAssertFalse(source.contains(forbidden),
                           "the update checker must not be able to fetch or run anything: \(forbidden)")
        }
    }

    // MARK: Parsing cannot be steered

    /// A reply that claims a huge version must still be subject to the pre-release
    /// filter: opting out of pre-releases is a safety choice, not a cosmetic one.
    func testPrereleaseFilterCannotBeBypassedByVersionInflation() {
        let data = Data(#"""
            [{"tag_name":"v99.0.0","prerelease":true,"draft":false}]
            """#.utf8)
        XCTAssertNil(UpdateChecker.newestUpdate(in: data, current: ReleaseVersion("0.2.0")!,
                                                includePrereleases: false))
    }

    /// Nothing in the reply should be able to make the app think it is out of date
    /// when it is not — the version comparison is done locally on parsed numbers.
    func testAReplyCannotForceAnUpdateWhenAlreadyCurrent() {
        let data = Data(#"""
            [{"tag_name":"v0.0.1","prerelease":false,"draft":false,
              "html_url":"https://github.com/mlaify/grrclone/releases/tag/v0.0.1"}]
            """#.utf8)
        XCTAssertNil(UpdateChecker.newestUpdate(in: data, current: ReleaseVersion("0.2.0")!,
                                                includePrereleases: true))
    }

    /// A response big enough to matter should not hang or crash the parser.
    func testAVeryLargeReplyIsHandled() {
        let entries = (0..<5000).map {
            #"{"tag_name":"v0.0.\#($0)","prerelease":false,"draft":false}"#
        }.joined(separator: ",")
        let data = Data("[\(entries)]".utf8)
        _ = UpdateChecker.newestUpdate(in: data, current: ReleaseVersion("0.2.0")!,
                                       includePrereleases: true)
    }
}

/// The response must be identifiable before it is believed.
final class UpdateResponseTrustTests: XCTestCase {

    /// A reply with no status or no origin is not evidence of anything. Both were
    /// previously `if let`, which accepted the reply when the value was absent —
    /// the opposite of what a security check should do when it cannot tell.
    func testFailureCasesDescribeThemselvesUsefully() {
        XCTAssertTrue(UpdateChecker.Failure.unexpectedHost("evil.example.com")
            .errorDescription?.contains("evil.example.com") ?? false)
        XCTAssertTrue(UpdateChecker.Failure.badResponse(403)
            .errorDescription?.localizedCaseInsensitiveContains("rate") ?? false)
        XCTAssertNotNil(UpdateChecker.Failure.malformed.errorDescription)
    }

    /// The host the reply must come from is a single constant, so widening it is a
    /// visible edit rather than a scattered one.
    func testOnlyGitHubsAPIIsAccepted() {
        XCTAssertEqual(UpdateChecker.apiHost, "api.github.com")
        XCTAssertEqual(UpdateChecker().releasesURL.host, UpdateChecker.apiHost)
    }
}
