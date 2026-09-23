import Foundation
import Security

// MARK: - Credential roles and profiles
//
// OpenRouter separates ordinary inference keys from management keys: credits,
// activity, and account administration require a management key, and management
// keys are prohibited from inference. ORB historically stored ONE key and used
// it for both. Roles are now explicit, and secrets are stored behind a small
// seam so tests never touch the Keychain.

enum CredentialRole: String, Codable, Sendable, CaseIterable {
    /// Chat, media generation, and every per-request operation.
    case inference
    /// Credits, activity, and administrative reads/writes.
    case management

    /// Distinct Keychain account per role, so the two keys can never be
    /// swapped accidentally. The inference account name matches the legacy
    /// single-key slot for compatibility.
    var keychainAccount: String {
        switch self {
        case .inference: return "openrouter-api-key"
        case .management: return "openrouter-management-key"
        }
    }
}

/// A local credential profile: role references by Keychain account name.
/// No secret bytes are ever stored in a profile record.
struct CredentialProfile: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var inferenceKeyReference: String
    var managementKeyReference: String?

    init(
        id: UUID = UUID(),
        name: String = "OpenRouter",
        inferenceKeyReference: String = CredentialRole.inference.keychainAccount,
        managementKeyReference: String? = nil
    ) {
        self.id = id
        self.name = name
        self.inferenceKeyReference = inferenceKeyReference
        self.managementKeyReference = managementKeyReference
    }
}

// MARK: - Secret storage seam

/// Storage for secret bytes, addressed by role reference. Implementations must
/// never log or persist secrets outside their secure store.
protocol CredentialSecretStore: Sendable {
    func secret(forReference reference: String) -> String?
    /// Returns nil on success or a diagnostic error string on failure. Failed
    /// updates must leave the previous secret intact.
    func saveSecret(_ secret: String, forReference reference: String) -> String?
    func deleteSecret(forReference reference: String) -> Bool
    func hasSecret(forReference reference: String) -> Bool
}

/// macOS Keychain-backed store. Generic-password items under the ORB service
/// with one account per credential role.
struct KeychainCredentialStore: CredentialSecretStore {
    private let service = "com.eplisium.orb"

    func secret(forReference reference: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveSecret(_ secret: String, forReference reference: String) -> String? {
        guard let data = secret.data(using: .utf8) else {
            return "Could not encode key as UTF-8."
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        // Update first; add when absent. The old secret stays intact if the
        // update or add fails.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return nil }
        if updateStatus == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess { return nil }
            return "Keychain error \(addStatus)."
        }
        return "Keychain error \(updateStatus)."
    }

    func deleteSecret(forReference reference: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    func hasSecret(forReference reference: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// Test double. No Keychain, no filesystem, nothing shared between instances.
final class InMemoryCredentialStore: CredentialSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func secret(forReference reference: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[reference]
    }

    func saveSecret(_ secret: String, forReference reference: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        secrets[reference] = secret
        return nil
    }

    func deleteSecret(forReference reference: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return secrets.removeValue(forKey: reference) != nil
    }

    func hasSecret(forReference reference: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return secrets[reference] != nil
    }

    /// Test-only snapshot of every stored secret, for assertions about where
    /// secrets did and did not land.
    var allSecrets: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return secrets
    }
}

// MARK: - Role-resolving helper

/// Resolves a role to its secret for a profile, enforcing that each role reads
/// only its own reference.
enum CredentialRouter {
    static func secret(for role: CredentialRole, profile: CredentialProfile, store: CredentialSecretStore) -> String? {
        let reference: String?
        switch role {
        case .inference: reference = profile.inferenceKeyReference
        case .management: reference = profile.managementKeyReference
        }
        guard let reference else { return nil }
        return store.secret(forReference: reference)
    }
}
