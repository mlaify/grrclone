import Foundation

/// Runs short-lived helper processes (`/sbin/mount`, `diskutil`) with a hard timeout.
///
/// A timeout is mandatory rather than defensive: a `stat` or `mount` touching a wedged
/// NFS mount can block indefinitely in the kernel, and any such call made on the main
/// actor would beachball the app. Everything here is `async` and must stay off the main
/// actor.
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

        // Drain concurrently with waiting. A process that fills a 64 KiB pipe buffer
        // while we wait on exit would otherwise deadlock.
        async let outData = readToEnd(outPipe)
        async let errData = readToEnd(errPipe)

        let exited = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in cont.resume() }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        guard exited else {
            process.terminate()
            // SIGTERM can be ignored by a process blocked in an uninterruptible syscall.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw Failure.timedOut(command: "\(executable) \(arguments.joined(separator: " "))",
                                   seconds: timeout)
        }

        return Result(status: process.terminationStatus,
                      stdout: String(data: await outData, encoding: .utf8) ?? "",
                      stderr: String(data: await errData, encoding: .utf8) ?? "")
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: data)
            }
        }
    }
}
