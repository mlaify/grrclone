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

    /// The credential is revealed in process, never by running `rclone reveal` with
    /// it on a command line (#156). The round trip against the real rclone lives in
    /// ObscureTests; this pins the call site to the in-process codec.
    func testStorageUsageDoesNotRunRevealAsAProcess() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GrrCloneCore/ConnectionManager.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("\"reveal\""), "a `reveal` argument list is back in ConnectionManager")
        XCTAssertTrue(source.contains("RcloneObscure.reveal("))
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

/// Only connected storage is asked about its usage (#147).
final class StorageUsageGateTests: XCTestCase {

    /// A configured remote that is not mounted is not asked anything — not `about`,
    /// not the usage document. The supervisor here has no daemon, so if the gate
    /// were missing the outcome would be `.unreachable`, not `.notConnected`.
    func testAnUnmountedConnectionIsNotAsked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grr147-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = ConnectionManager(
            supervisor: DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"), runtimeDirectory: dir),
            registry: MountRegistry(fileURL: dir.appendingPathComponent("mounts.json")))
        let fetched = Recorder()
        let fetcher = StorageUsage.Fetcher { request in
            await fetched.record(request)
            throw URLError(.cancelled)
        }

        let outcome = await manager.storageUsage(for: Connection(remote: "proton", displayName: "Proton"),
                                                 fetcher: fetcher)

