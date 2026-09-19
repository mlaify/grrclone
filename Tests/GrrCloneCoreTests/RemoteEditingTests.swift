import XCTest
@testable import GrrCloneCore

/// What rclone does when an existing remote's settings are rewritten.
///
/// Every safety claim in the edit flow is a claim about rclone's behaviour, not
/// grrclone's: that a dumped secret comes back obscured rather than in plaintext,
/// that writing one back does not double-obscure it, and that the automatic
/// obscure-or-not decision is a *guess* which can be overridden. Claims about
/// someone else's behaviour are the ones worth pinning down, because they can change
/// in a release.
///
/// These drive the CLI because the daemon cannot be pointed at a throwaway config,
/// and running them against the real one is not an option.
final class RemoteEditingTests: XCTestCase {

    private var dir: URL!
    private var config: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grrclone-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = dir.appendingPathComponent("rclone.conf")
        FileManager.default.createFile(atPath: config.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func requireRclone() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/grrclone/Resources/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("no rclone binary found; run scripts/fetch-rclone.sh to exercise these")
        }
        return found
    }

    @discardableResult
    private func rclone(_ binary: URL, _ arguments: [String],
                        withConfig: Bool = true) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = (withConfig ? ["--config", config.path] : []) + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The value actually written to the file, not what any command reports.
    private func storedValue(_ key: String) throws -> String? {
        let text = try String(contentsOf: config, encoding: .utf8)
        for line in text.split(separator: "\n") where line.hasPrefix("\(key) = ") {
            return String(line.dropFirst("\(key) = ".count))
        }
        return nil
    }

    private func makeRemote(_ binary: URL, password: String = "alice-secret") throws {
        try rclone(binary, ["config", "create", "r", "webdav",
                            "url", "https://example.invalid", "user", "alice",
                            "pass", password])
    }

    /// The premise of the whole design: a dumped secret is obscured, and obscuring is
    /// reversible. That is why the form must not display it.
    func testDumpedSecretsAreObscuredNotPlaintext() throws {
        let binary = try requireRclone()
        try makeRemote(binary)

        let stored = try XCTUnwrap(storedValue("pass"))
        XCTAssertNotEqual(stored, "alice-secret", "the secret must not sit in the clear")

        let revealed = try rclone(binary, ["reveal", stored], withConfig: false)
        XCTAssertEqual(revealed, "alice-secret",
                       "and it must be trivially reversible — which is why it is not "
                       + "safe to show in a password field")
    }

    /// Changing one field must not disturb the others, and in particular must not
    /// re-obscure a password nobody touched.
    func testUpdatingOneFieldLeavesTheSecretByteIdentical() throws {
        let binary = try requireRclone()
        try makeRemote(binary)
        let before = try XCTUnwrap(storedValue("pass"))

        try rclone(binary, ["config", "update", "r",
                            "url", "https://corrected.invalid", "--non-interactive"])

        XCTAssertEqual(try storedValue("pass"), before,
                       "an untouched password must come through unchanged")
        XCTAssertEqual(try storedValue("url"), "https://corrected.invalid")
    }

    /// A genuinely new password must end up obscured, not written in the clear.
    func testANewPasswordIsStoredObscured() throws {
        let binary = try requireRclone()
        try makeRemote(binary)

        try rclone(binary, ["config", "update", "r",
                            "pass", "brand-new-password", "--non-interactive"])

        let stored = try XCTUnwrap(storedValue("pass"))
        XCTAssertNotEqual(stored, "brand-new-password")
        XCTAssertEqual(try rclone(binary, ["reveal", stored], withConfig: false),
                       "brand-new-password")
    }

    /// rclone's automatic decision is a guess, and this is the case it gets wrong.
    ///
    /// It tries to reveal the incoming value; if that succeeds it assumes the value
    /// was already obscured and stores it unchanged. So a literal password that
    /// happens to be a valid obscured string is *revealed* instead of obscured, and
    /// the stored password becomes something the user never typed.
    ///
    /// Pinned here because it is the reason `updateRemote` forces `obscure: true`
    /// rather than trusting the default — if rclone ever fixes this, the test says so.
    func testTheAutomaticObscureDecisionIsAGuessThatCanBeWrong() throws {
        let binary = try requireRclone()
        try makeRemote(binary)

        // A plaintext password that is, coincidentally, valid obscured text.
        let looksObscured = try rclone(binary, ["obscure", "hunter2"], withConfig: false)
        try rclone(binary, ["config", "update", "r", "pass", looksObscured,
                            "--non-interactive"])

        let stored = try XCTUnwrap(storedValue("pass"))
        let revealed = try rclone(binary, ["reveal", stored], withConfig: false)
        XCTAssertEqual(revealed, "hunter2",
                       "documents the misfire: rclone revealed a literal password "
                       + "instead of obscuring it. If this ever fails, rclone has "
                       + "changed and the forced-obscure in updateRemote can be "
                       + "revisited.")
    }

    /// Forcing it produces the right answer for the same input, which is why
    /// `updateRemote` always does.
    func testForcingObscureStoresTheLiteralValue() throws {
        let binary = try requireRclone()
        try makeRemote(binary)

        let looksObscured = try rclone(binary, ["obscure", "hunter2"], withConfig: false)
        try rclone(binary, ["config", "update", "r", "pass", looksObscured,
                            "--obscure", "--non-interactive"])

        let stored = try XCTUnwrap(storedValue("pass"))
        XCTAssertEqual(try rclone(binary, ["reveal", stored], withConfig: false),
                       looksObscured,
                       "with obscure forced, the literal string the user typed is what "
                       + "comes back")
    }

    /// Editing one remote must not touch another, encrypted config or not.
    func testUpdatingOneRemoteLeavesAnotherUntouched() throws {
        let binary = try requireRclone()
        try makeRemote(binary)
        try rclone(binary, ["config", "create", "other", "webdav",
                            "url", "https://other.invalid", "user", "bob",
                            "pass", "bob-secret"])

        let otherBefore = try rclone(binary, ["config", "show", "other"])
        try rclone(binary, ["config", "update", "r", "user", "changed",
                            "--non-interactive"])

        XCTAssertEqual(try rclone(binary, ["config", "show", "other"]), otherBefore)
        XCTAssertTrue(otherBefore.contains("bob"), "sanity: reading a real remote")
    }

    /// The type must survive an edit. Losing it would leave a section rclone cannot
    /// interpret at all.
    func testUpdatingDoesNotDropTheBackendType() throws {
        let binary = try requireRclone()
        try makeRemote(binary)

        try rclone(binary, ["config", "update", "r", "user", "changed",
                            "--non-interactive"])

        XCTAssertEqual(try storedValue("type"), "webdav")
    }
}
