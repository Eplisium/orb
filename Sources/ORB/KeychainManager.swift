import Foundation
import LocalAuthentication
import Security

/// Secure storage for the OpenRouter API key using macOS Keychain.
///
/// All mechanics live in `KeychainSecrets`: saves go to the open-access v2
/// service (prompt-free), and any item left by an older build under the
/// legacy service is read at most once to mirror it across, then never
/// touched again. No operation raises the legacy keychain dialogs.
enum KeychainManager {
    private static let account = "openrouter-api-key"

    /// Save or update the API key in the Keychain.
    /// Returns nil on success, or a diagnostic error string on failure.
    static func saveAPIKey(_ key: String) -> String? {
        KeychainSecrets.save(account, key)
    }

    /// Retrieve the API key from the Keychain. Returns nil if not set.
    static func getAPIKey() -> String? {
        KeychainSecrets.read(account)
    }

    /// Delete the API key (leaves a tombstone so a dormant legacy copy can
    /// never resurrect the old value).
    @discardableResult
    static func deleteAPIKey() -> Bool {
        KeychainSecrets.delete(account)
        return true
    }

    /// Whether an API key is currently stored. Does NOT trigger auth prompts.
    static var hasAPIKey: Bool {
        // Review mode (-orb.reviewMode YES) never touches the Keychain.
        if UserDefaults.standard.bool(forKey: "orb.reviewMode") { return false }
        return KeychainSecrets.exists(account)
    }

    /// Masked version of the key for display (e.g. "sk-or-v1-abc...xyz").
    static var maskedKey: String? {
        guard let key = getAPIKey(), key.count > 12 else { return nil }
        // Reveal only the well-known prefix and last 4 characters.
        let prefix = key.hasPrefix("sk-or-v1-") ? "sk-or-v1-" : String(key.prefix(4))
        return "\(prefix)••••••••\(key.suffix(4))"
    }
}
