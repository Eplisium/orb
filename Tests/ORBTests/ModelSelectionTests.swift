import Foundation
import Testing
@testable import ORB

// MARK: - Fixtures

private func model(id: String, name: String = "Test Model") -> ModelInfo {
    ModelInfo(
        id: id,
        canonicalSlug: nil,
        huggingFaceId: nil,
        name: name,
        created: nil,
        description: nil,
        contextLength: 128_000,
        architecture: Architecture(
            modality: "text->text",
            inputModalities: ["text"],
            outputModalities: ["text"],
            tokenizer: nil,
            instructType: nil
        ),
        pricing: Pricing(prompt: "0.000001", completion: "0.000002", inputCacheRead: nil),
        topProvider: nil,
        supportedParameters: [],
        reasoning: nil,
        knowledgeCutoff: nil,
        expirationDate: nil,
        supportedVoices: nil,
        benchmarks: nil,
        perRequestLimits: nil,
        defaultParameters: nil
    )
}

private func endpointURL(_ modelId: String) -> URL {
    URL(string: "https://openrouter.ai/api/v1/models/\(modelId)/endpoints")!
}

private func endpointsJSON(provider: String) -> String {
    """
    {"data":{"id":"fixture","name":"Fixture","endpoints":[{"provider_name":"\(provider)","pricing":{"prompt":"0.1","completion":"0.2"}}]}}
    """
}

/// URL loader that records every call, answers pre-enqueued responses
/// immediately, and *holds* any other request on a continuation until the
/// test releases it — making out-of-order completion deterministic.
final class GatedLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [URL] = []
    private var immediate: [String: (Data, Int)] = [:]
    private var held: [String: CheckedContinuation<(Data, URLResponse), Never>] = [:]

    func enqueue(_ key: String, json: String, status: Int = 200) {
        lock.lock()
        immediate[key] = (Data(json.utf8), status)
        lock.unlock()
    }

    /// Resumes a held request once, matching the stored full-URL key by
    /// substring. Unreleased requests would hang forever, so every test must
    /// release what it gated.
    func release(_ key: String, json: String, status: Int = 200) {
        lock.lock()
        let heldKey = held.keys.first { $0.contains(key) }
        let cont = heldKey.flatMap { held.removeValue(forKey: $0) }
        lock.unlock()
        let response = HTTPURLResponse(
            url: endpointURL(key), statusCode: status, httpVersion: nil, headerFields: nil
        )!
        cont?.resume(returning: (Data(json.utf8), response))
    }

    func callCount(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.filter { $0.absoluteString.contains(key) }.count
    }

    func handle(_ url: URL) async -> (Data, URLResponse) {
        lock.lock()
        calls.append(url)
        let key = url.absoluteString
        if let (data, status) = immediate.removeValue(forKey: key) {
            lock.unlock()
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        lock.unlock()
        return await withCheckedContinuation { cont in
            lock.lock()
            if let (data, status) = immediate.removeValue(forKey: key) {
                lock.unlock()
                cont.resume(returning: (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!))
            } else {
                held[key] = cont
                lock.unlock()
            }
        }
    }
}

/// MainActor-friendly poll: reads view-model state from the test's actor.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func makeVM(_ loader: GatedLoader) -> BrowserViewModel {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("orb-selection-cache-\(UUID().uuidString).json")
    let api = APIService(cacheURL: cache) { url in
        await loader.handle(url)
    }
    // DatabaseManager() builds an isolated implicit test database, never the
    // user's live store.
    return BrowserViewModel(api: api, db: DatabaseManager())
}

// MARK: - Tests

@Suite("Model selection")
@MainActor
struct ModelSelectionTests {

