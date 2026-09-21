import Foundation

/// Whether a new remote may take a name.
///
/// rclone's `config/create` deletes any existing section of that name before
/// writing — verified against 1.75.1, not inferred — so creating "dav1" over an
/// existing "dav1" destroys its credentials with no warning and no backup (#110).
/// Nothing in rclone refuses this; grrclone has to.
///
/// Names are compared exactly. rclone keeps `Keep` and `keep` as two remotes
/// (verified), so a case-insensitive refusal would block a name rclone accepts.
public enum RemoteName {

    /// Why `name` cannot be used for a new remote, or nil if it can.
    public static func refusal(for name: String, existing: [String]) -> String? {
        guard existing.contains(name) else { return nil }
        return "A remote called \(name) already exists. Creating another with that name "
             + "would replace its settings and credentials. Edit it from its connection "
             + "instead, or choose a different name."
    }
}
