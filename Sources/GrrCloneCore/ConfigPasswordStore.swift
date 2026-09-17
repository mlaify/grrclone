import Foundation
import Security

/// Stores the password for an encrypted `rclone.conf` in the login keychain.
///
/// The password is the key to every remote the user has configured, so what this does
/// and does not protect is worth stating precisely.
///
/// **It uses the legacy file-based keychain, deliberately.** The modern data protection
/// keychain — the one that honours `kSecAttrAccessible` — requires the
/// `keychain-access-groups` entitlement, and a Developer ID app distributed outside the
/// App Store cannot carry that without an embedded provisioning profile. Measured, not
/// assumed: `SecItemAdd` with `kSecUseDataProtectionKeychain` fails with `-34018`,
/// "a required entitlement is not present".
///
/// That has a consequence worth being honest about. An earlier version of this file set
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and claimed in a comment that the
/// password was unreadable while the Mac was locked. **It was not.** The legacy keychain
/// silently ignores the attribute — reading the item back showed no `pdmn` attribute at
/// all — so the claim was false and the protection imaginary. The item is protected by
/// the login keychain, which is unlocked for the whole login session.
///
/// What is true:
///
/// - **Encrypted at rest** in the login keychain, not in a preferences file.
/// - **Never synchronised.** iCloud Keychain covers only data protection keychain items,
///   and `kSecAttrSynchronizable` is set to false explicitly rather than left to a
///   default that could change.
/// - **Keyed by config path**, so pointing grrclone at a different config gets a
///   different item instead of silently reusing a password that cannot work.
///
/// Saving is always the user's choice. Nothing is written unless they ask, and `forget`
/// makes the choice reversible without opening Keychain Access.
public struct ConfigPasswordStore: Sendable {
    public static let service = "org.mlaify.grrclone.config"

    private let configPath: String

    public init(configPath: String) {
        self.configPath = configPath
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: configPath]
    }

    /// The saved password, or nil if there is none.
    ///
    /// Returns nil rather than throwing on any failure. A missing item and an
    /// unreadable one lead to the same place — ask the user — and a keychain error is
    /// not something they can act on.
    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return password
    }

    /// Save or replace the password. Throws so a failure to save can be reported rather
    /// than leaving the user thinking they will not be asked again.
    public func save(_ password: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw Failure.unexpected(errSecParam)
        }

        // Update in place if it exists, so the item keeps its identity and the user is
        // not asked to re-authorise access after every change.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw Failure.unexpected(updateStatus) }

        var query = baseQuery
        query[kSecValueData as String] = data
        // Explicit rather than defaulted: this password must never reach iCloud.
        query[kSecAttrSynchronizable as String] = false
        query[kSecAttrLabel as String] = "grrclone — rclone config password"
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.unexpected(addStatus) }
    }

    /// Remove the saved password. Succeeds when there was nothing to remove.
    public func forget() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpected(status)
        }
    }

    public var hasSavedPassword: Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public enum Failure: Error, LocalizedError {
        case unexpected(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpected(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status)\(detail.map { ": \($0)" } ?? "")"
            }
        }
    }
}