    @Test("out-of-order endpoint responses only apply to the current selection")
    func outOfOrderSelection() async throws {
        let loader = GatedLoader()
        let vm = makeVM(loader)
        let a = model(id: "openai/gpt-a", name: "A")
        let b = model(id: "openai/gpt-b", name: "B")

        vm.selectModel(a)
        let aStarted = await waitUntil { loader.callCount("openai/gpt-a") == 1 }
        #expect(aStarted)
        vm.selectModel(b)
        let bStarted = await waitUntil { loader.callCount("openai/gpt-b") == 1 }
        #expect(bStarted)
        #expect(vm.selectedModel?.id == "openai/gpt-b")
        // The previous selection's stale rows must not linger under B.
        #expect(vm.endpoints.isEmpty)
        #expect(vm.isLoadingEndpoints)

        // B finishes first, then slow A finishes last.
        loader.release("openai/gpt-b", json: endpointsJSON(provider: "Provider-B"))
        let loaded = await waitUntil { vm.endpoints.first?.providerName == "Provider-B" }
        #expect(loaded)
        loader.release("openai/gpt-a", json: endpointsJSON(provider: "Provider-A"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.endpoints.first?.providerName == "Provider-B")
        #expect(vm.isLoadingEndpoints == false)
    }

    @Test("reselecting the same model does not refetch")
    func sameModelReselectDoesNotRefetch() async throws {
        let loader = GatedLoader()
        loader.enqueue("https://openrouter.ai/api/v1/models/openai/gpt-a/endpoints", json: endpointsJSON(provider: "Provider-A"))
        let vm = makeVM(loader)

        vm.selectModel(model(id: "openai/gpt-a"))
        let loaded = await waitUntil { vm.endpoints.count == 1 }
        #expect(loaded)

        vm.selectModel(model(id: "openai/gpt-a"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.callCount("openai/gpt-a") == 1)
    }

    @Test("refetchEndpoints retries after an error and clears it on success")
    func refetchAfterError() async throws {
        let loader = GatedLoader()
        loader.enqueue("https://openrouter.ai/api/v1/models/openai/gpt-a/endpoints", json: "{}", status: 500)
        let vm = makeVM(loader)

        vm.selectModel(model(id: "openai/gpt-a"))
        let failed = await waitUntil { vm.api.endpointsError != nil }
        #expect(failed)
        #expect(vm.endpoints.isEmpty)

        loader.enqueue("https://openrouter.ai/api/v1/models/openai/gpt-a/endpoints", json: endpointsJSON(provider: "Provider-A"))
        vm.refetchEndpoints()
        let loaded = await waitUntil { vm.endpoints.count == 1 }
        #expect(loaded)
        #expect(vm.api.endpointsError == nil)
        #expect(loader.callCount("openai/gpt-a") == 2)
    }

    @Test("refresh refetches endpoints for the current selection")
    func refreshRefetchesSelectedEndpoints() async throws {
        let loader = GatedLoader()
        loader.enqueue("https://openrouter.ai/api/v1/models/openai/gpt-a/endpoints", json: endpointsJSON(provider: "Provider-A"))
        let vm = makeVM(loader)

        vm.selectModel(model(id: "openai/gpt-a"))
        let loaded = await waitUntil { vm.endpoints.count == 1 }
        #expect(loaded)

        loader.enqueue("https://openrouter.ai/api/v1/models/openai/gpt-a/endpoints", json: endpointsJSON(provider: "Provider-A-2"))
        // refresh() also fetches the model catalog; answer it so the await completes.
        loader.enqueue("https://openrouter.ai/api/v1/models", json: #"{"data":[]}"#)
        await vm.refresh()
        let refetched = await waitUntil { loader.callCount("openai/gpt-a") == 2 }
        #expect(refetched)
        let reloaded = await waitUntil { vm.endpoints.first?.providerName == "Provider-A-2" }
        #expect(reloaded)
    }

    @Test("favorites keep working across selection transitions")
    func favoritesPersistAcrossSelection() async throws {
        let loader = GatedLoader()
        loader.enqueue("https://openrouter.ai/api/v1/models/openai/gpt-a/endpoints", json: endpointsJSON(provider: "Provider-A"))
        let vm = makeVM(loader)

        vm.db.addFavorite("openai/gpt-a")
        vm.loadFavorites()
        #expect(vm.favoriteIds.contains("openai/gpt-a"))

        vm.selectModel(model(id: "openai/gpt-a"))
        let loaded = await waitUntil { vm.endpoints.count == 1 }
        #expect(loaded)
        #expect(vm.favoriteIds.contains("openai/gpt-a"))

        vm.toggleFavorite(model(id: "openai/gpt-b"))
        #expect(vm.favoriteIds.contains("openai/gpt-b"))
        #expect(vm.favoriteIds.contains("openai/gpt-a"))

        vm.toggleFavorite(model(id: "openai/gpt-a"))
        #expect(vm.favoriteIds.contains("openai/gpt-a") == false)
    }

    @Test("deselecting clears endpoints without extra fetches")
    func deselectClearsEndpoints() async throws {
        let loader = GatedLoader()
        loader.enqueue("https://openrouter.ai/api/v1/models/openai/gpt-a/endpoints", json: endpointsJSON(provider: "Provider-A"))
        let vm = makeVM(loader)

        vm.selectModel(model(id: "openai/gpt-a"))
        let loaded = await waitUntil { vm.endpoints.count == 1 }
        #expect(loaded)

        vm.selectModel(nil)
        #expect(vm.selectedModel == nil)
        #expect(vm.endpoints.isEmpty)
        #expect(vm.isLoadingEndpoints == false)
        #expect(loader.callCount("openai/gpt-a") == 1)
    }
}
