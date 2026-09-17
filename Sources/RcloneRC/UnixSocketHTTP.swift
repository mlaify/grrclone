import Foundation
import Network

/// Minimal HTTP/1.1 client speaking over a unix domain socket.
///
/// grrclone binds rclone's remote-control API to a unix socket rather than a TCP port so
/// that access is governed by filesystem permissions and nothing is reachable over the
/// network, not even loopback. `URLSession` cannot address unix sockets, hence this.
///
/// Only what the rc API needs is implemented: POST with a JSON body, Basic auth, and a
/// response delimited by connection close.
public actor UnixSocketHTTP {
    public enum Failure: Error, LocalizedError {
        case connectionFailed(String)
        case timedOut
        case malformedResponse(String)
        case http(status: Int, body: String)

        public var errorDescription: String? {
            switch self {
            case .connectionFailed(let d): return "Could not reach the rclone control socket: \(d)"
            case .timedOut: return "The rclone control socket did not respond in time."
            case .malformedResponse(let d): return "Malformed response from rclone: \(d)"
            case .http(let status, let body): return "rclone: \(Failure.message(from: body, status: status))"
            }
        }

        /// Pull the human part out of an rc error response.
        ///
        /// rclone answers a bad request with a JSON object whose `error` field is the
        /// actual message and whose other fields repeat the request. Showing the whole
        /// blob was tolerable while these strings only reached a log; now that they are
        /// shown in the menu, a user asking for a bandwidth limit of "banana" should
        /// read `bad bwlimit: bad suffix 'a'`, not six lines of JSON.
        ///
        /// Falls back to the raw body, because an unparseable error is still better
        /// than no error.
        static func message(from body: String, status: Int) -> String {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = object["error"] as? String, !error.isEmpty
            else {
                return "HTTP \(status): \(body)"
            }
            return error
        }
    }

    private let socketPath: String
    private let authorization: String?
    private let timeout: TimeInterval

    public init(socketPath: String, user: String? = nil, password: String? = nil,
                timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
        if let user, let password,
           let encoded = "\(user):\(password)".data(using: .utf8)?.base64EncodedString() {
            self.authorization = "Basic \(encoded)"
        } else {
            self.authorization = nil
        }
    }

    /// POST `body` to `path` and return the raw response body.
    /// `timeoutOverride` exists for one case: an interactive config step that waits
    /// for a person. Signing in through a browser can take minutes — finding the
    /// password, approving on a phone — and the default watchdog would cancel the
    /// connection underneath a flow the user is still completing.
    public func post(path: String, body: Data,
                     timeoutOverride: TimeInterval? = nil) async throws -> Data {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw Failure.connectionFailed("socket \(socketPath) does not exist")
        }

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection.start(queue: .global(qos: .userInitiated))

        // One watchdog for the whole request. Cancelling the connection is what makes a
        // timeout real here: it forces every pending state change and every outstanding
        // send or receive callback to fire, which is the only way to unblock a connection
        // stuck in `.waiting`. Nothing else can.
        let watchdog = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (timeoutOverride ?? timeout),
                                                            execute: watchdog)
        defer {
            watchdog.cancel()
            connection.cancel()
        }

        try await Self.waitUntilReady(connection)

        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        if let authorization { head += "Authorization: \(authorization)\r\n" }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        let request = payload

        try await Self.send(request, on: connection)
        let raw = try await Self.receiveAll(connection)
        return try Self.parse(raw)
    }

    // MARK: - Connection

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = OneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { cont.resume() }

                case .failed(let error):
                    if gate.claim() {
                        cont.resume(throwing: Failure.connectionFailed(error.localizedDescription))
                    }

                case .waiting(let error):
                    // For a unix socket, `.waiting` means the listener is not there.
                    // NWConnection would retry forever; there is nothing to wait for, and
                    // failing to handle this state is what previously leaked the
                    // continuation and hung the caller past its deadline.
                    if gate.claim() {
                        cont.resume(throwing: Failure.connectionFailed(
                            "rclone is not listening on the control socket (\(error.localizedDescription))"))
                    }

                case .cancelled:
                    // Reached when the watchdog fires.
                    if gate.claim() { cont.resume(throwing: Failure.timedOut) }

                default:
                    break
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = OneShot()
            connection.send(content: data, completion: .contentProcessed { error in
                guard gate.claim() else { return }
                if let error {
                    cont.resume(throwing: Failure.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Read until the peer closes. The request sends `Connection: close`, so EOF delimits
    /// the body and chunked transfer decoding is never needed.
    private static func receiveAll(_ connection: NWConnection) async throws -> Data {
        var accumulated = Data()
        while true {
            let (chunk, isComplete) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Data?, Bool), Error>) in
                let gate = OneShot()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                    data, _, isComplete, error in
                    guard gate.claim() else { return }
                    if let error {
                        cont.resume(throwing: Failure.connectionFailed(error.localizedDescription))
                    } else {
                        cont.resume(returning: (data, isComplete))
                    }
                }
            }
            if let chunk { accumulated.append(chunk) }
            if isComplete { break }
        }
        return accumulated
    }

    // MARK: - Parsing

    static func parse(_ raw: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw Failure.malformedResponse("no header/body separator")
        }
        let headerData = raw[raw.startIndex..<range.lowerBound]
        let body = raw[range.upperBound...]

        guard let headerText = String(data: headerData, encoding: .utf8),
              let statusLine = headerText.split(separator: "\r\n").first else {
            throw Failure.malformedResponse("unreadable headers")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw Failure.malformedResponse("bad status line: \(statusLine)")
        }
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status, body: String(data: body, encoding: .utf8) ?? "")
        }
        return Data(body)
    }
}
