import Foundation
import Testing
@testable import ORB

/// Store whose deletion always fails while the secret stays present.
private final class LifecycleStuckStore: CredentialSecretStore, @unchecked Sendable {
    let inner = InMemoryCredentialStore()
    func secret(forReference r: String) -> String? { inner.secret(forReference: r) }
    func saveSecret(_ s: String, forReference r: String) -> String? { inner.saveSecret(s, forReference: r) }
    func deleteSecret(forReference r: String) -> Bool { false }
    func hasSecret(forReference r: String) -> Bool { inner.hasSecret(forReference: r) }
}

/// Data loader whose responses are released manually, keyed by bearer token.
private final class LifecycleGatedLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<(Data, URLResponse), Error>] = [:]

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let token = (request.url?.lastPathComponent ?? "") + "|" + (request.value(forHTTPHeaderField: "Authorization") ?? "")
        return try await withCheckedThrowingContinuation { c in
            lock.lock(); pending[token] = c; lock.unlock()
        }
    }

    func isPending(_ key: String, _ path: String = "credits") -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending["\(path)|Bearer \(key)"] != nil
    }

    func finish(_ key: String, _ path: String = "credits", body: String) {
        lock.lock()
        let c = pending.removeValue(forKey: "\(path)|Bearer \(key)")
        lock.unlock()
        let url = URL(string: "https://openrouter.ai/api/v1/x")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        c?.resume(returning: (Data(body.utf8), resp))
    }
}

private func credits(_ total: Double) -> String {
    #"{"data":{"total_credits":\#(total),"total_usage":1.0}}"#
}

private func activity(_ model: String) -> String {
    #"{"data":[{"date":"2026-10-01","model":"\#(model)","usage":1.0,"requests":1,"prompt_tokens":1,"completion_tokens":1,"reasoning_tokens":0}]}"#
}

@MainActor
private func waitUntil(_ cond: @autoclosure () -> Bool) async {
    for _ in 0..<2000 where !cond() { await Task.yield() }
}

@Suite("Account service credential lifecycle")
@MainActor
struct AccountServiceCredentialLifecycleTests {
    private let ref = CredentialRole.management.keychainAccount

    private func make(_ loader: LifecycleGatedLoader, key: String = "A") -> (AccountService, InMemoryCredentialStore) {
        let store = InMemoryCredentialStore()
        store.saveSecret(key, forReference: ref)
        let svc = AccountService(profile: CredentialProfile(managementKeyReference: ref), secretStore: store) {
            try await loader.load($0)
        }
        return (svc, store)
    }

