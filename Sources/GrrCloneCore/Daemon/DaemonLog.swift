import Foundation

/// Keeps the daemon's recent output so a failed mount can be diagnosed without a
/// terminal.
///
/// **This also fixes a hang.** rclone's output went to a `Pipe` that nothing read.
/// A pipe holds about 64 KB, and a process writing to a full pipe *blocks* — verified
/// directly: a child writing 20,000 lines to an undrained pipe was still stuck five
/// seconds later. At `NOTICE` that buffer takes a long time to fill, which is why this
/// has not bitten yet, but a daemon having a bad day is exactly when it logs most and
/// exactly when freezing it takes every mount with it. Draining the pipe is therefore
/// not a side effect of showing logs; it is the point.
///
/// Bounded on purpose. A long-running daemon must not accumulate output forever, so
/// only the most recent lines are kept.
public actor DaemonLog {

    public struct Line: Sendable, Identifiable, Equatable {
        public let id: UInt64
        public let text: String
        public let received: Date
    }

    private var lines: [Line] = []
    private var nextID: UInt64 = 0
    private var partial = ""
    private let capacity: Int

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    /// Append raw bytes read from the daemon's stdout or stderr.
    ///
    /// A read can split a line anywhere, so the trailing fragment is held over until
    /// the rest of it arrives. Without that, a log line could be redacted in two
    /// halves and a secret straddling the boundary would survive in neither half's
    /// pattern but in the joined output.
    public func append(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        partial += text

        var pieces = partial.components(separatedBy: "\n")
        partial = pieces.removeLast()

        for piece in pieces where !piece.trimmingCharacters(in: .whitespaces).isEmpty {
            record(piece)
        }

        // A very long line with no newline must not grow without bound.
        if partial.count > 8192 {
            record(partial)
            partial = ""
        }
    }

    private func record(_ raw: String) {
        lines.append(Line(id: nextID, text: DaemonLog.redact(raw), received: Date()))
        nextID += 1
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    public var recent: [Line] { lines }

    public func clear() {
        lines.removeAll()
        partial = ""
    }

    /// Remove credentials before a line is stored.
    ///
    /// Redacting on the way in rather than on the way out, so a secret is never held
    /// in memory in the clear and cannot escape through a future caller that forgets
    /// to sanitise. This project promises not to leak user data, and a log viewer with
    /// a copy button is a very easy way to break that promise by accident.
    ///
    /// Handles what rclone actually emits: credentials embedded in URLs, and the
    /// control-socket credentials if a command line is ever echoed.
    static func redact(_ line: String) -> String {
        var result = line

        // scheme://user:secret@host  →  scheme://user:***@host
        result = result.replacingOccurrences(
            of: "([a-zA-Z][a-zA-Z0-9+.-]*://[^\\s:/@]+):[^\\s@/]+@",
            with: "$1:***@",
            options: .regularExpression)

        // Credential flags, in every shape rclone actually prints them.
        //
        // The first version of this matched only `--rc-pass VALUE` and missed the real
        // thing entirely: rclone echoes its own command line as
        // `"--rc-pass" "roOiGfANU…"`, with each argument quoted, so the pattern never
        // fired and the control-socket credentials sat in the log in clear text. Found
        // by reading actual DEBUG output rather than the invented example the first
        // test was written against.
        result = result.replacingOccurrences(
            of: "(--(?:rc-user|rc-pass|user|pass|password|api-key)\"?(?:\\s*=\\s*|\"?\\s+)\"?)[^\\s\"]+",
            with: "$1***",
            options: .regularExpression)

        // token=…, password=…, secret=… in query strings or JSON-ish output.
        result = result.replacingOccurrences(
            of: "(?i)((?:token|password|secret|api_key|apikey)[\"']?\\s*[:=]\\s*[\"']?)[^\\s,\"'}&]+",
            with: "$1***",
            options: .regularExpression)

        // Whole-value headers.
        //
        // The patterns above key on a credential *word*, which is why they caught
        // `X-Auth-Token:` and missed the two that matter most: `Authorization: Bearer
        // <oauth token>` and `Authorization: Basic <base64 user:password>`. Neither
        // contains "token", "password" or "secret" anywhere, so both passed through
        // untouched — verified by running these expressions against captured header
        // lines rather than invented ones.
        //
        // The scheme is kept and everything after it replaced: knowing a request used
        // Bearer is useful when diagnosing an auth failure, and the credential never
        // is. `Proxy-Authorization` is covered by the same pattern.
        result = result.replacingOccurrences(
            of: "(?i)((?:proxy-)?authorization\\s*:\\s*)(\\S+)(\\s+\\S+)?",
            with: "$1$2 ***",
            options: .regularExpression)

        // Cookies carry session material and no useful diagnostic detail.
        result = result.replacingOccurrences(
            of: "(?i)((?:set-)?cookie\\s*:\\s*).+",
            with: "$1***",
            options: .regularExpression)

        // AWS SigV4, which names neither a token nor a password. The access key id in
        // `Credential=` identifies the account and the signature authenticates the
        // request; neither belongs in a log a user is invited to copy.
        result = result.replacingOccurrences(
            of: "(?i)\\b(Signature|Credential|X-Amz-Signature|X-Amz-Credential)(=)[^\\s,&]+",
            with: "$1$2***",
            options: .regularExpression)

        return result
    }
}
