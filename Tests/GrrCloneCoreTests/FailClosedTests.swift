import XCTest
@testable import GrrCloneCore

/// The cluster of fail-open defects found by the 2026-09-18 audit.
///
/// Each was the same mistake wearing ordinary Swift: `try? … ?? []`, a discarded
/// `OSStatus`, a `guard let … else { return false }`. They read as tolerant code,
/// which is exactly why they were invisible — tolerance is wrong when the question is
/// "is it safe to proceed".
final class FailClosedTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grrclone-failclosed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - MountRegistry (#75)

    /// An absent file legitimately means "nothing mounted".
    func testAbsentRegistryIsEmptyAndNotAFailure() async {
        let registry = MountRegistry(fileURL: dir.appendingPathComponent("mounts.json"))
        let entries = await registry.all
        let failure = await registry.loadFailure
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(failure, "a missing registry is not a failure to read one")
    }

    /// An unreadable file must not silently read as "we own nothing". That is what
    /// disowns live mounts: `owns()` goes false, `shutdown()` skips them, and
    /// `reconcileOrphans()` returns early.
    func testUnreadableRegistryIsReportedNotSilentlyEmpty() async throws {
        let url = dir.appendingPathComponent("mounts.json")
        try Data("{ this is not the json you are looking for".utf8).write(to: url)

        let registry = MountRegistry(fileURL: url)
        let failure = await registry.loadFailure

        XCTAssertNotNil(failure, "a corrupt registry must be reported, not treated as empty")
    }

    /// The realistic trigger is a schema change, not disk damage: one new
    /// non-optional field and every existing record stops decoding.
    func testRegistryWithMissingFieldIsTreatedAsUnreadable() async throws {
        let url = dir.appendingPathComponent("mounts.json")
        // A well-formed array of objects that are missing `transport`.
        try Data("""
        [{"connectionID":"\(UUID().uuidString)","mountPoint":"/tmp/x",
          "pid":1,"createdAt":"2026-09-18T00:00:00Z"}]
        """.utf8).write(to: url)

        let registry = MountRegistry(fileURL: url)
        let failure = await registry.loadFailure

        XCTAssertNotNil(failure, "a schema mismatch must not read as an empty registry")
    }

    /// The unreadable file is moved aside, not deleted: it is the only record of what
    /// might still be mounted, and it is JSON a human can read.
    func testUnreadableRegistryIsQuarantinedRatherThanDestroyed() async throws {
        let url = dir.appendingPathComponent("mounts.json")
        try Data("not json".utf8).write(to: url)

        _ = MountRegistry(fileURL: url)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("mounts.json.unreadable-") },
                      "the unreadable file should be kept aside, got \(siblings)")
    }

    // MARK: - ConfigEncryption (#79, #80)

    /// "Cannot read the file" is not "the file is plaintext".
    func testEncryptionStateIsUnknownForAnUnreadableConfig() {
        let missing = dir.appendingPathComponent("nope.conf").path
        XCTAssertNil(ConfigEncryption.encryptionState(configPath: missing),
                     "an unreadable config must report unknown, not 'not encrypted'")
        XCTAssertNil(ConfigEncryption.encryptionState(configPath: ""),
                     "an empty path cannot answer anything")
    }

    func testEncryptionStateReadsARealConfig() throws {
        let plain = dir.appendingPathComponent("plain.conf")
        try "[dav1]\ntype = webdav\n".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigEncryption.encryptionState(configPath: plain.path), false)

        let sealed = dir.appendingPathComponent("sealed.conf")
        try "# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nabc123\n"
            .write(to: sealed, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigEncryption.encryptionState(configPath: sealed.path), true)
    }

    /// Refuse rather than aim a real password at an unintended target.
    func testEncryptRefusesAnEmptyPath() {
        XCTAssertThrowsError(
            try ConfigEncryption.encrypt(rclone: URL(fileURLWithPath: "/bin/echo"),
                                         configPath: "", password: "hunter2")
        ) { error in
            guard case ConfigEncryption.Failure.unknownConfigPath = error else {
                return XCTFail("expected unknownConfigPath, got \(error)")
            }
        }
    }

    /// Unknown is not permission to proceed.
    func testEncryptRefusesAConfigItCannotRead() {
        let missing = dir.appendingPathComponent("nope.conf").path
        XCTAssertThrowsError(
            try ConfigEncryption.encrypt(rclone: URL(fileURLWithPath: "/bin/echo"),
                                         configPath: missing, password: "hunter2")
        ) { error in
            guard case ConfigEncryption.Failure.cannotReadConfig = error else {
                return XCTFail("expected cannotReadConfig, got \(error)")
            }
        }
    }

    // MARK: - TransportKind (#78)

    /// A transport we no longer implement must not decode into a connection that can
    /// never connect and has no UI to repair it.
    func testRetiredTransportDecodesAsNFS() throws {
        let json = """
        {"id":"\(UUID().uuidString)","remote":"dav1","path":"","displayName":"dav1",
         "transport":"webdav-netfs","connectAtLogin":false,
         "options":{"readOnly":false,"vfsCacheMode":"full","vfsCacheMaxAge":"24h",
                    "vfsCacheMaxSize":"20G","dirCacheTime":"30s","vfsWriteBack":"5s",
                    "pollInterval":"1m","nfsCacheType":"disk"}}
        """
        let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
        XCTAssertEqual(connection.transport, .nfs)
    }

    func testUnknownTransportDecodesAsNFS() throws {
        let json = """
        {"id":"\(UUID().uuidString)","remote":"dav1","path":"","displayName":"dav1",
         "transport":"something-from-the-future","connectAtLogin":false,
         "options":{"readOnly":false,"vfsCacheMode":"full","vfsCacheMaxAge":"24h",
                    "vfsCacheMaxSize":"20G","dirCacheTime":"30s","vfsWriteBack":"5s",
                    "pollInterval":"1m","nfsCacheType":"disk"}}
        """
        let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
        XCTAssertEqual(connection.transport, .nfs)
    }
}
