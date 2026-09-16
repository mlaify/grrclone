import Foundation
import AppKit
import Network

/// Watches for the two events that silently break a mount: the machine waking from
/// sleep, and the network path changing.
///
/// Neither produces an error anywhere. The mount simply stops responding, and Finder
/// hangs on it until something notices. This is what notices.
@MainActor
final class SystemEvents {
    private let monitor = NWPathMonitor()
    private var started = false
    private var lastPathStatus: NWPath.Status?
    private var onChange: (@MainActor (String) -> Void)?

    /// - Parameter handler: called with a short reason describing what changed. Always on
    ///   the main actor, and expected to hand the actual work to a detached task, since
    ///   probing a mount can block.
    func start(_ handler: @escaping @MainActor (String) -> Void) {
        guard !started else { return }
        started = true
        onChange = handler

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Waking is the most common way a mount breaks: the TCP connection to the
            // loopback server is gone, but the mount is still in the table.
            Task { @MainActor in self?.onChange?("woke from sleep") }
        }

        // Also worth watching: the volume the mount lives under being ejected, and the
        // screen unlocking after a long idle period.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onChange?("a volume was unmounted") }
        }

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                // Only react to real transitions. The monitor fires on interface details
                // that do not affect reachability, and remounting on each one would churn
                // pointlessly.
                defer { self.lastPathStatus = path.status }
                guard let previous = self.lastPathStatus, previous != path.status else { return }
                if path.status == .satisfied {
                    self.onChange?("network came back")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "org.mlaify.grrclone.network"))
    }

    func stop() {
        monitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        started = false
    }
}
