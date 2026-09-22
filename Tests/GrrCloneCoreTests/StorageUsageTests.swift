import XCTest
import RcloneRC
@testable import GrrCloneCore

/// The parsers are pure and fed captured bytes; the fetcher gets a stubbed transport.
/// Nothing here touches the network or a daemon.
final class StorageUsageTests: XCTestCase {

    // A document shaped exactly like the reference implementation writes it.
    private let document = """
    {"version": 1, "user": "mdavis", "generated_at": "2026-09-22T18:00:00Z",
     "categories": [
      {"id": "files", "label": "Files", "used_bytes": 1076546999296,
       "soft_limit_bytes": 1924145348608, "hard_limit_bytes": 2199023255552, "grace": null},
      {"id": "photos", "label": "Photos", "used_bytes": 170688508942,
       "soft_limit_bytes": null, "hard_limit_bytes": 536870912000, "grace": null},
      {"id": "vault", "label": "Vault", "used_bytes": 214748364,
       "soft_limit_bytes": null, "hard_limit_bytes": null, "grace": null}
     ]}
    """

    func testParsesAVersionOneDocument() throws {
        let usage = try StorageUsage.parseUsageDocument(Data(document.utf8))
        XCTAssertEqual(usage.source, .usageDocument)
        XCTAssertEqual(usage.categories.count, 3)
        XCTAssertEqual(usage.categories[0].usedBytes, 1_076_546_999_296)
        XCTAssertEqual(usage.categories[0].softLimitBytes, 1_924_145_348_608)
        XCTAssertEqual(usage.categories[0].hardLimitBytes, 2_199_023_255_552)
        XCTAssertNil(usage.categories[0].grace)
        XCTAssertNotNil(usage.generatedAt)
        // JSON null is a real "no limit", not zero.
        XCTAssertNil(usage.categories[1].softLimitBytes)
        XCTAssertNil(usage.categories[2].hardLimitBytes)
        XCTAssertNil(usage.categories[2].fractionUsed, "no cap means no bar, not 100 %")
        XCTAssertEqual(usage.categories[0].fractionUsed ?? 0, 0.489, accuracy: 0.001)
        XCTAssertFalse(usage.categories[0].isOverSoftLimit)
    }

    func testSoftLimitAndGraceAreSurfaced() throws {
        let over = """
        {"version": 1, "categories": [{"id": "files", "used_bytes": 200, "soft_limit_bytes": 100,
          "hard_limit_bytes": 300, "grace": "6days"}]}
        """
        let usage = try StorageUsage.parseUsageDocument(Data(over.utf8))
        XCTAssertTrue(usage.categories[0].isOverSoftLimit)
        XCTAssertEqual(usage.categories[0].grace, "6days")
        XCTAssertEqual(usage.categories[0].label, "files", "label falls back to the id")
    }

    func testRefusesOtherVersionsAndMalformedDocuments() {
        XCTAssertThrowsError(try StorageUsage.parseUsageDocument(Data("{\"version\": 2, \"categories\": []}".utf8))) {
            XCTAssertEqual($0 as? StorageUsage.Failure, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try StorageUsage.parseUsageDocument(Data("{\"version\": 1, \"categories\": []}".utf8)))
        XCTAssertThrowsError(try StorageUsage.parseUsageDocument(Data("not json".utf8)))
        XCTAssertThrowsError(try StorageUsage.parseUsageDocument(Data("{\"version\": 1, \"categories\": [{\"label\": \"x\"}]}".utf8)))
    }

    func testAboutBecomesOneCategoryWhenItSaysEnough() throws {
        let decoder = JSONDecoder()
        let full = try decoder.decode(JSONValue.self, from: Data("{\"total\": 1000, \"used\": 250, \"free\": 750}".utf8))
        let usage = StorageUsage.fromAbout(full)
        XCTAssertEqual(usage?.source, .about)
        XCTAssertEqual(usage?.categories.first?.usedBytes, 250)
        XCTAssertEqual(usage?.categories.first?.hardLimitBytes, 1000)

        let usedAndFree = try decoder.decode(JSONValue.self, from: Data("{\"used\": 250, \"free\": 750}".utf8))
        XCTAssertEqual(StorageUsage.fromAbout(usedAndFree)?.categories.first?.hardLimitBytes, 1000)

        let totalAndFree = try decoder.decode(JSONValue.self, from: Data("{\"total\": 1000, \"free\": 600}".utf8))
        XCTAssertEqual(StorageUsage.fromAbout(totalAndFree)?.categories.first?.usedBytes, 400)

        // A backend that answered with nothing usable is "not reported", not zero.
        let empty = try decoder.decode(JSONValue.self, from: Data("{}".utf8))
        XCTAssertNil(StorageUsage.fromAbout(empty))
        let onlyFree = try decoder.decode(JSONValue.self, from: Data("{\"free\": 5}".utf8))
        XCTAssertNil(StorageUsage.fromAbout(onlyFree))
    }

    // MARK: - Revealing the stored credential

    /// `--` before the value, always: an obscured value can begin with `-`.
    func testRevealTerminatesFlagParsing() {
        XCTAssertEqual(ConnectionManager.revealArguments(for: "-abc"), ["reveal", "--", "-abc"])
    }

    /// Against the real rclone: obscure until a value that starts with `-` turns up,
    /// then reveal it through the same argument list the app uses. The bare form
    /// is shown to fail on that value, so this test is known to be able to fail.
    func testADashLeadingObscuredValueRevealsWithTheAppsArguments() async throws {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/grrclone/Resources/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        guard let rclone = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("no rclone binary found")
        }
        var obscured: String?
        for attempt in 0..<600 {
            let out = try await Shell.run(rclone.path, ["obscure", "--", "example-\(attempt)"], timeout: 10)
            let value = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("-") { obscured = value; break }
        }
        let value = try XCTUnwrap(obscured, "600 obscures produced no dash-leading value; the odds say ~9 should")

        let bare = try await Shell.run(rclone.path, ["reveal", value], timeout: 10)
        XCTAssertFalse(bare.succeeded, "the bare form must fail on this value, or the fix is untested")

        let terminated = try await Shell.run(rclone.path, ConnectionManager.revealArguments(for: value), timeout: 10)
        XCTAssertTrue(terminated.succeeded, terminated.stderr)
        XCTAssertTrue(terminated.stdout.hasPrefix("example-"), terminated.stdout)
    }

