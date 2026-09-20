import XCTest
import RcloneRC
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

    // MARK: - The mount table (#115, #108)

    /// A supervisor that is never started. `ConnectionManager` needs one to exist;
    /// none of these paths ever talk to it.
    private func idleSupervisor() -> DaemonSupervisor {
        DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"), runtimeDirectory: dir)
    }

    private func entry(_ path: String) -> MountRegistry.Entry {
        MountRegistry.Entry(connectionID: UUID(), mountPoint: path, transport: "nfs",
                            serverID: nil, port: nil, pid: 1)
    }

    /// `getmntinfo` returning 0 is an error — `/` is always mounted — and the old
    /// `?? []` made it read as "none of our mounts are up". That forgot every entry,
    /// reported them all as cleaned, and so authorised killing the orphan daemon
    /// under live mounts. Nothing may be forgotten and the kill must be refused.
    func testUnreadableMountTableKeepsEveryRecordAndRefusesTheKill() async throws {
        let registry = MountRegistry(fileURL: dir.appendingPathComponent("mounts.json"))
        try await registry.record(entry("/Users/x/Cloud"))
        try await registry.record(entry("/Users/x/CloudVaults"))

        let manager = ConnectionManager(
            supervisor: idleSupervisor(), registry: registry,
            mountTable: { throw SystemMounts.MountTableError.unreadable })

        let outcome = await manager.unmountRecordedMounts()
        XCTAssertEqual(Set(outcome.stillMounted), ["/Users/x/Cloud", "/Users/x/CloudVaults"],
                       "every recorded mount must be reported as still up: nothing was established")
        XCTAssertTrue(outcome.unmounted.isEmpty)

        let report = try await manager.reconcileOrphans()
        XCTAssertTrue(report.tableUnreadable)
        XCTAssertTrue(report.cleaned.isEmpty, "nothing was cleaned, so nothing may say it was")

        let remaining = await registry.all.map(\.mountPoint)
        XCTAssertEqual(Set(remaining), ["/Users/x/Cloud", "/Users/x/CloudVaults"],
                       "an unreadable table must not forget a single owned mount")
    }

    /// With a readable table the same records are handled as before: one not in the
    /// table is stale and forgotten. This is the control for the test above.
    func testReadableMountTableStillClearsStaleRecords() async throws {
        let registry = MountRegistry(fileURL: dir.appendingPathComponent("mounts.json"))
        try await registry.record(entry("/Users/x/Gone"))

        let manager = ConnectionManager(
            supervisor: idleSupervisor(), registry: registry,
            mountTable: { [SystemMounts.MountEntry(source: "/dev/disk1", mountPoint: "/", fileSystemType: "apfs")] })

        let report = try await manager.reconcileOrphans()
        XCTAssertEqual(report.cleaned, ["/Users/x/Gone"])
        XCTAssertFalse(report.tableUnreadable)
        let remaining = await registry.all
        XCTAssertTrue(remaining.isEmpty)
    }

    /// The mechanism behind three NFS mounts stacked on one folder. The directory is
    /// empty — a dead mount's listing fails, or the volume simply has nothing in it —
    /// and the old check, keyed on visible entries, let the mount proceed.
    func testRefusesToMountOverAnExistingMountEvenWhenItLooksEmpty() throws {
        let point = dir.appendingPathComponent("Cloud")
        try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)

        XCTAssertNoThrow(try NFSTransport.prepareMountPoint(point, existingMounts: 0),
                         "an empty directory with nothing mounted on it is fine")
        XCTAssertThrowsError(try NFSTransport.prepareMountPoint(point, existingMounts: 1)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("already mounted"), text)
            XCTAssertTrue(text.contains("umount -f"), "must say how to clear it: \(text)")
        }
        XCTAssertThrowsError(try NFSTransport.prepareMountPoint(point, existingMounts: 3)) { error in
            XCTAssertTrue(error.localizedDescription.contains("3 volumes are stacked"),
                          error.localizedDescription)
        }
    }

    /// Mounting blind is the same mistake one step earlier: if the table cannot be
    /// read, whether the path already has a volume on it is unknown, and unknown is
    /// a refusal.
    func testMountRefusesWhenTheMountTableCannotBeRead() async throws {
        let point = dir.appendingPathComponent("Blind")
        let transport = NFSTransport(mountTable: { throw SystemMounts.MountTableError.unreadable })
        let server = RcloneRCClient.Server(id: "s1", addr: "127.0.0.1:2049")

        do {
            try await transport.mount(connection: Connection(remote: "x"), server: server, at: point)
            XCTFail("must not reach /sbin/mount")
        } catch let error as MountError {
            guard case .mountPointUnavailable(let why) = error else {
                return XCTFail("wrong refusal: \(error)")
            }
            XCTAssertTrue(why.contains("could not read the mount table"), why)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: point.path),
                       "refusing before the listing means nothing was created either")
    }

    /// The real table is never empty. If this ever fails, `current()` is throwing on
    /// a healthy machine, and the fail-closed paths above would refuse everything.
    func testTheRealMountTableAlwaysHoldsRoot() async throws {
        let table = try await SystemMounts.current()
        XCTAssertTrue(table.contains { $0.mountPoint == "/" })
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
    func testEncryptRefusesAnEmptyPath() async {
        do {
            try await ConfigEncryption.encrypt(rclone: URL(fileURLWithPath: "/bin/echo"),
                                               configPath: "", password: "hunter2")
            XCTFail("must refuse")
        } catch {
            guard case ConfigEncryption.Failure.unknownConfigPath = error else {
                return XCTFail("expected unknownConfigPath, got \(error)")
            }
        }
    }

    /// Unknown is not permission to proceed.
    func testEncryptRefusesAConfigItCannotRead() async {
        let missing = dir.appendingPathComponent("nope.conf").path
        do {
            try await ConfigEncryption.encrypt(rclone: URL(fileURLWithPath: "/bin/echo"),
                                               configPath: missing, password: "hunter2")
            XCTFail("must refuse")
        } catch {
            guard case ConfigEncryption.Failure.cannotReadConfig = error else {
                return XCTFail("expected cannotReadConfig, got \(error)")
            }
        }
    }

    /// A tool that never answers must not hang the caller. This stand-in ignores
    /// its arguments and sleeps, which is what an rclone stuck on an unexpected
    /// prompt looks like from here. The deadline ends it and says so.
    func testEncryptGivesUpOnAToolThatNeverFinishes() async throws {
        let config = dir.appendingPathComponent("rclone.conf")
        try "[dav1]\ntype = webdav\n".write(to: config, atomically: true, encoding: .utf8)
        let stuck = dir.appendingPathComponent("stuck-rclone.sh")
        try "#!/bin/sh\nsleep 30\n".write(to: stuck, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuck.path)
        let started = Date()
        do {
            try await ConfigEncryption.encrypt(rclone: stuck,
                                               configPath: config.path, password: "hunter2",
                                               timeout: 1)
            XCTFail("must time out")
        } catch {
            guard case ConfigEncryption.Failure.commandFailed(let why) = error else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertTrue(why.contains("did not finish"), why)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline must be real")
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
