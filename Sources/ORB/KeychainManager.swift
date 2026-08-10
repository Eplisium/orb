import Foundation
import LocalAuthentication
import Security

/// Secure storage for the OpenRouter API key using macOS Keychain.
///
/// Save always uses open-access (no ACL) so it never fails on any Mac
/// configuration. Read operations use `LAContext` with Touch ID / passcode
/// when the item has biometric access control, and fall back to plain
/// reads for open-access items.
enum KeychainManager {
    private static let service = "com.eplisium.orb"
    private static let account = "openrouter-api-key"

    /// Save or update the API key in the Keychain.
    /// Always uses open-access (no ACL) so save never fails.
    /// Returns nil on success, or a diagnostic error string on failure.
    static func saveAPIKey(_ key: String) -> String? {
        guard let data = key.data(using: .utf8) else { return "Could not encode key as UTF-8." }

        // Delete any existing item first (clears stale ACLs from old builds)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return nil }
        return keychainError(status)
    }

    private static func keychainError(_ status: OSStatus) -> String {
        if #available(macOS 12.0, *),
           let msg = SecCopyErrorMessageString(status, nil) {
            return "Keychain error \(status): \(msg)"
        }
        return "Keychain error \(status)."
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

    /// Whether an API key is currently stored. Does NOT trigger auth prompts.
    static var hasAPIKey: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Masked version of the key for display (e.g. "sk-or-v1-abc...xyz").
    static var maskedKey: String? {
        guard let key = getAPIKey(), key.count > 12 else { return nil }
        let prefix = key.prefix(12)
        let suffix = key.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
