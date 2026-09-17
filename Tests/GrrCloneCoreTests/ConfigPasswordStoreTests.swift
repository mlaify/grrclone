import XCTest
import Security
@testable import GrrCloneCore

/// Exercises the real Keychain rather than a fake.
///
/// The point of this type is its interaction with `SecItem*` — the query it builds, the
/// update-then-add fallback, the accessibility class — and a stub would test none of
/// that. Each test keys its item by a unique throwaway path, so it can never collide
/// with a real saved password, and removes it afterwards.
///
/// On a machine with no usable login keychain, such as some CI runners, the tests skip
/// rather than fail. The skip is narrow: it triggers only when the Keychain refuses the
/// first write outright, never on a wrong answer from a write that succeeded.
final class ConfigPasswordStoreTests: XCTestCase {

    private var store: ConfigPasswordStore!
    private var account: String!

    override func setUp() {
        super.setUp()
        account = "/tmp/grrclone-test-\(UUID().uuidString)/rclone.conf"
        store = ConfigPasswordStore(configPath: account)
    }

    override func tearDown() {
        try? store.forget()
        super.tearDown()
    }

    /// Saves, and skips the test if this environment has no writable keychain.
    private func saveOrSkip(_ password: String) throws {
        do {
            try store.save(password)
        } catch let ConfigPasswordStore.Failure.unexpected(status)
                    where status == errSecNotAvailable
                        || status == errSecInteractionNotAllowed
                        || status == errSecMissingEntitlement {
            throw XCTSkip("No usable keychain in this environment (OSStatus \(status))")
        }
    }

    func testRoundTripsAPassword() throws {
        XCTAssertNil(store.load(), "a fresh path must not find a password")
        XCTAssertFalse(store.hasSavedPassword)

        try saveOrSkip("correct horse battery staple")

        XCTAssertEqual(store.load(), "correct horse battery staple")
        XCTAssertTrue(store.hasSavedPassword)
    }

    /// The update-then-add path. Saving twice must replace the value, not fail with
    /// errSecDuplicateItem and not leave the old password in place — which would mean a
    /// user who changed their config password could never save the new one.
    func testSavingTwiceReplacesTheValue() throws {
        try saveOrSkip("first")
        try store.save("second")
        XCTAssertEqual(store.load(), "second")
    }

    func testForgetRemovesIt() throws {
        try saveOrSkip("temporary")
        XCTAssertNotNil(store.load())

        try store.forget()

        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasSavedPassword)
    }

    /// Forgetting what was never saved is not an error. The user can always choose to
    /// stop saving the password, whether or not one is currently stored.
    func testForgetIsSafeWhenNothingIsSaved() {
        XCTAssertNoThrow(try store.forget())
    }

    /// Two configs must not share a password. Someone pointing grrclone at a different
    /// config file would otherwise be handed the first one's password, which cannot
    /// work and looks like a rejected password rather than a missing one.
    func testPasswordsAreKeyedByConfigPath() throws {
        try saveOrSkip("password-for-a")

        let other = ConfigPasswordStore(configPath: account + ".other")
        defer { try? other.forget() }

        XCTAssertNil(other.load())
        try other.save("password-for-b")

        XCTAssertEqual(store.load(), "password-for-a")
        XCTAssertEqual(other.load(), "password-for-b")
    }

    /// The password must never reach iCloud Keychain.
    ///
    /// Reads the stored attributes back rather than trusting the write. That matters:
    /// this test is why the store no longer sets `kSecAttrAccessible`. The first
    /// version asserted the item was accessible only while the Mac was unlocked, and
    /// this assertion failed — the legacy keychain had ignored the attribute entirely
    /// and stored no `pdmn` at all, so the code was claiming a protection it did not
    /// have. See the type's documentation.
    func testStoredPasswordIsNotSynchronisedToICloud() throws {
        try saveOrSkip("secret")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ConfigPasswordStore.service,
            kSecAttrAccount as String: account!,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Match regardless, so a synchronised item cannot hide from this check.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = item as? [String: Any]

        // Absent counts as not synchronised; present and true does not.
        let synchronisable = attributes?[kSecAttrSynchronizable as String] as? Bool ?? false
        XCTAssertFalse(synchronisable, "the config password must not sync to iCloud")
    }

    /// The password is not left anywhere a plain file read could reach it — in
    /// particular not in `UserDefaults`, which is a plist in the user's Library.
    func testPasswordIsNotWrittenToUserDefaults() throws {
        try saveOrSkip("distinctive-password-value")

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in defaults {
            if let string = value as? String {
                XCTAssertFalse(string.contains("distinctive-password-value"),
                               "password leaked into UserDefaults key \(key)")
            }
        }
    }
}
