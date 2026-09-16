import Foundation
import Network

/// Minimal HTTP/1.1 client speaking over a unix domain socket.
///
/// grrclone binds rclone's remote-control API to a unix socket rather than a TCP port
/// so that access is governed by filesystem permissions and nothing is reachable over
/// the network, not even loopback. `URLSession` cannot address unix sockets, hence this.
///
/// Only what the rc API needs is implemented: POST with a JSON body, Basic auth, and
/// responses delimited by `Content-Length`.
public actor UnixSocketHTTP {
    public enum Failure: Error, LocalizedError {
        case connectionFailed(String)
        case timedOut
        case malformedResponse(String)
        case http(status: Int, body: String)

        public var errorDescription: String? {
            switch self {
            case .connectionFailed(let d): return "Could not connect to the rclone control socket: \(d)"
            case .timedOut: return "The rclone control socket did not respond in time."
            case .malformedResponse(let d): return "Malformed response from rclone: \(d)"
            case .http(let status, let body): return "rclone returned HTTP \(status): \(body)"
            }
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
    public func post(path: String, body: Data) async throws -> Data {
        let connection = try makeConnection()
        defer { connection.cancel() }

        try await withTimeout { try await Self.waitUntilReady(connection) }

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

        try await withTimeout { try await Self.send(request, on: connection) }
        let raw = try await withTimeout { try await Self.receiveAll(connection) }
        return try Self.parse(raw)
    }

    // MARK: - Connection

    private func makeConnection() throws -> NWConnection {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw Failure.connectionFailed("socket \(socketPath) does not exist")
        }
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: .global(qos: .userInitiated))
        return connection
    }

    private func withTimeout<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { [timeout] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timedOut
            }
            guard let first = try await group.next() else { throw Failure.timedOut }
            group.cancelAll()
            return first
        }
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.testAndSet() { cont.resume() }
                case .failed(let error):
                    if resumed.testAndSet() { cont.resume(throwing: Failure.connectionFailed(error.localizedDescription)) }
                case .cancelled:
                    if resumed.testAndSet() { cont.resume(throwing: Failure.connectionFailed("cancelled")) }
                default:
                    break
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: Failure.connectionFailed(error.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    /// Read until the peer closes. We send `Connection: close`, so EOF delimits the body
    /// and we never have to implement chunked transfer decoding.
    private static func receiveAll(_ connection: NWConnection) async throws -> Data {
        var accumulated = Data()
        while true {
            let (chunk, isComplete) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                    data, _, isComplete, error in
                    if let error { cont.resume(throwing: Failure.connectionFailed(error.localizedDescription)) }
                    else { cont.resume(returning: (data, isComplete)) }
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

/// One-shot flag so a continuation is resumed exactly once from an NWConnection callback,
/// which can fire more than once for the states we observe.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
