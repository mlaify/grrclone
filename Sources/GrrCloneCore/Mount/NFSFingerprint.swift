import Foundation

/// The mount options grrclone's own NFS mounts carry, as the kernel reports them,
/// and a reader for what is mounted now.
///
/// grrclone unmounts only what its registry records; a hand-rolled `rclone nfsmount`
/// looks identical in `mount(8)`. But mounts made by grrclone *before the registry
/// existed* are also unrecorded, and three of those stacked on `~/Cloud` took
/// `diskutil`, three `umount -f`s and a reboot to clear by hand (#105). This is the
/// evidence that lets grrclone *offer* — never decide — to clear such a mount: its
/// original options, from `nfsstat -m`, must be exactly the set this app passes.
///
/// Captured from a live machine rather than inferred. The kernel drops `nolocks`
/// (it and `locallocks` select the same lock mode) and adds `port`/`mountport`,
/// which vary per mount, so the fingerprint is the option set with those removed.
public enum NFSFingerprint {

    /// What `nfsstat -m` reports as the original options of a grrclone mount, less
    /// the per-mount ports. Kept in step with `NFSTransport.mountOptions` by a test.
    public static let expected: Set<String> = [
        "tcp", "soft", "intr", "locallocks", "nfc",
        "timeo=600", "retrans=2", "rsize=131072", "wsize=131072",
    ]

    /// Options that vary per mount, or that the kernel adds, and say nothing about
    /// who made it.
    static let ignored: Set<String> = ["rdonly"]

    public struct Entry: Sendable, Equatable {
        public let mountPoint: String
        public let source: String
        /// The `NFS parameters` under `Original mount options`, split on commas.
        public let originalOptions: Set<String>

        public init(mountPoint: String, source: String, originalOptions: Set<String>) {
            self.mountPoint = mountPoint
            self.source = source
            self.originalOptions = originalOptions
        }

        /// True when these are grrclone's options and nothing else.
        public var isGrrcloneShaped: Bool {
            NFSFingerprint.matches(originalOptions) && (source == "localhost:/" || source.hasPrefix("localhost:"))
        }
    }

    /// Exact set equality after removing the per-mount ports. One value changed —
    /// `timeo=300`, no `nfc`, an extra `resvport` — and it is somebody else's mount.
    public static func matches(_ options: Set<String>) -> Bool {
        let significant = Set(options.filter {
            !$0.hasPrefix("port=") && !$0.hasPrefix("mountport=") && !$0.hasPrefix("vers=")
                && !ignored.contains($0)
        })
        return significant == expected
    }

    /// Parse `nfsstat -m` output. Each mount is a block beginning
    /// `<path> from <source>`, and the line wanted is the `NFS parameters:` under
    /// `Original mount options`, not the one under `Current mount parameters`,
    /// which carries everything the kernel filled in.
    public static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        var path: String?
        var source: String?
        var inOriginal = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !line.hasPrefix(" "), let range = line.range(of: " from ") {
                path = String(line[..<range.lowerBound])
                source = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                inOriginal = false
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-- Original mount options") { inOriginal = true; continue }
            if trimmed.hasPrefix("-- ") { inOriginal = false; continue }
            guard inOriginal, trimmed.hasPrefix("NFS parameters:"),
                  let path, let source else { continue }
            let options = trimmed.dropFirst("NFS parameters:".count)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            entries.append(Entry(mountPoint: path, source: source, originalOptions: Set(options)))
            inOriginal = false
        }
        return entries
    }

    /// Something that reports the current NFS mounts with their original options.
    public typealias Reader = @Sendable () async throws -> [Entry]

    /// The real reader.
    public static func current() async throws -> [Entry] {
        let result = try await Shell.run("/usr/bin/nfsstat", ["-m"], timeout: 10)
        guard result.succeeded else {
            throw MountError.mountFailed("nfsstat -m failed: \(result.stderr)")
        }
        return parse(result.stdout)
    }
}
