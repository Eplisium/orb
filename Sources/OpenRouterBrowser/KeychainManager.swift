import Foundation
import Security

/// Secure storage for the OpenRouter API key using macOS Keychain.
enum KeychainManager {
    private static let service = "com.eplisium.openrouter-browser"
    private static let account = "openrouter-api-key"

    /// Save or update the API key in the Keychain.
    static func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
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
