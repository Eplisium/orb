import Foundation
import Security
import Combine

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

// MARK: - Credential revisions

/// In-process invalidation, scoped to a backing store and reference. Only
/// opaque revisions and reference names are retained/emitted, never secrets
/// or key-derived hashes. Each in-memory store has its own isolated source;
/// all wrappers of the production Keychain share one source.
final class CredentialChanges: @unchecked Sendable {
    static let keychain = CredentialChanges()
    private let lock = NSLock()
    private var revisions: [String: UUID] = [:]
    private let subject = PassthroughSubject<String, Never>()

    var publisher: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }

    func revision(for reference: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return revisions[reference]
    }

    func recordChange(for reference: String) {
        lock.lock()
        revisions[reference] = UUID()
        lock.unlock()
        // Subscribers can re-read presence/revisions; never call them locked.
        subject.send(reference)
    }
}

// MARK: - Secret storage seam

/// Storage for secret bytes, addressed by role reference. Implementations must
/// never log or persist secrets outside their secure store.
protocol CredentialSecretStore: Sendable {
    /// Shared by all handles to the same backing store. Custom stores that
    /// support external writes should expose a source and record mutations.
    var credentialChanges: CredentialChanges? { get }
    func secret(forReference reference: String) -> String?
    /// Returns nil on success or a diagnostic error string on failure. Failed
    /// updates must leave the previous secret intact.
    func saveSecret(_ secret: String, forReference reference: String) -> String?
    /// Returns true only when the secret is verified absent afterwards; false
    /// means it may still exist and callers must not report it as removed.
    func deleteSecret(forReference reference: String) -> Bool
    func hasSecret(forReference reference: String) -> Bool
}

extension CredentialSecretStore {
    var credentialChanges: CredentialChanges? { nil }
}

/// macOS Keychain-backed store. All mechanics live in `KeychainSecrets`:
/// saves use the ORB-only v3 service, and confirmed-missing slots can mirror
/// dormant items without ever modifying them.
struct KeychainCredentialStore: CredentialSecretStore {
    var credentialChanges: CredentialChanges? { .keychain }

    func secret(forReference reference: String) -> String? {
        KeychainSecrets.read(reference)
    }

    func saveSecret(_ secret: String, forReference reference: String) -> String? {
        KeychainSecrets.save(reference, secret)
    }

    func deleteSecret(forReference reference: String) -> Bool {
        KeychainSecrets.delete(reference)
    }

    func hasSecret(forReference reference: String) -> Bool {
        KeychainSecrets.exists(reference)
    }
}

/// Test double. No Keychain, no filesystem, nothing shared between instances.
final class InMemoryCredentialStore: CredentialSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    let credentialChanges: CredentialChanges? = CredentialChanges()

    func secret(forReference reference: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[reference]
    }

    func saveSecret(_ secret: String, forReference reference: String) -> String? {
        lock.lock()
        secrets[reference] = secret
        lock.unlock()
        credentialChanges?.recordChange(for: reference)
        return nil
    }

    func deleteSecret(forReference reference: String) -> Bool {
        lock.lock()
        secrets.removeValue(forKey: reference)
        lock.unlock()
        credentialChanges?.recordChange(for: reference)
        return true // absent afterwards, whether or not it existed
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
