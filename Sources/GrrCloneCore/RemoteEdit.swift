import Foundation

/// Working out what an edit to a remote should actually send.
///
/// In `GrrCloneCore` rather than in the sheet that uses it, because the app target
/// has no test bundle and this function decides whether a password survives. The
/// first version lived in the view and wiped one: it treated "is a secret" and "the
/// user typed a new secret" as the same flag, so an untouched password field — blank
/// on screen, obscured in the stored config — compared unequal and was sent as an
/// empty string.
public enum RemoteEdit {

    /// The fields to send to `config/update`.
    ///
    /// - Parameters:
    ///   - values: what the form currently shows. Secret fields are blank unless the
    ///     user typed into them.
    ///   - original: what `config/dump` returned. Secrets here are *obscured*, which
    ///     is why they can never be compared against what the form shows.
    ///   - secretFields: every option that is a password or otherwise sensitive,
    ///     whether or not it was touched.
    ///   - editedSecrets: the secret fields the user actually typed into.
    ///
    /// Three rules, in order:
    ///
    /// 1. A secret is sent only if the user typed a new one, and only if non-empty.
    ///    Blank means "leave it alone" — which is what the form promises — and
    ///    sending an empty string would overwrite the stored password with nothing.
    /// 2. Everything else is sent only when it differs from what was loaded.
    /// 3. Nothing else is sent at all. Rewriting untouched values would put each one
    ///    through rclone's guess-whether-to-obscure heuristic for no reason.
    public static func changeSet(values: [String: String],
                                 original: [String: String],
                                 secretFields: Set<String>,
                                 editedSecrets: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values {
            if secretFields.contains(key) {
                guard editedSecrets.contains(key), !value.isEmpty else { continue }
                result[key] = value
            } else if value != (original[key] ?? "") {
                result[key] = value
            }
        }
        return result
    }
}
