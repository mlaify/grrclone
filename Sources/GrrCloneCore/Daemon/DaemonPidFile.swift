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
    public struct Record: Codable, Sendable, Equatable {
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

    /// The recorded daemon, if it is provably still ours and therefore safe to kill.
    ///
    /// Split from the kill itself so a caller can act in between. That gap is not a
    /// convenience: an orphaned daemon is still serving live NFS mounts, and killing
    /// it before those come down leaves the kernel talking to a dead server. See
    /// `DaemonSupervisor.orphanCleanup`.
    ///
    /// A record that does not identify a live daemon of ours is cleared as stale and
    /// nil returned, so callers cannot act on it.
    public enum Reapable: Sendable {
        /// Nothing recorded, or the record is provably stale. Safe to proceed.
        case nothingToReap
        /// A daemon of ours that is still running.
        case orphan(Record)
        /// A recorded PID we could not identify. Proceeding would risk orphaning a
        /// live daemon, so the caller must not.
        case undetermined(Record)
    }

    public func reapableOrphan() async -> Reapable {
        guard let record = read() else { return .nothingToReap }

        switch await Self.identify(pid: record.pid, socketPath: record.socketPath) {
        case .ours:
            return .orphan(record)
        case .notOurs:
            // Gone, or the PID belongs to something else entirely. Either way the
            // record is stale and killing anything would be wrong.
            clear()
            return .nothingToReap
        case .unknown:
            // Deliberately keeps the record. Clearing it here is what would lose
            // track of a daemon that may well still be running.
            return .undetermined(record)
        }
    }

    /// Terminate a daemon confirmed by `reapableOrphan()`, revalidating first.
    ///
    /// Returns the PID killed, or nil if it is no longer ours.
    ///
    /// **The recheck is the point.** Splitting identify-then-kill so an unmount can
    /// happen in between opened a window that did not exist before: unmounting a
    /// wedged volume can take a minute, and in that time the orphan can exit and its
    /// PID be reused. Signalling the recorded PID on the strength of a check made
    /// before the unmount would eventually kill an unrelated process — the same PID
    /// reuse hazard `isOurDaemon` exists to close, reintroduced by the fix for it.
    @discardableResult
    public func reap(_ record: Record) async -> Int32? {
        switch await Self.identify(pid: record.pid, socketPath: record.socketPath) {
        case .ours:
            break
        case .notOurs:
            // It exited on its own, or the PID is someone else's now. Either way there
            // is nothing of ours to kill, and the record is spent.
            clear()
            try? FileManager.default.removeItem(atPath: record.socketPath)
            return nil
        case .unknown:
            // Neither kill nor forget. A signal sent on a guess could hit a stranger,
            // and clearing the record would lose the only pointer to a daemon that
            // may still be running.
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

    /// Identify and terminate in one step, with nothing in between.
    ///
    /// Only for callers that own no mounts. Anything that might have mounts served by
    /// this daemon must use `reapableOrphan()` and `reap(_:)` with an unmount between
    /// them.
    @discardableResult
    public func reapOrphan() async -> Int32? {
        guard case .orphan(let record) = await reapableOrphan() else { return nil }
        return await reap(record)
    }

    /// True only if the PID is live, is an rclone process, and its command line names the
    /// socket we recorded. All three are required: PID reuse makes the first two alone
    /// insufficient to prove identity.
    /// What we were able to establish about a recorded PID.
    public enum Identity: Sendable, Equatable {
        /// Live, an rclone, and its command line names our socket.
        case ours
        /// Definitely not ours: gone, or the PID belongs to something else.
        case notOurs
        /// Could not be determined — `ps` did not answer.
        case unknown
    }

    /// Identify a recorded PID, distinguishing "not ours" from "could not tell".
    ///
    /// The distinction is the whole point. This previously returned `Bool` and
    /// collapsed a failed `ps` into `false`, i.e. "not our daemon" — and both callers
    /// treat that as a stale record, clear it, delete the socket and start a fresh
    /// daemon. So a `ps` that was merely slow would orphan a live daemon *permanently*,
    /// still serving mounts with nothing able to reach or stop it: precisely the
    /// failure this type exists to prevent, caused by the check meant to prevent it.
    ///
    /// Found via a test that failed about two runs in five, taking 10.6 seconds — 5s
    /// for the `ps` timeout plus 5s for the assertion's own wait.
    static func identify(pid: Int32, socketPath: String) async -> Identity {
        guard kill(pid, 0) == 0 else { return .notOurs }

        // Retried once, because the observed failure was a transient timeout under
        // load rather than a persistent inability to run `ps`.
        for attempt in 0..<2 {
            guard let result = try? await Shell.run(
                "/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 10) else {
                if attempt == 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
                continue
            }
            // A non-zero exit from `ps -p` means no such process, which is an answer.
            guard result.succeeded else { return .notOurs }
            let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.contains("rclone") && command.contains(socketPath)
                ? .ours : .notOurs
        }
        return .unknown
    }
}
