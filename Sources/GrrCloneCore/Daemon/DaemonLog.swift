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

    /// True while the rest of an over-long *sensitive* line is still arriving.
    ///
    /// A line longer than the flush limit is recorded in fragments. The first
    /// fragment carries the `rc: "config/…"` prefix and is redacted by it; the
    /// later ones do not, and would have been stored as ordinary text — which for a
    /// `config/dump` reply on a large configuration, or a service-account JSON
    /// blob, is most of the secret. So once a flushed fragment is a sensitive
    /// trace, everything up to its newline is dropped rather than stored.
    private var droppingRestOfSensitiveLine = false

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

        for (index, piece) in pieces.enumerated() {
            if index == 0 && droppingRestOfSensitiveLine {
                // The tail of a line whose head was already flushed and redacted.
                droppingRestOfSensitiveLine = false
                continue
            }
            if !piece.trimmingCharacters(in: .whitespaces).isEmpty { record(piece) }
        }

        // A very long line with no newline must not grow without bound.
        if partial.count > Self.flushLimit {
            if droppingRestOfSensitiveLine {
                // Still inside the same sensitive line; keep dropping.
            } else if Self.isSensitiveTrace(partial) {
                record(partial)   // redacted by its prefix
                droppingRestOfSensitiveLine = true
            } else {
                record(partial)
            }
            partial = ""
        }
    }

    /// Characters an unterminated line may reach before it is flushed in pieces.
    static let flushLimit = 8192

    /// Whether a fragment begins a line whose payload must not be stored in
    /// pieces. An rc trace always carries its method within the first few dozen
    /// characters, so the head fragment is enough to decide for the whole line.
    static func isSensitiveTrace(_ fragment: String) -> Bool {
        fragment.range(of: "rc: \"config/", options: .literal) != nil
            || fragment.range(of: "\\bparameters:map\\[", options: .regularExpression) != nil
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

        // The rc API's own trace, which carries the whole request.
        //
        // At DEBUG rclone logs every rc call as
        // `rc: "config/create": with parameters map[name:w opt:map[…]
        // parameters:map[pass:hunter2 url:… user:u] type:webdav]`, and every reply as
        // `rc: "config/dump": reply map[…]`. Captured from rclone 1.75.1, not
        // supposed. The key-word patterns above missed it entirely: the password
        // sits under `pass`, which none of them name, and the value is inside Go's
        // `map[k:v k:v]` form, which none of them parse. So the wizard's password
        // and the edit sheet's replacement went into the log in clear text under a
        // tab that says passwords are removed automatically — verified before this
        // was written (#109).
        //
        // The keys are the user's backend's option names. They cannot be listed:
        // `pass`, `key`, `sas_url`, `client_id`, `account`, and whatever rclone adds
        // next month. So the payload goes, not the value. Everything after
        // `with parameters` is replaced for any `config/*` call — those are the
        // calls that carry or return credentials, obscured ones included, and
        // `rclone reveal` undoes obscuring in one step.
        result = result.replacingOccurrences(
            of: "(rc: \"config/[A-Za-z]+\": with parameters) .*$",
            with: "$1 ***",
            options: .regularExpression)

        // A reply is `reply <map>: <error>`. The map goes; the error stays, because
        // a failed `config/create` with its reason removed is a line that says only
        // that something failed. The map is a Go `map[…]` and its closing bracket is
        // the last `]` that is followed by `: `. A reply that does not have that
        // shape is redacted whole rather than trusted.
        result = result.replacingOccurrences(
            of: "(rc: \"config/[A-Za-z]+\": reply) map\\[.*\\](: .*)$",
            with: "$1 ***$2",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(rc: \"config/[A-Za-z]+\": reply) (?!\\*\\*\\*).*$",
            with: "$1 ***",
            options: .regularExpression)

        // Other rc calls carry no credentials by construction — grrclone never sends
        // any — but a backend command or a serve with `user`/`pass` would. Redact a
        // `parameters:map[…]` block wherever it appears, to the end of the line:
        // the map cannot be parsed reliably, because a value may contain `]`.
        result = result.replacingOccurrences(
            of: "(rc: \"[A-Za-z/]+\": with parameters .*?\\bparameters:map\\[).*$",
            with: "$1***",
            options: .regularExpression)

        // Bare short keys rclone's backends use for secrets, in `key:value` or
        // `key=value` form. Word-bounded, unlike the list above, because `key` and
        // `pass` are ordinary words: `keychain:` and `bypass:` must not trip this.
        result = result.replacingOccurrences(
            of: "(?i)\\b((?:pass|key|sas_url|client_id|access_key_id|secret_access_key|key_file_pass|service_principal_file)[\"']?\\s*[:=]\\s*[\"']?)[^\\s,\"'}&\\]]+",
            with: "$1***",
            options: .regularExpression)

        return result
    }
}
