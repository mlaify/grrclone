import Foundation
import Darwin

/// Reads the live mount table.
///
/// Used only to answer "is this path I already know I own still mounted?". It is never
/// used to decide ownership: see `MountRegistry` for why that distinction matters.
///
/// The kernel is queried directly through `getmntinfo(3)` rather than by parsing
/// `mount(8)` output. That output is genuinely ambiguous — its `<source> on <mountpoint>
/// (<options>)` shape cannot be split reliably when a mount point contains " on ", as
/// `~/My Files on Cloud` does. A unit test caught exactly that case truncating a path to
/// `Cloud`, which would have made grrclone fail to recognise a mount it owns.
public enum SystemMounts {
    public struct MountEntry: Sendable, Equatable {
        public let source: String
        public let mountPoint: String
        public let fileSystemType: String

        public init(source: String, mountPoint: String, fileSystemType: String = "") {
            self.source = source
            self.mountPoint = mountPoint
            self.fileSystemType = fileSystemType
        }

        /// An NFS mount served from this machine. True for grrclone's mounts *and* for
        /// any the user made themselves, which is precisely why this cannot imply
        /// ownership.
        public var isLoopbackNFS: Bool {
            fileSystemType == "nfs" && (source == "localhost:/" || source.hasPrefix("localhost:"))
        }
    }

    /// Snapshot of every mounted filesystem.
    ///
    /// `MNT_NOWAIT` returns cached kernel state instead of asking each filesystem to
    /// refresh its statistics. That matters here: a request that reaches a wedged NFS
    /// mount can block indefinitely, and this is called during startup reconciliation
    /// when exactly such a mount is likely to be present.
    public static func current() async throws -> [MountEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return MountEntry(
                source: string(from: &entry.f_mntfromname),
                mountPoint: string(from: &entry.f_mntonname),
                fileSystemType: string(from: &entry.f_fstypename))
        }
    }

    public static func isMounted(_ path: String) async -> Bool {
        guard let entries = try? await current() else { return false }
        return entries.contains { $0.mountPoint == path }
    }

    /// Converts one of statfs's fixed-size `CChar` tuples into a String.
    private static func string<T>(from tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    /// Parses `mount(8)` text output. Retained only for tests and for diagnostics against
    /// captured fixtures — the live path uses `current()`. Splits on the FIRST " on ",
    /// since a mount point may contain that sequence but a device or host spec will not.
    public static func parse(_ output: String) -> [MountEntry] {
        output.split(separator: "\n").compactMap { line -> MountEntry? in
            let text = String(line)
            guard let optionsStart = text.lastIndex(of: "("), text.hasSuffix(")") else { return nil }

            let beforeOptions = text[text.startIndex..<optionsStart]
                .trimmingCharacters(in: .whitespaces)
            let options = String(text[text.index(after: optionsStart)..<text.index(before: text.endIndex)])

            guard let onRange = beforeOptions.range(of: " on ") else { return nil }
            let source = String(beforeOptions[beforeOptions.startIndex..<onRange.lowerBound])
            let mountPoint = String(beforeOptions[onRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, !mountPoint.isEmpty else { return nil }

            // mount(8) lists the filesystem type first in the option list.
            let type = options.split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return MountEntry(source: source, mountPoint: mountPoint, fileSystemType: type)
        }
    }
}
