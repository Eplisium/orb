import Foundation
import Security
import Testing
@testable import ORB

/// In-memory stand-in for the Security framework. Never touches the real
/// Keychain; every operation is logged and any status can be forced to fail.
private final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    var items: [String: Data] = [:]
    private(set) var log: [String] = []
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess

    private func key(_ q: [String: Any]) -> String {
        "\(q[kSecAttrService as String] as? String ?? "")|\(q[kSecAttrAccount as String] as? String ?? "")"
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        log.append("add")
        if addStatus != errSecSuccess { return addStatus }
        let k = key(attributes)
        if items[k] != nil { return errSecDuplicateItem }
        items[k] = attributes[kSecValueData as String] as? Data ?? Data()
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        log.append("update")
        if updateStatus != errSecSuccess { return updateStatus }
        let k = key(query)
        guard items[k] != nil else { return errSecItemNotFound }
        if let d = attributes[kSecValueData as String] as? Data { items[k] = d }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        log.append("delete")
        if deleteStatus != errSecSuccess { return deleteStatus }
        return items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        lock.lock(); defer { lock.unlock() }
        guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data as AnyObject)
    }
}

@Suite("Keychain secrets failure handling")
struct KeychainSecretsFailureTests {
    private let account = "test-account"
    private var service: String { KeychainSecrets.currentService }
    private var itemKey: String { "\(service)|\(account)" }

    @Test("a failed replacement keeps the old key and reports the error")
    func failedReplacementKeepsOldKey() {
        let fake = FakeKeychainBackend()
        #expect(KeychainSecrets.save(account, "old-key", backend: fake) == nil)
        fake.updateStatus = errSecAuthFailed
        fake.addStatus = errSecAuthFailed

        let error = KeychainSecrets.save(account, "new-key", backend: fake)

        #expect(error != nil)
        #expect(KeychainSecrets.read(account, backend: fake) == "old-key")
        #expect(!fake.log.contains("delete"))
    }

    @Test("replacing an existing key updates the value only: no delete, no add")
    func replacementIsValueOnlyUpdate() {
        let fake = FakeKeychainBackend()
        _ = KeychainSecrets.save(account, "old-key", backend: fake)
        let before = fake.log.count
        #expect(KeychainSecrets.save(account, "new-key", backend: fake) == nil)
        #expect(Array(fake.log.dropFirst(before)) == ["update"])
        #expect(KeychainSecrets.read(account, backend: fake) == "new-key")
    }

    @Test("a failed first add stores nothing and reports the error")
    func failedFirstAdd() {
        let fake = FakeKeychainBackend()
        fake.addStatus = errSecInteractionNotAllowed
        #expect(KeychainSecrets.save(account, "k", backend: fake) != nil)
        #expect(fake.items.isEmpty)
    }

    @Test("a failed delete reports failure and the credential is still present")
    func failedDeleteReportsFailure() {
        let fake = FakeKeychainBackend()
        _ = KeychainSecrets.save(account, "secret", backend: fake)
        fake.updateStatus = errSecAuthFailed
        fake.deleteStatus = errSecAuthFailed

        #expect(KeychainSecrets.delete(account, backend: fake) == false)
        #expect(KeychainSecrets.exists(account, backend: fake))
        #expect(KeychainSecrets.read(account, backend: fake) == "secret")
    }

    @Test("a successful delete leaves a verified empty tombstone")
    func successfulDelete() {
        let fake = FakeKeychainBackend()
        _ = KeychainSecrets.save(account, "secret", backend: fake)
        #expect(KeychainSecrets.delete(account, backend: fake))
        #expect(!KeychainSecrets.exists(account, backend: fake))
        #expect(KeychainSecrets.read(account, backend: fake) == nil)
        #expect(fake.items[itemKey] == Data())
    }

    @Test("deleting when nothing is stored writes a tombstone and succeeds")
    func deleteWhenAbsent() {
        let fake = FakeKeychainBackend()
        #expect(KeychainSecrets.delete(account, backend: fake))
        #expect(fake.items[itemKey] == Data())
    }

    @Test("a failed tombstone write reports failure")
    func failedTombstone() {
        let fake = FakeKeychainBackend()
        fake.addStatus = errSecAuthFailed
        #expect(KeychainSecrets.delete(account, backend: fake) == false)
    }

    @Test("a save after a delete revives the tombstone")
    func saveAfterDelete() {
        let fake = FakeKeychainBackend()
        _ = KeychainSecrets.save(account, "a", backend: fake)
        _ = KeychainSecrets.delete(account, backend: fake)
        #expect(KeychainSecrets.save(account, "b", backend: fake) == nil)
        #expect(KeychainSecrets.read(account, backend: fake) == "b")
    }
}
