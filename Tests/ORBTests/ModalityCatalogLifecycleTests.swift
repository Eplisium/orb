import Foundation
import Testing
@testable import ORB

@Suite("Modality catalog lifecycle", .serialized)
@MainActor
struct ModalityCatalogLifecycleTests {
    @Test("Failed refresh preserves models and a subsequent load retries")
    func failureCanRetry() async {
        let transport = MockMediaTransport(responses: [
            .json(#"{"data":[{"id":"speech/old","name":"Old"}]}"#),
            .status(503, "offline fixture"),
            .json(#"{"data":[{"id":"speech/new","name":"New"}]}"#)
        ])
        let choices = ModalityModelChoices(catalog: GenerateModelCatalog(transport: transport))
        await choices.load("speech")
        await choices.load("speech")
        #expect(choices.models.map(\.id) == ["speech/old"])
        #expect(choices.error != nil)
        #expect(!choices.isLoading)
        await choices.load("speech")
        #expect(choices.models.map(\.id) == ["speech/new"])
        #expect(choices.error == nil)
        #expect(!choices.isLoading)
        #expect(transport.sentCount() == 3)
    }

    @Test("Different modality requests serialize instead of sharing the wrong response")
    func differentModalityDoesNotJoinWrongCatalog() async throws {
        let transport = ModalityHeldTransport()
        let choices = ModalityModelChoices(catalog: GenerateModelCatalog(transport: transport))
        let first = Task { await choices.load("speech") }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await transport.gate.isWaiting("speech")), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        var began = false
        let second = Task { @MainActor in
            began = true
            await choices.load("embeddings")
        }
        while !began { await Task.yield() }
        #expect(await transport.gate.count("embeddings") == 0)
        await transport.gate.release("speech")
        await first.value
        // Releasing before the request arrives is also safe in this fixture.
        await transport.gate.release("embeddings")
        await second.value
        #expect(choices.models.map(\.id) == ["embeddings/fixture"])
        #expect(await transport.gate.count("speech") == 1)
        #expect(await transport.gate.count("embeddings") == 1)
        #expect(!choices.isLoading)
    }

    @Test("Replacement callers await discovery after the first view departs", arguments: ["speech", "transcription", "embeddings", "rerank"])
    func cancelledCallerDoesNotOwnRefresh(modality: String) async throws {
        let transport = ModalityHeldTransport()
        let choices = ModalityModelChoices(catalog: GenerateModelCatalog(transport: transport))
        let first = Task { await choices.load(modality) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await transport.gate.isWaiting(modality)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await transport.gate.isWaiting(modality) else {
            first.cancel()
            await transport.gate.release(modality)
            await first.value
            Issue.record("Catalog request never reached its gate")
            return
        }
        first.cancel()
        var began = false
        var finished = false
        let replacement = Task { @MainActor in
            began = true
            await choices.load(modality)
            finished = true
            return choices.models.map(\.id)
        }
        while !began { await Task.yield() }
        #expect(!finished)
        #expect(choices.isLoading)
        await transport.gate.release(modality)
        await first.value
        let received = await replacement.value
        #expect(received == ["\(modality)/fixture"])
        #expect(await transport.gate.count(modality) == 1)
        #expect(!choices.isLoading)
        #expect(choices.error == nil)
    }
}

private actor ModalityCatalogGate {
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<String> = []
    private var requests: [String: Int] = [:]
    func isWaiting(_ modality: String) -> Bool { !(waiters[modality] ?? []).isEmpty }
    func count(_ modality: String) -> Int { requests[modality, default: 0] }
    func pause(_ modality: String) async {
        requests[modality, default: 0] += 1
        if released.contains(modality) { return }
        await withCheckedContinuation { waiters[modality, default: []].append($0) }
    }
    func release(_ modality: String) {
        released.insert(modality)
        for waiter in waiters.removeValue(forKey: modality) ?? [] { waiter.resume() }
    }
}

private final class ModalityHeldTransport: MediaTransport, @unchecked Sendable {
    let gate = ModalityCatalogGate()
    init() {
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "test-key" })
    }
    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let url = request.url!
        let modality = url.path.hasSuffix("embeddings/models") ? "embeddings" :
            URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first(where: { $0.name == "output_modalities" })!.value!
        await gate.pause(modality)
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: Data("{\"data\":[{\"id\":\"\(modality)/fixture\",\"name\":\"Fixture\"}]}".utf8))
    }
}
