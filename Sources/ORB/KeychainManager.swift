import Foundation
import LocalAuthentication
import Security

/// Secure storage for the OpenRouter API key using macOS Keychain.
///
/// All mechanics live in `KeychainSecrets`: saves use the ORB-only v3
/// service and publish opaque store revisions. Dormant items may be read
/// once to fill a confirmed missing slot, but are never modified. A failed
/// current-item read must never authorize migration over it.
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
    /// never resurrect the old value). Returns true only when the removal
    /// was verified; false means the key may still be stored.
    @discardableResult
    static func deleteAPIKey() -> Bool {
        KeychainSecrets.delete(account)
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
