import Foundation

/// The daemon-wide transfer rate limit.
///
/// One rclone daemon serves every connection, and `core/bwlimit` sets a single limit
/// for that process, so the limit is global rather than per-connection. That is not a
/// simplification — rclone has no way to express a per-server rate through this API.
///
/// Applies to the running daemon immediately: no restart, no remount, and transfers in
/// flight are throttled from the moment it is set.
extension RcloneRCClient {

    public struct Bandwidth: Sendable, Equatable {
        /// What rclone reports the limit as, e.g. `"off"`, `"1Mi"`, `"1Mi:100Ki"`.
        public let rate: String
        /// Upload limit in bytes per second, or -1 for unlimited.
        public let upload: Int
        /// Download limit in bytes per second, or -1 for unlimited.
        public let download: Int

        public var isLimited: Bool { upload >= 0 || download >= 0 }
    }

    /// The limit currently in force.
    public func bandwidthLimit() async throws -> Bandwidth {
        try Self.bandwidth(from: try await call("core/bwlimit"))
    }

    /// Set the limit. `"off"` removes it.
    ///
    /// Accepts rclone's own syntax, including an `upload:download` pair. Invalid input
    /// is rejected by rclone with a message such as `bad bwlimit: bad suffix 'a'`, and
    /// — verified against 1.75.1 — **the previous limit is left in force** rather than
    /// being cleared, so a typo cannot accidentally unthrottle a connection.
    @discardableResult
    public func setBandwidthLimit(_ rate: String) async throws -> Bandwidth {
        let trimmed = rate.trimmingCharacters(in: .whitespaces)
        let wanted = trimmed.isEmpty ? "off" : trimmed
        return try Self.bandwidth(from: try await call("core/bwlimit", ["rate": .string(wanted)]))
    }

    static func bandwidth(from value: JSONValue) throws -> Bandwidth {
        guard let rate = value["rate"]?.stringValue else {
            throw RcloneRCError.unexpectedResponse("core/bwlimit returned no rate")
        }
        // Tx is upload and Rx is download, from the daemon's point of view. Read those
        // rather than `bytesPerSecond`, which carries only the upload half of a pair.
        return Bandwidth(rate: rate,
                         upload: value["bytesPerSecondTx"]?.intValue ?? -1,
                         download: value["bytesPerSecondRx"]?.intValue ?? -1)
    }
}

/// Runtime options.
extension RcloneRCClient {

    /// Change how much the daemon logs, without restarting it.
    ///
    /// `--log-level` is a launch flag, but the same setting is reachable at runtime
    /// through `options/set`. That distinction matters: restarting the daemon to turn
    /// on verbose logging would unmount every volume, which is an absurd price for
    /// looking at a log — and would very likely destroy the transient failure the user
    /// was trying to diagnose.
    public func setLogLevel(_ level: String) async throws {
        _ = try await call("options/set", ["main": .object(["LogLevel": .string(level)])])
    }
}
