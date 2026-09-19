import XCTest
@testable import RcloneRC

/// Parsing `core/stats`.
///
/// The fixtures here are captured from a live daemon during a real transfer, not
/// written from documentation. That matters twice over: the previous version of
/// `stats()` passed `short: true`, which omits the `transferring` array entirely, so
/// its transfer count could only ever be zero — and nothing noticed, because the
/// function had no callers.
final class TransferStatsTests: XCTestCase {

    /// Exactly what a live daemon returned mid-copy, fields and all.
    private let midTransfer = """
    {
      "bytes": 52428800,
      "totalBytes": 1258291200,
      "errors": 0,
      "eta": 96,
      "speed": 12582912,
      "transfers": 0,
      "transferring": [
        {
          "bytes": 52428800,
          "dstFs": "/tmp/dst",
          "eta": 96,
          "group": "job/1",
          "name": "big.bin",
          "percentage": 4,
          "size": 1258291200,
          "speed": 12582912,
          "speedAvg": 11000000,
          "srcFs": "/tmp/src"
        }
      ]
    }
    """

    /// At rest, rclone omits `transferring` entirely rather than sending `[]`.
    private let atRest = """
    {"bytes": 0, "totalBytes": 0, "errors": 0, "eta": null, "speed": 0, "transfers": 0}
    """

    /// Calls the client's own parser rather than a copy of it. A test that
    /// re-implements the thing it tests proves only that it agrees with itself.
    private func stats(_ json: String) throws -> RcloneRCClient.Stats {
        RcloneRCClient.parseStats(
            try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    func testParsesALiveTransfer() throws {
        let parsed = try stats(midTransfer)

        XCTAssertTrue(parsed.isActive)
        XCTAssertEqual(parsed.transferring.count, 1)
        XCTAssertEqual(parsed.speed, 12_582_912)
        XCTAssertEqual(parsed.eta, 96)

        let file = try XCTUnwrap(parsed.transferring.first)
        XCTAssertEqual(file.name, "big.bin")
        XCTAssertEqual(file.size, 1_258_291_200)
        XCTAssertEqual(file.bytes, 52_428_800)
        XCTAssertEqual(file.eta, 96)
    }

    /// A missing `transferring` key means nothing is moving, and must not be an
    /// error or a crash.
    func testParsesAnIdleDaemon() throws {
        let parsed = try stats(atRest)
        XCTAssertFalse(parsed.isActive)
        XCTAssertTrue(parsed.transferring.isEmpty)
        XCTAssertNil(parsed.eta)
    }

    /// `eta` is genuinely null until rclone has a sample to estimate from. Nil, not
    /// zero — "unknown" and "no time left" are different things to put in front of
    /// someone watching an upload.
    func testMissingEtaIsUnknownRatherThanZero() throws {
        let json = """
        {"bytes":0,"speed":0,"transferring":[
          {"name":"new.bin","size":1000,"bytes":0,"speed":0,"eta":null}]}
        """
        let file = try XCTUnwrap(stats(json).transferring.first)
        XCTAssertNil(file.eta, "a null eta must not become 0s left")
    }

    /// A transfer whose size rclone has not reported must not render as 0%, which
    /// looks stuck. Nil drives an indeterminate bar instead.
    func testUnknownSizeHasNoFraction() throws {
        let json = """
        {"transferring":[{"name":"stream.bin","size":0,"bytes":4096,"speed":100}]}
        """
        let file = try XCTUnwrap(stats(json).transferring.first)
        XCTAssertNil(file.fraction)
    }

    func testFractionIsClampedToOne() {
        // rclone can briefly report more bytes than size on a resumed transfer.
        let over = RcloneRCClient.Transfer(name: "x", size: 100, bytes: 150,
                                           speed: 0, eta: nil)
        XCTAssertEqual(over.fraction, 1)

        let half = RcloneRCClient.Transfer(name: "x", size: 100, bytes: 50,
                                           speed: 0, eta: nil)
        XCTAssertEqual(half.fraction, 0.5)
    }

    /// An entry without a name is not something to display; skip it rather than
    /// render a blank row.
    func testEntriesWithoutANameAreSkipped() throws {
        let json = """
        {"transferring":[{"size":10,"bytes":1},{"name":"real.bin","size":10,"bytes":1}]}
        """
        let parsed = try stats(json)
        XCTAssertEqual(parsed.transferring.map(\.name), ["real.bin"])
    }
}
