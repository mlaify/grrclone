import Foundation

/// What can and cannot be done about Finder's metadata files on a remote.
///
/// Two different files, with two different causes, and only one of them fixable.
/// Treating them as one problem is why the obvious fixes all failed.
///
/// **`.DS_Store`** is written by Finder to record folder view settings. macOS can be
/// told not to write it to network volumes at all, and an NFS mount counts. Verified:
/// with the preference set, opening the mount in Finder produced neither the file nor
/// its sidecar, where before it produced both immediately. That is what this type
/// exposes.
///
/// **`._name` sidecars** hold extended attributes for filesystems that cannot store
/// them natively. NFSv3 cannot, and rclone serves NFSv3 — `namedattr`, which would let
/// the server hold them, is NFSv4 only. A sidecar therefore appears for essentially
/// *every* file written through the mount: macOS attaches `com.apple.provenance` to
/// copies, so even a plain text file with no tags and no quarantine flag gets one.
/// Measured, not assumed.
///
/// Those cannot be prevented from here. rclone's `--no-appledouble` is a FUSE mount
/// flag and does not exist on `serve nfs`, and filters do not help: serving with
/// `--exclude ".DS_Store" --exclude "._*"` and then writing both still put both on the
/// remote, because filters govern what rclone lists and reads, not what the VFS writes
/// back. Removing them afterwards is a job for rclone itself; see docs/progress.md.
public enum FinderMetadata {

    /// Whether macOS is currently configured to write `.DS_Store` to network volumes.
    ///
    /// System-wide, and not grrclone's to change silently: it affects every network
    /// volume the user has, including SMB shares that have nothing to do with this app.
    public static var writesDSStoreToNetworkVolumes: Bool {
        // Absent means the default, which is to write them.
        UserDefaults(suiteName: "com.apple.desktopservices")?
            .object(forKey: "DSDontWriteNetworkStores") as? Bool != true
    }
}
