import Foundation

/// What rclone's local cache still owes the storage provider.
///
/// `--vfs-cache-mode full` makes a write return as soon as the bytes are on local
/// disk. Finder shows the file as saved while nothing has reached the remote, and
/// rclone uploads it in the background. So the cache can hold the only copy of a
/// file, and anything that throws the cache away has to know that first.
public struct PendingUploads: Sendable, Equatable {
    /// Paths, relative to the remote, whose cached copy has not been uploaded.
    public var dirtyFiles: [String]

    /// True when the cache could not be read, so the answer is unknown.
    ///
    /// Tracked separately because "we could not look" is not "there is nothing
    /// there". Collapsing the two is what makes a safety check fail open, and it
    /// would do so at the worst moment: a cache we cannot parse is more likely to be
    /// one in a strange state than one that is empty.
    public var inspectionFailed: Bool

    public init(dirtyFiles: [String] = [], inspectionFailed: Bool = false) {
        self.dirtyFiles = dirtyFiles
        self.inspectionFailed = inspectionFailed
    }

    /// Only true when the cache was read successfully *and* held nothing pending.
    public var isSafeToDiscard: Bool { dirtyFiles.isEmpty && !inspectionFailed }

    public var count: Int { dirtyFiles.count }
}

/// Where rclone keeps a remote's cached data, and what it says about it.
///
/// Read from disk rather than asked of the daemon. `vfs/stats` is the better answer
/// when a remote is mounted, but a remote being deleted is usually *not* mounted, in
/// which case the daemon has no VFS for it and would truthfully report nothing
/// pending for a cache that is full of unsent writes.
public enum VFSCache {

    /// rclone's own name for a filesystem, as it appears under the cache root.
    ///
    /// The colon in `remote:path` becomes a path separator, so `dav1:` caches under
    /// `dav1` and `dav1:photos/2024` under `dav1/photos/2024`. Verified against a
    /// live cache directory rather than inferred.
    public static func cacheSubpath(forFS fsSpec: String) -> String {
        var path = fsSpec.replacingOccurrences(of: ":", with: "/")
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The JSON companions, one per cached file, that carry the `Dirty` flag.
    public static func metadataDirectory(cacheRoot: URL, fsSpec: String) -> URL {
        cacheRoot.appendingPathComponent("vfsMeta/\(cacheSubpath(forFS: fsSpec))")
    }

    /// The cached file contents themselves.
    public static func dataDirectory(cacheRoot: URL, fsSpec: String) -> URL {
        cacheRoot.appendingPathComponent("vfs/\(cacheSubpath(forFS: fsSpec))")
    }

    /// Everything in this remote's cache that has not reached the provider.
    ///
    /// The `Dirty` flag is the authority. An earlier attempt at this counted files in
    /// the cache directory and reported 28 pending uploads for a cache in which every
    /// single one had already been uploaded — a warning that cries wolf is a warning
    /// people learn to click through.
    public static func pendingUploads(cacheRoot: URL, fsSpec: String,
                                      fileManager: FileManager = .default) -> PendingUploads {
        let root = metadataDirectory(cacheRoot: cacheRoot, fsSpec: fsSpec)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            // No metadata directory means rclone never cached anything for this
            // remote. That is a real, safe answer, not a failure to look.
            return PendingUploads()
        }
        guard isDirectory.boolValue else {
            return PendingUploads(inspectionFailed: true)
        }

        // No `.skipsHiddenFiles`. A remote's dotfiles are ordinary files — `.env`,
        // anything under `.git/` — and their metadata lives under a matching dotted
        // path here. Skipping them would report a cache as safe while a dirty
        // `.env` sat in it, and purge the only copy.
        guard let walker = fileManager.enumerator(at: root,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: []) else {
            return PendingUploads(inspectionFailed: true)
        }

        var dirty: [String] = []
        var failed = false
        let prefix = root.standardizedFileURL.path

        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }

            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // A metadata file we cannot read might describe a dirty item. Refusing
                // to guess is the whole point.
                failed = true
                continue
            }
            if object["Dirty"] as? Bool == true {
                var relative = url.standardizedFileURL.path
                if relative.hasPrefix(prefix) { relative.removeFirst(prefix.count) }
                dirty.append(relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
            }
        }
        return PendingUploads(dirtyFiles: dirty.sorted(), inspectionFailed: failed)
    }

    /// Remove a remote's cached data and metadata.
    ///
    /// Callers must have established that nothing is pending. This deletes the only
    /// copy of anything still dirty.
    public static func purge(cacheRoot: URL, fsSpec: String,
                             fileManager: FileManager = .default) throws {
        for directory in [dataDirectory(cacheRoot: cacheRoot, fsSpec: fsSpec),
                          metadataDirectory(cacheRoot: cacheRoot, fsSpec: fsSpec)] {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try fileManager.removeItem(at: directory)
        }
    }
}
