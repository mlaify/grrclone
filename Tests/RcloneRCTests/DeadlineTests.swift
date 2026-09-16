import XCTest
@testable import RcloneRC

/// Regression tests for the timeout primitive.
///
/// The bug these exist to prevent: a task-group timeout does not time out. A task group
/// waits for every child to finish, and `cancelAll()` cannot resume a task blocked in an
/// uninterruptible syscall or suspended on a callback that never fires. The timeout fires
/// and the group hangs anyway. In this project that made a 5-second mount probe hang
/// indefinitely against the dead mount it was written to detect.
///
/// Each test has an XCTest timeout well under the blocking work's duration, so a
/// regression fails the suite instead of hanging it.
final class DeadlineTests: XCTestCase {

    func testReturnsValueWhenWorkFinishesInTime() async {
        let result = await Deadline.run(seconds: 5) { 42 }
        XCTAssertEqual(result, 42)
    }

    /// The load-bearing test. The work blocks a thread for 10 seconds and cannot be
    /// cancelled; the call must still return after roughly 1.
    func testAbandonsWorkThatBlocksPastTheDeadline() async {
        let started = Date()
        let result: Int? = await Deadline.run(seconds: 1) {
            Thread.sleep(forTimeInterval: 10)   // stands in for a wedged NFS call
            return 99
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result, "blocked work must be abandoned, not awaited")
        XCTAssertLessThan(elapsed, 5, "returned after \(elapsed)s; the deadline was 1s")
    }

    /// The abandoned thread finishes eventually and tries to deliver its result. Resuming
    /// an already-resumed continuation is undefined behaviour and usually crashes, so the
    /// late arrival must be dropped silently.
    func testLateResultFromAbandonedWorkIsDiscarded() async {
        _ = await Deadline.run(seconds: 0.2) {
            Thread.sleep(forTimeInterval: 1)
            return "late"
        }
        // Outlive the abandoned thread. A double resume would crash the test process.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    func testThrowingVariantThrowsOnTimeout() async {
        struct Expected: Error {}
        do {
            _ = try await Deadline.run(seconds: 0.5, timeoutError: Expected()) {
                Thread.sleep(forTimeInterval: 5)
                return 1
            }
            XCTFail("expected a timeout")
        } catch is Expected {
            // correct
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testThrowingVariantReturnsValueWhenFastEnough() async throws {
        struct Unexpected: Error {}
        let value = try await Deadline.run(seconds: 5, timeoutError: Unexpected()) { "ok" }
        XCTAssertEqual(value, "ok")
    }

    func testConcurrentDeadlinesDoNotInterfere() async {
        async let fast = Deadline.run(seconds: 5) { "fast" }
        async let slow: String? = Deadline.run(seconds: 0.3) {
            Thread.sleep(forTimeInterval: 3)
            return "slow"
        }
        let results = await (fast, slow)
        XCTAssertEqual(results.0, "fast")
        XCTAssertNil(results.1)
    }
}

final class OneShotTests: XCTestCase {

    func testOnlyTheFirstClaimSucceeds() {
        let gate = OneShot()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    /// Exactly one of many racing threads may resume a continuation.
    func testExactlyOneClaimWinsUnderContention() {
        let gate = OneShot()
        let winners = NSMutableArray()
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if gate.claim() {
                lock.lock(); winners.add(1); lock.unlock()
            }
        }
        XCTAssertEqual(winners.count, 1)
    }
}
