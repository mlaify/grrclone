import XCTest
@testable import GrrCloneCore

/// Exercises the real `rclone` binary, because the thing being tested is an
/// interaction with it: a subprocess that asks for a password twice on stdin and
/// rewrites a file. A stub would test the stub.
final class ConfigEncryptionTests: XCTestCase {

    private var dir: URL!
    private var config: String { dir.appendingPathComponent("rclone.conf").path }

    private var rclone: URL? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/grrclone/Resources/rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grr-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[testlocal]\ntype = local\n".write(toFile: config, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAPlainConfigIsNotReportedAsEncrypted() {
        XCTAssertFalse(ConfigEncryption.isEncrypted(configPath: config))
    }

    func testAMissingFileIsNotReportedAsEncrypted() {
        XCTAssertFalse(ConfigEncryption.isEncrypted(configPath: dir.appendingPathComponent("nope").path))
    }

    func testEncryptingMakesTheCredentialsUnreadable() throws {
        let rclone = try XCTUnwrap(self.rclone, "no rclone binary to test against")
        try "[dav]\ntype = webdav\npass = obscuredvalue\n"
            .write(toFile: config, atomically: true, encoding: .utf8)

        try ConfigEncryption.encrypt(rclone: rclone, configPath: config, password: "a-test-password")

        XCTAssertTrue(ConfigEncryption.isEncrypted(configPath: config))
        let contents = try String(contentsOfFile: config, encoding: .utf8)
        XCTAssertFalse(contents.contains("obscuredvalue"),
                       "the credential is still readable after encryption")
        XCTAssertFalse(contents.contains("webdav"),
                       "even the remote type should not be legible")
    }

    /// Encrypting an already-encrypted config would prompt for the *old* password and
    /// hang on a pipe that will never answer it.
    func testRefusesToEncryptTwice() throws {
        let rclone = try XCTUnwrap(self.rclone, "no rclone binary to test against")
        try ConfigEncryption.encrypt(rclone: rclone, configPath: config, password: "first")

        XCTAssertThrowsError(
            try ConfigEncryption.encrypt(rclone: rclone, configPath: config, password: "second")
        ) { error in
            guard case ConfigEncryption.Failure.alreadyEncrypted = error else {
                return XCTFail("expected alreadyEncrypted, got \(error)")
            }
        }
    }

    /// The failure that matters most: reporting success while leaving the credentials
    /// readable would have the user believe they are protected when they are not. The
    /// check is on the file, not the exit status.
    func testSuccessIsDecidedByTheFileNotTheExitStatus() throws {
        let rclone = try XCTUnwrap(self.rclone, "no rclone binary to test against")
        try ConfigEncryption.encrypt(rclone: rclone, configPath: config, password: "pw")
        XCTAssertTrue(ConfigEncryption.isEncrypted(configPath: config))

        // And the detection is not fooled by the word appearing in ordinary content.
        let decoy = dir.appendingPathComponent("decoy.conf").path
        try "[notes]\ncomment = RCLONE_ENCRYPT_V0 is the marker\n"
            .write(toFile: decoy, atomically: true, encoding: .utf8)
        XCTAssertTrue(ConfigEncryption.isEncrypted(configPath: decoy),
                      "detection is deliberately eager: a false positive refuses to encrypt, "
                      + "a false negative would encrypt twice and hang")
    }
}
