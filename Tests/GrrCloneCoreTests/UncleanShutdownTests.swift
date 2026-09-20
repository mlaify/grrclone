import XCTest
@testable import GrrCloneCore

final class MountPointProtectionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grr-protect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? NFSTransport.unprotect(root)
        try? FileManager.default.removeItem(at: root)
    }

    /// The whole point: a mountpoint with nothing mounted on it must not silently
    /// accept data that the next mount would hide.
    func testAFreshMountPointRefusesWrites() throws {
        let mountPoint = root.appendingPathComponent("dav1")
        try NFSTransport.prepareMountPoint(mountPoint)

        let stray = mountPoint.appendingPathComponent("stray.txt")
        XCTAssertThrowsError(try "data".write(to: stray, atomically: true, encoding: .utf8),
                             "an unmounted mountpoint must not be writable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testProtectionIsReversible() throws {
        let mountPoint = root.appendingPathComponent("dav1")
        try NFSTransport.prepareMountPoint(mountPoint)
        try NFSTransport.unprotect(mountPoint)

        let file = mountPoint.appendingPathComponent("ok.txt")
        XCTAssertNoThrow(try "data".write(to: file, atomically: true, encoding: .utf8))
    }

    /// Removing a directory needs write permission on it, so the cleanup path has to
    /// undo its own protection. If it does not, every disconnect leaves a directory
    /// behind and the protection becomes the thing creating the litter.
    func testAProtectedEmptyMountPointCanStillBeRemoved() throws {
        let mountPoint = root.appendingPathComponent("dav1")
        try NFSTransport.prepareMountPoint(mountPoint)

        ConnectionManager.removeIfEmpty(mountPoint.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint.path),
                       "an empty mountpoint should be removed, not left protected")
    }

    /// A mountpoint that cannot be removed because it holds something must be left
    /// unwritable rather than left as a trap.
    func testANonEmptyMountPointIsProtectedRatherThanRemoved() throws {
        let mountPoint = root.appendingPathComponent("dav1")
        try NFSTransport.prepareMountPoint(mountPoint)
        try NFSTransport.unprotect(mountPoint)
        try "shadowed".write(to: mountPoint.appendingPathComponent("file.txt"),
                             atomically: true, encoding: .utf8)

        ConnectionManager.removeIfEmpty(mountPoint.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.path))
        XCTAssertThrowsError(try "more".write(to: mountPoint.appendingPathComponent("b.txt"),
                                              atomically: true, encoding: .utf8))
    }
}

final class SessionMarkerTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grr-session-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testACleanShutdownLeavesNothingBehind() {
        let marker = SessionMarker(url: url)
        marker.begin()
        marker.clear()
        XCTAssertNil(marker.previousSession(), "a cleared marker must read as a clean exit")
    }

    /// A start that fails must not touch the previous session's record. It used to
    /// begin the new session before anything could throw, so a launch refused for
    /// an orphan it could not identify — or, as here, a binary that is not rclone —
    /// overwrote the crash record with an empty one, and the retry reported that
    /// nothing had been lost (#117).
    func testAFailedStartLeavesThePreviousSessionsRecordIntact() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = SessionMarker(url: SessionMarker.defaultURL(runtimeDirectory: dir))
        marker.begin()
        marker.update(mountPoints: ["/Users/x/Cloud"])

        // Exists and is executable, exits at once, never opens the socket.
        let supervisor = DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/true"),
                                          runtimeDirectory: dir)
        do {
            _ = try await supervisor.start()
            XCTFail("/usr/bin/true is not an rclone daemon; start must throw")
        } catch {
            // expected
        }

        let record = marker.previousSession()
        XCTAssertEqual(record?.mountPoints, ["/Users/x/Cloud"],
                       "the crash record must survive a start that failed")
        let seen = await supervisor.previousSession
        XCTAssertEqual(seen?.mountPoints, ["/Users/x/Cloud"], "and be what the caller is shown")
    }

    func testAnInterruptedSessionIsDetected() {
        let marker = SessionMarker(url: url)
        marker.begin()
        marker.update(mountPoints: ["/Users/someone/Cloud"])
        // No clear() — the process died here.

        let previous = SessionMarker(url: url).previousSession()
        XCTAssertEqual(previous?.mountPoints, ["/Users/someone/Cloud"])
    }

    func testUpdatingMountPointsKeepsTheStartTime() {
        let marker = SessionMarker(url: url)
        marker.begin()
        let started = marker.previousSession()?.startedAt
        marker.update(mountPoints: ["/a", "/b"])

        XCTAssertEqual(marker.previousSession()?.startedAt, started)
        XCTAssertEqual(marker.previousSession()?.mountPoints, ["/a", "/b"])
    }

    func testReadingIsNotDestructive() {
        let marker = SessionMarker(url: url)
        marker.begin()
        _ = marker.previousSession()
        XCTAssertNotNil(marker.previousSession(), "reading must not consume the evidence")
    }
}

final class UncleanShutdownReportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grr-unclean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSeparatesShadowedPathsFromEmptyOnes() throws {
        let withData = root.appendingPathComponent("Cloud")
        let empty = root.appendingPathComponent("Vaults")
        try FileManager.default.createDirectory(at: withData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try "lost work".write(to: withData.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)

        let record = SessionMarker.Record(startedAt: Date(),
                                          mountPoints: [withData.path, empty.path])
        let report = UncleanShutdownReport.inspect(record)

        XCTAssertEqual(report.shadowedPaths, [withData.path])
        XCTAssertEqual(report.cleanPaths, [empty.path])
        XCTAssertTrue(report.needsAttention)
    }

    /// A .DS_Store is not the user's work and must not raise an alarm, or the warning
    /// fires after every crash regardless and stops meaning anything.
    func testADSStoreAloneIsNotTreatedAsShadowedData() throws {
        let path = root.appendingPathComponent("Cloud")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try "".write(to: path.appendingPathComponent(".DS_Store"),
                     atomically: true, encoding: .utf8)

        let report = UncleanShutdownReport.inspect(
            SessionMarker.Record(startedAt: Date(), mountPoints: [path.path]))

        XCTAssertFalse(report.needsAttention)
        XCTAssertEqual(report.cleanPaths, [path.path])
    }

    func testAPathThatNoLongerExistsIsIgnored() {
        let report = UncleanShutdownReport.inspect(
            SessionMarker.Record(startedAt: Date(),
                                 mountPoints: [root.appendingPathComponent("gone").path]))
        XCTAssertTrue(report.shadowedPaths.isEmpty)
        XCTAssertTrue(report.cleanPaths.isEmpty)
    }

    /// Recovery moves the data aside so the remote can be mounted without hiding it.
    /// It must never merge into the remote: grrclone cannot know which copy is newer.
    func testRecoveryMovesDataAsideAndFreesTheMountPoint() throws {
        let path = root.appendingPathComponent("Cloud")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try "lost work".write(to: path.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)

        let moved = try UncleanShutdownReport.recover(path: path.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path),
                       "the mountpoint must be free for the remote")
        XCTAssertTrue(moved.lastPathComponent.contains("recovered"))
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("notes.txt"),
                                  encoding: .utf8), "lost work")
    }

    /// Two crashes on the same day must not have the second recovery overwrite the
    /// first one's data.
    func testASecondRecoveryDoesNotClobberTheFirst() throws {
        let path = root.appendingPathComponent("Cloud")
        for content in ["first", "second"] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try content.write(to: path.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)
            _ = try UncleanShutdownReport.recover(path: path.path)
        }

        let recovered = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("recovered") }
        XCTAssertEqual(recovered.count, 2, "each recovery needs its own folder")
    }
}
