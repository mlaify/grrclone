import Foundation
import RcloneRC

/// Liveness probe for a mounted path.
///
/// A mount can be present in the kernel's mount table and still be unusable — the rclone
/// server behind it may have died, or the connection may have been severed by sleep. The
/// mount table alone therefore cannot answer "is this working?"; something has to
/// actually touch the filesystem.
///
/// Touching it is the dangerous part. A `stat` against a wedged NFS mount blocks until
/// the soft-mount timeout expires, so every probe runs on a detached task with a deadline
/// the caller can abandon. Nothing here may ever be awaited from the main actor without
/// that deadline.
public enum MountHealth: Sendable {

    public enum Status: Sendable, Equatable {
        case healthy
        /// Mounted, but did not respond within the deadline. Usually a dead server.
        case unresponsive
        /// No longer in the mount table at all.
        case gone
    }

    /// Probe a mount point.
    ///
    /// - Parameter timeout: how long to wait before declaring it unresponsive. Kept well
    ///   below the NFS soft-mount timeout so the UI learns about trouble long before the
    ///   kernel gives up.
    public static func probe(_ mountPoint: URL, timeout: TimeInterval = 5) async -> Status {
        guard await SystemMounts.isMounted(mountPoint.path) else { return .gone }

        // Look up a name that cannot exist. This is deliberate and load-bearing.
        //
        // Listing the directory does NOT work: the NFS client answers from its own
        // attribute and directory cache without contacting the server at all, so a mount
        // whose server has been killed still reports healthy. That was observed — a probe
        // returned "healthy after 0.0s" against a server killed moments earlier.
        //
        // A randomly named path cannot be in any cache, so the client must issue a LOOKUP
        // and wait for the server. ENOENT is a perfectly good answer: it proves something
        // replied. Only silence means the mount is broken.
        let probePath = (mountPoint.path as NSString)
            .appendingPathComponent(".grrclone-probe-\(UUID().uuidString)")

        // Deadline, not a task group: a task group waits for every child to finish, and a
        // filesystem call blocked on a dead NFS server cannot be cancelled, so the group
        // would hang past its own deadline. That exact mistake made an earlier version of
        // this probe hang forever against the case it was written to detect.
        // Returning quickly is not the same as working. Once a soft NFS mount has given
        // up on its server, the client fast-fails every call: lstat returns immediately
        // with ETIMEDOUT or ESTALE rather than blocking. Treating "it returned" as healthy
        // therefore reports a dead mount as fine, which was observed.
        //
        // So the errno decides. ENOENT is the success case: the server was asked about a
        // file that does not exist and said so.
        let outcome: Int32? = await Deadline.run(seconds: timeout) {
            var info = stat()
            if lstat(probePath, &info) == 0 { return 0 }
            return errno
        }

        guard let outcome else { return .unresponsive }   // no answer within the deadline

        switch outcome {
        case 0, ENOENT:
            return .healthy
        case ETIMEDOUT, ESTALE, EIO, ENOTCONN, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENXIO:
            return .unresponsive
        default:
            // Anything else (EACCES, ENAMETOOLONG, …) still proves the filesystem
            // responded, which is all this probe claims to measure.
            return .healthy
        }
    }

    /// Delay before the next reconnect attempt: 1s, 5s, 30s, then 300s.
    ///
    /// Backing off matters because the usual cause of a failed reconnect is an absent
    /// network, and retrying every second on a laptop that has been closed for an hour
    /// wakes the radio and drains the battery for nothing.
    public static func backoff(attempt: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [1, 5, 30, 300]
        return ladder[min(max(attempt, 0), ladder.count - 1)]
    }
}
