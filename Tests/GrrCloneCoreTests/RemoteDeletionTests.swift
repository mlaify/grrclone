import XCTest
@testable import GrrCloneCore

/// Deleting a remote, and the four ways it could lose data.
///
/// The point of these is not that deletion works. It is that no data is lost and no
/// *other* remote is affected — which is why most of them assert about something the
/// deletion was supposed to leave alone.
final class RemoteDeletionTests: XCTestCase {

    private var dir: URL!
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grrclone-delete-\(UUID().uuidString)")
        cacheRoot = dir.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Reading the cache

    /// rclone turns the colon of `remote:path` into a path separator. Checked
    /// against a live cache directory, not inferred.
    func testCacheSubpathMatchesRcloneLayout() {
        XCTAssertEqual(VFSCache.cacheSubpath(forFS: "dav1:"), "dav1")
        XCTAssertEqual(VFSCache.cacheSubpath(forFS: "dav1:photos/2024"), "dav1/photos/2024")
        XCTAssertEqual(VFSCache.cacheSubpath(forFS: "box:"), "box")
    }

    private func writeMeta(fs: String, path: String, dirty: Bool) throws {
        let file = VFSCache.metadataDirectory(cacheRoot: cacheRoot, fsSpec: fs)
            .appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("""
        {"ModTime":"2026-09-18T00:00:00Z","Size":4096,"Fingerprint":"4096","Dirty":\(dirty)}
        """.utf8).write(to: file)
    }

    /// No cache directory is a real answer — rclone never cached anything — and must
    /// not be confused with a failure to look.
    func testNoCacheMeansNothingPending() {
        let pending = VFSCache.pendingUploads(cacheRoot: cacheRoot, fsSpec: "dav1:")
        XCTAssertTrue(pending.isSafeToDiscard)
        XCTAssertFalse(pending.inspectionFailed)
    }

    /// The `Dirty` flag is the authority. Counting cached files instead reported 28
    /// pending uploads for a cache in which every one had already been sent.
    func testOnlyDirtyFilesCount() throws {
        try writeMeta(fs: "dav1:", path: "holiday.jpg", dirty: false)
        try writeMeta(fs: "dav1:", path: "notes/todo.md", dirty: true)
        try writeMeta(fs: "dav1:", path: "archive/old.zip", dirty: false)

        let pending = VFSCache.pendingUploads(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertEqual(pending.dirtyFiles, ["notes/todo.md"])
        XCTAssertFalse(pending.isSafeToDiscard)
    }

    /// A metadata file we cannot parse might describe a dirty item.
    func testUnparseableMetadataIsReportedAsUnknown() throws {
        try writeMeta(fs: "dav1:", path: "fine.jpg", dirty: false)
        let broken = VFSCache.metadataDirectory(cacheRoot: cacheRoot, fsSpec: "dav1:")
            .appendingPathComponent("broken.jpg")
        try Data("{ not json".utf8).write(to: broken)

        let pending = VFSCache.pendingUploads(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertTrue(pending.inspectionFailed,
                      "an unreadable metadata file must not read as 'nothing pending'")
        XCTAssertFalse(pending.isSafeToDiscard)
    }

    /// Dotfiles are ordinary files on a remote, and their cache metadata lives under
    /// a matching dotted path. An enumerator with `.skipsHiddenFiles` walked straight
    /// past them, so a dirty `.env` reported the cache as safe to purge.
    func testDirtyDotfilesAreNotSkipped() throws {
        try writeMeta(fs: "dav1:", path: "visible.txt", dirty: false)
        try writeMeta(fs: "dav1:", path: ".env", dirty: true)

        let pending = VFSCache.pendingUploads(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertEqual(pending.dirtyFiles, [".env"])
        XCTAssertFalse(pending.isSafeToDiscard)
    }

    /// The same for anything beneath a dot-directory, which is the `.git/` case.
    func testDirtyFilesInsideDotDirectoriesAreNotSkipped() throws {
        try writeMeta(fs: "dav1:", path: ".git/config", dirty: true)

        let pending = VFSCache.pendingUploads(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertEqual(pending.dirtyFiles, [".git/config"])
    }

    /// One remote's cache must not answer for another's.
    func testCachesAreScopedPerRemote() throws {
        try writeMeta(fs: "dav1:", path: "pending.txt", dirty: true)
        try writeMeta(fs: "box:", path: "clean.txt", dirty: false)

        XCTAssertFalse(VFSCache.pendingUploads(cacheRoot: cacheRoot, fsSpec: "dav1:").isSafeToDiscard)
        XCTAssertTrue(VFSCache.pendingUploads(cacheRoot: cacheRoot, fsSpec: "box:").isSafeToDiscard)
    }

    /// Purging one remote must leave the others' caches alone.
    func testPurgeRemovesOnlyThatRemotesCache() throws {
        try writeMeta(fs: "dav1:", path: "a.txt", dirty: false)
        try writeMeta(fs: "box:", path: "b.txt", dirty: false)
        let boxMeta = VFSCache.metadataDirectory(cacheRoot: cacheRoot, fsSpec: "box:")

        try VFSCache.purge(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VFSCache.metadataDirectory(cacheRoot: cacheRoot, fsSpec: "dav1:").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: boxMeta.path),
                      "box's cache is not dav1's to delete")
    }

    // MARK: - The configuration backup

    func testBackupIsByteIdenticalAndBesideTheOriginal() throws {
        let config = dir.appendingPathComponent("rclone.conf")
        let contents = "[dav1]\ntype = webdav\nuser = alice\npass = obscured\n"
        try contents.write(to: config, atomically: true, encoding: .utf8)

        let backup = try ConfigBackup.make(configPath: config.path)

        XCTAssertEqual(backup.deletingLastPathComponent(), config.deletingLastPathComponent(),
                       "a backup you cannot find is not a backup")
        XCTAssertEqual(try Data(contentsOf: backup), try Data(contentsOf: config))
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("rclone.conf.grrclone-backup-"))
    }

    /// An encrypted config is opaque, so byte equality is the only claim worth making
    /// — and the only one that matters, since it is what allows a restore.
    func testBackupPreservesAnEncryptedConfigExactly() throws {
        let config = dir.appendingPathComponent("rclone.conf")
        let sealed = "# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nZm9v\n"
        try sealed.write(to: config, atomically: true, encoding: .utf8)

        let backup = try ConfigBackup.make(configPath: config.path)

        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), sealed)
        XCTAssertTrue(ConfigEncryption.isEncrypted(configPath: backup.path),
                      "the backup of an encrypted config is still an encrypted config")
    }

