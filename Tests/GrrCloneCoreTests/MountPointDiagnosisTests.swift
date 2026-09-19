import XCTest
@testable import GrrCloneCore

/// Three things surfaced by one screenshot: a path mounted three times over, an
/// error that blamed files for it, and a new copy of the app that would have
/// refused to start while the old one was still tidying up.
final class MountPointDiagnosisTests: XCTestCase {

    // MARK: - Why a mount point is unusable (#103)

    /// The existing message, which is correct when the cause really is local files.
    func testLocalFilesAreReportedAsFiles() {
        let why = NFSTransport.whyUnusable(path: "/Users/x/Cloud", itemCount: 12, existingMounts: 0)
        XCTAssertTrue(why.contains("12 existing item(s)"), why)
        XCTAssertFalse(why.contains("mounted"), "nothing is mounted, so do not say so")
    }

    /// The observed case. 582 "items" were another volume's contents, and telling
    /// the user to move them sent them after files that did not exist.
    func testAStackedMountIsReportedAsAMountNotAsFiles() {
        let why = NFSTransport.whyUnusable(path: "/Users/x/Cloud", itemCount: 582, existingMounts: 3)
        XCTAssertTrue(why.contains("3 volumes are stacked"), why)
        XCTAssertTrue(why.contains("diskutil umount force /Users/x/Cloud"), why)
        XCTAssertFalse(why.contains("582"),
                       "the file count is misleading here and must not be shown")
    }

    func testASingleForeignMountReadsNaturally() {
        let why = NFSTransport.whyUnusable(path: "/Users/x/Cloud", itemCount: 40, existingMounts: 1)
        XCTAssertTrue(why.contains("Something is already mounted at /Users/x/Cloud"), why)
        XCTAssertTrue(why.contains("Disconnect it first"), why)
        XCTAssertFalse(why.contains("once per mount"), "one mount, one command")
    }

    // MARK: - Collapsing repeated foreign mounts

    /// Three equal strings as `ForEach` identities is undefined behaviour, and three
    /// identical rows reads as a bug. One row with a count is both.
    func testRepeatedPathsCollapseToOneWithACount() {
        let grouped = ForeignMount.group(["/Users/x/Cloud", "/Users/x/Cloud", "/Users/x/Cloud"])
        XCTAssertEqual(grouped, [ForeignMount(path: "/Users/x/Cloud", count: 3)])
    }

    func testDistinctPathsStayDistinctAndOrdered() {
        let grouped = ForeignMount.group(["/a", "/b", "/a", "/c"])
        XCTAssertEqual(grouped.map(\.path), ["/a", "/b", "/c"], "first-seen order, stable between refreshes")
        XCTAssertEqual(grouped.map(\.count), [2, 1, 1])
    }

    func testIdsAreUnique() {
        let grouped = ForeignMount.group(["/a", "/a", "/b"])
        XCTAssertEqual(Set(grouped.map(\.id)).count, grouped.count)
    }

    // MARK: - Waiting for a previous instance (#102)

    /// An instance that has exited is not something to wait for.
    func testATerminatedInstanceEndsTheWaitImmediately() {
        XCTAssertFalse(InstanceWait.shouldKeepWaiting(isTerminated: true, elapsed: 0))
        XCTAssertEqual(InstanceWait.outcome(isTerminated: true), .clear)
    }

    /// The case this exists for: the old copy is mid-teardown. Keep waiting.
    func testALiveInstanceIsWaitedFor() {
        XCTAssertTrue(InstanceWait.shouldKeepWaiting(isTerminated: false, elapsed: 5))
        XCTAssertTrue(InstanceWait.shouldKeepWaiting(isTerminated: false, elapsed: 120),
                      "a two-minute upload drain is a normal teardown, not a hang")
    }

    /// Bounded. A wedged instance must not wedge the launch too, and at the end the
    /// answer has to be refusal — two instances corrupt each other's registry.
    func testTheWaitIsBoundedAndThenRefuses() {
        XCTAssertFalse(InstanceWait.shouldKeepWaiting(isTerminated: false,
                                                      elapsed: InstanceWait.deadline))
        XCTAssertEqual(InstanceWait.outcome(isTerminated: false), .occupied)
    }

    /// The deadline has to cover a real teardown, or the fix does nothing in the
    /// exact case it was written for.
    func testTheDeadlineCoversAFullUploadDrain() {
        XCTAssertGreaterThanOrEqual(InstanceWait.deadline, 120 + NFSTransport.unmountBudget,
                                    "must outlast the drain plus at least one unmount")
    }
}
