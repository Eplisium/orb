import Foundation
import Security

// MARK: - Open ("allow all applications") keychain access
//
// The legacy ACL on a generic-password item defaults to trusting the
// *creating app's designated requirement*. ORB is rebuilt (and was ad-hoc
// re-signed) constantly, so every rebuild was a "different app" to the
// keychain and macOS raised the legacy "enter your login keychain password"
// dialog — confusing, and it can never be satisfied by Touch ID.
//
// These items are instead created with a single ACL entry that trusts ALL
// applications with no prompt (Any authorization, promptSelector 0, NULL
// trusted-application list — the documented representation of Keychain
// Access's "Allow all applications to access this item"). Combined with
// stable code signing, reads never raise that dialog again. The real
// protections are the user's login session (FileVault) and ORB's own
// Touch ID / password app unlock.

enum KeychainOpenAccess {
    static func makeAccess(label: String = "ORB credentials") -> SecAccess? {
        var access: SecAccess?
        // Empty trusted list: create the access object with no default ACL,
        // then add exactly one explicit "allow all applications" entry below.
        guard SecAccessCreate(label as CFString, [] as CFArray, &access) == errSecSuccess,
              let access else { return nil }
        var acl: SecACL?
        let status = SecACLCreateWithSimpleContents(
            access,
            nil, // NULL trusted-application list = trust every application
            "Allow ORB to use this item" as CFString,
            SecKeychainPromptSelector(rawValue: 0), // never prompt
            &acl
        )
        guard status == errSecSuccess else { return nil }
        return access
    }
}

// MARK: - One-time migration of legacy items

/// Rewrites existing ORB items to open access. Items created by an older
/// (ad-hoc) build carry an ACL that trusts only that dead identity, so the
/// system may show its dialog ONE last time while an item's ACL is rewritten;
/// afterwards no rebuild or re-signing can trigger it again.
enum KeychainMigrator {
    static let service = "com.eplisium.orb"

    /// Account names of every ORB item in the keychain. Metadata-only query —
    /// never triggers an auth prompt.
    static func knownAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Applies open access to every item. Returns the migrated account names.
    @discardableResult
    static func migrateToOpenAccess() -> [String] {
        guard let access = KeychainOpenAccess.makeAccess() else { return [] }
        var migrated: [String] = []
        for account in knownAccounts() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let update: [String: Any] = [kSecAttrAccess as String: access]
            if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
                migrated.append(account)
            }
        }
        return migrated
    }
}
