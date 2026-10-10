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

    // MARK: - No secret on the command line (#156)

    private func commandLine(of pid: Int32) async throws -> String {
        ProcessArguments.commandLine(pid: pid) ?? ""
    }

    /// Every local account can read a process's arguments on macOS. The daemon's
    /// must carry a path to the credential, never the credential.
    func testTheDaemonsArgumentsCarryNoCredential() async throws {
        let (supervisor, pid) = try await startedSupervisor()
        let args = try await commandLine(of: pid)
        XCTAssertFalse(args.isEmpty, "could not read the daemon's arguments, so this proves nothing")
        XCTAssertFalse(args.contains("--rc-pass"), "password on the command line: \(args)")
        XCTAssertFalse(args.contains("--rc-user"), "user on the command line: \(args)")
        XCTAssertTrue(args.contains("--rc-htpasswd"), args)

        let file = dir.appendingPathComponent(RcAuthFile.fileName)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the credential file must be this user's alone")
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(contents.contains(":{SHA}"), "a hash, not the password")

        // And the daemon actually authenticates with it.
        let version = try await supervisor.requireClient().version()
        XCTAssertTrue(version.meetsMinimum)

        await supervisor.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "stop() must remove the credential file")
    }

    /// A daemon that dies takes its credential file with it too.
    func testAnUnexpectedExitRemovesTheCredentialFile() async throws {
        let (supervisor, pid) = try await startedSupervisor()
        let fired = Flag()
        await supervisor.setOnUnexpectedExit { fired.set($0) }
        let file = dir.appendingPathComponent(RcAuthFile.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        kill(pid, SIGKILL)
        _ = await wait(for: fired, seconds: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// A link planted at the path is replaced, never written through.
    func testTheCredentialFileIsNotWrittenThroughASymlink() throws {
        let target = dir.appendingPathComponent("elsewhere")
        let path = dir.appendingPathComponent(RcAuthFile.fileName)
        try "untouched".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)

        try RcAuthFile.write(user: "u", password: "p", to: path)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
        let type = try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
    }

    /// A daemon that never opens its socket must not leave the credential file
    /// behind. The socket wait times out after the supervisor has let go of the
    /// process, so neither the exit handler nor the partial-start cleanup removes
    /// it; Codex found that on review. An immediate exit does not test this — the
    /// exit handler catches that one — so the stand-in stays alive past the wait.
    /// Takes the ten-second startup timeout.
    func testAStartThatNeverOpensItsSocketRemovesTheCredentialFile() async throws {
        let fake = dir.appendingPathComponent("rclone-that-hangs")
        try "#!/bin/sh\nexec sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let supervisor = DaemonSupervisor(
            binary: fake, settings: DaemonSettings(cacheDirectory: dir.appendingPathComponent("cache")),
            runtimeDirectory: dir)
        supervisors.append(supervisor)

        do {
            _ = try await supervisor.start()
            XCTFail("a daemon without a socket cannot have started")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(RcAuthFile.fileName).path),
                       "a failed start left the credential file behind")
    }

    func testTheLineIsAnHtpasswdSHA1Entry() {
        // SHA-1("abc") = a9993e36...; base64 of that digest is qZk+NkcGgWq6PiVxeFDCbJzQ2J0=
        XCTAssertEqual(RcAuthFile.line(user: "u", password: "abc"), "u:{SHA}qZk+NkcGgWq6PiVxeFDCbJzQ2J0=\n")
    }
}
