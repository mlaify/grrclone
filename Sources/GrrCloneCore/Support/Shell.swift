import Foundation
import RcloneRC

/// Runs short-lived helper processes (`/sbin/mount`, `diskutil`) with a real timeout.
///
/// The timeout is not defensive dressing. `mount` and `diskutil` can block for a long
/// time against a wedged NFS mount, and a call that never returns on the main actor is
/// exactly the beachball this project exists to avoid. Everything here is `async` and
/// must stay off the main actor.
///
/// See `Deadline` for why the timeout is built on Dispatch rather than a task group.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { status == 0 }
    }

    public enum Failure: Error, LocalizedError {
        case timedOut(command: String, seconds: TimeInterval)
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .timedOut(let command, let seconds):
                return "\(command) did not finish within \(Int(seconds))s."
            case .launchFailed(let detail):
                return "Could not run helper process: \(detail)"
            }
        }
    }

    /// Extra time allowed for draining stdout and stderr after the process itself has
    /// hit its timeout. A call that times out therefore returns after roughly
    /// `timeout + pipeDrainSlack`, which callers budgeting a deadline must account for.
    public static let pipeDrainSlack: TimeInterval = 5

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 30) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Exit is observed through a handler installed *before* `run()`, signalling a
        // semaphore. Not `waitUntilExit()`: called from the Dispatch thread `Deadline`
        // runs work on, it intermittently never returned — a two-millisecond `rclone
        // obscure` hitting a ten-second timeout, `ps` timing out under #95, config
        // encryption hitting sixty seconds — none reproducible in isolation, all the
        // signature of a run loop spun on a worker thread. A handler set before launch
        // cannot miss an exit, and a semaphore has no run loop to be starved of.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do { try process.run() }
        catch { throw Failure.launchFailed(error.localizedDescription) }

        // Drain on their own threads. A process that fills a 64 KiB pipe buffer while we
        // wait for it to exit would otherwise deadlock: it blocks writing, we block
        // waiting, neither moves.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Deadline.run(seconds: timeout + pipeDrainSlack) {
            (try? outHandle.readToEnd()) ?? Data()
        }
        async let errData = Deadline.run(seconds: timeout + pipeDrainSlack) {
            (try? errHandle.readToEnd()) ?? Data()
        }

        let finished = await Deadline.run(seconds: timeout) {
            // Blocks a Dispatch thread, which is abandonable, and returns the moment the
            // handler above fires.
            exited.wait(timeout: .now() + timeout) == .success
        } ?? false

        guard finished else {
            process.terminate()
            // SIGTERM can be ignored by a process blocked in an uninterruptible syscall,
            // which is precisely the case a timeout implies.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw Failure.timedOut(command: "\(executable) \(arguments.joined(separator: " "))",
                                   seconds: timeout)
        }

        return Result(status: process.terminationStatus,
                      stdout: String(data: await outData ?? Data(), encoding: .utf8) ?? "",
                      stderr: String(data: await errData ?? Data(), encoding: .utf8) ?? "")
    }
}
