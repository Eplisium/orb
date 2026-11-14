import Foundation
import Testing
@testable import ORB

// Wave-1 tests track: TestRunner spend, ceiling, latency and streaming fixes
// (TESTS-2, 3, 4, 8, 12). Real NativeAgentRunner with scripted clients; no network.

private func testsW1Model(_ id: String, tools: Bool) throws -> ModelInfo {
    let object: [String: Any] = [
        "id": id, "name": id,
        "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]],
        "supported_parameters": tools ? ["tools"] : [],
    ]
    return try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: object))
}

private let testsW1ProjectScenario = TestScenario(
    id: "w1-project", category: .apiDesign, title: "Fixture", subtitle: "", icon: "doc",
    difficulty: .foundational, estimatedSeconds: 1, systemPrompt: "Build", userPrompt: "Create",
    evaluationCriteria: [])

private let testsW1TextScenario = TestScenario(
    id: "w1-text", category: .apiDesign, title: "Text", subtitle: "", icon: "doc",
    difficulty: .foundational, estimatedSeconds: 1, systemPrompt: "Answer", userPrompt: "Say hi",
    evaluationCriteria: [], evaluationMode: .textResponse)

/// Every turn asks for one harmless tool call and reports `costPerTurn`.
/// `hangOnTurn` never finishes that turn's stream (until cancelled).
private actor TestsW1LoopingToolClient: OpenRouterClientProtocol {
    private(set) var requests = 0
    let costPerTurn: Double?
    let hangOnTurn: Int?

    init(costPerTurn: Double?, hangOnTurn: Int? = nil) {
        self.costPerTurn = costPerTurn
        self.hangOnTurn = hangOnTurn
    }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests += 1
        let turn = requests
        let cost = costPerTurn
        let hang = hangOnTurn == turn
        return AsyncThrowingStream { continuation in
            if hang {
                // Hold the turn open until the consumer is cancelled.
                let task = Task { try? await Task.sleep(for: .seconds(30)); continuation.finish() }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            continuation.yield(.toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-\(turn)", type: "function",
                                                 name: "list_directory", arguments: #"{"path":"."}"#))
            continuation.yield(.finishReason(choiceIndex: 0, reason: "tool_calls"))
            continuation.yield(.usage(ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15, cost: cost)))
            continuation.finish()
        }
    }

    func count() -> Int { requests }
}

/// Model A is rejected before streaming (HTTP 404); model B answers with a cost.
private actor TestsW1PerModelClient: OpenRouterClientProtocol {
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        if request.model == "vendor/a" {
            throw OpenRouterClientError.http(status: 404, message: "No endpoints found", retryAfter: nil)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta(choiceIndex: 0, text: "hi"))
            continuation.yield(.usage(ChatUsage(promptTokens: 2, completionTokens: 1, totalTokens: 3, cost: 0.001)))
            continuation.finish()
        }
    }
}

/// Waits before the first token so TTFT is measurable.
private struct TestsW1DelayedTextClient: OpenRouterClientProtocol {
    let delay: Duration
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        let delay = self.delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: delay)
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Hello "))
                try? await Task.sleep(for: .milliseconds(20))
                continuation.yield(.contentDelta(choiceIndex: 0, text: "there"))
                continuation.yield(.usage(ChatUsage(promptTokens: 4, completionTokens: 20, totalTokens: 24, cost: 0.0001)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// First turn asks for run_command (needs approval); second turn answers.
private actor TestsW1ApprovalClient: OpenRouterClientProtocol {
    private var turn = 0
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        turn += 1
        let first = turn == 1
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(.toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "c", type: "function",
                                                     name: "run_command", arguments: #"{"command":"echo"}"#))
                continuation.yield(.finishReason(choiceIndex: 0, reason: "tool_calls"))
            } else {
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Done."))
            }
            continuation.finish()
        }
    }
}

@MainActor
private final class TestsW1LedgerBox {
    var events: [String: UsageEvent] = [:]
    /// Strong capture on purpose: the box must outlive every ledger write.
    lazy var ledger = UsageLedger(recordEvent: { event in self.events[event.id] = event })
    var requests: Int { events.values.reduce(0) { $0 + $1.requests } }
    var knownCost: Double { events.values.compactMap(\.cost).reduce(0, +) }
}

@Suite("W1 tests: TestRunner spend and timing", .serialized)
@MainActor
struct W1TestsRunnerFixTests {
    private func makeRunner(_ client: any OpenRouterClientProtocol, ledger: UsageLedger,
                            records: @escaping (ExperimentRunRecord) -> Void = { _ in },
                            directory: URL) -> TestRunner {
        TestRunner(client: client, agentToolExecutor: { _ in .init(content: "[]", isError: false) },
                   credential: { "offline-placeholder" }, saveResult: { _ in }, saveExperiment: records,
                   outputRoot: directory, usageLedger: ledger)
    }

    private func waitUntilIdle(_ runner: TestRunner) async throws {
        for _ in 0..<2_500 where runner.isRunning { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!runner.isRunning)
    }

