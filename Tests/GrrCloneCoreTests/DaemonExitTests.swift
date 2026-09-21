import XCTest
@testable import GrrCloneCore

/// A daemon that dies is noticed at once (#119), and one that is stopped on
/// purpose is not mistaken for one that died.
///
/// Real `rclone rcd`, as the orphan tests use, because the thing under test is
/// Foundation's termination handler on the real process. Skipped when no rclone
/// is available.
final class DaemonExitTests: XCTestCase {

    private var dir: URL!
    private var supervisors: [DaemonSupervisor] = []

    override func setUpWithError() throws {
        // Short: a unix socket path is capped at 104 bytes.
        dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("grx" + String(UInt32.random(in: 0..<0xFFFFFF), radix: 16))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for supervisor in supervisors { await supervisor.stop() }
        supervisors = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func requireRclone() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/grrclone/Resources/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("no rclone binary found; run scripts/fetch-rclone.sh to exercise these")
        }
        return found
    }

    private func startedSupervisor() async throws -> (DaemonSupervisor, Int32) {
        let supervisor = DaemonSupervisor(
            binary: try requireRclone(),
            settings: DaemonSettings(cacheDirectory: dir.appendingPathComponent("cache")),
            runtimeDirectory: dir)
        supervisors.append(supervisor)
        _ = try await supervisor.start()
        let pidFile = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir))
        let pid = try XCTUnwrap(pidFile.read()?.pid, "a started supervisor records its daemon")
        return (supervisor, pid)
    }

    /// Wait for a flag set from another task, bounded.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        func set(_ pid: Int32) { lock.lock(); value = pid; lock.unlock() }
        func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func wait(for flag: Flag, seconds: TimeInterval) async -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let v = flag.get() { return v }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return flag.get()
    }

    /// SIGKILL the daemon as a crash would, and the handler fires with its pid,
    /// promptly — not on the next wake.
    func testAKilledDaemonIsReportedAtOnce() async throws {
        let (supervisor, pid) = try await startedSupervisor()
        let fired = Flag()
        await supervisor.setOnUnexpectedExit { fired.set($0) }

        kill(pid, SIGKILL)

        let reported = await wait(for: fired, seconds: 5)
        XCTAssertEqual(reported, pid, "the exit handler must fire, with the daemon's pid")
        let running = await supervisor.isRunning
        XCTAssertFalse(running)
        let record = DaemonPidFile(url: DaemonPidFile.defaultURL(runtimeDirectory: dir)).read()
        XCTAssertNil(record, "a dead daemon's record must be cleared, or the next start refuses on it")
    }

    /// A deliberate stop is not a crash. Firing the repair here would start a new
    /// daemon during shutdown, which is the one thing shutdown exists to prevent.
    func testAnOrderedStopDoesNotFireTheHandler() async throws {
        let (supervisor, _) = try await startedSupervisor()
        let fired = Flag()
        await supervisor.setOnUnexpectedExit { fired.set($0) }

        await supervisor.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertNil(fired.get(), "stop() must not be reported as an unexpected exit")
    }
}
