import XCTest
@testable import RcloneRC

final class VersionTests: XCTestCase {

    func testParsesStandardVersionStrings() {
        XCTAssertEqual(RcloneRCClient.parseVersion("v1.75.1").0, 1)
        XCTAssertEqual(RcloneRCClient.parseVersion("v1.75.1").1, 75)
        XCTAssertEqual(RcloneRCClient.parseVersion("v1.75.1").2, 1)
        XCTAssertEqual(RcloneRCClient.parseVersion("1.74.4").1, 74)
    }

    func testParsesDevelopmentVersions() {
        // Beta builds look like "v1.76.0-beta.1234.abcdef".
        let parsed = RcloneRCClient.parseVersion("v1.76.0-beta.8901.deadbeef")
        XCTAssertEqual(parsed.0, 1)
        XCTAssertEqual(parsed.1, 76)
        XCTAssertEqual(parsed.2, 0)
    }

    /// An unparseable version must compare as older than the minimum. Failing closed
    /// means an unknown build is rejected rather than optimistically trusted with mount
    /// behaviour we have not verified.
    func testUnparseableVersionFailsClosed()  {
        let unknown = RcloneRCClient.Version(version: "weird",
                                             components: RcloneRCClient.parseVersion("weird"))
        XCTAssertFalse(unknown.meetsMinimum)
    }

    func testMinimumVersionBoundary() {
        func version(_ string: String) -> RcloneRCClient.Version {
            .init(version: string, components: RcloneRCClient.parseVersion(string))
        }
        // 1.74.4 fixed Mknod-based file creation, ESTALE from unstable inodes, and
        // large-directory listings. Below it, NFS mounting misbehaves in ways users
        // would report as data loss.
        XCTAssertFalse(version("v1.74.3").meetsMinimum)
        XCTAssertTrue(version("v1.74.4").meetsMinimum)
        XCTAssertTrue(version("v1.75.1").meetsMinimum)
        XCTAssertTrue(version("v2.0.0").meetsMinimum)
        XCTAssertFalse(version("v1.68.0").meetsMinimum)
    }
}

final class JSONValueTests: XCTestCase {

    func testRoundTripsNestedStructures() throws {
        let json = """
        {"id":"nfs-abc","addr":"127.0.0.1:64899","count":3,"ok":true,
         "list":[1,2],"nested":{"a":null}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["id"]?.stringValue, "nfs-abc")
        XCTAssertEqual(value["count"]?.intValue, 3)
        XCTAssertEqual(value["ok"]?.boolValue, true)
        XCTAssertEqual(value["list"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["nested"]?["a"], .null)

        let reencoded = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        XCTAssertEqual(value, again)
    }

    /// Whole numbers must stay integers. Re-encoding a port as 64899.0 produces a
    /// serve/start request rclone rejects.
    func testWholeNumbersDoNotBecomeDoubles() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("{\"port\":64899}".utf8))
        XCTAssertEqual(value["port"], .int(64899))
        let text = String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("64899"))
        XCTAssertFalse(text.contains("64899.0"))
    }

    func testMissingKeysReadAsNilRatherThanThrowing() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("{}".utf8))
        XCTAssertNil(value["absent"])
        XCTAssertNil(value["absent"]?.stringValue)
    }
}

final class ServerTests: XCTestCase {

    func testExtractsPortFromIPv4Address() {
        XCTAssertEqual(RcloneRCClient.Server(id: "x", addr: "127.0.0.1:64899").port, 64899)
    }

    func testExtractsPortFromIPv6Address() {
        // rclone reports wildcard binds as "[::]:4321".
        XCTAssertEqual(RcloneRCClient.Server(id: "x", addr: "[::]:4321").port, 4321)
    }

    func testMissingPortIsNil() {
        XCTAssertNil(RcloneRCClient.Server(id: "x", addr: "").port)
        XCTAssertNil(RcloneRCClient.Server(id: "x", addr: "localhost").port)
    }
}

final class HTTPParsingTests: XCTestCase {

    func testParsesSuccessfulResponse() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}"
        let body = try UnixSocketHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(String(data: body, encoding: .utf8), "{\"ok\":true}")
    }

    /// rclone reports a bad serve/start as HTTP 500 with the reason in the body. Losing
    /// that body would turn an actionable "unknown parameters: attr_timeout" into an
    /// opaque failure.
    func testSurfacesErrorBodyOnFailureStatus() {
        let raw = "HTTP/1.1 500 Internal Server Error\r\n\r\n{\"error\":\"unknown parameters: attr_timeout\"}"
        XCTAssertThrowsError(try UnixSocketHTTP.parse(Data(raw.utf8))) { error in
            guard case UnixSocketHTTP.Failure.http(let status, let body) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertTrue(body.contains("attr_timeout"))
        }
    }

    func testRejectsResponseWithoutHeaderSeparator() {
        XCTAssertThrowsError(try UnixSocketHTTP.parse(Data("HTTP/1.1 200 OK".utf8)))
    }

    func testHandlesEmptyBody() throws {
        let body = try UnixSocketHTTP.parse(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        XCTAssertTrue(body.isEmpty)
    }
}
