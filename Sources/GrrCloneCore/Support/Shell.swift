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

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 30) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() }
        catch { throw Failure.launchFailed(error.localizedDescription) }

        // Drain on their own threads. A process that fills a 64 KiB pipe buffer while we
        // wait for it to exit would otherwise deadlock: it blocks writing, we block
        // waiting, neither moves.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Deadline.run(seconds: timeout + 5) {
            (try? outHandle.readToEnd()) ?? Data()
        }
        async let errData = Deadline.run(seconds: timeout + 5) {
            (try? errHandle.readToEnd()) ?? Data()
        }

        let exited = await Deadline.run(seconds: timeout) {
            // Blocks a Dispatch thread, which is abandonable. `terminationHandler` is
            // deliberately not used: if the process has already exited by the time it is
            // installed, it may never fire, leaving the caller suspended forever.
            process.waitUntilExit()
            return true
        } ?? false

        guard exited else {
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
