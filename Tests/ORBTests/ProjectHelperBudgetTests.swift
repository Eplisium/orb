import Foundation
import Testing
@testable import ORB

@Suite("Project helper budget integration", .serialized)
@MainActor
struct ProjectHelperBudgetTests {
    @Test("Known and unknown helper spend both stop the next model", arguments: [true, false])
    func helperCostStopsBatch(known: Bool) async throws {
        let prefix = "budget-\(UUID())"
        func model(_ suffix: String) throws -> ModelInfo {
            let json: [String: Any] = ["id": "\(prefix)/\(suffix)", "name": suffix,
                "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]],
                "supported_parameters": ["tools"]]
            return try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let a = try model("a"), b = try model("b")
        let client = HelperBudgetClient()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = TestRunner(client: client, agentToolExecutor: { _ in
            await MainActor.run {
                UsageLedger.shared.record(.agentWebSearch, model: a.id, cost: known ? 2 : nil)
            }
            return .init(content: "Fixture search", isError: false)
        }, credential: { "fixture" }, saveResult: { _ in }, saveExperiment: { _ in }, outputRoot: directory)
        let scenario = TestScenario(id: "helper-budget", category: .apiDesign, title: "Fixture",
            subtitle: "", icon: "doc", difficulty: .foundational, estimatedSeconds: 1,
            systemPrompt: "Build", userPrompt: "Create", evaluationCriteria: [])
        subject.start(scenario: scenario, modelIDs: [a.id, b.id], models: [a, b], ceilingUSD: 1)
        for _ in 0..<1000 where subject.isRunning { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!subject.isRunning)
        #expect(subject.batchCompleted == 1)
        #expect(await client.models == [a.id, a.id])
        #expect(subject.batchUnreportedRuns == (known ? 0 : 1))
        #expect(subject.batchNotice?.contains(known ? "ceiling" : "did not report cost") == true)
        let expected = known ? 2.4 : 0.4
        #expect(abs((subject.results.first?.cost ?? -1) - expected) < 0.000001)
        let bucket = try #require(UsageLedger.shared.buckets(.model).first { $0.key == a.id })
        #expect(abs(bucket.cost - expected) < 0.000001)
        #expect(bucket.requests == 3)
        #expect(bucket.unpricedRequests == (known ? 0 : 1))
    }
}

private actor HelperBudgetClient: OpenRouterClientProtocol {
    var models: [String] = []
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        models.append(request.model)
        let first = models.count % 2 == 1
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(.toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "search", type: "function", name: "web_search", arguments: #"{"query":"fixture"}"#))
                continuation.yield(.finishReason(choiceIndex: 0, reason: "tool_calls"))
            } else {
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Done."))
            }
            continuation.yield(.usage(ChatUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2, cost: 0.2)))
            continuation.finish()
        }
    }
}
