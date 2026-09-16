import Foundation

/// Tracks the rclone daemon grrclone started, so an orphan from an unclean shutdown can
/// be identified and reaped instead of being silently abandoned.
///
/// Without this, a second launch removes the existing control socket and creates its
/// own. The first daemon keeps running, still serving every mount it created, but is now
/// unreachable — nothing can stop it or its servers, and the mounts it backs cannot be
/// cleanly unmounted. That was observed during M1 development: two daemons, one socket.
///
/// Identification is deliberately stricter than a PID comparison. PIDs are reused, so a
/// recorded PID alone is not evidence: the process must still be an rclone daemon *and*
/// its command line must reference the exact socket path we recorded. Anything else is
/// treated as an unrelated process and left alone, on the same principle that governs
/// `MountRegistry`.
public struct DaemonPidFile: Sendable {
    public struct Record: Codable, Sendable {
        public let pid: Int32
        public let socketPath: String
        public let startedAt: Date
    }

    private let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL(runtimeDirectory: URL) -> URL {
        runtimeDirectory.appendingPathComponent("daemon.pid")
    }

    public func write(pid: Int32, socketPath: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Record(pid: pid, socketPath: socketPath, startedAt: Date()))
        try data.write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    public func read() -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    /// Terminate a previously recorded daemon if, and only if, it is provably still ours.
    /// Returns the PID reaped, or nil if there was nothing to reap.
    @discardableResult
    public func reapOrphan() async -> Int32? {
        guard let record = read() else { return nil }

        guard await Self.isOurDaemon(pid: record.pid, socketPath: record.socketPath) else {
            // Either gone, or the PID now belongs to something else entirely. Either way
            // the record is stale and killing anything would be wrong.
            clear()
            return nil
        }

        kill(record.pid, SIGTERM)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if kill(record.pid, 0) != 0 { break }
        }
        if kill(record.pid, 0) == 0 { kill(record.pid, SIGKILL) }

        clear()
        try? FileManager.default.removeItem(atPath: record.socketPath)
        return record.pid
    }

    /// True only if the PID is live, is an rclone process, and its command line names the
    /// socket we recorded. All three are required: PID reuse makes the first two alone
    /// insufficient to prove identity.
    static func isOurDaemon(pid: Int32, socketPath: String) async -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        guard let result = try? await Shell.run("/bin/ps", ["-p", String(pid), "-o", "command="],
                                                timeout: 5),
              result.succeeded else { return false }
        let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.contains("rclone") && command.contains(socketPath)
    }
}
