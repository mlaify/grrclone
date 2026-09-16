import XCTest
@testable import GrrCloneCore

/// These cover the paths where a mistake destroys user data rather than merely failing:
/// deciding which mounts grrclone may unmount, and where it may mount.
final class MountSafetyTests: XCTestCase {

    // MARK: - Parsing the mount table

    func testParsesRealMountOutput() {
        // Captured verbatim from the development machine, which runs both grrclone's
        // mounts and the user's own hand-rolled ones.
        let output = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        localhost:/ on /Users/mdavis/CloudVaults (nfs, nodev, nosuid, mounted by mdavis)
        localhost:/ on /Users/mdavis/Cloud (nfs, nodev, nosuid, mounted by mdavis)
        map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
        """
        let entries = SystemMounts.parse(output)
        XCTAssertEqual(entries.count, 4)

        let nfs = entries.filter(\.isLoopbackNFS)
        XCTAssertEqual(nfs.map(\.mountPoint),
                       ["/Users/mdavis/CloudVaults", "/Users/mdavis/Cloud"])
        XCTAssertEqual(entries[0].source, "/dev/disk3s1s1")
        XCTAssertEqual(entries[0].mountPoint, "/")
    }

    func testParsesMountPointContainingSpaces() {
        // " on " appears inside the path, so a naive split on the first occurrence would
        // truncate the mount point and we would then fail to recognise a path we own.
        let output = "localhost:/ on /Users/mdavis/My Files on Cloud (nfs, mounted by mdavis)"
        let entries = SystemMounts.parse(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].mountPoint, "/Users/mdavis/My Files on Cloud")
    }

    func testIgnoresMalformedLines() {
        XCTAssertTrue(SystemMounts.parse("garbage without parens").isEmpty)
        XCTAssertTrue(SystemMounts.parse("").isEmpty)
    }

    // MARK: - Ownership

    /// The core safety property. A user's own rclone mount is byte-for-byte
    /// indistinguishable from ours in mount(8) output, so ownership must come from our
    /// own records. If this ever returns true for an unrecorded path, grrclone will
    /// force-unmount volumes it did not create.
    func testOwnershipRequiresAnExplicitRecord() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let registry = MountRegistry(fileURL: url)
        let ours = "/Users/mdavis/grrclone/testvault"
        let theirs = "/Users/mdavis/Cloud"

        try await registry.record(.init(connectionID: UUID(), mountPoint: ours,
                                        transport: "nfs", serverID: "nfs-1",
                                        port: 12345, pid: 999))

        let ownsOurs = await registry.owns(mountPoint: ours)
        let ownsTheirs = await registry.owns(mountPoint: theirs)
        XCTAssertTrue(ownsOurs)
        XCTAssertFalse(ownsTheirs, "A path grrclone never recorded must never be claimed")
    }

    func testForgettingRevokesOwnership() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let registry = MountRegistry(fileURL: url)
        let path = "/Users/mdavis/grrclone/x"
        try await registry.record(.init(connectionID: UUID(), mountPoint: path,
                                        transport: "nfs", serverID: "s", port: 1, pid: 2))
        try await registry.forget(mountPoint: path)
        let owns = await registry.owns(mountPoint: path)
        XCTAssertFalse(owns)
    }

    func testOwnershipSurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let path = "/Users/mdavis/grrclone/persisted"
        let first = MountRegistry(fileURL: url)
        try await first.record(.init(connectionID: UUID(), mountPoint: path,
                                     transport: "nfs", serverID: "s", port: 1, pid: 2))

        // A fresh instance models the app relaunching after a crash. Without this, an
        // orphaned mount could never be identified and cleaned up.
        let reloaded = MountRegistry(fileURL: url)
        let owns = await reloaded.owns(mountPoint: path)
        XCTAssertTrue(owns)
    }

    // MARK: - Mount point safety

    func testRefusesToMountOverANonEmptyDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("important".utf8).write(to: directory.appendingPathComponent("user-file.txt"))

        // Mounting over existing files hides them for the life of the mount, which users
        // reasonably read as data loss.
        XCTAssertThrowsError(try NFSTransport.prepareMountPoint(directory))
    }

    func testToleratesDSStoreInAnOtherwiseEmptyMountPoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Finder leaves .DS_Store behind constantly; treating it as "occupied" would make
        // a mount point unusable after a single Finder visit.
        try Data().write(to: directory.appendingPathComponent(".DS_Store"))
        XCTAssertNoThrow(try NFSTransport.prepareMountPoint(directory))
    }

    func testCreatesAMissingMountPoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try NFSTransport.prepareMountPoint(directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Mount options

    /// These options are the difference between a dead backend returning an error and a
    /// dead backend wedging Finder until reboot. Measured: 7.1s to fail, versus hanging
    /// indefinitely without them. See docs/benchmarks.md.
    func testMountOptionsIncludeTheAntiHangSet() {
        let options = NFSTransport.mountOptions(port: 4321, readOnly: false)
        for required in ["soft", "intr", "timeo=600", "retrans=2", "nolocks", "locallocks"] {
            XCTAssertTrue(options.contains(required), "missing \(required)")
        }
        XCTAssertTrue(options.contains("port=4321"))
        XCTAssertTrue(options.contains("mountport=4321"))
        XCTAssertTrue(options.contains("tcp"))
        XCTAssertTrue(options.contains("nfc"), "macOS filename normalisation")
        XCTAssertFalse(options.contains("rdonly"))
    }

    func testReadOnlyAddsRdonly() {
        XCTAssertTrue(NFSTransport.mountOptions(port: 1, readOnly: true).contains("rdonly"))
    }

    // MARK: - serve/start parameters

    /// rclone rejects the entire serve/start request if given a key outside the vfs and
    /// nfs option blocks. attr_timeout is FUSE-only; cache_dir, transfers and checkers
    /// are process-global. All four were rejected in testing.
    func testServeParametersOmitGlobalAndFUSEOnlyKeys() {
        let connection = Connection(remote: "dav1", displayName: "Cloud")
        let params = NFSTransport().serveParameters(
            for: connection, cacheRoot: URL(fileURLWithPath: "/tmp/cache"))

        for forbidden in ["attr_timeout", "cache_dir", "transfers", "checkers"] {
            XCTAssertNil(params[forbidden], "\(forbidden) is not valid for serve/start")
        }
        XCTAssertEqual(params["type"]?.stringValue, "nfs")
        XCTAssertEqual(params["fs"]?.stringValue, "dav1:")
        XCTAssertEqual(params["nfs_cache_type"]?.stringValue, "disk")
    }

    /// rclone's NFS server has no authentication at all, so a non-loopback bind address
    /// would publish the user's entire storage account to the local network.
    func testServerAlwaysBindsToLoopback() {
        let params = NFSTransport().serveParameters(
            for: Connection(remote: "dav1"), cacheRoot: URL(fileURLWithPath: "/tmp/cache"))
        let addr = params["addr"]?.stringValue ?? ""
        XCTAssertTrue(addr.hasPrefix("localhost:"), "got \(addr)")
        XCTAssertFalse(addr.contains("0.0.0.0"))
    }

    /// symlink handle caching requires a Linux capability and cannot work on macOS.
    func testDefaultNFSCacheTypeIsUsableOnMacOS() {
        XCTAssertEqual(MountOptions().nfsCacheType, "disk")
        XCTAssertNotEqual(MountOptions().nfsCacheType, "symlink")
    }

    func testFsSpecIncludesSubpathWhenPresent() {
        XCTAssertEqual(Connection(remote: "dav1").fsSpec, "dav1:")
        XCTAssertEqual(Connection(remote: "dav1", path: "Photos/2026").fsSpec, "dav1:Photos/2026")
    }
}

/// The live mount table is read from the kernel, not parsed from text. These confirm the
/// real path agrees with reality on this machine.
final class LiveMountTableTests: XCTestCase {

    func testReadsRealMountTableFromKernel() async throws {
        let entries = try await SystemMounts.current()
        XCTAssertFalse(entries.isEmpty, "the kernel always has at least the root filesystem")
        XCTAssertTrue(entries.contains { $0.mountPoint == "/" })
    }

    func testRootIsAlwaysReportedAsMounted() async {
        let mounted = await SystemMounts.isMounted("/")
        XCTAssertTrue(mounted)
    }

    func testUnmountedPathIsNotReported() async {
        let mounted = await SystemMounts.isMounted("/definitely/not/a/mount/\(UUID().uuidString)")
        XCTAssertFalse(mounted)
    }

    func testEntriesCarryFileSystemType() async throws {
        let entries = try await SystemMounts.current()
        let root = entries.first { $0.mountPoint == "/" }
        XCTAssertEqual(root?.fileSystemType, "apfs")
    }
}

/// The liveness probe. Two subtle failure modes are covered here, both of which produced
/// a "healthy" verdict for a mount whose server had just been killed.
final class MountHealthTests: XCTestCase {

    func testHealthyForALiveLocalPath() async {
        let status = await MountHealth.probe(URL(fileURLWithPath: "/"))
        XCTAssertEqual(status, .healthy)
    }

    func testGoneForAPathThatIsNotAMount() async {
        let status = await MountHealth.probe(
            URL(fileURLWithPath: "/definitely/not/mounted/\(UUID().uuidString)"))
        XCTAssertEqual(status, .gone)
    }

    /// The probe must return well inside its deadline even on a healthy filesystem, since
    /// it runs on every wake and network change.
    func testProbeIsFast() async {
        let started = Date()
        _ = await MountHealth.probe(URL(fileURLWithPath: "/"), timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testBackoffLadderClimbsAndSaturates() {
        XCTAssertEqual(MountHealth.backoff(attempt: 0), 1)
        XCTAssertEqual(MountHealth.backoff(attempt: 1), 5)
        XCTAssertEqual(MountHealth.backoff(attempt: 2), 30)
        XCTAssertEqual(MountHealth.backoff(attempt: 3), 300)
        // Retrying a mount on a laptop that has been shut for hours must not spin.
        XCTAssertEqual(MountHealth.backoff(attempt: 99), 300)
        XCTAssertEqual(MountHealth.backoff(attempt: -1), 1)
    }
}
