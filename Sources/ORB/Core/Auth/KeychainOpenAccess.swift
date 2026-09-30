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
    /// Access object for a NEW item: exactly one trusted application — this
    /// running ORB, matched by its code-signing designated requirement
    /// (`identifier … and certificate leaf = H"…"`). Because rebuilds are
    /// signed with the same stable certificate, the requirement keeps
    /// matching and reads never prompt; any *other* process (a script, a
    /// different app) is not trusted and macOS asks before releasing the
    /// secret. Every ACL entry is stripped of prompt selectors so ORB itself
    /// is never interrupted, and the "change permissions" entries are limited
    /// to the same trusted list.
    ///
    /// Falls back to `nil` (system default ACL, which also trusts only the
    /// creating app) if the trusted-application object can't be built —
    /// never to an allow-everything ACL.
    static func makeAccess(label: String = "ORB credentials") -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted else { return nil }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, [trusted] as CFArray, &access) == errSecSuccess,
              let access else { return nil }
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
// 2. Dormant (v1/v2) items are READ at most once each: the first read may show
//    one system dialog (click "Always Allow"), the value is mirrored into the
//    v3 service (ORB-only ACL, this-device-only), and the old item goes
//    permanently dormant.

enum KeychainSecrets {
    /// Current store: ORB-only ACL (see `KeychainOpenAccess`).
    static let currentService = "com.eplisium.orb.v3"
    /// Dormant sources, newest first. v2 used an allow-all ACL that was
    /// unreliable on some Macs (re-prompting); v1 is the original store.
    static let v2Service = "com.eplisium.orb.v2"
    static let legacyService = "com.eplisium.orb"
    static let dormantServices = [v2Service, legacyService]

    /// Accounts whose dormant copies were already attempted this install
    /// (whether allowed or denied). Prevents a denied prompt from returning
    /// on every launch; the Settings button clears it for a manual retry.
    private static let attemptedKey = "orb.keychain.migrationAttempted"
    private static var attempted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: attemptedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: attemptedKey) }
    }

    static func read(_ account: String) -> String? {
        if let (data, present) = readItem(service: currentService, account: account) {
            // Present-but-empty is a deletion tombstone; dormant copies must
            // never resurrect a deleted secret.
            return (present && !data.isEmpty) ? String(data: data, encoding: .utf8) : nil
        }
        guard KeychainGate.allowsLegacyReads, !attempted.contains(account) else { return nil }
        return mirrorFromDormant(account)
    }

    /// Reads each dormant copy at most once (the only operation that can
    /// raise a system dialog — "Always Allow" once), then writes the value
    /// into v3. Dormant items are never modified or deleted.
    private static func mirrorFromDormant(_ account: String) -> String? {
        var seen = attempted
        seen.insert(account)
        attempted = seen // record BEFORE the read: a crash/deny can't loop
        for service in dormantServices {
            guard let (data, present) = readItem(service: service, account: account),
                  present, !data.isEmpty,
                  let value = String(data: data, encoding: .utf8) else { continue }
            if save(account, value) == nil { return value }
        }
        return nil
    }

    /// Save or replace in v3. Never touches dormant items.
    static func save(_ account: String, _ value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return "Could not encode key as UTF-8." }
        _ = deleteItem(service: currentService, account: account) // ours — silent
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Never leaves this Mac (no iCloud Keychain sync, no backups
            // restored to another device) and only readable while unlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        // ACL is stamped on ADD only — touching an existing item's ACL is
        // what raises the "change access permissions" dialog.
        if let access = KeychainOpenAccess.makeAccess() {
            add[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess ? nil : "Keychain error \(status)."
    }

    /// Delete and leave a tombstone so a dormant copy can't resurrect it.
    static func delete(_ account: String) {
        _ = deleteItem(service: currentService, account: account)
        let tombstone: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(),
        ]
        SecItemAdd(tombstone as CFDictionary, nil)
    }

    /// Prompt-free existence check (metadata-only; never reads secret data).
    static func exists(_ account: String) -> Bool {
        if let (data, present) = readItem(service: currentService, account: account) {
            return present && !data.isEmpty
        }
        return dormantServices.contains { dormantExists(service: $0, account: account) }
    }

    private static func dormantExists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: One-shot migration

    /// Account names in dormant stores. Metadata-only — never prompts.
    static func legacyAccounts() -> [String] {
        var names = Set<String>()
        for service in dormantServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]] else { continue }
            for item in items {
                if let a = item[kSecAttrAccount as String] as? String { names.insert(a) }
            }
        }
        return names.sorted()
    }

    /// Accounts with a dormant copy but no v3 item yet (tombstones count as
    /// migrated). Prompt-free.
    static func pendingLegacyAccounts() -> [String] {
        legacyAccounts().filter { readItem(service: currentService, account: $0) == nil }
    }

    /// Batch migration. `force` (the Settings button) ignores the
    /// already-attempted memory so a previously denied prompt can be retried.
    @discardableResult
    static func migrateAllLegacy(force: Bool = false) -> [String] {
        guard KeychainGate.allowsLegacyReads else { return [] }
        if force { attempted = [] }
        var migrated: [String] = []
        for account in pendingLegacyAccounts() where force || !attempted.contains(account) {
            if mirrorFromDormant(account) != nil { migrated.append(account) }
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
