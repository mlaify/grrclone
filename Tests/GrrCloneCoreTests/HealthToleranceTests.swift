import XCTest
import RcloneRC
@testable import GrrCloneCore

/// A mount that is slow is not a mount that is dead (#146).
///
/// A remote backend on a slow disk misses a five-second lookup a few times a
/// day. Rebuilding on that cancelled a 118 MB upload mid-flight and raised the
/// kernel's "server not responding" prompt for a volume that was fine. Now one
/// miss is a report, a second miss with a long deadline is a rebuild, and a
/// mount with uploads in flight is never rebuilt while they run.
final class HealthToleranceTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Records every unmount asked of it and refuses, so a rebuild attempt shows
    /// up as a "would not come down" failure rather than a real unmount.
    private final class RecordingTransport: MountTransport, @unchecked Sendable {
        let kind: TransportKind = .nfs
        private let lock = NSLock()
        private(set) var unmounts: [String] = []
        func serveParameters(for connection: Connection, cacheRoot: URL) -> [String: JSONValue] { [:] }
        func mount(connection: Connection, server: RcloneRCClient.Server, at mountPoint: URL) async throws {}
        private func record(_ path: String) { lock.lock(); unmounts.append(path); lock.unlock() }
        func unmount(at mountPoint: URL) async throws {
            record(mountPoint.path)
            throw MountError.unmountFailed("\(mountPoint.path) would not come down")
        }
    }

    /// Answers a scripted sequence of statuses and records the deadlines asked.
    private final class ScriptedProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var script: [MountHealth.Status]
        private(set) var deadlines: [TimeInterval] = []
        init(_ script: [MountHealth.Status]) { self.script = script }
        func answer(_ point: URL, _ timeout: TimeInterval) -> MountHealth.Status {
            lock.lock(); defer { lock.unlock() }
            deadlines.append(timeout)
            return script.isEmpty ? .healthy : script.removeFirst()
        }
    }

    private func makeManager(probe: ScriptedProbe, uploads: Int?,
                         transport: RecordingTransport) async throws -> (ConnectionManager, Connection) {
        let registry = MountRegistry(fileURL: dir.appendingPathComponent("mounts.json"))
        let supervisor = DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"),
                                          runtimeDirectory: dir)
        let manager = ConnectionManager(supervisor: supervisor, registry: registry,
                                        transports: [transport],
                                        probe: { probe.answer($0, $1) },
                                        uploadsInFlight: { _ in uploads })
        let connection = Connection(remote: "dav1", displayName: "Cloud")
        let point = dir.appendingPathComponent("Cloud")
        try await registry.record(MountRegistry.Entry(
            connectionID: connection.id, mountPoint: point.path, transport: "nfs",
            serverID: "s1", port: 2049, pid: 1))
        await manager.adoptActiveMountForTesting(
            ConnectionManager.ActiveMount(connection: connection, serverID: "s1", mountPoint: point))
        return (manager, connection)
    }

    /// The case from the field: one lookup takes six seconds, the next answers.
    func testOneSlowAnswerIsReportedAndNothingIsTouched() async throws {
        let probe = ScriptedProbe([.unresponsive, .healthy])
        let transport = RecordingTransport()
        let (manager, connection) = try await makeManager(probe: probe, uploads: 0, transport: transport)

        let report = await manager.checkHealth()

        XCTAssertEqual(transport.unmounts, [], "a slow mount must not be torn down")
        XCTAssertEqual(report.repaired, [])
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertNotNil(report.slow[connection.id], "but the slowness is reported")
        XCTAssertEqual(probe.deadlines, [ConnectionManager.probeDeadline,
                                         ConnectionManager.confirmationDeadline],
                       "the second look must wait longer than the first")
        XCTAssertGreaterThanOrEqual(ConnectionManager.confirmationDeadline, 30)
    }

    /// Silence twice, the second time for the long deadline, is a rebuild.
    func testTwoMissesWithNothingInFlightRebuilds() async throws {
        let probe = ScriptedProbe([.unresponsive, .unresponsive])
        let transport = RecordingTransport()
        let (manager, connection) = try await makeManager(probe: probe, uploads: 0, transport: transport)

        let report = await manager.checkHealth()

        XCTAssertEqual(transport.unmounts.count, 1, "the rebuild must be attempted")
        XCTAssertTrue(report.failed[connection.id]?.contains("would not come down") == true,
                      "and, with this transport, fail honestly: \(report.failed)")
        XCTAssertNil(report.slow[connection.id])
    }

    /// An upload in progress is proof the VFS is alive, and a rebuild would
    /// cancel it — the 09:03 `Put vault.kdbx: context canceled` in the log that
    /// prompted this. Never, however many probes miss.
    func testUploadsInFlightForbidARebuild() async throws {
        let probe = ScriptedProbe([.unresponsive, .unresponsive, .unresponsive])
        let transport = RecordingTransport()
        let (manager, connection) = try await makeManager(probe: probe, uploads: 1, transport: transport)

        let report = await manager.checkHealth()

        XCTAssertEqual(transport.unmounts, [], "never rebuild under an upload")
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        XCTAssertTrue(report.slow[connection.id]?.contains("upload") == true, "\(report.slow)")
        XCTAssertEqual(probe.deadlines.count, 1,
                       "with an upload in flight there is nothing a second probe could change")
    }

    /// When the daemon cannot say whether uploads are in flight, the long second
    /// probe still stands between a miss and a rebuild.
    func testUnknownUploadsStillGetASecondLook() async throws {
        let probe = ScriptedProbe([.unresponsive, .healthy])
        let transport = RecordingTransport()
        let (manager, _) = try await makeManager(probe: probe, uploads: nil, transport: transport)
        _ = await manager.checkHealth()
        XCTAssertEqual(transport.unmounts, [])
        XCTAssertEqual(probe.deadlines.count, 2)
    }

    /// ...but a second miss then does rebuild: a daemon that answers nothing
    /// about its uploads and a path that answers nothing twice is the case
    /// repair exists for.
    func testUnknownUploadsAndTwoMissesRebuild() async throws {
        let probe = ScriptedProbe([.unresponsive, .unresponsive])
        let transport = RecordingTransport()
        let (manager, _) = try await makeManager(probe: probe, uploads: nil, transport: transport)
        _ = await manager.checkHealth()
        XCTAssertEqual(transport.unmounts.count, 1)
    }

    /// Gone from the mount table is not slow; it is rebuilt at once, as before.
    func testAMountGoneFromTheTableIsRebuiltWithoutWaiting() async throws {
        let probe = ScriptedProbe([.gone])
        let transport = RecordingTransport()
        let (manager, _) = try await makeManager(probe: probe, uploads: 0, transport: transport)
        _ = await manager.checkHealth()
        XCTAssertEqual(transport.unmounts.count, 1)
        XCTAssertEqual(probe.deadlines.count, 1, "no confirmation probe for a mount that is not there")
    }

    /// The daemon-exit handler knows the server is gone. Making every mount sit
    /// through a 45 s confirmation there would leave the volumes dead for most
    /// of a minute each, serially. Codex caught this on review.
    func testAKnownDaemonExitSkipsTheConfirmation() async throws {
        let probe = ScriptedProbe([.unresponsive])
        let transport = RecordingTransport()
        let (manager, _) = try await makeManager(probe: probe, uploads: nil, transport: transport)

        _ = await manager.checkHealth(confirm: false)

        XCTAssertEqual(transport.unmounts.count, 1, "rebuilt on the first miss")
        XCTAssertEqual(probe.deadlines, [ConnectionManager.probeDeadline], "no second probe")
    }

    /// An upload in flight still forbids the rebuild even without confirmation:
    /// a daemon that answers about its uploads is not a daemon that exited.
    func testUploadsInFlightForbidARebuildEvenWithoutConfirmation() async throws {
        let probe = ScriptedProbe([.unresponsive])
        let transport = RecordingTransport()
        let (manager, _) = try await makeManager(probe: probe, uploads: 2, transport: transport)
        _ = await manager.checkHealth(confirm: false)
        XCTAssertEqual(transport.unmounts, [])
    }

    /// After a slow report the next quiet report is delivered, so the menu can
    /// stop saying "responding slowly"; the quiet ones after that are not.
    func testPeriodicCheckDeliversTheAllClearOnceAfterANoisyReport() async throws {
        let probe = ScriptedProbe([.unresponsive, .healthy, .healthy, .healthy, .healthy, .healthy])
        let transport = RecordingTransport()
        let (manager, _) = try await makeManager(probe: probe, uploads: 0, transport: transport)

        final class Delivered: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var reports: [ConnectionManager.HealthReport] = []
            func add(_ r: ConnectionManager.HealthReport) { lock.lock(); reports.append(r); lock.unlock() }
        }
        let delivered = Delivered()
        await manager.startPeriodicHealthChecks(every: 0.05) { delivered.add($0) }
        // Five checks' worth of time, plus slack for the scheduler.
        try await Task.sleep(nanoseconds: 600_000_000)
        await manager.stopPeriodicHealthChecks()

        XCTAssertGreaterThanOrEqual(probe.deadlines.count, 4, "several checks ran: \(probe.deadlines)")
        XCTAssertEqual(delivered.reports.count, 2, "the slow report and one all-clear, nothing more")
        XCTAssertFalse(delivered.reports.first?.slow.isEmpty ?? true)
        XCTAssertTrue(delivered.reports.last?.slow.isEmpty ?? false)
        XCTAssertFalse(delivered.reports.last?.healthy.isEmpty ?? true)
    }

    /// The timer is a backstop for a wedged server, not a heartbeat. Ninety
    /// seconds found a slow moment on a remote backend regularly; five minutes
    /// is the floor.
    func testPeriodicIntervalIsAtLeastFiveMinutes() {
        XCTAssertGreaterThanOrEqual(ConnectionManager.periodicHealthCheckInterval, 300)
    }
}
