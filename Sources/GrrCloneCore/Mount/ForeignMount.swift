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
public struct ForeignMount: Sendable, Equatable, Identifiable {
    public let path: String
    public let count: Int

    public var id: String { path }

    public init(path: String, count: Int) {
        self.path = path
        self.count = count
    }

    /// Collapse repeated paths, preserving first-seen order so the list is stable
    /// between refreshes rather than reshuffling under the cursor.
    public static func group(_ paths: [String]) -> [ForeignMount] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for path in paths {
            if counts[path] == nil { order.append(path) }
            counts[path, default: 0] += 1
        }
        return order.map { ForeignMount(path: $0, count: counts[$0]!) }
    }
}
