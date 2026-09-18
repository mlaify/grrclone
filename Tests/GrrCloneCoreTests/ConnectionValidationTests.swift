import XCTest
@testable import GrrCloneCore

/// The two pieces of input that decide *where a volume appears* and *what gets
/// mounted*.
///
/// Both lived in the settings view until now, which is why neither had a test: the
/// app target has no test bundle. Moving them to the model is the point — a function
/// that determines the mount point deserves more than a careful reading.
final class ConnectionValidationTests: XCTestCase {

    // MARK: - Names, which become the mount folder

    func testNameKeepsOrdinaryInput() {
        XCTAssertEqual(Connection.sanitisedName("Photos", fallback: "dav1"), "Photos")
        XCTAssertEqual(Connection.sanitisedName("  Work Files  ", fallback: "dav1"),
                       "Work Files")
    }

    /// A separator would create nested directories, and then the mount point no
    /// longer has the shape `mountRoot(containing:displayName:)` assumes — which is
    /// how a repair could put a volume back a level deeper than it found it.
    func testNameSeparatorsAreReplaced() {
        XCTAssertEqual(Connection.sanitisedName("team/docs", fallback: "dav1"), "team-docs")
        XCTAssertEqual(Connection.sanitisedName("a:b", fallback: "dav1"), "a-b")
    }

    /// `.` and `..` are not usable folder names; empty is not a folder at all.
    func testUnusableNamesFallBack() {
        XCTAssertEqual(Connection.sanitisedName("", fallback: "dav1"), "dav1")
        XCTAssertEqual(Connection.sanitisedName("   ", fallback: "dav1"), "dav1")
        XCTAssertEqual(Connection.sanitisedName(".", fallback: "dav1"), "dav1")
        XCTAssertEqual(Connection.sanitisedName("..", fallback: "dav1"), "dav1")
    }

    // MARK: - Subpaths, which decide what is mounted

    func testPathKeepsOrdinaryInput() {
        XCTAssertEqual(Connection.sanitisedPath("photos"), "photos")
        XCTAssertEqual(Connection.sanitisedPath("photos/2024"), "photos/2024")
        XCTAssertEqual(Connection.sanitisedPath(""), "")
    }

    /// The one that changes what gets mounted rather than merely looking untidy:
    /// `remote:a:b` parses as a different remote entirely.
    func testColonIsRemovedFromPath() {
        XCTAssertEqual(Connection.sanitisedPath("other:secret"), "othersecret")

        var connection = Connection(remote: "dav1")
        connection.path = Connection.sanitisedPath("other:secret")
        XCTAssertEqual(connection.fsSpec, "dav1:othersecret",
                       "a colon in the subpath must not be able to name another remote")
    }

    /// `remote:/folder` is an absolute path — accepted by some backends, rejected by
    /// others. A trailing slash only looks like a mistake, but is trimmed too.
    func testSlashesAreTrimmed() {
        XCTAssertEqual(Connection.sanitisedPath("/photos"), "photos")
        XCTAssertEqual(Connection.sanitisedPath("photos/"), "photos")
        XCTAssertEqual(Connection.sanitisedPath("/photos/2024/"), "photos/2024")
        XCTAssertEqual(Connection.sanitisedPath("///"), "")
    }

    /// rclone does not resolve `..`, so a path containing one points at a directory
    /// that does not exist rather than at the parent.
    func testRelativeComponentsAreDropped() {
        XCTAssertEqual(Connection.sanitisedPath("photos/../secrets"), "photos/secrets")
        XCTAssertEqual(Connection.sanitisedPath("./photos"), "photos")
        XCTAssertEqual(Connection.sanitisedPath(".."), "")
    }

    func testEmptyPathMeansTheWholeRemote() {
        let whole = Connection(remote: "dav1", path: "")
        XCTAssertEqual(whole.fsSpec, "dav1:")

        let part = Connection(remote: "dav1", path: "photos/2024")
        XCTAssertEqual(part.fsSpec, "dav1:photos/2024")
    }

    // MARK: - The interaction with #77

    /// Changing the subpath changes what is mounted, so a mounted connection has to
    /// be told its saved settings are not yet in force. `needsRemountBetween` lives
    /// in the app target, but the property it depends on is here: two connections
    /// differing only by `path` must not compare equal.
    func testConnectionsDifferingOnlyByPathAreNotEqual() {
        let base = Connection(id: UUID(), remote: "dav1", path: "")
        var moved = base
        moved.path = "photos"
        XCTAssertNotEqual(base, moved)
    }

    /// A subpath must survive a round-trip through the store, or the mount silently
    /// reverts to the whole remote on the next launch.
    func testSubpathSurvivesEncoding() throws {
        let original = Connection(remote: "dav1", path: "photos/2024",
                                  displayName: "Photos")
        let decoded = try JSONDecoder().decode(
            Connection.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.path, "photos/2024")
        XCTAssertEqual(decoded.fsSpec, "dav1:photos/2024")
    }
}
