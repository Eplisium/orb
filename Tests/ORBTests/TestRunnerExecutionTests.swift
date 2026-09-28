import Foundation
import Testing
@testable import ORB

private actor RecordedClient: OpenRouterClientProtocol {
    var requests: [OpenRouterRequest] = []
    let events: [OpenRouterStreamEvent]
    let error: Error?

    init(_ events: [OpenRouterStreamEvent] = [], error: Error? = nil) {
        self.events = events
        self.error = error
    }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests.append(request)
        let events = self.events
        let error = self.error
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }

    func captured() -> [OpenRouterRequest] { requests }
}

private actor RunGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var waiting = false
    func wait() async throws {
        waiting = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func isWaiting() -> Bool { waiting }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class ExperimentCapture {
    var records: [ExperimentRunRecord] = []
}

@Suite("TestRunner execution", .serialized)
@MainActor
struct TestRunnerExecutionTests {
    private func model(_ id: String, input: [String] = ["text"], output: [String] = ["text"], tools: Bool = false) throws -> ModelInfo {
        let object: [String: Any] = [
            "id": id, "name": id,
            "architecture": ["input_modalities": input, "output_modalities": output],
            "supported_parameters": tools ? ["tools"] : []
        ]
        return try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private var scenario: TestScenario { TestCatalog.allScenarios[0] }

    private func runner(_ client: RecordedClient, capture: ExperimentCapture? = nil,
                        agent: @escaping TestRunner.AgentRun = { _, _, _, _, _, _ in
        Issue.record("Agent should not run for a text model")
        throw CancellationError()
    }) -> TestRunner {
        TestRunner(client: client, agentRun: agent, credential: { "offline-placeholder" },
                   saveResult: { _ in }, saveExperiment: { capture?.records.append($0) },
                   outputRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("Text edge-case probe uses no tools even on a tool-capable model")
    func edgeCaseToolModel() async throws {
        let tool = try model("vendor/tool", tools: true)
        let probe = try #require(TestCatalog.scenario(id: "llm-structured-output"))
        let client = RecordedClient([.contentDelta(choiceIndex: 0, text: "{\"name\":\"A\\\"B\",\"count\":2}")])
        let capture = ExperimentCapture()
        let subject = runner(client, capture: capture) { _, _, _, _, _, _ in
            Issue.record("A text-response scenario must not invoke the agent")
            throw CancellationError()
        }
        await subject.run(scenario: probe, modelId: tool.id, models: [tool])
        #expect(subject.results.first?.errorMessage == TestRunner.unverifiedMessage)
        #expect(subject.results.first?.outputPath == nil)
        #expect(capture.records.first?.verdict == .unverified)
        #expect(capture.records.first?.policy.capabilities == [])
        let request = try #require(await client.captured().first)
        #expect(request.tools == nil)
    }

    @Test("Text routing streams without tools, preserves prompt and usage")
    func textSuccess() async throws {
        let client = RecordedClient([
            .contentDelta(choiceIndex: 0, text: "Answer"),
            .usage(ChatUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5, cost: 0.004)),
            .done
        ])
        let capture = ExperimentCapture()
        let subject = runner(client, capture: capture)
        let text = try model("vendor/text")
        await subject.run(scenario: scenario, modelId: text.id, models: [text], userInput: "extra")
        let result = try #require(subject.results.first)
        #expect(result.modelId == text.id)
        #expect(!result.success)
        #expect(result.errorMessage == TestRunner.unverifiedMessage)
        #expect(capture.records.first?.verdict == .unverified)
        #expect(capture.records.first?.artifactChecks.first?.name == "textResponseMode")
        #expect(result.outputPath == nil)
        #expect(result.totalTokens == 5)
        #expect(result.cost == 0.004)
        let request = try #require(await client.captured().first)
        #expect(request.tools == nil)
        #expect(request.toolChoice == nil)
        #expect(request.messages.last?.content?.contains("User input for this run:\nextra") == true)
    }

    @Test("Refusal, whitespace and provider errors do not pass")
    func textFailures() async throws {
        let text = try model("vendor/text")
        for (events, reason) in [
            ([OpenRouterStreamEvent.contentDelta(choiceIndex: 0, text: "I cannot complete this")], "refusal"),
            ([OpenRouterStreamEvent.contentDelta(choiceIndex: 0, text: "  \n")], "empty"),
            ([OpenRouterStreamEvent.apiError(.init(code: 503, message: "provider down", errorType: nil, providerName: nil))], "provider")
        ] {
            let subject = runner(RecordedClient(events))
            await subject.run(scenario: scenario, modelId: text.id, models: [text])
            let result = try #require(subject.results.first)
            #expect(!result.success, "\(reason) must fail")
            #expect(result.errorMessage != nil)
        }
        let transport = runner(RecordedClient(error: OpenRouterClientError.abruptEOF))
        await transport.run(scenario: scenario, modelId: text.id, models: [text])
        #expect(transport.results.first?.success == false)
        #expect(transport.results.first?.errorMessage?.contains("terminal event") == true)

        let truncated = runner(RecordedClient([
            .contentDelta(choiceIndex: 0, text: "partial"),
            .finishReason(choiceIndex: 0, reason: "length")
        ]))
        await truncated.run(scenario: scenario, modelId: text.id, models: [text])
        #expect(truncated.results.first?.success == false)
        #expect(truncated.results.first?.errorMessage?.contains("truncated") == true)
    }

    @Test("Project summary cannot pass without artifacts; evaluator verdict governs")
    func projectVerdict() async throws {
        let tool = try model("vendor/tool", tools: true)
        let client = RecordedClient()
        let subject = runner(client) { _, modelID, _, directory, _, _ in
            #expect(modelID == tool.id)
            #expect(FileManager.default.fileExists(atPath: directory.path))
            return NativeAgentRunResult(response: "I built it", history: [], usage: nil,
                                        toolNames: [], toolCallDisplays: [], toolMessages: [])
        }
        await subject.run(scenario: scenario, modelId: tool.id, models: [tool])
        let result = try #require(subject.results.first)
        #expect(!result.success)
        #expect(result.outputPath != nil)
        #expect(await client.captured().isEmpty)
        if let path = result.outputPath { try? FileManager.default.removeItem(atPath: path) }
    }

    @Test("Project artifact creates a passing verdict; tool budget cannot pass")
    func projectSuccessAndBudget() async throws {
        let tool = try model("vendor/tool", tools: true)
        let fixture = TestScenario(id: "offline-project", category: .apiDesign, title: "Offline project",
            subtitle: "", icon: "doc", difficulty: .foundational, estimatedSeconds: 1,
            systemPrompt: "Build", userPrompt: "Create", evaluationCriteria: [])
        let capture = ExperimentCapture()
        let subject = runner(RecordedClient(), capture: capture) { _, _, _, directory, _, _ in
            try Data("actual artifact".utf8).write(to: directory.appendingPathComponent("file.txt"))
            return NativeAgentRunResult(response: "Created file.txt", history: [], usage: nil,
                toolNames: ["write_file"], toolCallDisplays: [], toolMessages: [])
        }
        await subject.run(scenario: fixture, modelId: tool.id, models: [tool])
        #expect(subject.results.first?.success == true)
        #expect(capture.records.first?.verdict == .passed)
        if let path = subject.results.first?.outputPath { try? FileManager.default.removeItem(atPath: path) }

        let exhausted = runner(RecordedClient()) { _, _, _, directory, _, _ in
            try Data("actual artifact".utf8).write(to: directory.appendingPathComponent("file.txt"))
            return NativeAgentRunResult(response: "Created file.txt", history: [], usage: nil,
                toolNames: ["write_file"], toolCallDisplays: [], toolMessages: [], hitToolBudget: true)
        }
        await exhausted.run(scenario: fixture, modelId: tool.id, models: [tool])
        #expect(exhausted.results.first?.success == false)
        if let path = exhausted.results.first?.outputPath { try? FileManager.default.removeItem(atPath: path) }
    }

    @Test("Selection deduplicates, rejects unsupported modalities, and limits batch")
    func selection() throws {
        let text = try model("a/text")
        let tool = try model("b/tool", tools: true)
        let image = try model("c/image", output: ["image"])
        #expect(TestModelRoute.resolve(text) == .text)
        #expect(TestModelRoute.resolve(tool) == .project)
        #expect(TestModelRoute.resolve(image) == nil)
        #expect(TestBatchSelection.eligibleIDs([text.id, text.id, image.id, tool.id, "missing"], catalog: [text, tool, image]) == [text.id, tool.id])
        #expect(TestBatchSelection.maximumModels == 5)
    }

    @Test("Batch keeps separate model results and stops at known spend ceiling")
    func budgetAndAttribution() async throws {
        let a = try model("a/text")
        let b = try model("b/text")
        let c = try model("c/text")
        let client = RecordedClient([
            .contentDelta(choiceIndex: 0, text: "answer"),
            .usage(ChatUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2, cost: 0.60))
        ])
        let subject = runner(client)
        subject.start(scenario: scenario, modelIDs: [a.id, b.id, c.id], models: [a, b, c], ceilingUSD: 1.0)
        for _ in 0..<100 where subject.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(subject.batchCompleted == 2)
        #expect(Set(subject.results.map(\.modelId)) == Set([a.id, b.id]))
        #expect(await client.captured().map(\.model) == [a.id, b.id])
        #expect(subject.batchNotice?.contains("ceiling") == true)
    }

    @Test("Unknown spend stops a paid batch before the next model")
    func unknownSpend() async throws {
        let a = try model("a/text")
        let b = try model("b/text")
        let client = RecordedClient([.contentDelta(choiceIndex: 0, text: "answer")])
        let subject = runner(client)
        subject.start(scenario: scenario, modelIDs: [a.id, b.id], models: [a, b], ceilingUSD: 1.0)
        for _ in 0..<100 where subject.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(subject.batchCompleted == 1)
        #expect(subject.batchNotice?.contains("did not report cost") == true)
        #expect(await client.captured().count == 1)
    }

    @Test("Selection over cap and invalid ceiling start no requests")
    func invalidStarts() throws {
        let models = try (0..<6).map { try model("vendor/\($0)") }
        let client = RecordedClient()
        let subject = runner(client)
        subject.start(scenario: scenario, modelIDs: models.map(\.id), models: models, ceilingUSD: 1)
        #expect(!subject.isRunning)
        #expect(subject.batchNotice?.contains("at most") == true)
        subject.start(scenario: scenario, modelIDs: [models[0].id], models: models, ceilingUSD: -1)
        #expect(!subject.isRunning)
        #expect(subject.results.isEmpty)
    }

    @Test("Concurrent starts are ignored, cancellation skips unstarted models")
    func cancellation() async throws {
        let a = try model("a/tool", tools: true)
        let b = try model("b/tool", tools: true)
        let gate = RunGate()
        let subject = runner(RecordedClient()) { _, _, _, _, _, _ in
            try await gate.wait()
            return NativeAgentRunResult(response: "done", history: [], usage: nil,
                                        toolNames: [], toolCallDisplays: [], toolMessages: [])
        }
        subject.start(scenario: scenario, modelIDs: [a.id, b.id], models: [a, b])
        subject.start(scenario: scenario, modelIDs: [b.id], models: [a, b])
        #expect(subject.batchTotal == 2)
        for _ in 0..<100 where !(await gate.isWaiting()) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.isWaiting())
        subject.cancel()
        await gate.release()
        for _ in 0..<100 where subject.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!subject.isRunning)
        #expect(subject.batchCompleted == 1)
        #expect(subject.results.first?.errorMessage == "Cancelled by user")
    }
}
