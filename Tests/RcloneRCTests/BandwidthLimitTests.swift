import XCTest
@testable import RcloneRC

/// Parsed from responses captured from rclone 1.75.1, because the published
/// documentation for this endpoint is wrong in two ways that matter.
final class BandwidthLimitTests: XCTestCase {

    private func parse(_ json: String) throws -> RcloneRCClient.Bandwidth {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try RcloneRCClient.bandwidth(from: value)
    }

    func testUnlimited() throws {
        let b = try parse(#"{"bytesPerSecond":-1,"bytesPerSecondRx":-1,"bytesPerSecondTx":-1,"rate":"off"}"#)
        XCTAssertEqual(b.rate, "off")
        XCTAssertFalse(b.isLimited)
    }

    /// rclone echoes a limit back in IEC units: `1M` comes back as `1Mi`. Anything
    /// comparing what the user typed against what rclone reports must expect that, or
    /// it will see a change that did not happen.
    func testASymmetricLimitIsReportedInIECUnits() throws {
        let b = try parse(#"{"bytesPerSecond":1048576,"bytesPerSecondRx":1048576,"bytesPerSecondTx":1048576,"rate":"1Mi"}"#)
        XCTAssertEqual(b.rate, "1Mi")
        XCTAssertEqual(b.upload, 1_048_576)
        XCTAssertEqual(b.download, 1_048_576)
        XCTAssertTrue(b.isLimited)
    }

    /// The documented example claims an `up:down` pair reports only the upload half as
    /// `rate`. It does not: 1.75.1 returns the whole pair, and the two directions
    /// differ in the byte counts. Reading `bytesPerSecond` alone would silently report
    /// the download limit as equal to the upload one.
    func testAPairKeepsBothDirections() throws {
        let b = try parse(#"{"bytesPerSecond":1048576,"bytesPerSecondRx":102400,"bytesPerSecondTx":1048576,"rate":"1Mi:100Ki"}"#)
        XCTAssertEqual(b.rate, "1Mi:100Ki")
        XCTAssertEqual(b.upload, 1_048_576)
        XCTAssertEqual(b.download, 102_400)
        XCTAssertNotEqual(b.upload, b.download, "the two directions must not be collapsed")
    }

    /// A limit in one direction only still counts as limited.
    func testDownloadOnlyLimitCountsAsLimited() throws {
        let b = try parse(#"{"bytesPerSecond":-1,"bytesPerSecondRx":102400,"bytesPerSecondTx":-1,"rate":"off:100Ki"}"#)
        XCTAssertTrue(b.isLimited)
        XCTAssertEqual(b.download, 102_400)
        XCTAssertEqual(b.upload, -1)
    }

    func testAResponseWithoutARateIsRejected() {
        XCTAssertThrowsError(try parse(#"{"bytesPerSecond":-1}"#))
    }
}

/// Error messages reach the menu now, so they have to read like sentences.
final class HTTPErrorMessageTests: XCTestCase {

    func testExtractsTheMessageFromAnRcErrorBody() {
        let body = #"{"error":"bad bwlimit: bad suffix 'a'","input":{"rate":"banana"},"path":"core/bwlimit","status":500}"#
        XCTAssertEqual(UnixSocketHTTP.Failure.message(from: body, status: 500),
                       "bad bwlimit: bad suffix 'a'")
    }

    /// An unparseable error is still better than no error.
    func testFallsBackToTheRawBody() {
        XCTAssertTrue(UnixSocketHTTP.Failure.message(from: "gateway exploded", status: 502)
                        .contains("gateway exploded"))
    }

    func testAnEmptyErrorFieldFallsBackRatherThanShowingNothing() {
        let body = #"{"error":"","status":500}"#
        XCTAssertTrue(UnixSocketHTTP.Failure.message(from: body, status: 500).contains("500"))
    }

    /// The whole point: no JSON punctuation in what the user reads.
    func testTheDescriptionIsNotAJSONBlob() {
        let body = #"{"error":"bad bwlimit: bad suffix 'a'","input":{"rate":"banana"}}"#
        let description = UnixSocketHTTP.Failure.http(status: 500, body: body).errorDescription ?? ""
        XCTAssertFalse(description.contains("{"), "the user should not be shown raw JSON")
        XCTAssertTrue(description.contains("bad suffix"))
    }
}
