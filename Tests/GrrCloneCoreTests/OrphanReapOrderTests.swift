import XCTest
@testable import GrrCloneCore

/// The order in which a leftover daemon is dealt with at startup.
///
/// An orphaned `rclone rcd` from an unclean shutdown is still serving live NFS mounts.
/// Killing it before those mounts come down leaves the kernel talking to a dead server
/// — the exact state `DaemonSupervisor.stop()` and `ConnectionManager.shutdown()` are
/// both written to avoid. `soft,intr` turns that into I/O errors rather than a
/// permanent wedge, which is why the inversion survived a release unnoticed.
///
/// These tests assert the *ordering*, not the end state. An end-state assertion — the
/// orphan is dead, the mounts are down — passes just as happily with the steps in the
/// wrong order, which is precisely how this was missed.
final class OrphanReapOrderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        // Short by necessity, not by taste. A unix socket path is capped at 104 bytes
        // on Darwin, and NSTemporaryDirectory() alone is ~50 of them — a UUID-named
        // subdirectory under it puts `rc.sock` over the limit and rclone fails with
        // "bind: invalid argument", which reads like a permissions problem.
        dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("grr" + String(UInt32.random(in: 0..<0xFFFFFF), radix: 16))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertLessThan(dir.appendingPathComponent("rc.sock").path.utf8.count, 104,
                          "test socket path must fit Darwin's limit")
    }

    override func tearDownWithError() throws {
        for pid in spawned where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        spawned = []
        try? FileManager.default.removeItem(at: dir)
    }

    private var spawned: [Int32] = []

    /// A stand-in for a leftover daemon.
    ///
    /// `DaemonPidFile.isOurDaemon` proves identity from `ps` output: the command line
    /// must contain "rclone" *and* the recorded socket path. So the stand-in has to be
    /// named `rclone` and carry the socket path as an argument — anything less would
    /// test a code path the real thing never takes.
    private func spawnFakeOrphan(socketPath: String) throws -> Int32 {
        let fake = dir.appendingPathComponent("rclone")
        try "#!/bin/sh\nsleep 300\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fake.path)

        let process = Process()
        process.executableURL = fake
        process.arguments = ["rcd", "--rc-addr", "unix://\(socketPath)"]
        try process.run()
        spawned.append(process.processIdentifier)
        return process.processIdentifier
    }

    // MARK: - The window exists

    /// `reapableOrphan()` must identify the daemon and leave it running, so a caller
    /// has somewhere to unmount. If it killed on identification there would be no
    /// ordering to get right.
    func testIdentifyingAnOrphanDoesNotKillIt() async throws {
        let socket = dir.appendingPathComponent("rc.sock").path
        let pid = try spawnFakeOrphan(socketPath: socket)
        let pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir))
        try pidFile.write(pid: pid, socketPath: socket)

        let record = await pidFile.reapableOrphan()

        XCTAssertEqual(record?.pid, pid, "the orphan should be identified as ours")
        XCTAssertEqual(kill(pid, 0), 0, "identifying an orphan must not kill it")

        await pidFile.reap(record!)
        XCTAssertNotEqual(kill(pid, 0), 0, "reap() should have terminated it")
    }

    /// A record whose PID is no longer ours must be cleared and must not be actionable.
    /// PIDs are reused; killing on a bare PID match would eventually kill a stranger.
    func testStaleRecordIsNotReapable() async throws {
        let socket = dir.appendingPathComponent("rc.sock").path
        let pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir))
        // PID 1 is launchd: alive, but not an rclone naming our socket.
        try pidFile.write(pid: 1, socketPath: socket)

        let record = await pidFile.reapableOrphan()

        XCTAssertNil(record, "launchd is not our daemon and must never be reapable")
        XCTAssertNil(pidFile.read(), "a stale record should be cleared")
    }

    // MARK: - The supervisor gets the order right

    /// The decisive test: when the supervisor finds an orphan, the cleanup hook must
    /// run *while the orphan is still alive*.
    ///
    /// The hook records whether the orphan was still running at the moment it was
    /// called. That single boolean is the whole assertion — it is false if the kill
    /// moves back above the unmount, and no end-state check would notice.
    func testCleanupRunsBeforeTheOrphanIsKilled() async throws {
        let rclone = try requireRclone()
        let socket = dir.appendingPathComponent("rc.sock").path
        let orphanPID = try spawnFakeOrphan(socketPath: socket)

        let pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir))
        try pidFile.write(pid: orphanPID, socketPath: socket)

        let observed = OrphanObserver()
        let supervisor = DaemonSupervisor(
            binary: rclone,
            settings: DaemonSettings(cacheDirectory: dir.appendingPathComponent("cache")),
            runtimeDirectory: dir)
        await supervisor.setOrphanCleanup {
            await observed.record(orphanAlive: kill(orphanPID, 0) == 0)
            return .init(unmounted: ["/fake/mountpoint"])
        }

        _ = try await supervisor.start()
        defer { Task { await supervisor.stop() } }

        let ran = await observed.ran
        let aliveWhenCalled = await observed.orphanWasAlive
        XCTAssertTrue(ran, "the cleanup hook must run when an orphan is found")
        XCTAssertTrue(aliveWhenCalled,
                      "mounts must be brought down while the orphan is still serving them")
        XCTAssertNotEqual(kill(orphanPID, 0), 0, "the orphan should be gone afterwards")

        let unmounted = await supervisor.orphanMountsUnmounted
        XCTAssertEqual(unmounted, ["/fake/mountpoint"],
                       "what the cleanup brought down should be reported")
    }

    /// No orphan, no hook. An ordinary launch must not pay for this.
    func testCleanupDoesNotRunWithoutAnOrphan() async throws {
        let rclone = try requireRclone()
        let observed = OrphanObserver()
        let supervisor = DaemonSupervisor(
            binary: rclone,
            settings: DaemonSettings(cacheDirectory: dir.appendingPathComponent("cache")),
            runtimeDirectory: dir)
        await supervisor.setOrphanCleanup {
            await observed.record(orphanAlive: false)
            return .nothingToDo
        }

        _ = try await supervisor.start()
        defer { Task { await supervisor.stop() } }

        let ran = await observed.ran
        XCTAssertFalse(ran, "nothing to reap means nothing to unmount")
    }

    // MARK: - Reaping is conditional (Codex, P1)

    /// If the cleanup could not bring a mount down, the daemon must be left alive.
    ///
    /// The first version of this fix returned only the list of paths successfully
    /// unmounted, so a `diskutil` failure was indistinguishable from "nothing to do"
    /// and the orphan was killed regardless — straight back into the dead-server state
    /// the whole ordering exists to prevent.
    func testOrphanSurvivesWhenCleanupCannotUnmount() async throws {
        let rclone = try requireRclone()
        let socket = dir.appendingPathComponent("rc.sock").path
        let orphanPID = try spawnFakeOrphan(socketPath: socket)

        let pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir))
        try pidFile.write(pid: orphanPID, socketPath: socket)

        let supervisor = DaemonSupervisor(
            binary: rclone,
            settings: DaemonSettings(cacheDirectory: dir.appendingPathComponent("cache")),
            runtimeDirectory: dir)
        await supervisor.setOrphanCleanup {
            .init(unmounted: [], stillMounted: ["/Users/x/grrclone/dav1"])
        }

        do {
            _ = try await supervisor.start()
            XCTFail("start() should refuse while an owned mount is still live")
        } catch let error as DaemonSupervisor.Failure {
            guard case .orphanMountsStillLive(let paths) = error else {
                return XCTFail("expected orphanMountsStillLive, got \(error)")
            }
            XCTAssertEqual(paths, ["/Users/x/grrclone/dav1"])
        }

        XCTAssertEqual(kill(orphanPID, 0), 0,
                       "the orphan must stay alive while it still has mounts to serve")
    }

    /// A cleanup that threw, or could not read the registry, reports everything as
    /// possibly-still-mounted. That must block the kill too.
    func testOrphanSurvivesWhenCleanupOutcomeIsUnknown() async throws {
        let rclone = try requireRclone()
        let socket = dir.appendingPathComponent("rc.sock").path
        let orphanPID = try spawnFakeOrphan(socketPath: socket)

        let pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir))
        try pidFile.write(pid: orphanPID, socketPath: socket)

        let supervisor = DaemonSupervisor(
            binary: rclone,
            settings: DaemonSettings(cacheDirectory: dir.appendingPathComponent("cache")),
            runtimeDirectory: dir)
        await supervisor.setOrphanCleanup { .init(stillMounted: ["<unknown>"]) }

        _ = try? await supervisor.start()
        XCTAssertEqual(kill(orphanPID, 0), 0,
                       "an unknown cleanup result must not authorise the kill")
    }

    /// Splitting identify-then-kill so an unmount can run in between opened a PID
    /// reuse window that did not exist before. `reap()` must revalidate.
    func testReapRevalidatesBeforeSignalling() async throws {
        let socket = dir.appendingPathComponent("rc.sock").path
        let pid = try spawnFakeOrphan(socketPath: socket)
        let pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir))
        try pidFile.write(pid: pid, socketPath: socket)

        let found = await pidFile.reapableOrphan()
        let record = try XCTUnwrap(found)

        // Stand in for "the orphan exited during a slow unmount and something else
        // inherited its PID": kill it ourselves, then hand the stale record back.
        kill(pid, SIGKILL)
        var waited = 0
        while kill(pid, 0) == 0 && waited < 50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }

        let reaped = await pidFile.reap(record)
        XCTAssertNil(reaped, "a PID that is no longer our daemon must not be signalled")
    }

    // MARK: - Helpers

    private actor OrphanObserver {
        private(set) var ran = false
        private(set) var orphanWasAlive = false
        func record(orphanAlive: Bool) {
            ran = true
            orphanWasAlive = orphanAlive
        }
    }

    private func requireRclone() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/grrclone/Resources/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("no rclone binary found; run scripts/fetch-rclone.sh to exercise these")
        }
        return found
    }
}
