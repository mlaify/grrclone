import XCTest
@testable import GrrCloneCore

/// A new remote may not take an existing remote's name: rclone's `config/create`
/// replaces the section, credentials and all (#110).
final class RemoteNameTests: XCTestCase {

    func testAnExistingNameIsRefusedWithAReason() {
        let why = RemoteName.refusal(for: "dav1", existing: ["dav1", "box"])
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("dav1") == true, why ?? "")
        XCTAssertTrue(why?.contains("replace") == true, "must say what would happen: \(why ?? "")")
    }

    func testAFreshNameIsAllowed() {
        XCTAssertNil(RemoteName.refusal(for: "photos", existing: ["dav1", "box"]))
        XCTAssertNil(RemoteName.refusal(for: "dav1", existing: []))
    }

    /// rclone keeps `Keep` and `keep` as two remotes (verified against 1.75.1), so
    /// the comparison is exact: refusing on case would block a name rclone accepts.
    func testComparisonIsExactLikeRclones() {
        XCTAssertNil(RemoteName.refusal(for: "Dav1", existing: ["dav1"]))
    }
}
