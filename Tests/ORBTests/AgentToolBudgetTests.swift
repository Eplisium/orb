import Foundation
import Testing
@testable import ORB

private actor BudgetFixtureClient: OpenRouterClientProtocol {
    var turns: [[OpenRouterStreamEvent]]
    private(set) var requests: [OpenRouterRequest] = []
    private let fallback: [OpenRouterStreamEvent]

    init(_ turns: [[OpenRouterStreamEvent]], fallback: [OpenRouterStreamEvent] = []) {
        self.turns = turns
        self.fallback = fallback
    }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests.append(request)
        let events = turns.isEmpty ? fallback : turns.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor CountingExecutor {
    var count = 0
    func execute(_ call: AssembledAgentToolCall) async throws -> NativeAgentToolResult {
        count += 1
        return .init(content: "ok-\(count)", isError: false)
    }
}

@Suite("Agent tool budget")
struct AgentToolBudgetTests {
    /// A turn that always asks for another tool call, so the agent can never
    /// finish on its own and must hit the budget.
    private func loopingTurn(_ index: Int) -> [OpenRouterStreamEvent] {
        [
            .toolCallFragment(
                choiceIndex: 0, toolIndex: 0, id: "call-\(index)", type: "function",
                name: "run_command", arguments: "{\"command\":\"echo \(index)\"}"
            ),
            .finishReason(choiceIndex: 0, reason: "tool_calls")
        ]
    }

    @Test("hitting the budget summarizes instead of discarding the whole run")
    func gracefulFinalization() async throws {
        let budget = 4
        let client = BudgetFixtureClient(
            (0..<budget).map(loopingTurn),
            fallback: [
                .contentDelta(choiceIndex: 0, text: "Here is what I completed."),
                .finishReason(choiceIndex: 0, reason: "stop")
            ]
        )
        let executor = CountingExecutor()

        let result = try await NativeAgentRunner.run(
            prompt: "long task", modelId: "m", apiKey: "k", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            maximumTurns: budget,
            toolExecutor: { try await executor.execute($0) },
            onEvent: { _ in }
        )

        // Previously this threw NativeAgentError.exhausted and the user lost
        // every tool result gathered along the way.
        #expect(result.response == "Here is what I completed.")
        #expect(result.hitToolBudget)
        #expect(await executor.count == budget)
    }

    @Test("the finalizing turn is sent without tools so it cannot loop again")
    func finalTurnHasNoTools() async throws {
        let budget = 2
        let client = BudgetFixtureClient(
            (0..<budget).map(loopingTurn),
            fallback: [
                .contentDelta(choiceIndex: 0, text: "Done."),
                .finishReason(choiceIndex: 0, reason: "stop")
            ]
        )
        _ = try await NativeAgentRunner.run(
            prompt: "task", modelId: "m", apiKey: "k", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            maximumTurns: budget,
            toolExecutor: { _ in .init(content: "ok", isError: false) },
            onEvent: { _ in }
        )
        let requests = await client.requests
        #expect(requests.count == budget + 1)
        // Every budgeted turn offers tools; the final summary turn must not.
        for request in requests.prefix(budget) {
            #expect(request.tools?.isEmpty == false)
        }
        #expect(requests.last?.tools == nil)
    }

    @Test("a finalizing event is emitted so the UI can explain the wait")
    func emitsFinalizingEvent() async throws {
        let budget = 2
        let client = BudgetFixtureClient(
            (0..<budget).map(loopingTurn),
            fallback: [
                .contentDelta(choiceIndex: 0, text: "Summary."),
                .finishReason(choiceIndex: 0, reason: "stop")
            ]
        )
        actor EventLog {
            var sawFinalizing = false
            func record(_ event: NativeAgentEvent) {
                if case .finalizing = event { sawFinalizing = true }
            }
        }
        let log = EventLog()
        _ = try await NativeAgentRunner.run(
            prompt: "task", modelId: "m", apiKey: "k", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            maximumTurns: budget,
            toolExecutor: { _ in .init(content: "ok", isError: false) },
            onEvent: { await log.record($0) }
        )
        #expect(await log.sawFinalizing)
    }

    @Test("a normal run that finishes early does not flag the budget")
    func normalRunUnflagged() async throws {
        let client = BudgetFixtureClient([[
            .contentDelta(choiceIndex: 0, text: "Immediate answer."),
            .finishReason(choiceIndex: 0, reason: "stop")
        ]])
        let result = try await NativeAgentRunner.run(
            prompt: "quick", modelId: "m", apiKey: "k", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            maximumTurns: 50,
            toolExecutor: { _ in .init(content: "ok", isError: false) },
            onEvent: { _ in }
        )
        #expect(result.hitToolBudget == false)
        #expect(result.response == "Immediate answer.")
    }

    @Test("history stays API-valid after forced finalization")
    func historyRemainsValid() async throws {
        let budget = 3
        let client = BudgetFixtureClient(
            (0..<budget).map(loopingTurn),
            fallback: [
                .contentDelta(choiceIndex: 0, text: "Wrap up."),
                .finishReason(choiceIndex: 0, reason: "stop")
            ]
        )
        let result = try await NativeAgentRunner.run(
            prompt: "task", modelId: "m", apiKey: "k", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            maximumTurns: budget,
            toolExecutor: { _ in .init(content: "ok", isError: false) },
            onEvent: { _ in }
        )
        // Unpaired tool_calls would 400 the next request.
        let announced = Set(result.history.flatMap { ($0.toolCalls ?? []).map(\.id) })
        let replied = Set(result.history.compactMap(\.toolCallId))
        #expect(announced == replied)
        #expect(announced.count == budget)
    }
}
