import Foundation
import IssaCore
import Security

/// Keychain-backed token persistence.
///
/// `…AfterFirstUnlockThisDeviceOnly`. First-unlock because background download
/// tasks run while the device is locked and need the token; ThisDeviceOnly
/// because without it the item is included in an encrypted backup and restores
/// onto a *different* device, which then holds a working credential — one
/// `Session` documents as lasting thirty-five years — with no sign-in and
/// nothing server-side to distinguish it.
///
/// The widget was the stated reason for the weaker class and was never a
/// reason: no target carries a `keychain-access-groups` entitlement, this type
/// is only ever constructed with `accessGroup: nil`, and the widget never
/// touches the keychain. ThisDeviceOnly satisfies the background downloader
/// identically.
///
/// `kSecUseDataProtectionKeychain` on every query, because on macOS its absence
/// puts the item in the legacy file-based keychain, where `kSecAttrAccessible`
/// is ignored outright and the protection promised above does not exist.
///
/// And a one-time migration on macOS, because adding that flag moved the
/// *lookup* without moving the *item*: every token build 24 wrote on a Mac is
/// in the login keychain, the flagged query looks in the data-protection one,
/// and the first version of this change dropped every existing Mac reader to
/// the sign-in form on update — while `delete` aimed at the new keychain,
/// reported not-found as success, and left the old thirty-five-year credential
/// in the login keychain for good. `read` now falls through to the legacy
/// keychain on a miss and, on a hit, moves the item across; `delete` clears
/// both. On iOS the flag is a no-op and there is nothing to migrate.
public struct KeychainStorage: TokenPersisting {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.benjaminissa.issareader.token", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// - Parameter dataProtection: which keychain. `false` names the legacy
    ///   login keychain, and exists only for the macOS migration below.
    private func baseQuery(account: String, dataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    public func read(account: String) -> String? {
        if let token = read(account: account, dataProtection: true) { return token }
        #if os(macOS)
        // The migration. A token in the login keychain is one build 24 wrote;
        // it is moved rather than merely read, so this path runs once per
        // account and the legacy copy does not outlive it.
        guard let legacy = read(account: account, dataProtection: false) else { return nil }
        if write(legacy, account: account) {
            let status = SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
            IssaLog.info("keychain token migrated", [
                "legacyDeleted": String(status == errSecSuccess),
            ])
        } else {
            // Left where it was, and still returned: a reader stays signed in
            // either way, and the next launch tries the move again.
            IssaLog.warning("keychain token could not be migrated")
        }
        return legacy
        #else
        return nil
        #endif
    }

    private func read(account: String, dataProtection: Bool) -> String? {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    /// Stores the token, and says so when it could not.
    ///
    /// Every status code used to be discarded: `SecItemUpdate`'s was compared
    /// only against `errSecItemNotFound` and `SecItemAdd`'s was never read at
    /// all, so a failed write was indistinguishable from a successful one. The
    /// reachable case is not exotic — a background task refreshing a token
    /// before first unlock gets `errSecInteractionNotAllowed` — and its symptom
    /// was a sign-in that appeared to work followed by a launch back at the
    /// server form, with nothing anywhere saying why.
    @discardableResult
    public func write(_ token: String, account: String) -> Bool {
        let data = Data(token.utf8)
        let query = baseQuery(account: account)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            IssaLog.warning("keychain write failed", ["status": String(status)])
            return false
        }
        return true
    }

    /// Removes the token, and says so when it could not.
    ///
    /// A delete that silently fails is worse than a write that does: the UI
    /// shows the reader signed out while a working credential stays on disk,
    /// and the next launch restores straight back into the library they
    /// believed they had left.
    @discardableResult
    public func delete(account: String) -> Bool {
        var deleted = delete(account: account, dataProtection: true)
        #if os(macOS)
        // Both keychains. Signing out on a Mac that had not yet launched the
        // migrated build must not leave the login-keychain copy behind — that
        // is the credential the reader believes they just revoked.
        deleted = delete(account: account, dataProtection: false) && deleted
        #endif
        return deleted
    }

    private func delete(account: String, dataProtection: Bool) -> Bool {
        let status = SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            IssaLog.warning("keychain delete failed", [
                "status": String(status), "dataProtection": String(dataProtection),
            ])
            return false
        }
        return true
    }
}
