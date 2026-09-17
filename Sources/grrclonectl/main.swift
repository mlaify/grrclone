import Foundation
import GrrCloneCore
import RcloneRC

// Headless harness for GrrCloneCore. Everything the menu-bar app will do, driven from a
// terminal, so the core can be exercised and debugged without any UI in the way.

func usage() -> Never {
    print("""
    grrclonectl — headless harness for the grrclone core

    USAGE
      grrclonectl remotes                     list remotes from rclone.conf
      grrclonectl mounts                      show what grrclone owns, and what it does not
      grrclonectl connect <remote> [name]     serve and mount a remote under ~/grrclone
      grrclonectl disconnect <name>           unmount and stop serving
      grrclonectl bwlimit [rate]              show or set the transfer limit (e.g. 10M, 1M:100k, off)
      grrclonectl reconcile                   clean up orphans from an unclean shutdown
      grrclonectl recovery-test <remote>      connect, kill the server, verify self-repair
      grrclonectl drain-test <remote>         write a large file, verify uploads are tracked
      grrclonectl quit-safety-test <remote>   kill the daemon mid-upload, verify we warn
      grrclonectl doctor                      check the environment

    Mounts land in ~/grrclone/<name>. Nothing outside grrclone's own records is ever
    unmounted; see `mounts` for the distinction.
    """)
    exit(1)
}

func makeSupervisor() throws -> DaemonSupervisor {
    guard let binary = DaemonSupervisor.locateBinary() else {
        FileHandle.standardError.write(Data("No rclone binary found.\n".utf8))
        exit(1)
    }
    return DaemonSupervisor(binary: binary)
}

