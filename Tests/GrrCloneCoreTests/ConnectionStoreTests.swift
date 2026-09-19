import XCTest
@testable import GrrCloneCore

final class ConnectionStoreTests: XCTestCase {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grrclone-store-\(UUID().uuidString).json")
    }

    func testAdoptsRemotesOnFirstRun() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConnectionStore(fileURL: url)
        let added = try await store.adoptNewRemotes(["dav1", "vaults"])
        XCTAssertEqual(added.count, 2)

        let all = await store.all
        XCTAssertEqual(Set(all.map(\.remote)), ["dav1", "vaults"])
    }

    /// Adoption must be idempotent. rclone.conf is read on every launch, so a second run
    /// that re-added the same remotes would duplicate every connection each time.
    func testAdoptionIsIdempotent() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConnectionStore(fileURL: url)
        _ = try await store.adoptNewRemotes(["dav1"])
        let second = try await store.adoptNewRemotes(["dav1"])

        XCTAssertTrue(second.isEmpty)
        let all = await store.all
        XCTAssertEqual(all.count, 1)
    }

    func testAdoptsOnlyRemotesThatAreNew() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConnectionStore(fileURL: url)
        _ = try await store.adoptNewRemotes(["dav1"])
        let added = try await store.adoptNewRemotes(["dav1", "vaults"])

        XCTAssertEqual(added.map(\.remote), ["vaults"])
    }

    /// Display names become directory names under the mount root, so a collision would
    /// point two connections at one mount point and the second would fail to mount.
    func testDisplayNameCollisionsAreDisambiguated() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConnectionStore(fileURL: url)
        try await store.upsert(Connection(remote: "other", displayName: "dav1"))
        let added = try await store.adoptNewRemotes(["dav1"])

        XCTAssertEqual(added.first?.displayName, "dav1 2")
        let names = await store.all.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "display names must stay unique")
    }

    func testUpsertReplacesRatherThanAppends() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConnectionStore(fileURL: url)
        var connection = Connection(remote: "dav1", displayName: "Cloud")
        try await store.upsert(connection)

        connection.displayName = "Renamed"
        connection.options.readOnly = true
        try await store.upsert(connection)

        let all = await store.all
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.displayName, "Renamed")
        XCTAssertEqual(all.first?.options.readOnly, true)
    }

    func testSettingsSurviveRelaunch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let id: UUID
        do {
            let store = ConnectionStore(fileURL: url)
            var connection = Connection(remote: "dav1", displayName: "Cloud")
            connection.connectAtLogin = true
            connection.options.vfsCacheMaxSize = "50G"
            id = connection.id
            try await store.upsert(connection)
        }

        let reloaded = ConnectionStore(fileURL: url)
        let restored = await reloaded.connection(id: id)
        XCTAssertEqual(restored?.connectAtLogin, true)
        XCTAssertEqual(restored?.options.vfsCacheMaxSize, "50G")
    }

    func testRemoveDeletesTheConnection() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConnectionStore(fileURL: url)
        let connection = Connection(remote: "dav1")
        try await store.upsert(connection)
        try await store.remove(id: connection.id)

        let all = await store.all
        XCTAssertTrue(all.isEmpty)
    }

    func testMissingFileLoadsAsEmptyRatherThanThrowing() async {
        let store = ConnectionStore(fileURL: temporaryURL())
        let all = await store.all
        XCTAssertTrue(all.isEmpty)
    }
}

// MARK: - #112, #113

extension ConnectionStoreTests {

    /// The name is the mount folder. Two connections resolving to one folder is
    /// how the second came to overwrite the first's ownership record (#112).
    func testUpsertRefusesADuplicateDisplayName() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)

        let a = Connection(remote: "dav1", displayName: "Cloud")
        var b = Connection(remote: "box", displayName: "Box")
        try await store.upsert(a)
        try await store.upsert(b)

        b.displayName = "Cloud"
        do {
            try await store.upsert(b)
            XCTFail("a second connection named Cloud must be refused")
        } catch let conflict as ConnectionStore.Conflict {
            XCTAssertEqual(conflict, .displayNameTaken("Cloud", by: "dav1"))
            XCTAssertTrue(conflict.localizedDescription.contains("mount folder"),
                          "must say why the name matters: \(conflict.localizedDescription)")
        }

        let names = await store.all.map(\.displayName)
        XCTAssertEqual(Set(names), ["Cloud", "Box"], "the refused save must not have taken")
    }

    /// Re-saving a connection under its own name is an edit, not a collision.
    func testUpsertAcceptsAConnectionKeepingItsOwnName() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(fileURL: url)

        var a = Connection(remote: "dav1", displayName: "Cloud")
        try await store.upsert(a)
        a.options.readOnly = true
        try await store.upsert(a)   // must not throw: an edit, not a collision
        let saved = await store.connection(id: a.id)
        XCTAssertEqual(saved?.options.readOnly, true)
    }

    /// An unreadable store is reported and moved aside, never read as empty and
    /// then overwritten by the adoption that follows (#113).
    func testAnUnreadableStoreIsQuarantinedNotOverwritten() async throws {
        let url = temporaryURL()
        let dir = url.deletingLastPathComponent()
        let stem = url.lastPathComponent
        defer {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where item.hasPrefix(stem) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(item))
            }
        }
        let original = Data("{ not the connections you are looking for".utf8)
        try original.write(to: url)

        let store = ConnectionStore(fileURL: url)
        let failure = await store.loadFailure
        let all = await store.all

        XCTAssertNotNil(failure, "a corrupt store must be reported, not treated as empty")
        XCTAssertTrue(all.isEmpty)
        let aside = try XCTUnwrap(failure?.quarantinedAt)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("\(stem).unreadable-"), aside.path)
        XCTAssertEqual(try Data(contentsOf: aside), original,
                       "the unreadable file must survive byte for byte where a person can find it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "and be out of the way of the next write")

        // The adoption that follows at startup writes a fresh file beside it.
        _ = try await store.adoptNewRemotes(["dav1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: aside), original, "adoption must not touch the quarantined file")
    }

    /// A schema change is the realistic trigger: a record missing a field that the
    /// decoder requires. It must be treated as unreadable, not as no connections.
    func testAStoreMissingARequiredFieldIsUnreadable() async throws {
        let url = temporaryURL()
        let dir = url.deletingLastPathComponent(), stem = url.lastPathComponent
        defer {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where item.hasPrefix(stem) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(item))
            }
        }
        try Data(#"[{"id":"\#(UUID().uuidString)","remote":"dav1"}]"#.utf8).write(to: url)
        let store = ConnectionStore(fileURL: url)
        let failure = await store.loadFailure
        XCTAssertNotNil(failure)
    }
}
