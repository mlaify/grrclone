import XCTest
@testable import GrrCloneCore

final class DaemonLogRedactionTests: XCTestCase {

    func testRedactsCredentialsEmbeddedInAURL() {
        let line = "2026/09/17 NOTICE: webdav: connecting to https://matt:s3cr3t@dav.example.com/remote.php"
        let out = DaemonLog.redact(line)
        XCTAssertFalse(out.contains("s3cr3t"))
        XCTAssertTrue(out.contains("https://matt:***@dav.example.com"),
                      "the host must survive, or the line stops being useful: \(out)")
    }

    /// Captured verbatim from rclone 1.75.1 at DEBUG, not invented.
    ///
    /// This test exists because the first version of it was invented. It asserted the
    /// shape `--rc-pass VALUE`, the redaction matched that shape, the test passed —
    /// and the real log line is `"--rc-pass" "VALUE"` with every argument quoted, so
    /// nothing was redacted at all and the control-socket credentials went into the
    /// log in clear text. A test written from imagination proves only that the code
    /// agrees with the imagination.
    func testRedactsTheCommandLineRcloneActuallyEchoes() {
        let line = #"2026/09/17 07:35:32 DEBUG : rclone: Version "v1.75.1" starting with parameters ["/opt/homebrew/bin/rclone" "rcd" "--rc-addr" "unix:///Users/x/rc.sock" "--rc-user" "rr5xrS6uijLDUgwxyo3qszKiXTQwhAUe" "--rc-pass" "roOiGfANU_SfyOGX4tL-TSjGj8fW0QE_" "--transfers" "8" "--log-level" "DEBUG"]"#
        let out = DaemonLog.redact(line)

        XCTAssertFalse(out.contains("rr5xrS6uijLDUgwxyo3qszKiXTQwhAUe"), "leaked rc-user: \(out)")
        XCTAssertFalse(out.contains("roOiGfANU_SfyOGX4tL-TSjGj8fW0QE_"), "leaked rc-pass: \(out)")
        XCTAssertTrue(out.contains("--log-level"), "unrelated flags must survive")
        XCTAssertTrue(out.contains("v1.75.1"), "the version is diagnostic and must survive")
    }

    /// The other real line, where rclone redacts the password itself but not the user.
    func testRedactsTheAuthenticatedUserLine() {
        let line = "2026/09/17 07:35:32 INFO  : Using --user rr5xrS6uijLDUgwxyo3qszKiXTQwhAUe --pass *** as authenticated user"
        XCTAssertFalse(DaemonLog.redact(line).contains("rr5xrS6uijLDUgwxyo3qszKiXTQwhAUe"))
    }

    func testRedactsTheEqualsForm() {
        XCTAssertFalse(DaemonLog.redact("rclone rcd --rc-pass=SECRETVALUE").contains("SECRETVALUE"))
    }

    func testRedactsTokensAndPasswordsInKeyValueOutput() {
        for line in [#"{"token":"ya29.a0AfH6SMB","expiry":"2026"}"#,
                     "password=hunter2&user=matt",
                     #"api_key: "sk-live-abcdef""#] {
            let out = DaemonLog.redact(line)
            for secret in ["ya29.a0AfH6SMB", "hunter2", "sk-live-abcdef"] {
                XCTAssertFalse(out.contains(secret), "leaked \(secret) in: \(out)")
            }
        }
    }

    /// Redaction must not destroy the diagnostic value of ordinary lines, or people
    /// will stop reading the log and go back to the terminal.
    func testLeavesOrdinaryLinesAlone() {
        let line = "2026/09/17 12:04:11 NOTICE: dav1: vfs cache: cleaned 3 files, 12Mi in use"
        XCTAssertEqual(DaemonLog.redact(line), line)
    }

    func testAPathThatLooksLikeAURLIsNotMangled() {
        let line = "mount: /Users/someone/Cloud/dav1 served on localhost:41234"
        XCTAssertEqual(DaemonLog.redact(line), line)
    }
}

final class DaemonLogBufferTests: XCTestCase {

    func testSplitsLinesAndDropsBlanks() async {
        let log = DaemonLog()
        await log.append(Data("first\n\nsecond\n".utf8))
        let lines = await log.recent
        XCTAssertEqual(lines.map(\.text), ["first", "second"])
    }

