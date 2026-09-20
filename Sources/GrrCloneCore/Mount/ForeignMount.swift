import Foundation

/// A loopback NFS mount grrclone can see but did not make, with how many times it
/// appears at that path.
///
/// macOS allows mounting on top of an existing mount, and a hand-rolled launchd
/// agent that retries produces exactly that: the same path mounted three times.
/// Listing the path three times is accurate and reads as a rendering bug — and, as
/// `ForEach` identities, three equal strings are undefined behaviour in SwiftUI. One
/// row saying "mounted 3 times" is both correct and the clue a user needs to
/// understand why grrclone refused to mount there.
public struct ForeignMount: Sendable, Equatable, Hashable, Identifiable {
    public let path: String
    public let count: Int
    /// True when grrclone may *offer* to disconnect it: every layer carries
    /// grrclone's exact option fingerprint, the source is loopback, and the path is
    /// under the mount root. Still not ours by the registry's rule — the offer is
    /// confirmed by the user, never acted on alone (#105).
    public let reclaimable: Bool

    public var id: String { path }

    public init(path: String, count: Int, reclaimable: Bool = false) {
        self.path = path
        self.count = count
        self.reclaimable = reclaimable
    }

    /// Collapse repeated paths, preserving first-seen order so the list is stable
    /// between refreshes rather than reshuffling under the cursor.
    public static func group(_ paths: [String], reclaimable: Set<String> = []) -> [ForeignMount] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for path in paths {
            if counts[path] == nil { order.append(path) }
            counts[path, default: 0] += 1
        }
        return order.map { ForeignMount(path: $0, count: counts[$0]!, reclaimable: reclaimable.contains($0)) }
    }

    /// Whether an unrecorded loopback mount may be offered for disconnection.
    ///
    /// Three gates, all required. Every layer at the path must carry the exact
    /// fingerprint (one layer that does not is somebody else's, and nothing at
    /// that path is touched), the source must be loopback, and the path must sit
    /// under one of `roots` — the configured mount root. A fingerprinted mount
    /// somewhere else is left alone: it may be another tool using the same options.
    public static func isReclaimable(path: String,
                                     fingerprints: [NFSFingerprint.Entry],
                                     roots: [String]) -> Bool {
        let layers = fingerprints.filter { $0.mountPoint == path }
        guard !layers.isEmpty, layers.allSatisfy(\.isGrrcloneShaped) else { return false }
        let key = Connection.folderKey(path)
        return roots.contains { root in
            let prefix = Connection.folderKey(root.hasSuffix("/") ? root : root + "/")
            return key.hasPrefix(prefix)
        }
    }
}
