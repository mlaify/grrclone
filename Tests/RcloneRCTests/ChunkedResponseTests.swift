import XCTest
@testable import RcloneRC

/// Chunked transfer decoding, which this client assumed it would never need.
///
/// The assumption was written down and wrong: `Connection: close` does delimit the
/// body, so a reader can consume to EOF — but that is about *length*, not *encoding*.
/// rclone chunks large replies anyway. `config/providers` is 757 KB and arrives
/// chunked, while every other call in this client is small enough to come back in one
/// piece, so the add-remote wizard was the first thing to see it.
final class ChunkedResponseTests: XCTestCase {

    private func response(headers: String, body: String) -> Data {
        Data("HTTP/1.1 200 OK\r\n\(headers)\r\n\r\n\(body)".utf8)
    }

    /// Build a chunked body with the sizes computed rather than counted by hand.
    ///
    /// The first version of these tests wrote the hex lengths manually and got two of
    /// them wrong, which failed as "unreadable chunk size" and looked like a decoder
    /// bug. A fixture that is hard to write by hand should not be written by hand.
    private func chunked(_ pieces: [String], extension ext: String = "") -> String {
        pieces.map { piece in
            String(format: "%x", piece.utf8.count) + ext + "\r\n" + piece + "\r\n"
        }.joined() + "0\r\n\r\n"
    }

    func testDecodesASingleChunk() throws {
        let raw = response(headers: "Transfer-Encoding: chunked",
                           body: chunked([#"{"remotes":["dav1","x"]}"#]))
        let body = try UnixSocketHTTP.parse(raw)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"remotes":["dav1","x"]}"#)
    }

    func testJoinsMultipleChunks() throws {
        let raw = response(headers: "Transfer-Encoding: chunked",
                           body: chunked([#"{"a":"#, "1234", "}"]))
        let body = try UnixSocketHTTP.parse(raw)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"a":1234}"#)
    }

    /// The case that actually broke: a body big enough that rclone chunks it, which
    /// must come back byte-identical.
    func testHandlesALargeChunkedBody() throws {
        let payload = #"{"providers":["# + (0..<2000).map { #"{"Name":"p\#($0)"}"# }.joined(separator: ",") + "]}"
        var pieces: [String] = []
        var remaining = Substring(payload)
        while !remaining.isEmpty {
            pieces.append(String(remaining.prefix(4096)))
            remaining = remaining.dropFirst(4096)
        }

        let body = try UnixSocketHTTP.parse(response(headers: "Transfer-Encoding: chunked",
                                                     body: chunked(pieces)))
        XCTAssertEqual(String(data: body, encoding: .utf8), payload)
    }

    /// An unchunked reply must be unaffected — every other call in the client sends one.
    func testLeavesAnUnchunkedBodyAlone() throws {
        let raw = response(headers: "Content-Length: 24", body: #"{"remotes":["dav1","x"]}"#)
        let body = try UnixSocketHTTP.parse(raw)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"remotes":["dav1","x"]}"#)
    }

    func testTheHeaderMatchIsCaseInsensitive() throws {
        let raw = response(headers: "transfer-encoding: CHUNKED", body: chunked(["hi"]))
        XCTAssertEqual(String(data: try UnixSocketHTTP.parse(raw), encoding: .utf8), "hi")
    }

    /// Chunk extensions are legal and rclone may add them; a reader that choked would
    /// fail over something it does not need.
    func testToleratesChunkExtensions() throws {
        let raw = response(headers: "Transfer-Encoding: chunked",
                           body: chunked(["hi"], extension: ";name=value"))
        XCTAssertEqual(String(data: try UnixSocketHTTP.parse(raw), encoding: .utf8), "hi")
    }

    func testAnEmptyChunkedBodyIsEmpty() throws {
        let raw = response(headers: "Transfer-Encoding: chunked", body: "0\r\n\r\n")
        XCTAssertEqual(try UnixSocketHTTP.parse(raw).count, 0)
    }

    /// A truncated body must fail rather than silently return a fragment that would
    /// then be reported as malformed JSON, pointing at the wrong thing.
    func testATruncatedChunkIsRejected() {
        let raw = response(headers: "Transfer-Encoding: chunked", body: "ff\r\nshort\r\n")
        XCTAssertThrowsError(try UnixSocketHTTP.parse(raw))
    }

    func testAnUnreadableChunkSizeIsRejected() {
        let raw = response(headers: "Transfer-Encoding: chunked", body: "zz\r\nhi\r\n0\r\n\r\n")
        XCTAssertThrowsError(try UnixSocketHTTP.parse(raw))
    }

    /// An error response arrives chunked too, and must be readable — otherwise the
    /// user is shown hex framing instead of rclone's message.
    func testAChunkedErrorBodyIsDecodedBeforeBeingReported() {
        let payload = #"{"error":"something broke"}"#
        let raw = Data(("HTTP/1.1 500 Internal Server Error\r\nTransfer-Encoding: chunked\r\n\r\n"
                        + chunked([payload])).utf8)
        XCTAssertThrowsError(try UnixSocketHTTP.parse(raw)) { error in
            XCTAssertTrue("\(error)".contains("something broke"), "got: \(error)")
        }
    }
}
