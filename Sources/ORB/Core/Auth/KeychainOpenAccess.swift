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
// New items are created with a single ACL entry that trusts ALL applications
// with no prompt (Any authorization, promptSelector 0, NULL trusted-
// application list — the documented representation of Keychain Access's
// "Allow all applications to access this item"). Combined with stable code
// signing, reads never raise that dialog again. The real protections are the
// user's login session (FileVault) and ORB's own Touch ID / password unlock.

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

// MARK: - Legacy-read gate

/// While the app is locked, nothing may attempt a legacy-item data read — it
/// is the one keychain operation that can still raise a system dialog, and a
/// lock screen with a keychain prompt over it is worse than no lock at all.
enum KeychainGate {
    nonisolated(unsafe) static var allowsLegacyReads = false
}

// MARK: - Secret storage with one-time legacy mirror
//
// Two rules keep the keychain silent:
//
// 1. Nothing ever MUTATES a legacy item (no ACL rewrite, no update, no
//    delete). Those operations raise the "ORB wants to change access
//    permissions of the 'ORB credentials' item" dialog, and that dialog can
//    never be satisfied without the login keychain password — an old
//    migration looped on exactly this.
// 2. Legacy items are READ at most once each: the first read may show the
//    "use your confidential information" dialog (click Allow once), the
//    value is mirrored into the v2 service with an open-access ACL, and the
//    legacy item goes permanently dormant — never queried again.

enum KeychainSecrets {
    static let legacyService = "com.eplisium.orb"
    static let v2Service = "com.eplisium.orb.v2"

    static func read(_ account: String) -> String? {
        if let (data, present) = readItem(service: v2Service, account: account) {
            // Present-but-empty is a deletion tombstone; the dormant legacy
            // item must never resurrect a deleted secret.
            return (present && !data.isEmpty) ? String(data: data, encoding: .utf8) : nil
        }
        guard KeychainGate.allowsLegacyReads,
              let (data, present) = readItem(service: legacyService, account: account),
              present, !data.isEmpty,
              let value = String(data: data, encoding: .utf8) else { return nil }
        save(account, value) // mirror once — the legacy item is never touched again
        return value
    }

    /// Save or replace. Returns nil on success. Writes only to v2, so saving
    /// is prompt-free regardless of what legacy items exist.
    static func save(_ account: String, _ value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return "Could not encode key as UTF-8." }
        _ = deleteItem(service: v2Service, account: account) // ours — silent
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: v2Service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        // Open access is stamped on ADD only — touching an existing item's
        // ACL is what raises the "change access permissions" dialog.
        if let access = KeychainOpenAccess.makeAccess() {
            add[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess ? nil : "Keychain error \(status)."
    }

    /// Delete and leave a tombstone. Legacy items are left in place — deleting
    /// them is an ACL mutation and would prompt.
    static func delete(_ account: String) {
        _ = deleteItem(service: v2Service, account: account)
        let tombstone: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: v2Service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(),
        ]
        SecItemAdd(tombstone as CFDictionary, nil)
    }

    /// Prompt-free existence check (metadata-only against legacy items).
    static func exists(_ account: String) -> Bool {
        if let (data, present) = readItem(service: v2Service, account: account) {
            return present && !data.isEmpty
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: One-shot legacy migration

    /// Account names of legacy items. Metadata-only — never prompts.
    static func legacyAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Accounts with a legacy item but no v2 copy yet (tombstones count as
    /// migrated — a deleted secret must stay deleted). Prompt-free.
    static func pendingLegacyAccounts() -> [String] {
        legacyAccounts().filter { readItem(service: v2Service, account: $0) == nil }
    }

    /// Batch migration: reads every unmigrated legacy item — the one
    /// operation that can prompt, exactly once per item ("Allow" is enough;
    /// the value is mirrored immediately) — and returns the migrated
    /// accounts. Run while unlocked.
    @discardableResult
    static func migrateAllLegacy() -> [String] {
        guard KeychainGate.allowsLegacyReads else { return [] }
        var migrated: [String] = []
        for account in pendingLegacyAccounts() {
            if read(account) != nil {
                migrated.append(account)
            }
        }
        return migrated
    }

    // MARK: Raw item operations

    /// (data, itemPresent) — distinguishes "absent" from "present but empty".
    /// Any failure (including a denied read) reports as absent.
    private static func readItem(service: String, account: String) -> (Data, Bool)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as? Data ?? Data(), true)
    }

    private static func deleteItem(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