        XCTAssertEqual(outcome, .notConnected)
        let request = await fetched.last
        XCTAssertNil(request, "nothing may be fetched for an unmounted connection")
    }

    /// The same connection, once mounted, gets past the gate (and here, with no
    /// daemon, fails honestly as unreachable rather than claiming not-connected).
    func testAMountedConnectionIsAsked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grr147-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = ConnectionManager(
            supervisor: DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"), runtimeDirectory: dir),
            registry: MountRegistry(fileURL: dir.appendingPathComponent("mounts.json")))
        let connection = Connection(remote: "dav1", displayName: "Cloud")
        await manager.adoptActiveMountForTesting(ConnectionManager.ActiveMount(
            connection: connection, serverID: "s1", mountPoint: dir.appendingPathComponent("Cloud")))

        let outcome = await manager.storageUsage(for: connection)

        guard case .unreachable = outcome else { return XCTFail("expected unreachable, got \(outcome)") }
    }

    /// A real daemon with a throwaway config holding one WebDAV remote on an
    /// `.invalid` host, so `about` fails at once and the usage-document path runs.
    private func withGateDaemon(_ body: (ConnectionManager, Connection) async throws -> Void) async throws {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/grrclone/Resources/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
        ]
        guard let rclone = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("no rclone binary found")
        }
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("gru" + String(UInt32.random(in: 0..<0xFFFFFF), radix: 16))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("rclone.conf")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let previous = ProcessInfo.processInfo.environment["RCLONE_CONFIG"]
        setenv("RCLONE_CONFIG", config.path, 1)
        defer { if let previous { setenv("RCLONE_CONFIG", previous, 1) } else { unsetenv("RCLONE_CONFIG") } }

        let supervisor = DaemonSupervisor(binary: rclone,
                                          settings: DaemonSettings(cacheDirectory: dir.appendingPathComponent("c")),
                                          runtimeDirectory: dir)
        let client = try await supervisor.start()
        do {
            try await client.createRemote(name: "gate", type: "webdav",
                                          parameters: ["url": "https://grr-test.invalid/", "vendor": "other"])
            let manager = ConnectionManager(supervisor: supervisor,
                                            registry: MountRegistry(fileURL: dir.appendingPathComponent("mounts.json")))
            let connection = Connection(remote: "gate", displayName: "Gate")
            await manager.adoptActiveMountForTesting(ConnectionManager.ActiveMount(
                connection: connection, serverID: "s1", mountPoint: dir.appendingPathComponent("Gate")))
            try await body(manager, connection)
        } catch {
            await supervisor.stop()
            throw error
        }
        await supervisor.stop()
    }

    private static let validDocument =
        #"{"version": 1, "categories": [{"id": "files", "label": "Files", "used_bytes": 1, "hard_limit_bytes": 10}]}"#

    private static func ok(_ request: URLRequest) -> (Data, URLResponse) {
        (Data(validDocument.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                   headerFields: ["Content-Type": "application/json"])!)
    }

    /// A disconnect that lands while the usage document is being fetched: the
    /// figures are not reported for a volume that is no longer there (Codex, on
    /// review). The fetcher disconnects mid-request and then returns good figures.
    func testADisconnectDuringTheFetchIsNotReportedAsUsage() async throws {
        try await withGateDaemon { manager, connection in
            let fetcher = StorageUsage.Fetcher { request in
                await manager.forgetActiveMountForTesting(connection.id)   // the user clicks Disconnect
                return Self.ok(request)
            }
            let outcome = await manager.storageUsage(for: connection, fetcher: fetcher)
            XCTAssertEqual(outcome, .notConnected, "figures were reported for a volume disconnected mid-fetch")
        }
    }

    /// When the caller says stop — the request superseded, the remote edited — the
    /// request contacts nothing more. Here it stops just before the document fetch.
    func testAStoppedRequestDoesNotFetch() async throws {
        try await withGateDaemon { manager, connection in
            final class Counter: @unchecked Sendable {
                private let lock = NSLock(); private var n = 0
                func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
            }
            let asks = Counter(), fetches = Counter()
            let fetcher = StorageUsage.Fetcher { request in _ = fetches.next(); return Self.ok(request) }
            // Yes after the client, yes after `about`, then no.
            let outcome = await manager.storageUsage(for: connection, fetcher: fetcher,
                                                     proceed: { asks.next() < 3 })
            XCTAssertEqual(outcome, .notConnected)
            XCTAssertEqual(fetches.next(), 1, "the document was fetched after the caller said stop")
        }
    }

    /// Mid-disconnect — unmounted, server not yet stopped, still in `active` — is not
    /// connected for this purpose. A transport whose unmount waits lets the test ask
    /// in exactly that window.
    func testAVolumeBeingDisconnectedIsNotAsked() async throws {
        actor Gate { var open = false; func release() { open = true }; func wait() async {
            while !open { try? await Task.sleep(nanoseconds: 10_000_000) } } }
        struct SlowUnmount: MountTransport {
            let kind: TransportKind = .nfs
            let gate: Gate
            func serveParameters(for connection: Connection, cacheRoot: URL) -> [String: JSONValue] { [:] }
            func mount(connection: Connection, server: RcloneRCClient.Server, at mountPoint: URL) async throws {}
            func unmount(at mountPoint: URL) async throws { await gate.wait() }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grr147-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let manager = ConnectionManager(
            supervisor: DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"), runtimeDirectory: dir),
            registry: MountRegistry(fileURL: dir.appendingPathComponent("mounts.json")),
            transports: [SlowUnmount(gate: gate)])
        let connection = Connection(remote: "dav1", displayName: "Cloud")
        await manager.adoptActiveMountForTesting(ConnectionManager.ActiveMount(
            connection: connection, serverID: "s1", mountPoint: dir.appendingPathComponent("Cloud")))

        let disconnecting = Task { try? await manager.disconnect(connection.id) }
        try await Task.sleep(nanoseconds: 100_000_000)   // inside the unmount now
        let stillListed = await manager.activeMounts.contains { $0.connection.id == connection.id }
        XCTAssertTrue(stillListed, "the window this test needs: listed as active mid-disconnect")

        let outcome = await manager.storageUsage(for: connection)
        await gate.release()
        _ = await disconnecting.value

        XCTAssertEqual(outcome, .notConnected, "a volume being disconnected must not be asked")
    }
}