    @Test("Cancelled project run keeps partial spend in the result, record and ledger")
    func cancelledProjectKeepsSpend() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1tests-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TestsW1LoopingToolClient(costPerTurn: 0.4, hangOnTurn: 3)
        let box = TestsW1LedgerBox()
        var records: [ExperimentRunRecord] = []
        let runner = makeRunner(client, ledger: box.ledger, records: { records.append($0) }, directory: dir)
        let model = try testsW1Model("vendor/tool", tools: true)
        runner.start(scenario: testsW1ProjectScenario, modelIDs: [model.id], models: [model])
        for _ in 0..<2_500 where await client.count() < 3 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await client.count() == 3)
        runner.cancel()
        try await waitUntilIdle(runner)
        let result = try #require(runner.results.first)
        #expect(!result.success)
        #expect(abs(result.cost - 0.8) < 0.000_001)
        #expect(result.totalTokens == 30)
        #expect(records.first?.completionStatus == .cancelled)
        #expect(records.first?.spend.knownCostSubtotalUSD.map { abs($0 - 0.8) < 0.000_001 } == true)
        // Two priced turns plus the in-flight turn as an explicit unpriced request.
        #expect(box.requests == 3)
        #expect(abs(box.knownCost - 0.8) < 0.000_001)
        #expect(box.events.values.contains { $0.cost == nil && $0.requests == 1 })
    }

    @Test("Ceiling stops a project run mid-loop")
    func ceilingStopsMidLoop() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1tests-ceiling-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TestsW1LoopingToolClient(costPerTurn: 0.4)
        let box = TestsW1LedgerBox()
        let runner = makeRunner(client, ledger: box.ledger, directory: dir)
        let a = try testsW1Model("vendor/tool-a", tools: true)
        let b = try testsW1Model("vendor/tool-b", tools: true)
        runner.start(scenario: testsW1ProjectScenario, modelIDs: [a.id, b.id], models: [a, b], ceilingUSD: 1)
        try await waitUntilIdle(runner)
        #expect(await client.count() <= 3)
        #expect(runner.results.count == 1, "the second model must be skipped")
        #expect(runner.results.first?.errorMessage == "Stopped at spend ceiling.")
        #expect(runner.batchNotice?.contains("spend ceiling") == true)
        #expect(runner.batchSpent >= 1)
        #expect(abs(box.knownCost - 1.2) < 0.000_001)
    }

    @Test("Unknown turn cost stops a ceiling-bound project run")
    func unknownTurnCostStops() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1tests-unknown-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TestsW1LoopingToolClient(costPerTurn: nil)
        let runner = makeRunner(client, ledger: TestsW1LedgerBox().ledger, directory: dir)
        let model = try testsW1Model("vendor/tool", tools: true)
        runner.start(scenario: testsW1ProjectScenario, modelIDs: [model.id], models: [model], ceilingUSD: 1)
        try await waitUntilIdle(runner)
        #expect(await client.count() == 1)
        #expect(runner.batchNotice?.contains("did not report its cost") == true)
    }

    @Test("Pre-stream HTTP error does not stop the batch")
    func preStreamErrorContinues() async throws {
        let box = TestsW1LedgerBox()
        let runner = makeRunner(TestsW1PerModelClient(), ledger: box.ledger,
                                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = try testsW1Model("vendor/a", tools: false)
        let b = try testsW1Model("vendor/b", tools: false)
        runner.start(scenario: testsW1TextScenario, modelIDs: [a.id, b.id], models: [a, b], ceilingUSD: 1)
        try await waitUntilIdle(runner)
        #expect(runner.batchCompleted == 2)
        #expect(runner.batchNotice?.contains("did not report cost") != true)
        #expect(box.requests == 1, "the rejected request is not billed")
    }

    @Test("Text stream records TTFT and throughput")
    func textTiming() async throws {
        let runner = makeRunner(TestsW1DelayedTextClient(delay: .milliseconds(60)), ledger: TestsW1LedgerBox().ledger,
                                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = try testsW1Model("vendor/text", tools: false)
        await runner.run(scenario: testsW1TextScenario, modelId: model.id, models: [model])
        let result = try #require(runner.results.first)
        #expect((result.ttftMs ?? 0) >= 50)
        #expect(result.tokensPerSec != nil)
        #expect(result.response == "Hello there")
    }

    @Test("Approval wait is excluded from latency")
    func approvalWaitExcluded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1tests-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = makeRunner(TestsW1ApprovalClient(), ledger: TestsW1LedgerBox().ledger, directory: dir)
        let host = UUID()
        runner.registerApprovalHost(host)
        let model = try testsW1Model("vendor/tool", tools: true)
        runner.start(scenario: testsW1ProjectScenario, modelIDs: [model.id], models: [model])
        for _ in 0..<1_000 where runner.approvalPresenter.queue.current == nil {
            try await Task.sleep(for: .milliseconds(2))
        }
        let prompt = try #require(runner.approvalPresenter.queue.current)
        try await Task.sleep(for: .milliseconds(400))
        runner.approvalPresenter.decide(prompt.id, .approved)
        try await waitUntilIdle(runner)
        let result = try #require(runner.results.first)
        #expect(result.latencyMs < 300, "latency \(result.latencyMs) ms must exclude the 400 ms approval wait")
    }
}
