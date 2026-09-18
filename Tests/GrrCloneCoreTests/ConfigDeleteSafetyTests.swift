import XCTest
@testable import GrrCloneCore

/// The assumptions `ConnectionManager.deleteRemote` rests on, checked against the
/// real `rclone` rather than believed.
///
/// `config/delete` rewrites the whole configuration file, not just the section being
/// removed. Everything about grrclone's deletion flow — that it is safe to do with
/// other remotes present, that an encrypted config stays encrypted, that a locked one
/// refuses rather than corrupts — is a claim about what rclone does with that
/// rewrite. Claims about someone else's behaviour are exactly the ones worth pinning
/// down, because they can change under you in a release.
///
/// These drive the CLI because the daemon has no way to be pointed at a throwaway
/// config, and running them against the user's real one is not an option.
final class ConfigDeleteSafetyTests: XCTestCase {

    private var dir: URL!
    private var config: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grrclone-cfgdel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = dir.appendingPathComponent("rclone.conf")
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
                        stdin: String? = nil,
                        password: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--config", config.path] + arguments

        if let password {
            var environment = ProcessInfo.processInfo.environment
            environment["RCLONE_CONFIG_PASS"] = password
            process.environment = environment
        }

        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let input = Pipe()
        process.standardInput = input

        try process.run()
        input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
        try? input.fileHandleForWriting.close()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Two remotes with distinguishable secrets, so "the other one survived" is a
    /// claim about its *contents* and not merely its presence.
    private func makeTwoRemotes(_ binary: URL, password: String? = nil) throws {
        try rclone(binary, ["config", "create", "keepme", "webdav",
                            "url", "https://example.invalid/keep",
                            "user", "alice", "pass", "alice-secret"], password: password)
        try rclone(binary, ["config", "create", "deleteme", "webdav",
                            "url", "https://example.invalid/gone",
                            "user", "bob", "pass", "bob-secret"], password: password)
    }

    /// The one that matters: deleting a remote must not disturb another's credentials.
    func testDeletingOneRemoteLeavesTheOthersSecretIntact() throws {
        let binary = try requireRclone()
        try makeTwoRemotes(binary)

        let before = try rclone(binary, ["config", "show", "keepme"]).output
        // Guard against passing vacuously: two empty strings are also equal, and a
        // `config show` that silently returned nothing would make this test green
        // while proving nothing at all.
        XCTAssertTrue(before.contains("alice"),
                      "setup failed: expected to be reading a real remote, got: \(before)")

        try rclone(binary, ["config", "delete", "deleteme"])
        let after = try rclone(binary, ["config", "show", "keepme"]).output

        XCTAssertEqual(before, after, "the surviving remote must be untouched")

        let remotes = try rclone(binary, ["listremotes"]).output
        XCTAssertTrue(remotes.contains("keepme:"))
        XCTAssertFalse(remotes.contains("deleteme:"))
    }

    /// The same, through an encrypted round-trip — where a rewrite could plausibly
    /// re-derive keys or re-obscure values and silently change the survivor.
    func testEncryptedConfigSurvivesADeleteWithItsSecretsUnchanged() throws {
        let binary = try requireRclone()
        let password = "test-config-password"

        try makeTwoRemotes(binary)
        try rclone(binary, ["config", "encryption", "set"],
                   stdin: "\(password)\n\(password)\n")
        XCTAssertTrue(ConfigEncryption.isEncrypted(configPath: config.path),
                      "setup failed: the config should be encrypted by now")

        let secretBefore = try rclone(binary, ["config", "show", "keepme"],
                                      password: password).output
        XCTAssertTrue(secretBefore.contains("alice"),
                      "setup failed: could not read the remote through the encrypted "
                      + "config, got: \(secretBefore)")

        try rclone(binary, ["config", "delete", "deleteme"], password: password)

        XCTAssertTrue(ConfigEncryption.isEncrypted(configPath: config.path),
                      "a delete must not quietly downgrade an encrypted config")

        let secretAfter = try rclone(binary, ["config", "show", "keepme"],
                                     password: password).output
        XCTAssertEqual(secretBefore, secretAfter,
                       "the surviving remote's credentials must be byte-identical")
        XCTAssertTrue(secretAfter.contains("alice"), "sanity: we are reading a real remote")
    }

    /// A locked config must refuse and leave the file exactly as it was. This is the
    /// case where a partial write would cost the user every credential they own.
    func testDeletingAgainstALockedConfigChangesNothing() throws {
        let binary = try requireRclone()
        let password = "test-config-password"

        try makeTwoRemotes(binary)
        try rclone(binary, ["config", "encryption", "set"],
                   stdin: "\(password)\n\(password)\n")

        let before = try Data(contentsOf: config)

        // No password supplied, and no terminal to prompt on.
        let result = try rclone(binary, ["--ask-password=false", "config", "delete", "deleteme"])

        XCTAssertNotEqual(result.status, 0, "a locked config must refuse the delete")
        XCTAssertEqual(try Data(contentsOf: config), before,
                       "the file must be byte-identical after a refused delete")
    }

    /// Deleting something that is not there must not rewrite the file.
    func testDeletingAnAbsentRemoteLeavesTheFileAlone() throws {
        let binary = try requireRclone()
        try makeTwoRemotes(binary)

        let before = try Data(contentsOf: config)
        _ = try rclone(binary, ["config", "delete", "neverexisted"])

        XCTAssertEqual(try Data(contentsOf: config), before,
                       "deleting a remote that does not exist must not touch the file")
    }

    /// Deleting the last remote must leave a valid, still-encrypted config — not an
    /// empty or truncated one. This is also the case where a naive implementation
    /// might decide the keychain entry is now pointless and remove it, locking the
    /// user out of a configuration they still have.
    func testDeletingTheLastRemoteLeavesAValidEncryptedConfig() throws {
        let binary = try requireRclone()
        let password = "test-config-password"

        try rclone(binary, ["config", "create", "onlyone", "webdav",
                            "url", "https://example.invalid/x", "user", "alice",
                            "pass", "alice-secret"])
        try rclone(binary, ["config", "encryption", "set"],
                   stdin: "\(password)\n\(password)\n")

        try rclone(binary, ["config", "delete", "onlyone"], password: password)

        XCTAssertTrue(ConfigEncryption.isEncrypted(configPath: config.path),
                      "an emptied config should still be encrypted, not reset")
        let remotes = try rclone(binary, ["listremotes"], password: password)
        XCTAssertEqual(remotes.status, 0, "the config must still be readable")
        XCTAssertTrue(remotes.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
