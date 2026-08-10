import Foundation
import Security

/// Secure storage for the OpenRouter API key using macOS Keychain.
///
/// Keychain items are created with `SecAccessCreate` where the trusted
/// applications list is `nil` — not an empty array. Passing `nil` creates
/// an ACL with no entries, which means ANY application running as the
/// current user can read the item without a password prompt. This is
/// essential for ad-hoc code-signed dev builds whose signature changes
/// on every rebuild.
///
/// Passing `[]` (empty array) would mean "zero trusted apps" — i.e. NO
/// app can access the item, which triggers the password prompt. That was
/// the previous bug.
enum KeychainManager {
    private static let service = "com.eplisium.orb"
    private static let account = "openrouter-api-key"

    /// Save or update the API key in the Keychain.
    static func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // Delete any existing item first (clears stale ACLs from old builds)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Build the add query with a SecAccess that has NO ACL entries.
        // Passing nil (not []) for trustedApplications creates an access
        // object with no restrictions — any app can read without prompting.
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        var access: SecAccess?
        // nil for trustedApplications = no ACL = any app can access
        let accessStatus = SecAccessCreate(
            "ORB API Key" as CFString,
            nil,
            &access
        )
        if accessStatus == errSecSuccess, let access {
            addQuery[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve the API key from the Keychain. Returns nil if not set.
    static func getAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the API key from the Keychain.
    static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Whether an API key is currently stored.
    static var hasAPIKey: Bool {
        getAPIKey() != nil
    }

    /// Masked version of the key for display (e.g. "sk-or-v1-abc...xyz").
    static var maskedKey: String? {
        guard let key = getAPIKey(), key.count > 12 else { return nil }
        let prefix = key.prefix(12)
        let suffix = key.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
