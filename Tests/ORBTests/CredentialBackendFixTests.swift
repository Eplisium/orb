import Foundation
import Security
import Testing
@testable import ORB

/// Faults and races are confined to this fake; no real Keychain operations.
private final class CredentialFixBackend: KeychainBackend, @unchecked Sendable {
    var current: Data?
    var currentStatus: OSStatus?
    var malformedCurrent = false
    var dormant = Data("dormant-fixture".utf8)
    var racedValue: Data?
    var writes = 0
    var dormantReads = 0
    let account = "credential-fix-\(UUID())"

    func add(_ attributes: [String: Any]) -> OSStatus {
        writes += 1
        if let racedValue { current = racedValue }
        guard current == nil else { return errSecDuplicateItem }
        current = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        writes += 1
        guard current != nil else { return errSecItemNotFound }
        current = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus { errSecNotAvailable }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        let service = query[kSecAttrService as String] as? String
        if service == KeychainSecrets.currentService {
            if let currentStatus { return (currentStatus, nil) }
            if malformedCurrent { return (errSecSuccess, "not data" as NSString) }
            guard let current else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, current as NSData)
        }
        guard service == KeychainSecrets.v2Service else { return (errSecItemNotFound, nil) }
        if query[kSecReturnAttributes as String] as? Bool == true {
            return (errSecSuccess, [[kSecAttrAccount as String: account]] as NSArray)
        }
        dormantReads += 1
        return (errSecSuccess, dormant as NSData)
    }
}

@Suite("Credential backend fixes")
struct CredentialBackendFixTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "CredentialBackendFixTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test("unavailable current reads preserve both replacements and tombstones",
          arguments: [Data("current-fixture".utf8), Data()],
          [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable])
    func unavailableRead(original: Data, status: OSStatus) {
        withDefaults { defaults in
            let backend = CredentialFixBackend()
            backend.current = original
            backend.currentStatus = status
            #expect(KeychainSecrets.read(backend.account, backend: backend, defaults: defaults, allowsLegacyReads: true) == nil)
            #expect(!KeychainSecrets.exists(backend.account, backend: backend))
            #expect(KeychainSecrets.pendingLegacyAccounts(backend: backend).isEmpty)
            #expect(KeychainSecrets.migrateAllLegacy(force: true, backend: backend, defaults: defaults, allowsLegacyReads: true).isEmpty)
            #expect(backend.writes == 0)
            #expect(backend.dormantReads == 0)
            #expect(backend.current == original)
            #expect(defaults.stringArray(forKey: "orb.keychain.migrationAttempted") == nil)
        }
    }

    @Test("present replacements and tombstones are never pending migration", arguments: [Data("current-fixture".utf8), Data()])
    func currentItemsAreNotMigrated(original: Data) {
        withDefaults { defaults in
            let backend = CredentialFixBackend()
            backend.current = original
            #expect(KeychainSecrets.pendingLegacyAccounts(backend: backend).isEmpty)
            #expect(KeychainSecrets.migrateAllLegacy(force: true, backend: backend, defaults: defaults, allowsLegacyReads: true).isEmpty)
            let value = KeychainSecrets.read(backend.account, backend: backend, defaults: defaults, allowsLegacyReads: true)
            #expect(value == (original.isEmpty ? nil : "current-fixture"))
            #expect(backend.current == original)
            #expect(backend.writes == 0)
            #expect(backend.dormantReads == 0)
        }
    }

    @Test("production wrappers share only opaque revision state and failed saves do not advance it")
    func keychainRevisions() {
        let first = KeychainCredentialStore()
        let second = KeychainCredentialStore()
        #expect(first.credentialChanges === second.credentialChanges)
        let backend = CredentialFixBackend()
        let before = first.credentialChanges?.revision(for: backend.account)
        #expect(KeychainSecrets.save(backend.account, "fixture", backend: backend) == nil)
        let saved = second.credentialChanges?.revision(for: backend.account)
        #expect(saved != before)
        #expect(KeychainSecrets.save(backend.account, "", backend: backend) != nil)
        #expect(second.credentialChanges?.revision(for: backend.account) == saved)
        #expect(KeychainSecrets.delete(backend.account, backend: backend))
        #expect(second.credentialChanges?.revision(for: backend.account) != saved)
    }

    @Test("malformed successful reads are not missing items or verified tombstones")
    func malformedRead() {
        withDefaults { defaults in
            let backend = CredentialFixBackend()
            backend.current = Data("current-fixture".utf8)
            backend.malformedCurrent = true
            #expect(KeychainSecrets.read(backend.account, backend: backend, defaults: defaults, allowsLegacyReads: true) == nil)
            #expect(backend.writes == 0)
            #expect(backend.dormantReads == 0)
            #expect(!KeychainSecrets.delete(backend.account, backend: backend))
        }
    }

    @Test("a denied deletion readback is not proof of removal")
    func deletionReadbackFailure() {
        let backend = CredentialFixBackend()
        backend.current = Data("current-fixture".utf8)
        backend.currentStatus = errSecNotAvailable
        #expect(!KeychainSecrets.delete(backend.account, backend: backend))
    }

    @Test("a confirmed missing item can migrate without updating dormant items")
    func migrateMissing() {
        withDefaults { defaults in
            let backend = CredentialFixBackend()
            let value = KeychainSecrets.read(backend.account, backend: backend, defaults: defaults, allowsLegacyReads: true)
            #expect(value == "dormant-fixture")
            #expect(backend.current == backend.dormant)
            #expect(backend.writes == 1)
        }
    }

    @Test("migration cannot overwrite an item created after the absence check",
          arguments: [Data("replacement-fixture".utf8), Data()])
    func migrationRace(original: Data) {
        withDefaults { defaults in
            let backend = CredentialFixBackend()
            backend.racedValue = original
            #expect(KeychainSecrets.read(backend.account, backend: backend, defaults: defaults, allowsLegacyReads: true) == nil)
            #expect(backend.current == original)
            #expect(backend.writes == 1)
        }
    }
}
