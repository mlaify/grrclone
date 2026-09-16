import XCTest
import RcloneRC
@testable import GrrCloneCore

/// Tests for the "is it safe to quit?" logic.
///
/// This exists because `--vfs-cache-mode full` makes a write return as soon as the bytes
/// reach local disk. Finder shows the file as saved while nothing has reached the storage
/// provider, so quitting at that moment strands the only copy in a cache the user does
/// not know exists.
final class ActivityTests: XCTestCase {

    private func stats(queued: Int = 0, inProgress: Int = 0, errored: Int = 0,
                       bytes: Int = 0, files: Int = 0,
                       outOfSpace: Bool = false) -> RcloneRCClient.VFSStats {
        .init(uploadsQueued: queued, uploadsInProgress: inProgress, erroredFiles: errored,
              bytesUsed: bytes, cachedFiles: files, outOfSpace: outOfSpace)
    }

    /// A file being uploaded right now is still unsafe to quit on. Counting only the
    /// queue would report zero while bytes are in flight — which is exactly why the
    /// implementation reads `vfs/stats` rather than `vfs/queue`.
    func testPendingCountsBothQueuedAndInFlight() {
        XCTAssertEqual(stats(queued: 3, inProgress: 2).pendingUploads, 5)
        XCTAssertTrue(stats(queued: 0, inProgress: 1).hasUnfinishedWork,
                      "an upload in flight is not finished")
        XCTAssertTrue(stats(queued: 1, inProgress: 0).hasUnfinishedWork)
        XCTAssertFalse(stats().hasUnfinishedWork)
    }

    func testActivitySumsAcrossConnections() {
        let a = UUID(), b = UUID()
        let activity = ConnectionManager.Activity(perConnection: [
            a: stats(queued: 2, inProgress: 1, errored: 1),
            b: stats(queued: 0, inProgress: 3, errored: 2),
        ])
        XCTAssertEqual(activity.pendingUploads, 6)
        XCTAssertEqual(activity.erroredFiles, 3)
        XCTAssertFalse(activity.isIdle)
    }

    func testIdleWhenNothingPending() {
        let activity = ConnectionManager.Activity(perConnection: [
            UUID(): stats(errored: 0, bytes: 90_165, files: 28),
        ])
        XCTAssertTrue(activity.isIdle, "cached files that are already uploaded are not pending")
        XCTAssertEqual(activity.pendingUploads, 0)
    }

    func testEmptyActivityIsIdle() {
        let activity = ConnectionManager.Activity()
        XCTAssertTrue(activity.isIdle)
        XCTAssertEqual(activity.pendingUploads, 0)
        XCTAssertFalse(activity.outOfSpace)
    }

    /// One full cache is a problem even if the others are fine: writes to that connection
    /// will start failing.
    func testOutOfSpaceOnAnyConnectionIsReported() {
        let activity = ConnectionManager.Activity(perConnection: [
            UUID(): stats(),
            UUID(): stats(outOfSpace: true),
        ])
        XCTAssertTrue(activity.outOfSpace)
    }
}

/// Decoding of the `vfs/stats` response, against the real shape rclone 1.75.1 returns.
final class VFSStatsDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// Captured verbatim from a live daemon.
    func testReadsTheFieldsRcloneActuallyReturns() throws {
        let value = try decode("""
        {"diskCache":{"bytesUsed":118843,"erroredFiles":0,"files":28,"hashType":0,
        "outOfSpace":false,"path":"/tmp/vfs","pathMeta":"/tmp/vfsMeta",
        "uploadsInProgress":1,"uploadsQueued":2},"inUse":1}
        """)
        let cache = value["diskCache"]
        XCTAssertEqual(cache?["uploadsQueued"]?.intValue, 2)
        XCTAssertEqual(cache?["uploadsInProgress"]?.intValue, 1)
        XCTAssertEqual(cache?["erroredFiles"]?.intValue, 0)
        XCTAssertEqual(cache?["bytesUsed"]?.intValue, 118_843)
        XCTAssertEqual(cache?["outOfSpace"]?.boolValue, false)
    }

    /// A connection with caching off has no `diskCache` at all. Reading it must report
    /// "nothing pending" rather than failing, or quitting would be blocked forever.
    func testMissingDiskCacheReadsAsNothingPending() throws {
        let value = try decode("{\"inUse\":1}")
        XCTAssertNil(value["diskCache"])
        XCTAssertNil(value["diskCache"]?["uploadsQueued"]?.intValue)
    }
}