func makeManager() throws -> (ConnectionManager, DaemonSupervisor) {
    let supervisor = try makeSupervisor()
    let registry = MountRegistry(fileURL: MountRegistry.defaultURL())
    return (ConnectionManager(supervisor: supervisor, registry: registry), supervisor)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

do {
    switch command {

    case "doctor":
        let binary = DaemonSupervisor.locateBinary()
        print("rclone binary:  \(binary?.path ?? "NOT FOUND")")
        guard binary != nil else { exit(1) }
        let supervisor = try makeSupervisor()
        let client = try await supervisor.start()
        let version = try await client.version()
        let minimum = RcloneRCClient.Version.minimumSupported
        print("rclone version: \(version.version)")
        print("minimum needed: \(minimum.0).\(minimum.1).\(minimum.2)  "
              + (version.meetsMinimum ? "OK" : "TOO OLD"))
        print("control socket: \(await supervisor.socketPath ?? "-")")
        let remotes = try await client.listRemotes()
        print("remotes:        \(remotes.isEmpty ? "none" : remotes.joined(separator: ", "))")
        await supervisor.stop()

    case "remotes":
        let supervisor = try makeSupervisor()
        let client = try await supervisor.start()
        let types = try await client.remoteTypes()
        for name in try await client.listRemotes().sorted() {
            print("\(name)\t\(types[name] ?? "?")")
        }
        await supervisor.stop()

    case "bwlimit":
        let supervisor = try makeSupervisor()
        let client = try await supervisor.start()
        let limit: RcloneRCClient.Bandwidth
        if arguments.count > 1 {
            limit = try await client.setBandwidthLimit(arguments[1])
        } else {
            limit = try await client.bandwidthLimit()
        }
        func describe(_ bytes: Int) -> String {
            bytes < 0 ? "unlimited" : "\(bytes) B/s"
        }
        print("rate     \(limit.rate)")
        print("upload   \(describe(limit.upload))")
        print("download \(describe(limit.download))")
        await supervisor.stop()

    case "mounts":
        let registry = MountRegistry(fileURL: MountRegistry.defaultURL())
        let owned = await registry.all
        print("Owned by grrclone (\(owned.count)):")
        if owned.isEmpty { print("  none") }
        for entry in owned {
            let live = await SystemMounts.isMounted(entry.mountPoint)
            print("  \(entry.mountPoint)  [\(entry.transport)]  \(live ? "mounted" : "stale record")")
        }
        let (manager, _) = try makeManager()
        let foreign = await manager.foreignLookalikes()
        print("\nLoopback NFS mounts grrclone does NOT own (\(foreign.count)):")
        if foreign.isEmpty { print("  none") }
        for path in foreign { print("  \(path)   <- left alone, not ours") }

    case "connect":
        guard arguments.count >= 2 else { usage() }
        let remote = arguments[1].hasSuffix(":") ? String(arguments[1].dropLast()) : arguments[1]
        let name = arguments.count >= 3 ? arguments[2] : remote
        let (manager, _) = try makeManager()
        let connection = Connection(remote: remote, displayName: name)
        print("Serving \(connection.fsSpec) and mounting...")
        let mount = try await manager.connect(connection)
        print("Mounted at \(mount.mountPoint.path)")
        print("Disconnect with:  grrclonectl disconnect \(name)")

    case "disconnect":
        guard arguments.count >= 2 else { usage() }
        let name = arguments[1]
        let registry = MountRegistry(fileURL: MountRegistry.defaultURL())
        let target = ConnectionManager.defaultMountRoot()
            .appendingPathComponent(name, isDirectory: true).path
        guard let entry = await registry.entry(forMountPoint: target) else {
            print("grrclone does not own a mount at \(target). Leaving it alone.")
            exit(1)
        }
        // A separate process cannot reuse the original manager's in-memory state, so
        // unmount directly from the recorded entry.
        try await NFSTransport().unmount(at: URL(fileURLWithPath: entry.mountPoint))
        try await registry.forget(mountPoint: entry.mountPoint)
        print("Unmounted \(entry.mountPoint)")
        print("Note: its rclone server exits with the daemon that started it.")

    case "reconcile":
        let (manager, supervisor) = try makeManager()
        let report = try await manager.reconcileOrphans()
        print("cleaned:      \(report.cleaned.isEmpty ? "none" : report.cleaned.joined(separator: ", "))")
        print("still stuck:  \(report.stillMounted.isEmpty ? "none" : report.stillMounted.joined(separator: ", "))")
        let foreign = await manager.foreignLookalikes()
        print("not ours:     \(foreign.isEmpty ? "none" : foreign.joined(separator: ", "))")
        await supervisor.stop()

    case "recovery-test":
        // Integration test for the path that matters most on a laptop: a mount whose
        // server has died must be detected and rebuilt, not left hanging Finder.
        guard arguments.count >= 2 else { usage() }
        let remote = arguments[1].hasSuffix(":") ? String(arguments[1].dropLast()) : arguments[1]
        let (manager, supervisor) = try makeManager()
        let connection = Connection(remote: remote, displayName: "recovery-test")

        print("1. connecting…")
        let mount = try await manager.connect(connection)
        print("   mounted at \(mount.mountPoint.path)")

        print("2. probing while healthy…")
        let before = await MountHealth.probe(mount.mountPoint)
        print("   \(before)")
        guard before == .healthy else {
            print("   FAIL: a fresh mount should be healthy"); exit(1)
        }

        print("3. killing the rclone daemon out from under the mount…")
        // By PID from our own record, never `pkill -f <pattern>`. A pattern broad enough
        // to match the daemon also matches any shell whose command line merely mentions
        // it — including the one running this test, which is exactly what happened the
        // first time and killed the harness instead of the daemon.
        let pidFile = DaemonPidFile(
            url: DaemonPidFile.defaultURL(runtimeDirectory: DaemonSupervisor.defaultRuntimeDirectory()))
        guard let record = pidFile.read() else {
            print("   FAIL: no daemon pid on record"); exit(1)
        }
        print("   killing pid \(record.pid)")
        kill(record.pid, SIGKILL)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        print("4. probing the broken mount (must not hang)…")
        let start = Date()
        let after = await MountHealth.probe(mount.mountPoint, timeout: 5)
        print("   \(after) after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")

        print("5. repairing…")
        let report = await manager.checkHealth()
        if !report.repaired.isEmpty {
            print("   REPAIRED")
        } else if !report.failed.isEmpty {
            print("   FAILED: \(report.failed.values.joined(separator: "; "))")
        } else {
            print("   nothing to do — mount reported healthy")
        }

        print("6. verifying the repaired mount is usable…")
        let final = await MountHealth.probe(mount.mountPoint)
        print("   \(final)")

        print("7. cleaning up…")
        await manager.shutdown()
        await supervisor.stop()
        print(final == .healthy ? "RESULT: recovery works" : "RESULT: recovery FAILED")

    case "drain-test":
        // Verifies the quit-safety path: a write must be visible as pending until it has
        // actually reached the provider, and shutdown must wait for it.
        guard arguments.count >= 2 else { usage() }
        let remote = arguments[1].hasSuffix(":") ? String(arguments[1].dropLast()) : arguments[1]
        let (manager, _) = try makeManager()
        let connection = Connection(remote: remote, displayName: "drain-test")

        print("1. connecting…")
        let mount = try await manager.connect(connection)

        print("2. writing 64 MB through the mount…")
        let payload = Data(repeating: 0x67, count: 64 * 1024 * 1024)
        let target = mount.mountPoint.appendingPathComponent(".grrclone-drain-probe")
        try payload.write(to: target)
        print("   write() returned — this is the dangerous moment: Finder now shows the")
        print("   file as saved, but it may exist only in the local cache.")

        let immediately = await manager.activity()
        print("3. pending uploads immediately after write: \(immediately.pendingUploads)")

        print("4. draining…")
        let started = Date()
        let stranded = await manager.drainUploads(timeout: 180) { pending in
            print("   \(pending) remaining…")
        }
        print("   drained in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, "
              + "stranded: \(stranded)")

        print("5. cleaning up…")
        try? FileManager.default.removeItem(at: target)
        _ = await manager.drainUploads(timeout: 60)
        await manager.shutdown()

        print(stranded == 0 && immediately.pendingUploads > 0
              ? "RESULT: pending uploads are tracked and drained correctly"
              : "RESULT: CHECK — pending=\(immediately.pendingUploads) stranded=\(stranded)")

    case "quit-safety-test":
        // The adversarial case. A daemon that dies holding queued uploads answers
        // nothing, and the danger is that silence reads as "all clear" — reassurance
        // at the moment it is least warranted. This asserts we report unknown instead.
        guard arguments.count >= 2 else { usage() }
        let remote = arguments[1].hasSuffix(":") ? String(arguments[1].dropLast()) : arguments[1]
        let (manager, supervisor) = try makeManager()
        let connection = Connection(remote: remote, displayName: "quit-safety-test")
        var failures: [String] = []

        print("1. connecting…")
        let mount = try await manager.connect(connection)

        print("2. baseline: an idle mount must be known-idle…")
        let idle = await manager.activity()
        print("   isKnownIdle=\(idle.isKnownIdle) pending=\(idle.pendingUploads) unknown=\(idle.hasUnknownState)")
        if !idle.isKnownIdle { failures.append("a freshly connected idle mount was not known-idle") }

        print("3. queueing a large upload…")
        let payload = Data(repeating: 0x71, count: 96 * 1024 * 1024)
        let target = mount.mountPoint.appendingPathComponent(".grrclone-quit-probe")
        try payload.write(to: target)
        let queued = await manager.activity()
        print("   pending=\(queued.pendingUploads) isKnownIdle=\(queued.isKnownIdle)")
        if queued.pendingUploads == 0 { failures.append("a 96 MB write registered no pending upload") }
        if queued.isKnownIdle { failures.append("pending uploads were reported as idle") }

        print("4. killing the daemon while that upload is still queued…")
        let pidFile = DaemonPidFile(
            url: DaemonPidFile.defaultURL(runtimeDirectory: DaemonSupervisor.defaultRuntimeDirectory()))
        guard let record = pidFile.read() else { print("   FAIL: no daemon pid"); exit(1) }
        kill(record.pid, SIGKILL)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        print("5. THE TEST: what do we tell the user now?")
        let dead = await manager.activity()
        print("   pending=\(dead.pendingUploads) unknown=\(dead.hasUnknownState) isKnownIdle=\(dead.isKnownIdle)")
        if dead.isKnownIdle {
            failures.append("a dead daemon holding a queued upload was reported as safe to quit")
        }
        if !dead.hasUnknownState {
            failures.append("a dead daemon was not reported as unknown state")
        }

        print("6. draining must not claim success against a dead daemon…")
        let stranded = await manager.drainUploads(timeout: 8)
        print("   drainUploads reported \(stranded) outstanding")
        if stranded == 0 { failures.append("drain reported everything finished against a dead daemon") }

        print("7. cleaning up…")
        _ = await manager.shutdown(drainTimeout: 0)
        await supervisor.stop()

        if failures.isEmpty {
            print("RESULT: quit safety holds — silence is reported as unknown, not as safe")
        } else {
            print("RESULT: FAILED")
            for f in failures { print("  - \(f)") }
            exit(1)
        }

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