    /// A backup of a credential file must not be more readable than the original.
    func testBackupIsNotWorldReadable() throws {
        let config = dir.appendingPathComponent("rclone.conf")
        try "[dav1]\ntype = webdav\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: config.path)

        let backup = try ConfigBackup.make(configPath: config.path)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value & 0o077, 0,
                       "the backup must not be readable by group or other")
    }

    /// Two deletions in the same second must not have the second overwrite the first.
    func testBackupsDoNotCollide() throws {
        let config = dir.appendingPathComponent("rclone.conf")
        try "[dav1]\n".write(to: config, atomically: true, encoding: .utf8)
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try ConfigBackup.make(configPath: config.path, now: fixed)
        let second = try ConfigBackup.make(configPath: config.path, now: fixed)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testBackupFailsLoudlyWhenTheConfigIsUnreadable() {
        XCTAssertThrowsError(
            try ConfigBackup.make(configPath: dir.appendingPathComponent("nope.conf").path))
    }
    // MARK: - Cache usage (#84)

    private func writeCachedFile(fs: String, path: String, bytes: Int) throws {
        let file = VFSCache.dataDirectory(cacheRoot: cacheRoot, fsSpec: fs)
            .appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: file)
    }

    func testUsageCountsDataAndMetadata() throws {
        try writeCachedFile(fs: "dav1:", path: "a.bin", bytes: 4096)
        try writeCachedFile(fs: "dav1:", path: "sub/b.bin", bytes: 4096)
        try writeMeta(fs: "dav1:", path: "a.bin", dirty: false)

        let usage = VFSCache.usage(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertEqual(usage.fileCount, 3, "two cached files plus one metadata file")
        XCTAssertGreaterThanOrEqual(usage.bytes, 8192)
        XCTAssertTrue(usage.isSafeToPurge)
    }

    func testUsageOfAnEmptyCacheIsZeroAndSafe() {
        let usage = VFSCache.usage(cacheRoot: cacheRoot, fsSpec: "dav1:")
        XCTAssertEqual(usage.bytes, 0)
        XCTAssertEqual(usage.fileCount, 0)
        XCTAssertTrue(usage.isSafeToPurge, "nothing cached is nothing to lose")
    }

    /// The interlock. A dirty entry is the only copy of that file, so the cache it
    /// sits in is not free disk space.
    func testCacheWithAnUnsentFileIsNotSafeToPurge() throws {
        try writeCachedFile(fs: "dav1:", path: "draft.txt", bytes: 128)
        try writeMeta(fs: "dav1:", path: "draft.txt", dirty: true)

        let usage = VFSCache.usage(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertFalse(usage.isSafeToPurge)
        XCTAssertEqual(usage.pending.dirtyFiles, ["draft.txt"])
    }

    /// Unknown is not permission here either.
    func testCacheThatCannotBeReadIsNotSafeToPurge() throws {
        try writeCachedFile(fs: "dav1:", path: "a.bin", bytes: 128)
        let broken = VFSCache.metadataDirectory(cacheRoot: cacheRoot, fsSpec: "dav1:")
            .appendingPathComponent("a.bin")
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken)

        XCTAssertFalse(VFSCache.usage(cacheRoot: cacheRoot, fsSpec: "dav1:").isSafeToPurge)
    }

    /// Sparse files must be measured by what purging would actually reclaim.
    ///
    /// rclone preallocates for partial downloads, so a half-fetched 4 GB video has a
    /// logical size of 4 GB and occupies far less. Reporting the logical size would
    /// promise disk space that clearing the cache will not give back.
    func testSparseFilesAreMeasuredByAllocatedSize() throws {
        let file = VFSCache.dataDirectory(cacheRoot: cacheRoot, fsSpec: "dav1:")
            .appendingPathComponent("sparse.bin")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1 << 30)   // a 1 GiB hole, nothing written
        try handle.close()

        let usage = VFSCache.usage(cacheRoot: cacheRoot, fsSpec: "dav1:")

        XCTAssertLessThan(usage.bytes, 1 << 30,
                          "a sparse file must not be reported at its logical size")
    }
}
