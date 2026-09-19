import AppKit
import Foundation
import GrrCloneCore

/// Ensures only one grrclone runs at a time.
///
/// Two instances are not merely untidy, they corrupt each other. Both read and write
/// the same mount registry, and both supervise a daemon recorded in the same pid file,
/// so the second one starting **reaps the first one's rclone daemon** — the orphan
/// cleanup working exactly as designed, aimed at a live process. If the first instance
/// had mounts, they are now backed by a dead server and Finder hangs on every one.
///
/// This was observed: a build from `/Applications` launched alongside a development
/// build, and the newcomer killed the running daemon within seconds.
///
/// It is easy to hit by accident. Launching from Finder while a copy is already running
/// normally just activates the existing app, but that guarantee does not hold across
/// two different copies of the bundle, which is precisely the situation during an
/// upgrade or after dragging a new version into `/Applications`.
@MainActor
enum SingleInstance {

    /// True if this process should continue. False means another instance owns the
    /// shared state and this one must exit without touching it.
    static func acquire() -> Bool {
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "org.mlaify.grrclone")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        guard let existing = others.first else { return true }

        // Wait for it, rather than giving up on it.
        //
        // The case this exists for is an upgrade, and an upgrade is exactly when the
        // old copy is mid-teardown: `applicationShouldTerminate` returns
        // `.terminateLater` and the quit path can run for minutes — draining
        // uploads, unmounting, stopping the daemon. Refusing on sight meant the new
        // copy silently terminated itself during that window, which reads as the new
        // version being broken.
        //
        // Bounded, because an instance wedged forever must not wedge the launch too.
        if waitForExit(of: existing) == .clear { return true }

        // Hand the user back to the instance that already owns the mounts, so the
        // launch does something sensible rather than silently nothing.
        existing.activate()
        notifyAlreadyRunning(existingPath: existing.bundleURL?.path)
        return false
    }

    /// Block until the other instance exits, or the deadline passes.
    ///
    /// Synchronous and on the main thread on purpose: this runs from
    /// `applicationDidFinishLaunching` before anything touches the mount registry or
    /// the daemon pid file, and letting the app proceed concurrently is precisely
    /// what must not happen.
    private static func waitForExit(of other: NSRunningApplication) -> InstanceWait.Outcome {
        let started = Date()
        while InstanceWait.shouldKeepWaiting(isTerminated: other.isTerminated,
                                             elapsed: Date().timeIntervalSince(started)) {
            // Keeps the run loop turning so `isTerminated` is actually updated —
            // `NSRunningApplication` refreshes through KVO on the main run loop, so a
            // bare `sleep` here would spin for the full deadline and then report the
            // instance as still running however long ago it exited.
            RunLoop.current.run(until: Date().addingTimeInterval(InstanceWait.pollInterval))
        }
        return InstanceWait.outcome(isTerminated: other.isTerminated)
    }

    /// Bundle identifier matching misses the case that actually caused trouble here:
    /// two *different copies* of the app. `NSRunningApplication` does find those, since
    /// it matches on identifier rather than path — but say which copy is running, since
    /// "it is already running" is confusing when the other copy is somewhere else.
    private static func notifyAlreadyRunning(existingPath: String?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "grrclone is already running"

        var text = """
            Another copy of grrclone is already running and managing your connections. \
            Two copies cannot run at once: they share the same settings and the same \
            rclone process, and the second would disconnect the first's volumes.
            """
        if let existingPath, existingPath != Bundle.main.bundleURL.path {
            text += "\n\nThe running copy is at:\n\(existingPath)"
        }
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
