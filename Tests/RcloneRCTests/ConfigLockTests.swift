import XCTest
@testable import RcloneRC

/// The lock classifier decides whether the user is asked for a password or shown a
/// stack trace, so it is tested against the *exact* strings rclone 1.75.1 produced,
/// captured from a real daemon running against a real encrypted config.
final class ConfigLockTests: XCTestCase {

    /// What `config/listremotes` returns with `--ask-password=false`, which is how
    /// grrclone always launches the daemon.
    private static let askPasswordDisabled = """
        {"error":"panic received: fatal error: Failed to load config file \
        \"/Users/someone/.config/rclone/rclone.conf\": unable to decrypt configuration \
        and not allowed to ask for password - set RCLONE_CONFIG_PASS to your \
        configuration password","input":{},"path":"config/listremotes","status":500}
        """

    /// What it returns when rclone is left to prompt and stdin is not a terminal.
    /// Nothing in this mentions encryption, which is why it is matched explicitly.
    private static let promptingWithNoTerminal = """
        {"error":"panic received: fatal error: Failed to read line: EOF","input":{},\
        "path":"config/listremotes","status":500}
        """

    func testRecognisesTheErrorProducedWhenPromptingIsDisabled() {
        let error = UnixSocketHTTP.Failure.http(status: 500, body: Self.askPasswordDisabled)
        XCTAssertTrue(RcloneRCClient.isLockedError(error))
    }

    func testRecognisesThePanicProducedWhenRcloneTriesToPrompt() {
        let error = UnixSocketHTTP.Failure.http(status: 500, body: Self.promptingWithNoTerminal)
        XCTAssertTrue(RcloneRCClient.isLockedError(error))
    }

    /// The failure that matters most: an unrelated error must not be reported as a
    /// locked config, or the app would demand a password that cannot fix anything and
    /// hide the real fault.
    func testDoesNotClaimUnrelatedFailuresAreLocks() {
        let cases: [Error] = [
            UnixSocketHTTP.Failure.http(status: 500,
                body: #"{"error":"didn't find section in config file","status":500}"#),
            UnixSocketHTTP.Failure.http(status: 404, body: #"{"error":"couldn't find method"}"#),
            UnixSocketHTTP.Failure.connectionFailed("Connection refused"),
            UnixSocketHTTP.Failure.malformedResponse("bad status line: garbage"),
            RcloneRCError.unexpectedResponse("serve/start returned no id"),
            RcloneRCError.unsupportedVersion(found: "1.70.0", minimum: "1.74.4"),
        ]
        for error in cases {
            XCTAssertFalse(RcloneRCClient.isLockedError(error),
                           "misclassified as a locked config: \(error)")
        }
    }

    /// A bare EOF is not enough. rclone reads lines for reasons other than the config
    /// password, and treating any of them as encryption would send the user down the
    /// wrong path entirely.
    func testBareEOFIsNotTreatedAsALock() {
        let error = UnixSocketHTTP.Failure.http(
            status: 500, body: #"{"error":"failed to read line: EOF","path":"core/command"}"#)
        XCTAssertFalse(RcloneRCClient.isLockedError(error))
    }

    func testMatchingIsCaseInsensitive() {
        let shouty = Self.askPasswordDisabled.uppercased()
        let error = UnixSocketHTTP.Failure.http(status: 500, body: shouty)
        XCTAssertTrue(RcloneRCClient.isLockedError(error))
    }

    func testLockedErrorsCarryAnActionableMessage() {
        // The user sees this. It has to say what to do, not what went wrong internally.
        XCTAssertTrue(RcloneRCError.configLocked.errorDescription?
            .localizedCaseInsensitiveContains("password") ?? false)
        XCTAssertTrue(RcloneRCError.configPasswordRejected.errorDescription?
            .localizedCaseInsensitiveContains("did not decrypt") ?? false)
    }
}
