import Foundation

/// How long to wait for a previous instance to finish going away.
///
/// In `GrrCloneCore` rather than in the app target so the policy can be tested —
/// the app target has no test bundle, and this decides whether an upgraded copy
/// starts at all.
public enum InstanceWait {

    /// Long enough to cover a real teardown.
    ///
    /// `applicationShouldTerminate` returns `.terminateLater` and the quit path can
    /// legitimately run for minutes: up to 120s draining uploads, plus
    /// `NFSTransport.unmountBudget` for each mount, plus the daemon stop. Anything
    /// shorter turns "the old copy is still tidying up" into "the new copy refused
    /// to start", which is what a user sees after an upgrade.
    ///
    /// Derived from the real budgets rather than picked. The first draft said 180,
    /// and a test pointed out that a single unmount plus the drain is already 250 —
    /// so the new copy would still have refused in precisely the case this exists
    /// for. Two unmounts' worth covers the common two-remote setup with headroom;
    /// the wait returns the moment the other copy exits, so the bound is only ever
    /// paid when it is genuinely still running.
    ///
    /// Bounded, though. An instance wedged forever must not wedge the launch too;
    /// after this, refusing is the right answer and the alert explains it.
    public static let deadline: TimeInterval =
        uploadDrainAllowance + 2 * NFSTransport.unmountBudget + 10

    /// Mirrors the drain the quit path allows when uploads are pending. Kept in step
    /// by the test that compares this against the real unmount budget.
    static let uploadDrainAllowance: TimeInterval = 120

    /// The wait when the other copy is the *same* bundle.
    ///
    /// There is no external signal that a macOS app is mid-`terminateLater`, so the
    /// only evidence available is where the other copy lives. A copy at a different
    /// path is the upgrade case the guard was written for — a new version dragged
    /// into /Applications while the old one quits — and deserves the full deadline.
    /// A copy at the *same* path is almost always one that is simply running: Launch
    /// Services normally activates a running app rather than starting a second
    /// process, so reaching this at all means something unusual, and the first draft
    /// made that person wait six and a half minutes before being told the app was
    /// already open. A few seconds covers a copy that is genuinely on its way out;
    /// after that, activate it and say so, as before.
    public static let samePathDeadline: TimeInterval = 5

    /// The deadline that applies, given where the other copy is.
    public static func deadline(samePath: Bool) -> TimeInterval {
        samePath ? samePathDeadline : deadline
    }

    /// How often to look. Frequent enough that a quick exit is not made to feel
    /// slow, rare enough to be free.
    public static let pollInterval: TimeInterval = 0.25

    /// Whether to keep waiting for an instance in this state.
    ///
    /// Split out from the polling loop because the loop needs `NSRunningApplication`
    /// and this does not, which is the whole difference between a rule that is
    /// tested and one that is only read.
    ///
    /// - Parameters:
    ///   - isTerminated: whether the other instance has exited.
    ///   - elapsed: seconds spent waiting so far.
    public static func shouldKeepWaiting(isTerminated: Bool, elapsed: TimeInterval,
                                         samePath: Bool = false) -> Bool {
        guard !isTerminated else { return false }
        return elapsed < deadline(samePath: samePath)
    }

    /// The outcome of waiting, for the caller to act on.
    public enum Outcome: Sendable, Equatable {
        /// Nothing else was running, or it exited while we waited.
        case clear
        /// Another instance is still running and is not going away.
        case occupied
    }

    /// Decide the outcome from what the wait observed.
    ///
    /// A terminated instance means the path is clear no matter how long it took.
    /// Still running at the deadline means occupied, and the caller must refuse —
    /// two instances corrupt each other's mount registry and each reaps the other's
    /// daemon, which is the entire reason the guard exists.
    public static func outcome(isTerminated: Bool) -> Outcome {
        isTerminated ? .clear : .occupied
    }
}
