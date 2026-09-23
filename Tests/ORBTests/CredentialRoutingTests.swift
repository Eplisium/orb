import Foundation
import Testing
@testable import ORB

@Suite("Credential routing")
@MainActor
struct CredentialRoutingTests {

    private func makeAccountService(
        store: InMemoryCredentialStore,
        calls: MockCallCounter
    ) -> AccountService {
        let profile = CredentialProfile(
            managementKeyReference: CredentialRole.management.keychainAccount
        )
        return AccountService(profile: profile, secretStore: store) { request in
            calls.increment()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    // MARK: Role separation

    @Test("roles resolve only their own secret reference")
    func roleReferenceIsolation() {
        let store = InMemoryCredentialStore()
        store.saveSecret("inference-secret", forReference: CredentialRole.inference.keychainAccount)
        store.saveSecret("management-secret", forReference: CredentialRole.management.keychainAccount)
        let profile = CredentialProfile(
            managementKeyReference: CredentialRole.management.keychainAccount
        )
        #expect(CredentialRouter.secret(for: .inference, profile: profile, store: store) == "inference-secret")
        #expect(CredentialRouter.secret(for: .management, profile: profile, store: store) == "management-secret")
        // Distinct references per role — keys cannot be swapped accidentally.
        #expect(CredentialRole.inference.keychainAccount != CredentialRole.management.keychainAccount)
    }

    @Test("profiles carry references, never secrets")
    func profileCodableContainsNoSecret() throws {
        let profile = CredentialProfile(name: "Work", managementKeyReference: "openrouter-management-key")
        let data = try JSONEncoder().encode(profile)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("sk-or"))
        #expect(json.contains("openrouter-management-key"))
        let decoded = try JSONDecoder().decode(CredentialProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test("a profile without a management reference has no management secret")
    func managementOptional() {
        let store = InMemoryCredentialStore()
        store.saveSecret("inference-secret", forReference: CredentialRole.inference.keychainAccount)
        let profile = CredentialProfile() // no management reference
        #expect(CredentialRouter.secret(for: .management, profile: profile, store: store) == nil)
        #expect(CredentialRouter.secret(for: .inference, profile: profile, store: store) == "inference-secret")
    }

    // MARK: Management-gated panels

    @Test("credits and activity lock with an actionable message when no management key exists")
    func panelsLockWithoutManagementKey() async {
        let store = InMemoryCredentialStore()
        let calls = MockCallCounter()
        let service = makeAccountService(store: store, calls: calls)
        #expect(service.hasManagementKey == false)

        await service.fetchCredits()
        #expect(service.credits == nil)
        #expect(service.creditsError?.contains("Management key required") == true)

        await service.fetchActivity()
        #expect(service.activity.isEmpty)
        #expect(service.activityError?.contains("Management key required") == true)

        // Locked panels must not hit the network at all.
        #expect(calls.current == 0)
    }

    @Test("management key authorizes credits and activity; inference key is never sent")
    func managementKeyRoutesToAccountEndpoints() async throws {
        let store = InMemoryCredentialStore()
        store.saveSecret("inference-secret", forReference: CredentialRole.inference.keychainAccount)
        store.saveSecret("management-secret", forReference: CredentialRole.management.keychainAccount)

        var recorded: [URLRequest] = []
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        let service = AccountService(profile: profile, secretStore: store) { request in
            recorded.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let body: Data
            if request.url?.path.hasSuffix("/credits") == true {
                body = Data(#"{"data":{"total_credits":10.0,"total_usage":2.5}}"#.utf8)
            } else {
                body = Data(#"{"data":[]}"#.utf8)
            }
            return (body, response)
        }
        #expect(service.hasManagementKey)

        await service.fetchCredits()
        #expect(service.credits?.totalCredits == 10.0)
        #expect(service.creditsError == nil)
        let creditsRequest = try #require(recorded.last)
        #expect(creditsRequest.url?.path == "/api/v1/credits")
        #expect(creditsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret")

        await service.fetchActivity()
        #expect(service.activityError == nil)
        let activityRequest = try #require(recorded.last)
        #expect(activityRequest.url?.path == "/api/v1/activity")
        #expect(activityRequest.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret")
        // The inference key never crosses to an account endpoint.
        for request in recorded {
            #expect(request.value(forHTTPHeaderField: "Authorization") != "Bearer inference-secret")
        }
    }

    @Test("401 from a management operation is reported as a management-key rejection")
    func unauthorizedManagementKeyMessage() async throws {
        let store = InMemoryCredentialStore()
        store.saveSecret("management-secret", forReference: CredentialRole.management.keychainAccount)
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        let service = AccountService(profile: profile, secretStore: store) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        await service.fetchCredits()
        #expect(service.creditsError?.contains("Management key rejected") == true)
    }

    // MARK: Key lifecycle safety

    @Test("removing the management key clears published account data immediately")
    func removalClearsPublishedData() async throws {
        let store = InMemoryCredentialStore()
        store.saveSecret("management-secret", forReference: CredentialRole.management.keychainAccount)
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        let service = AccountService(profile: profile, secretStore: store) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":{"total_credits":10.0,"total_usage":2.5}}"#.utf8), response)
        }
        await service.fetchCredits()
        #expect(service.credits != nil)

        service.removeManagementKey()
        #expect(service.hasManagementKey == false)
        #expect(service.credits == nil)
        #expect(service.activity.isEmpty)

        // Subsequent fetches are locked again without touching the network.
        await service.fetchCredits()
        #expect(service.creditsError?.contains("Management key required") == true)
    }

    @Test("failed management key save keeps the previous key")
    func failedSaveKeepsPreviousKey() async throws {
        final class FailingSaveStore: CredentialSecretStore {
            let existing: InMemoryCredentialStore
            init(existing: InMemoryCredentialStore) { self.existing = existing }
            func secret(forReference reference: String) -> String? {
                existing.secret(forReference: reference)
            }
            func saveSecret(_ secret: String, forReference reference: String) -> String? {
                "Keychain error -25299."
            }
            func deleteSecret(forReference reference: String) -> Bool {
                existing.deleteSecret(forReference: reference)
            }
            func hasSecret(forReference reference: String) -> Bool {
                existing.hasSecret(forReference: reference)
            }
        }

        let backing = InMemoryCredentialStore()
        backing.saveSecret("previous-management-key", forReference: CredentialRole.management.keychainAccount)
        let store = FailingSaveStore(existing: backing)
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        let service = AccountService(profile: profile, secretStore: store) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        let error = service.setManagementKey("replacement-key")
        #expect(error?.contains("Keychain error") == true)
        #expect(store.secret(forReference: CredentialRole.management.keychainAccount) == "previous-management-key")
        #expect(service.hasManagementKey == false)
    }
}
