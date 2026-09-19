import XCTest
import RcloneRC
@testable import GrrCloneCore

/// Unmounting is decided by a second read of the mount table, never by an exit
/// status — and a repair that cannot unmount keeps the record it could not clear.
///
/// Both come from one afternoon with three NFS mounts stacked on one path (#116,
/// #111): `diskutil` exited 0 having removed one layer, `umount -f` said "timed out"
/// having removed another, and the app's own repair path forgot a mount it had
/// failed to bring down.
final class UnmountVerificationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grrclone-unmount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A mount table that answers from a script, one read at a time. The last
    /// answer repeats, so a test does not have to predict the exact read count.
    private final class ScriptedTable: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [[SystemMounts.MountEntry]]
        private(set) var reads = 0

        init(_ answers: [[SystemMounts.MountEntry]]) { self.answers = answers }

        func read() throws -> [SystemMounts.MountEntry] {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            if answers.count > 1 { return answers.removeFirst() }
            return answers[0]
        }
    }

    private func nfs(_ path: String) -> SystemMounts.MountEntry {
        SystemMounts.MountEntry(source: "localhost:/", mountPoint: path, fileSystemType: "nfs")
    }

    // MARK: - #116

    /// The path is a plain directory, so both commands fail — and the table says
    /// the mount is gone after the first attempt. The table wins: success.
    func testUnmountBelievesTheTableNotTheExitStatus() async throws {
        let point = dir.appendingPathComponent("Cloud")
        let table = ScriptedTable([[nfs(point.path)], []])
        let transport = NFSTransport(mountTable: { try table.read() })

        try await transport.unmount(at: point)
        XCTAssertEqual(table.reads, 2, "one read before, one after the first attempt, then done")
    }

    /// Two layers before, one after: a layer came off and one remains. That is a
    /// failure, reported as exactly what it is, so the caller keeps the path as
    /// mounted and owned.
    func testALayerRemovedWithOneRemainingIsReportedNotSwallowed() async {
        let point = dir.appendingPathComponent("Stacked")
        let two = [nfs(point.path), nfs(point.path)]
        let table = ScriptedTable([two, two, [nfs(point.path)]])
        let transport = NFSTransport(mountTable: { try table.read() })

        do {
            try await transport.unmount(at: point)
            XCTFail("one layer is still mounted; this must throw")
        } catch let error as MountError {
            guard case .unmountFailed(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("Removed one of 2 volumes"), why)
            XCTAssertTrue(why.contains("1 remains"), why)
            XCTAssertTrue(why.contains("umount -f \(point.path)"), "must say how to clear the rest: \(why)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Nothing mounted there to begin with is the goal state already. No command
    /// runs, which is also what makes this fast enough to notice if it regresses.
    func testAnAlreadyClearPathSucceedsWithoutRunningAnything() async throws {
        let point = dir.appendingPathComponent("Clear")
        let table = ScriptedTable([[]])
        let transport = NFSTransport(mountTable: { try table.read() })

        let started = Date()
        try await transport.unmount(at: point)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "diskutil or umount ran on a path nothing is mounted at")
        XCTAssertEqual(table.reads, 1)
    }

    /// "Could not look" is not "it is gone". A caller that would go on to forget
    /// the record and clean the directory must be told the path may still be live.
    func testAnUnreadableTableIsAFailureNotASuccess() async {
        let point = dir.appendingPathComponent("Blind")
        let transport = NFSTransport(mountTable: { throw SystemMounts.MountTableError.unreadable })

        do {
            try await transport.unmount(at: point)
            XCTFail("must not report success on no evidence")
        } catch let error as MountError {
            guard case .unmountFailed(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("could not read the mount table"), why)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - #111

    /// A transport that will not let go.
    private struct StuckTransport: MountTransport {
        let kind: TransportKind = .nfs
        func serveParameters(for connection: Connection, cacheRoot: URL) -> [String: JSONValue] { [:] }
        func mount(connection: Connection, server: RcloneRCClient.Server, at mountPoint: URL) async throws {}
        func unmount(at mountPoint: URL) async throws {
            throw MountError.unmountFailed("\(mountPoint.path) would not come down")
        }
    }

    /// The repair path, given a mount the table no longer lists (so the probe says
    /// `.gone`) and a transport whose unmount fails. Before #111 the failure was
    /// `try?`'d and the record forgotten anyway; the mount stayed up, unowned.
    func testARepairThatCannotUnmountKeepsTheRecordAndTheMount() async throws {
        let registry = MountRegistry(fileURL: dir.appendingPathComponent("mounts.json"))
        let supervisor = DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"),
                                          runtimeDirectory: dir)
        let manager = ConnectionManager(supervisor: supervisor, registry: registry,
                                        transports: [StuckTransport()])

        let connection = Connection(remote: "dav1", displayName: "Cloud")
        let point = dir.appendingPathComponent("Cloud")
        try await registry.record(MountRegistry.Entry(
            connectionID: connection.id, mountPoint: point.path, transport: "nfs",
            serverID: "s1", port: 2049, pid: 1))
        await manager.adoptActiveMountForTesting(
            ConnectionManager.ActiveMount(connection: connection, serverID: "s1", mountPoint: point))

        let report = await manager.checkHealth()

        XCTAssertEqual(report.repaired, [], "nothing was repaired")
        XCTAssertNotNil(report.failed[connection.id], "the failure must be reported")
        XCTAssertTrue(report.failed[connection.id]?.contains("would not come down") == true,
                      "and say why: \(report.failed)")

        let stillOwned = await registry.owns(mountPoint: point.path)
        XCTAssertTrue(stillOwned, "a mount that would not come down is still ours")
        let stillActive = await manager.activeMounts.map(\.mountPoint.path)
        XCTAssertEqual(stillActive, [point.path], "and still live in this session")
    }
}