    // MARK: - Fetcher, with a stubbed transport

    private func response(_ url: URL, status: Int, type: String = "application/json") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": type])!
    }

    func testFetcherBuildsThePathAndSendsBasicAuthInAHeader() async throws {
        let seen = Recorder()
        let fetcher = StorageUsage.Fetcher { request in
            await seen.record(request)
            return (Data(self.document.utf8), self.response(request.url!, status: 200))
        }
        let usage = try await fetcher.usageDocument(baseURL: URL(string: "https://dav.example/dav")!,
                                                    user: "alice-laptop", password: "s3cret")
        XCTAssertEqual(usage?.categories.count, 3)
        let request = await seen.last
        XCTAssertEqual(request?.url?.absoluteString, "https://dav.example/dav/.usage/usage.json",
                       "a base without a trailing slash must not lose its last path component")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("alice-laptop:s3cret".utf8).base64EncodedString())
        XCTAssertFalse(request?.url?.absoluteString.contains("s3cret") ?? true, "credentials never travel in the URL")
    }

    func testServersWithoutTheDocumentAreNotReportedRatherThanErrors() async throws {
        for status in [401, 403, 404, 500] {
            let fetcher = StorageUsage.Fetcher { request in
                (Data(), self.response(request.url!, status: status))
            }
            let usage = try await fetcher.usageDocument(baseURL: URL(string: "https://dav.example/")!,
                                                        user: "u", password: "p")
            XCTAssertNil(usage, "status \(status) means no document, silently")
        }
        // 200 with an HTML login page is also "no document".
        let html = StorageUsage.Fetcher { request in
            (Data("<html>".utf8), self.response(request.url!, status: 200, type: "text/html"))
        }
        let usage = try await html.usageDocument(baseURL: URL(string: "https://dav.example/")!, user: "u", password: "p")
        XCTAssertNil(usage)
    }

    func testAnswersFromAnotherHostOrOverCleartextAreRefused() async {
        let elsewhere = StorageUsage.Fetcher { _ in
            (Data(self.document.utf8), self.response(URL(string: "https://evil.example/.usage/usage.json")!, status: 200))
        }
        do {
            _ = try await elsewhere.usageDocument(baseURL: URL(string: "https://dav.example/")!, user: "u", password: "p")
            XCTFail("a redirect to another host must not be accepted")
        } catch {
            XCTAssertEqual(error as? StorageUsage.Failure, .unexpectedHost("evil.example"))
        }
        let cleartext = StorageUsage.Fetcher { _ in XCTFail("must not be called"); throw URLError(.badURL) }
        do {
            _ = try await cleartext.usageDocument(baseURL: URL(string: "http://dav.example/")!, user: "u", password: "p")
            XCTFail("http must be refused before any request")
        } catch {
            XCTAssertEqual(error as? StorageUsage.Failure, .insecureURL)
        }
    }
}

private actor Recorder {
    var last: URLRequest?
    func record(_ request: URLRequest) { last = request }
}
