import Foundation

/// Runs work that cannot be cancelled, and stops waiting for it after a deadline.
///
/// This exists because the obvious Swift Concurrency approach is wrong in a way that is
/// easy to miss. A task group used as a timeout —
///
/// ```swift
/// try await withThrowingTaskGroup(of: T.self) { group in
///     group.addTask { try await work() }          // may block forever
///     group.addTask { try await sleep(); throw Timeout() }
///     let first = try await group.next()!
///     group.cancelAll()                           // does NOT unblock the first task
///     return first
/// }
/// ```
///
/// — **does not time out**. A task group will not return until every child task has
/// finished, and `cancelAll()` cannot resume a task suspended on a callback that will
/// never fire, or one blocked in an uninterruptible syscall. The timeout fires, and then
/// the group hangs anyway. That was observed here: a probe with a 5-second deadline hung
/// indefinitely against a dead NFS mount.
///
/// grrclone deals in exactly the operations this breaks on — `stat` against a wedged NFS
/// mount, `mount`, `diskutil`, a socket whose listener has died — so the timeout has to
/// be real.
///
/// The approach below runs the blocking work on a Dispatch thread, which is genuinely
/// abandonable: on timeout the caller stops waiting, and the thread finishes on its own
/// and its result is discarded. Nothing structured is waiting on it.
public enum Deadline {

    /// Run `work` on a background thread, returning `nil` if it does not finish in time.
    ///
    /// The abandoned thread is not killed. It cannot be — that is the whole problem — so
    /// it is left to unblock whenever the kernel lets it, by which point nobody cares.
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        qos: DispatchQoS.QoSClass = .userInitiated,
        work: @escaping @Sendable () -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = OneShot()

            DispatchQueue.global(qos: qos).async {
                let value = work()
                if gate.claim() { continuation.resume(returning: value) }
            }

            DispatchQueue.global(qos: qos).asyncAfter(deadline: .now() + seconds) {
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Throwing variant, for call sites where a timeout is an error rather than a `nil`.
    public static func run<T: Sendable>(
        seconds: TimeInterval,
        qos: DispatchQoS.QoSClass = .userInitiated,
        timeoutError: @autoclosure @Sendable () -> Error,
        work: @escaping @Sendable () -> T
    ) async throws -> T {
        guard let value = await run(seconds: seconds, qos: qos, work: work) else {
            throw timeoutError()
        }
        return value
    }
}

/// Ensures a continuation is resumed exactly once when several callbacks race for it.
/// Resuming a continuation twice is undefined behaviour and usually a crash.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