    @Test("replacement in another window clears already loaded credits and activity")
    func crossInstanceLoadedData() async {
        let store = InMemoryCredentialStore()
        _ = store.saveSecret("A", forReference: ref)
        let loader: AccountService.DataLoader = { request in
            let body = request.url?.lastPathComponent == "credits" ? credits(100) : activity("model-a")
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let first = AccountService(secretStore: store, dataLoader: loader)
        let second = AccountService(secretStore: store, dataLoader: loader)
        await first.fetchCredits()
        await first.fetchActivity()
        #expect(first.credits != nil)
        #expect(!first.activity.isEmpty)
        let revision = first.credentialRevision
        #expect(second.setManagementKey("B") == nil)
        // No window-focus or manual refresh required.
        #expect(first.credits == nil)
        #expect(first.activity.isEmpty)
        #expect(first.hasManagementKey)
        #expect(first.credentialRevision != revision)
    }

    @Test("other-window replacement drops late credits, activity, and failures", arguments: [false, true])
    func crossInstanceLateResponses(failOld: Bool) async {
        let loader = LifecycleGatedLoader()
        let (first, store) = make(loader)
        let second = AccountService(secretStore: store)
        let oldCredits = Task { await first.fetchCredits() }
        let oldActivity = Task { await first.fetchActivity() }
        await waitUntil(loader.isPending("A") && loader.isPending("A", "activity"))
        #expect(second.setManagementKey("B") == nil)
        let newCredits = Task { await first.fetchCredits() }
        let newActivity = Task { await first.fetchActivity() }
        await waitUntil(loader.isPending("B") && loader.isPending("B", "activity"))
        loader.finish("A", body: failOld ? "invalid" : credits(100))
        loader.finish("A", "activity", body: failOld ? "invalid" : activity("model-a"))
        await oldCredits.value
        await oldActivity.value
        #expect(first.credits == nil)
        #expect(first.activity.isEmpty)
        #expect(first.creditsError == nil)
        #expect(first.activityError == nil)
        #expect(first.isLoadingCredits)
        #expect(first.isLoadingActivity)
        loader.finish("B", body: credits(200))
        loader.finish("B", "activity", body: activity("model-b"))
        await newCredits.value
        await newActivity.value
        #expect(first.credits?.totalCredits == 200)
        #expect(first.activity.map(\.model) == ["model-b"])
    }

    @Test("other-window removal invalidates in-flight account data")
    func crossInstanceRemoval() async {
        let loader = LifecycleGatedLoader()
        let (first, store) = make(loader)
        let second = AccountService(secretStore: store)
        let pending = Task { await first.fetchCredits() }
        await waitUntil(loader.isPending("A"))
        #expect(second.removeManagementKey() == nil)
        #expect(!first.hasManagementKey)
        #expect(!first.isLoadingCredits)
        loader.finish("A", body: credits(100))
        await pending.value
        #expect(first.credits == nil)
    }

    @Test("direct shared-store writes invalidate, unrelated references and stores do not")
    func scopedStoreRevisions() async {
        let store = InMemoryCredentialStore()
        _ = store.saveSecret("A", forReference: ref)
        let first = AccountService(secretStore: store) { request in
            (Data(credits(100).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await first.fetchCredits()
        let revision = first.credentialRevision
        _ = store.saveSecret("inference-fixture", forReference: CredentialRole.inference.keychainAccount)
        _ = InMemoryCredentialStore().saveSecret("B", forReference: ref)
        #expect(first.credits != nil)
        #expect(first.credentialRevision == revision)
        _ = store.saveSecret("B", forReference: ref)
        #expect(first.credits == nil)
        #expect(first.credentialRevision != revision)
    }

    @Test("background store mutation invalidates a suspended response")
    func backgroundStoreReplacement() async {
        let loader = LifecycleGatedLoader()
        let (first, store) = make(loader)
        let pending = Task { await first.fetchCredits() }
        await waitUntil(loader.isPending("A"))
        let reference = ref
        await Task.detached { _ = store.saveSecret("B", forReference: reference) }.value
        loader.finish("A", body: credits(100))
        await pending.value
        #expect(first.credits == nil)
        #expect(first.creditsError == nil)
        #expect(!first.isLoadingCredits)
        #expect(first.hasManagementKey)
    }

    // MARK: Bug 2 — stale responses

    @Test("credits: a slow response for a replaced key never overwrites the new account")
    func staleCreditsDropped() async {
        let loader = LifecycleGatedLoader()
        let (svc, _) = make(loader)
        let a = Task { await svc.fetchCredits() }
        await waitUntil(loader.isPending("A"))
        svc.setManagementKey("B")
        let b = Task { await svc.fetchCredits() }
        await waitUntil(loader.isPending("B"))

        loader.finish("B", body: credits(200)); await b.value
        #expect(svc.credits?.totalCredits == 200)
        #expect(svc.isLoadingCredits == false)

        loader.finish("A", body: credits(100)); await a.value
        #expect(svc.credits?.totalCredits == 200)
        #expect(svc.creditsError == nil)
        #expect(svc.isLoadingCredits == false)
    }

    @Test("activity: a slow response for a replaced key never overwrites the new account")
    func staleActivityDropped() async {
        let loader = LifecycleGatedLoader()
        let (svc, _) = make(loader)
        let a = Task { await svc.fetchActivity() }
        await waitUntil(loader.isPending("A", "activity"))
        svc.setManagementKey("B")
        let b = Task { await svc.fetchActivity() }
        await waitUntil(loader.isPending("B", "activity"))

        loader.finish("B", "activity", body: activity("model-b")); await b.value
        loader.finish("A", "activity", body: activity("model-a")); await a.value
        #expect(svc.activity.map(\.model) == ["model-b"])
        #expect(svc.isLoadingActivity == false)
    }

    @Test("a stale response finishing while the new request is in flight keeps loading on")
    func staleDoesNotClearNewLoading() async {
        let loader = LifecycleGatedLoader()
        let (svc, _) = make(loader)
        let a = Task { await svc.fetchCredits() }
        await waitUntil(loader.isPending("A"))
        svc.setManagementKey("B")
        let b = Task { await svc.fetchCredits() }
        await waitUntil(loader.isPending("B"))
        #expect(svc.isLoadingCredits)

        loader.finish("A", body: credits(100)); await a.value
        #expect(svc.credits == nil)
        #expect(svc.isLoadingCredits, "B is still loading")

        loader.finish("B", body: credits(200)); await b.value
        #expect(svc.credits?.totalCredits == 200)
        #expect(svc.isLoadingCredits == false)
    }

    @Test("removal during flight: the late response is dropped and loading is not stuck")
    func removalDuringFlight() async {
        let loader = LifecycleGatedLoader()
        let (svc, _) = make(loader)
        let c = Task { await svc.fetchCredits() }
        let act = Task { await svc.fetchActivity() }
        await waitUntil(loader.isPending("A"))
        svc.removeManagementKey()
        #expect(svc.isLoadingCredits == false)
        #expect(svc.isLoadingActivity == false)

        await waitUntil(loader.isPending("A", "activity"))
        loader.finish("A", body: credits(100)); await c.value
        loader.finish("A", "activity", body: activity("model-a")); await act.value
        #expect(svc.credits == nil)
        #expect(svc.activity.isEmpty)
        #expect(svc.hasManagementKey == false)
        #expect(svc.isLoadingCredits == false)
        #expect(svc.isLoadingActivity == false)
    }

    @Test("an error from a stale request is dropped too")
    func staleErrorDropped() async {
        let loader = LifecycleGatedLoader()
        let (svc, _) = make(loader)
        let a = Task { await svc.fetchCredits() }
        await waitUntil(loader.isPending("A"))
        svc.setManagementKey("B")
        loader.finish("A", body: "not json"); await a.value
        #expect(svc.creditsError == nil)
    }

    // MARK: Bug 1 — removal failure surfaces

    @Test("failed removal reports the error and keeps state, key and data")
    func failedRemovalKeepsState() async {
        let store = LifecycleStuckStore()
        store.inner.saveSecret("A", forReference: ref)
        let svc = AccountService(profile: CredentialProfile(managementKeyReference: ref), secretStore: store) { req in
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(credits(10).utf8), r)
        }
        await svc.fetchCredits()
        #expect(svc.credits != nil)

        let error = svc.removeManagementKey()

        #expect(error != nil)
        #expect(svc.hasManagementKey == true)
        #expect(svc.credits != nil)
    }

    @Test("the Settings panel shows a failed removal instead of 'removed'")
    func panelSurfacesFailedRemoval() {
        let store = LifecycleStuckStore()
        store.inner.saveSecret("A", forReference: ref)
        let svc = AccountService(profile: CredentialProfile(managementKeyReference: ref), secretStore: store)
        var panel = ManagementKeyPanel()
        panel.removeKey(into: svc)
        #expect(panel.actionError != nil)
        #expect(svc.hasManagementKey)
    }

    @Test("a failed replacement keeps hasManagementKey truthful (old key still present)")
    func failedReplaceKeepsPresence() {
        let store = LifecycleStuckStore()
        store.inner.saveSecret("A", forReference: ref)
        final class FailSave: CredentialSecretStore, @unchecked Sendable {
            let base: LifecycleStuckStore
            init(_ b: LifecycleStuckStore) { base = b }
            func secret(forReference r: String) -> String? { base.secret(forReference: r) }
            func saveSecret(_ s: String, forReference r: String) -> String? { "Keychain error -1." }
            func deleteSecret(forReference r: String) -> Bool { false }
            func hasSecret(forReference r: String) -> Bool { base.hasSecret(forReference: r) }
        }
        let svc = AccountService(profile: CredentialProfile(managementKeyReference: ref), secretStore: FailSave(store))
        #expect(svc.setManagementKey("B") != nil)
        #expect(svc.hasManagementKey == true)
    }
}
