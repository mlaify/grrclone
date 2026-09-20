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

    /// The rc API's own trace, captured verbatim from rclone 1.75.1 at DEBUG after
    /// driving `config/create`, `config/update` and `config/unlock` over the socket.
    ///
    /// These lines are what the review found leaking (#109): `pass:` is not a word
    /// any earlier pattern names, and Go's `map[k:v]` form is not one any earlier
    /// pattern parses, so the wizard's password reached the log in clear text. The
    /// `configPassword:` line was already redacted — only because "configPassword"
    /// happens to contain "password", which is luck rather than design.
    func testRedactsTheRcParameterTraceRcloneActuallyEmits() {
        let create = "2026/09/19 16:28:59 DEBUG : rc: \"config/create\": with parameters map[name:w opt:map[nonInteractive:true obscure:true] parameters:map[pass:hunter2-plain url:https://x.example user:u] type:webdav]"
        let update = "2026/09/19 16:28:59 DEBUG : rc: \"config/update\": with parameters map[name:w opt:map[nonInteractive:true obscure:true] parameters:map[pass:hunter2-updated]]"
        let unlock = "2026/09/19 16:28:59 DEBUG : rc: \"config/unlock\": with parameters map[configPassword:secretpw-unlock]"

        for (line, secret) in [(create, "hunter2-plain"), (update, "hunter2-updated"),
                               (unlock, "secretpw-unlock")] {
            let out = DaemonLog.redact(line)
            XCTAssertFalse(out.contains(secret), "leaked \(secret): \(out)")
            XCTAssertTrue(out.contains("rc: \"config/"), "the method name is the diagnosis: \(out)")
        }
    }

    /// Replies carry the stored config back, obscured — one `rclone reveal` from
    /// plaintext — so they are payload too. The error at the end of a reply line is
    /// the one part worth keeping, and it is kept.
    func testRedactsConfigRepliesButKeepsTheMethodAndTheError() {
        let dump = "DEBUG : rc: \"config/dump\": reply map[dav1:map[pass:AbCdEfObscured type:webdav url:https://dav.example]]: <nil>"
        let out = DaemonLog.redact(dump)
        XCTAssertFalse(out.contains("AbCdEfObscured"), out)
        XCTAssertTrue(out.hasSuffix("rc: \"config/dump\": reply ***: <nil>"), out)

        // A failure's reason is the one part of a reply worth keeping. Codex
        // pointed out the first version removed it along with the map.
        let failed = "DEBUG : rc: \"config/create\": reply map[Error: Option:<nil>]: config name contains invalid characters"
        let kept = DaemonLog.redact(failed)
        XCTAssertTrue(kept.hasSuffix("reply ***: config name contains invalid characters"), kept)

        // A reply that is not map-shaped is not trusted; it is redacted whole.
        let odd = "DEBUG : rc: \"config/get\": reply something unexpected pass:x"
        XCTAssertTrue(DaemonLog.redact(odd).hasSuffix("reply ***"), DaemonLog.redact(odd))
    }

    /// A trace longer than the flush limit arrives in fragments. Only the first
    /// carries the `rc: "config/` prefix; the rest would have been stored as
    /// ordinary text, which for a large `config/dump` reply is most of the secrets.
    /// Codex found this on review of the first version.
    func testAnOverLongSensitiveLineIsNotLeakedInFragments() async {
        let log = DaemonLog()
        let secret = "SERVICE-ACCOUNT-SECRET-\(UUID().uuidString)"
        // Head fragment, well past the flush limit, then the tail with the secret,
        // then the newline that ends the logical line, then an ordinary line.
        let head = "DEBUG : rc: \"config/dump\": reply map[gdrive:map[service_account_credentials:"
            + String(repeating: "A", count: DaemonLog.flushLimit + 100)
        await log.append(Data(head.utf8))
        await log.append(Data((String(repeating: "B", count: DaemonLog.flushLimit + 100)).utf8))
        await log.append(Data("\(secret) type:drive]]: <nil>\n2026/09/19 16:29:00 NOTICE : ordinary line after\n".utf8))

        let stored = await log.recent.map(\.text).joined(separator: "\n")
        XCTAssertFalse(stored.contains(secret), "a later fragment leaked: \(stored.suffix(200))")
        XCTAssertFalse(stored.contains("BBBB"), "middle fragments must be dropped, not stored")
        XCTAssertTrue(stored.contains("rc: \"config/dump\": reply ***"), "the head is kept, redacted")
        XCTAssertTrue(stored.contains("ordinary line after"), "dropping must stop at the next record")
    }

    /// A trace is one record but not always one line: Go prints a string value
    /// raw, so a PEM key or a service-account JSON blob spans physical lines, and
    /// only the first carries the prefix. Everything until the next timestamped
    /// record is part of the trace and must go with it. Codex found this on the
    /// fourth review.
    func testAMultiLineValueInsideATraceIsDroppedWithIt() async {
        let log = DaemonLog()
        let keyLine = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC-FAKE-KEY-LINE"
        let trace = "2026/09/19 16:28:59 DEBUG : rc: \"config/create\": with parameters map[name:g parameters:map[service_account_credentials:{\"type\": \"service_account\",\n"
            + "  \"private_key\": \"-----BEGIN PRIVATE KEY-----\n\(keyLine)\n-----END PRIVATE KEY-----\"} ] type:drive]\n"
            + "2026/09/19 16:29:00 NOTICE : next record\n"
        await log.append(Data(trace.utf8))
        let stored = await log.recent.map(\.text)
        XCTAssertFalse(stored.joined().contains(keyLine), "a continuation line leaked: \(stored)")
        XCTAssertFalse(stored.joined().contains("private_key"), stored.joined(separator: " | "))
        XCTAssertEqual(stored.count, 2, "the redacted head and the next record, nothing between: \(stored)")
        XCTAssertEqual(stored.last, "2026/09/19 16:29:00 NOTICE : next record")
    }

    /// The two pipes interleave. A complete stdout line arriving while stderr is
    /// mid-way through an over-long sensitive trace must be stored as itself, and
    /// must not be taken for the end of that trace — which is what let the real
    /// tail through when the state was shared. Codex found this on the second
    /// review.
    func testAnotherStreamsLineDoesNotEndASensitiveLine() async {
        let log = DaemonLog()
        let secret = "INTERLEAVED-SECRET-\(UUID().uuidString)"
        let head = "DEBUG : rc: \"config/dump\": reply map[gdrive:map[service_account_credentials:"
            + String(repeating: "A", count: DaemonLog.flushLimit + 100)
        await log.append(Data(head.utf8), from: .stderr)
        await log.append(Data("NOTICE : stdout says hello\n".utf8), from: .stdout)
        await log.append(Data("\(secret) type:drive]]: <nil>\n2026/09/19 16:29:00 NOTICE : stderr after\n".utf8), from: .stderr)

        let stored = await log.recent.map(\.text)
        XCTAssertFalse(stored.joined().contains(secret), "the tail leaked past a line from the other pipe: \(stored)")
        XCTAssertTrue(stored.contains("NOTICE : stdout says hello"), "the other pipe's line is kept intact")
        XCTAssertTrue(stored.contains("NOTICE : stderr after"), "dropping stops at stderr's own newline")
    }

    /// Ordinary interleaving, with nothing sensitive: each stream's partial line is
    /// its own, so a stdout fragment is never glued onto a stderr one.
    func testStreamsAssembleTheirOwnLines() async {
        let log = DaemonLog()
        await log.append(Data("INFO : err-part-one ".utf8), from: .stderr)
        await log.append(Data("INFO : out-whole\n".utf8), from: .stdout)
        await log.append(Data("err-part-two\n".utf8), from: .stderr)
        let stored = await log.recent.map(\.text)
        XCTAssertEqual(stored, ["INFO : out-whole", "INFO : err-part-one err-part-two"])
    }

    /// An over-long line that is *not* sensitive is still flushed in pieces, as
    /// before: the fix must not turn every long line into nothing.
    func testAnOverLongOrdinaryLineIsStillKept() async {
        let log = DaemonLog()
        let long = "INFO : listing " + String(repeating: "x", count: DaemonLog.flushLimit + 50)
        await log.append(Data(long.utf8))
        await log.append(Data(" tail\n".utf8))
        let stored = await log.recent.map(\.text)
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored[1].contains("tail"))
    }

    /// A non-config call whose parameters block carries a secret — `serve/start`
    /// for a WebDAV server with `user`/`pass`, or a backend command — is redacted
    /// from the parameters block onward and no earlier, so the method and the
    /// leading arguments survive.
    func testRedactsParametersBlocksOnOtherRcCalls() {
        let line = "DEBUG : rc: \"backend/command\": with parameters map[command:x fs:s3: parameters:map[secret_access_key:wJalrXUtnFEMI]]"
        let out = DaemonLog.redact(line)
        XCTAssertFalse(out.contains("wJalrXUtnFEMI"), out)
        XCTAssertTrue(out.contains("fs:s3:"), "leading arguments are diagnostic: \(out)")
    }

    /// `serve/start` and `vfs/stats` carry no credentials and are the lines someone
    /// reads to see why a mount failed. They must come through untouched.
    func testLeavesCredentialFreeRcCallsAlone() {
        let line = "DEBUG : rc: \"serve/start\": with parameters map[addr:localhost:0 fs:dav1: type:nfs vfs_cache_mode:full]"
        XCTAssertEqual(DaemonLog.redact(line), line)
        let stats = "DEBUG : rc: \"vfs/stats\": reply map[diskCache:map[uploadsQueued:0]]: <nil>"
        XCTAssertEqual(DaemonLog.redact(stats), stats)
    }

    /// The short backend keys are word-bounded: `keychain:` and `bypass:` are not
    /// secrets, `key:` and `pass:` are.
    func testShortSecretKeysAreWordBounded() {
        XCTAssertFalse(DaemonLog.redact("sftp: key=PRIVATEKEYDATA").contains("PRIVATEKEYDATA"))
        XCTAssertFalse(DaemonLog.redact("pass: p4ssw0rd").contains("p4ssw0rd"))
        let ordinary = "NOTICE : keychain: item found, bypass: false"
        XCTAssertEqual(DaemonLog.redact(ordinary), ordinary)
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
