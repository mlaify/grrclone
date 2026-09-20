import XCTest
import RcloneRC
@testable import GrrCloneCore

/// Offering to disconnect an unrecorded mount that carries grrclone's fingerprint
/// (#105). The registry stays the only ownership test; this is an offer, gated
/// three ways, confirmed by a person, and never a reason to kill anything.
final class ReclaimTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grrclone-reclaim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - The fingerprint, from captured output

    /// Verbatim from `nfsstat -m` on a machine with three grrclone mounts up,
    /// trimmed to two: one as grrclone made it, one with `timeo` changed. Note the
    /// kernel drops `nolocks` and keeps `locallocks`, and adds the ports.
    static let captured = """
    /Users/x/Cloud from localhost:/
      -- Original mount options:
         General mount flags: 0x0
         NFS parameters: tcp,port=53771,mountport=53771,soft,intr,locallocks,rsize=131072,wsize=131072,timeo=600,retrans=2,nfc
         File system locations:
           / @ localhost (::1,127.0.0.1)
      -- Current mount parameters:
         General mount flags: 0x4000018 nodev,nosuid,multilabel
         NFS parameters: vers=3,tcp,port=53771,mountport=53771,nomntudp,soft,intr,noresvport,negnamecache,callumnt,locallocks,quota,rsize=131072,wsize=131072,readahead=16,dsize=8192,rdirplus,nodumbtimer,timeo=600,retrans=2,maxgroups=16,acregmin=5,acregmax=60,acdirmin=5,acdirmax=60,acrootdirmin=5,acrootdirmax=60,nomutejukebox,nfc,sec=none:sys,accesscache=3
         File system locations:
           / @ localhost (::1,127.0.0.1)
         Current location: 0x1 0 0 1:
           / @ localhost (127.0.0.1)
         Status flags: 0x0

    /Users/x/Theirs from localhost:/
      -- Original mount options:
         General mount flags: 0x0
         NFS parameters: tcp,port=51250,mountport=51250,soft,intr,locallocks,rsize=131072,wsize=131072,timeo=300,retrans=2,nfc
         File system locations:
           / @ localhost (::1,127.0.0.1)
      -- Current mount parameters:
         General mount flags: 0x4000018 nodev,nosuid,multilabel
         NFS parameters: vers=3,tcp,port=51250,mountport=51250,soft,intr,locallocks,timeo=300,retrans=2,nfc
         Status flags: 0x0

    """

    func testParsesTheOriginalOptionsNotTheCurrentOnes() {
        let entries = NFSFingerprint.parse(Self.captured)
        XCTAssertEqual(entries.map(\.mountPoint), ["/Users/x/Cloud", "/Users/x/Theirs"])
        XCTAssertEqual(entries.map(\.source), ["localhost:/", "localhost:/"])
        XCTAssertTrue(entries[0].originalOptions.contains("port=53771"))
        XCTAssertFalse(entries[0].originalOptions.contains("vers=3"),
                       "vers=3 is in the current parameters only; the original line is the one wanted")
        XCTAssertFalse(entries[0].originalOptions.contains("readahead=16"))
    }

    func testTheExactFingerprintMatchesAndOneChangedValueDoesNot() {
        let entries = NFSFingerprint.parse(Self.captured)
        XCTAssertTrue(entries[0].isGrrcloneShaped, "the mount as grrclone made it")
        XCTAssertFalse(entries[1].isGrrcloneShaped, "timeo=300 is not ours")

        var missing = entries[0].originalOptions; missing.remove("nfc")
        XCTAssertFalse(NFSFingerprint.matches(missing), "one option missing is not ours")
        var extra = entries[0].originalOptions; extra.insert("resvport")
        XCTAssertFalse(NFSFingerprint.matches(extra), "one option added is not ours")
        var otherPorts = entries[0].originalOptions
        otherPorts.remove("port=53771"); otherPorts.insert("port=1"); otherPorts.insert("mountport=1")
        XCTAssertTrue(NFSFingerprint.matches(otherPorts), "ports vary per mount and are ignored")
    }

    /// The fingerprint is derived from what `NFSTransport` passes; if the option
    /// string changes, this must change with it, or leftovers of the *new* version
    /// would never be offered.
    func testFingerprintStaysInStepWithTheMountOptions() {
        let passed = Set(NFSTransport.mountOptions(port: 1, readOnly: false).split(separator: ",").map(String.init))
        // The kernel drops `nolocks` and the ports; everything else must be there.
        var expectedFromPassed = passed
        expectedFromPassed.remove("nolocks"); expectedFromPassed.remove("port=1"); expectedFromPassed.remove("mountport=1")
        XCTAssertEqual(expectedFromPassed, NFSFingerprint.expected)
    }

    // MARK: - The gates

    private func print_(_ path: String, source: String = "localhost:/", timeo: String = "600") -> NFSFingerprint.Entry {
        NFSFingerprint.Entry(mountPoint: path, source: source, originalOptions: [
            "tcp", "port=1", "mountport=1", "soft", "intr", "locallocks",
            "rsize=131072", "wsize=131072", "timeo=\(timeo)", "retrans=2", "nfc"])
    }

    func testOfferedOnlyWithFingerprintAndPathUnderTheRoot() {
        let roots = ["/Users/x/grrclone"]
        XCTAssertTrue(ForeignMount.isReclaimable(path: "/Users/x/grrclone/Cloud",
                                                 fingerprints: [print_("/Users/x/grrclone/Cloud")], roots: roots))
        XCTAssertFalse(ForeignMount.isReclaimable(path: "/Users/x/grrclone/Cloud",
                                                  fingerprints: [print_("/Users/x/grrclone/Cloud", timeo: "300")], roots: roots),
                       "different options: not ours")
        XCTAssertFalse(ForeignMount.isReclaimable(path: "/Users/x/grrclone/Cloud",
                                                  fingerprints: [print_("/Users/x/grrclone/Cloud", source: "nas.local:/vol")], roots: roots),
                       "not loopback: not ours")
        XCTAssertFalse(ForeignMount.isReclaimable(path: "/Users/x/Elsewhere/Cloud",
                                                  fingerprints: [print_("/Users/x/Elsewhere/Cloud")], roots: roots),
                       "outside the mount root: left alone")
        XCTAssertFalse(ForeignMount.isReclaimable(path: "/Users/x/grrclone/Cloud",
                                                  fingerprints: [], roots: roots),
                       "no fingerprint data at all: unknown is not an offer")
        XCTAssertFalse(ForeignMount.isReclaimable(path: "/Users/x/grrclone/Cloud",
                                                  fingerprints: [print_("/Users/x/grrclone/Cloud")], roots: []),
                       "no root configured: nothing is offered")
    }

    func testAStackWithOneForeignLayerIsNotOffered() {
        let path = "/Users/x/grrclone/Cloud"
        XCTAssertTrue(ForeignMount.isReclaimable(path: path, fingerprints: [print_(path), print_(path)],
                                                 roots: ["/Users/x/grrclone"]))
        XCTAssertFalse(ForeignMount.isReclaimable(path: path, fingerprints: [print_(path), print_(path, timeo: "300")],
                                                  roots: ["/Users/x/grrclone"]),
                       "one layer that is not ours means nothing at that path is touched")
    }

    func testGroupingCarriesTheOfferOncePerPath() {
        let grouped = ForeignMount.group(["/a", "/a", "/b"], reclaimable: ["/a"])
        XCTAssertEqual(grouped, [ForeignMount(path: "/a", count: 2, reclaimable: true),
                                 ForeignMount(path: "/b", count: 1, reclaimable: false)])
    }

    // MARK: - The manager

    /// Counts unmounts and pretends each one removes a layer from a scripted table.
    private final class Layers: @unchecked Sendable {
        private let lock = NSLock()
        var remaining: [String: Int]
        var unmounts = 0
        init(_ remaining: [String: Int]) { self.remaining = remaining }
        func table() -> [SystemMounts.MountEntry] {
            lock.lock(); defer { lock.unlock() }
            return remaining.flatMap { path, n in
                Array(repeating: SystemMounts.MountEntry(source: "localhost:/", mountPoint: path, fileSystemType: "nfs"), count: n)
            }
        }
        func unmountOne(_ path: String) throws {
            lock.lock(); defer { lock.unlock() }
            unmounts += 1
            let before = remaining[path, default: 0]
            guard before > 0 else { return }
            remaining[path] = before - 1
            if before > 1 {
                throw MountError.unmountFailed("Removed one of \(before) volumes stacked at \(path); \(before - 1) remain.")
            }
        }
    }

    private struct LayeredTransport: MountTransport {
        let kind: TransportKind = .nfs
        let layers: Layers
        func serveParameters(for connection: Connection, cacheRoot: URL) -> [String: JSONValue] { [:] }
        func mount(connection: Connection, server: RcloneRCClient.Server, at mountPoint: URL) async throws {}
        func unmount(at mountPoint: URL) async throws { try layers.unmountOne(mountPoint.path) }
    }

    private func manager(layers: Layers, fingerprints: [NFSFingerprint.Entry]) -> ConnectionManager {
        ConnectionManager(
            supervisor: DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"), runtimeDirectory: dir),
            registry: MountRegistry(fileURL: dir.appendingPathComponent("mounts.json")),
            transports: [LayeredTransport(layers: layers)],
            mountTable: { layers.table() },
            fingerprints: { fingerprints })
    }

    func testLookalikesAreMarkedReclaimableOnlyUnderTheRoot() async {
        let inRoot = dir.appendingPathComponent("Cloud").path
        let outside = "/Users/x/Elsewhere"
        let layers = Layers([inRoot: 3, outside: 1])
        let manager = manager(layers: layers, fingerprints: [print_(inRoot), print_(inRoot), print_(inRoot), print_(outside)])

        let found = await manager.foreignLookalikes(under: [dir.path])
        XCTAssertEqual(Set(found), [ForeignMount(path: inRoot, count: 3, reclaimable: true),
                                    ForeignMount(path: outside, count: 1, reclaimable: false)])

        let noRoot = await manager.foreignLookalikes()
        XCTAssertTrue(noRoot.allSatisfy { !$0.reclaimable }, "with no root given, nothing is offered")
    }

    /// The gates are re-checked at the moment of acting, not trusted from the
    /// menu, and a refusal runs no unmount at all.
    func testReclaimRefusesWithoutTheFingerprintAndTouchesNothing() async {
        let path = dir.appendingPathComponent("Cloud").path
        let layers = Layers([path: 2])
        let manager = manager(layers: layers, fingerprints: [print_(path, timeo: "300"), print_(path)])

        do {
            _ = try await manager.reclaimForeignMount(at: path, under: [dir.path])
            XCTFail("must refuse")
        } catch let refusal as ConnectionManager.ReclaimRefusal {
            XCTAssertEqual(refusal, .notFingerprinted(path))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(layers.unmounts, 0, "a refusal must not unmount anything")
        XCTAssertEqual(layers.remaining[path], 2)
    }

    func testReclaimRefusesARecordedPath() async throws {
        let path = dir.appendingPathComponent("Cloud").path
        let layers = Layers([path: 1])
        let registry = MountRegistry(fileURL: dir.appendingPathComponent("mounts.json"))
        try await registry.record(.init(connectionID: UUID(), mountPoint: path, transport: "nfs",
                                        serverID: nil, port: nil, pid: 1))
        let manager = ConnectionManager(
            supervisor: DaemonSupervisor(binary: URL(fileURLWithPath: "/usr/bin/false"), runtimeDirectory: dir),
            registry: registry, transports: [LayeredTransport(layers: layers)],
            mountTable: { layers.table() }, fingerprints: { [self.print_(path)] })
        do {
            _ = try await manager.reclaimForeignMount(at: path, under: [dir.path])
            XCTFail("a recorded path is a connection, not a leftover")
        } catch let refusal as ConnectionManager.ReclaimRefusal {
            XCTAssertEqual(refusal, .recorded(path))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(layers.unmounts, 0)
    }

    /// Stacked layers come off one per unmount until the table is clear — and the
    /// table, not the count of attempts, decides.
    func testReclaimTakesEveryLayerOffAndNothingElse() async throws {
        let path = dir.appendingPathComponent("Cloud").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let layers = Layers([path: 3])
        let manager = manager(layers: layers, fingerprints: [print_(path), print_(path), print_(path)])

        let removed = try await manager.reclaimForeignMount(at: path, under: [dir.path])
        XCTAssertEqual(removed, 3)
        XCTAssertEqual(layers.unmounts, 3)
        XCTAssertEqual(layers.remaining[path], 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the empty mount point is tidied away")
    }
}
