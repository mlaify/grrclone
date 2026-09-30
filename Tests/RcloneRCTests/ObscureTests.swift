import XCTest
@testable import RcloneRC

/// The in-process obscure codec must agree with rclone in both directions (#156).
///
/// Against the real binary, because the whole claim is "this is what rclone does":
/// a codec that round-trips only with itself would pass with a wrong key.
final class ObscureTests: XCTestCase {

    private func rclone() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/grrclone/Resources/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("no rclone binary found; run scripts/fetch-rclone.sh to exercise these")
        }
        return found
    }

    /// Runs rclone with the value as an argument — fine in a test, which is exactly
    /// the exposure the app itself no longer has.
    private func run(_ binary: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "rclone \(args.first ?? "") failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private let samples = ["alice-secret", "-leading-dash", "ünïcødé pass word", "", String(repeating: "x", count: 200)]

    func testRevealsWhatRcloneObscured() throws {
        let binary = try rclone()
        for plain in samples {
            let obscured = try run(binary, ["obscure", "--", plain])
            XCTAssertEqual(try RcloneObscure.reveal(obscured), plain, "for \(plain.debugDescription)")
        }
    }

    func testRcloneRevealsWhatThisObscured() throws {
        let binary = try rclone()
        for plain in samples {
            let obscured = try RcloneObscure.obscure(plain)
            XCTAssertEqual(try run(binary, ["reveal", "--", obscured]), plain, "for \(plain.debugDescription)")
        }
    }

    /// About one obscured value in seventy starts with `-`; the old subprocess path
    /// tripped on those. Obscure until a few turn up and reveal them here.
    func testDashLeadingValuesReveal() throws {
        var found = 0
        for i in 0..<2000 where found < 5 {
            let plain = "example-\(i)"
            let obscured = try RcloneObscure.obscure(plain)
            guard obscured.hasPrefix("-") else { continue }
            found += 1
            XCTAssertEqual(try RcloneObscure.reveal(obscured), plain)
        }
        XCTAssertGreaterThan(found, 0, "2000 obscures produced no dash-leading value; the odds say ~28 should")
    }

    func testRejectsWhatIsNotObscured() {
        for bad in ["", "-", "short", "not base64 !!", "YWJj="] {
            XCTAssertThrowsError(try RcloneObscure.reveal(bad), "accepted \(bad.debugDescription)")
        }
    }

    /// A fresh IV each time: the same plaintext must not obscure to the same string.
    func testObscureUsesAFreshIV() throws {
        XCTAssertNotEqual(try RcloneObscure.obscure("same"), try RcloneObscure.obscure("same"))
    }
}
