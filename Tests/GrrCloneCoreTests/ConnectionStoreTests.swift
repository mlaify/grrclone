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