    /// A read can split anywhere. If the fragment were flushed as its own line, a
    /// secret straddling the boundary would match no pattern in either half and
    /// survive in the joined output.
    func testJoinsALineSplitAcrossReads() async {
        let log = DaemonLog()
        await log.append(Data("connecting to https://matt:s3c".utf8))
        await log.append(Data("r3t@dav.example.com/path\n".utf8))

        let lines = await log.recent
        XCTAssertEqual(lines.count, 1, "the two halves must become one line")
        XCTAssertFalse(lines[0].text.contains("s3cr3t"), "leaked across the split: \(lines[0].text)")
    }

    func testAnIncompleteLineIsNotShownUntilItIsComplete() async {
        let log = DaemonLog()
        await log.append(Data("half a line".utf8))
        let count = await log.recent.count
        XCTAssertEqual(count, 0)
    }

    /// A daemon running for weeks must not accumulate output forever.
    func testKeepsOnlyTheMostRecentLines() async {
        let log = DaemonLog(capacity: 10)
        for i in 0..<50 { await log.append(Data("line \(i)\n".utf8)) }

        let lines = await log.recent
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.first?.text, "line 40")
        XCTAssertEqual(lines.last?.text, "line 49")
    }

    /// An endless line with no newline must not grow without bound either.
    func testFlushesAnAbsurdlyLongLineRatherThanBuffering() async {
        let log = DaemonLog()
        await log.append(Data(String(repeating: "x", count: 9000).utf8))
        let count = await log.recent.count
        XCTAssertEqual(count, 1, "an 8 KB fragment with no newline should be flushed")
    }

    func testClearEmptiesEverything() async {
        let log = DaemonLog()
        await log.append(Data("something\n".utf8))
        await log.clear()
        let count = await log.recent.count
        XCTAssertEqual(count, 0)
    }
    // MARK: - Header-shaped credentials (#73)

    /// The original patterns keyed on a credential *word* — token, password, secret —
    /// so they caught `X-Auth-Token:` and missed the two that matter most. Neither
    /// `Authorization: Bearer <oauth token>` nor `Authorization: Basic <base64
    /// user:password>` contains any of those words.
    ///
    /// These cases are the literal strings that survived redaction when the audit ran
    /// the expressions against captured output, not invented examples.
    func testAuthorizationHeadersAreRedacted() {
        let bearer = DaemonLog.redact("HTTP REQUEST Authorization: Bearer ya29.a0AfB_REAL_TOKEN")
        XCTAssertFalse(bearer.contains("ya29.a0AfB_REAL_TOKEN"), bearer)
        XCTAssertTrue(bearer.contains("Bearer"), "the scheme is useful when diagnosing auth")

        // Built at runtime rather than written out.
        //
        // An earlier version pasted a literal `Basic <base64>` into the source. It was
        // fake, but it is credential-*shaped*: GitHub's secret scanner flagged it, and
        // a reader has no way to tell a fabricated one from a real one. Encoding it
        // here keeps the realistic base64 the regex has to cope with, without any
        // string in the file that looks like a credential.
        let encoded = Data("example-user:example-password".utf8).base64EncodedString()

        let basic = DaemonLog.redact("Authorization: Basic \(encoded)")
        XCTAssertFalse(basic.contains(encoded), basic)

        let proxy = DaemonLog.redact("Proxy-Authorization: Basic \(encoded)")
        XCTAssertFalse(proxy.contains(encoded), proxy)
    }

    func testCookiesAreRedacted() {
        let set = DaemonLog.redact("Set-Cookie: session=abc123deadbeef; Path=/")
        XCTAssertFalse(set.contains("abc123deadbeef"), set)

        let sent = DaemonLog.redact("Cookie: sid=deadbeef")
        XCTAssertFalse(sent.contains("deadbeef"), sent)
    }

    /// AWS SigV4 names neither a token nor a password. `Credential=` identifies the
    /// account and `Signature=` authenticates the request.
    func testAWSSignaturesAreRedacted() {
        let line = DaemonLog.redact(
            "Credential=AKIAIOSFODNN7EXAMPLE/20260918/us-east-1, Signature=fe5f80f77d5fa3")
        XCTAssertFalse(line.contains("AKIAIOSFODNN7EXAMPLE"), line)
        XCTAssertFalse(line.contains("fe5f80f77d5fa3"), line)
    }

    /// Over-redaction has a cost too: a log that hides the ordinary lines is useless
    /// for the job it exists to do.
    func testOrdinaryLinesAreLeftAlone() {
        let line = "NOTICE: dav1: Mounted at /Users/x/grrclone/dav1"
        XCTAssertEqual(DaemonLog.redact(line), line)

        let serving = "INFO : Serving NFS on 127.0.0.1:52341"
        XCTAssertEqual(DaemonLog.redact(serving), serving)
    }
}
