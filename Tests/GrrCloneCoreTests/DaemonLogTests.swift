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
}
