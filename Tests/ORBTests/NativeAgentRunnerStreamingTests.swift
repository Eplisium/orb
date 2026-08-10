import Foundation
import Testing
@testable import ORB

private actor AgentFixtureClient: OpenRouterClientProtocol {
    var turns: [[OpenRouterStreamEvent]]
    private(set) var requests: [OpenRouterRequest] = []
    init(_ turns: [[OpenRouterStreamEvent]]) { self.turns = turns }
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests.append(request)
        let events = turns.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor ToolRecorder {
    var calls: [AssembledAgentToolCall] = []
    func execute(_ call: AssembledAgentToolCall) async throws -> NativeAgentToolResult {
        calls.append(call)
        return .init(content: "result-\(call.id)", isError: false)
    }
}

@Suite("Native agent streamed turns")
struct NativeAgentRunnerStreamingTests {
    @Test("final text is observable before completion")
    func streamedFinalText() async throws {
        let client = AgentFixtureClient([[
            .contentDelta(choiceIndex: 0, text: "hel"),
            .contentDelta(choiceIndex: 0, text: "lo"),
            .finishReason(choiceIndex: 0, reason: "stop")
        ]])
        let events = EventRecorder()
        let result = try await NativeAgentRunner.run(
            prompt: "hi", modelId: "test/model", apiKey: "fixture", workspace: "/tmp",
            fullComputerAccess: false, history: [], client: client,
            onEvent: { await events.append($0) }
        )
        #expect(result.response == "hello")
        #expect(await events.values.contains(.textDelta("hel")))
        #expect(await events.values.contains(.textDelta("lo")))
    }

    @Test("split tool fragments assemble and execute once")
    func splitToolCall() async throws {
        let client = AgentFixtureClient([[
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "read_", arguments: "{\"pa"),
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: nil, type: nil, name: "file", arguments: "th\":\"a\"}"),
            .finishReason(choiceIndex: 0, reason: "tool_calls")
        ], [
            .contentDelta(choiceIndex: 0, text: "done"), .finishReason(choiceIndex: 0, reason: "stop")
        ]])
        let tools = ToolRecorder()
        _ = try await NativeAgentRunner.run(
            prompt: "read", modelId: "test/model", apiKey: "fixture", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            toolExecutor: { try await tools.execute($0) }, onEvent: { _ in }
        )
        let calls = await tools.calls
        #expect(calls.count == 1)
        #expect(calls.first?.id == "call-1")
        #expect(calls.first?.name == "read_file")
        #expect(calls.first?.arguments == "{\"path\":\"a\"}")
    }

    @Test("two calls retain IDs and sequential result order")
    func orderedCalls() async throws {
        let client = AgentFixtureClient([[
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "a", type: "function", name: "first", arguments: "{}"),
            .toolCallFragment(choiceIndex: 0, toolIndex: 1, id: "b", type: "function", name: "second", arguments: "{}"),
            .finishReason(choiceIndex: 0, reason: "tool_calls")
        ], [.contentDelta(choiceIndex: 0, text: "ok"), .done]])
        let tools = ToolRecorder()
        let result = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "fixture", workspace: "/tmp", fullComputerAccess: true,
            history: [], client: client, toolExecutor: { try await tools.execute($0) }, onEvent: { _ in }
        )
        #expect(await tools.calls.map(\.id) == ["a", "b"])
        #expect(result.history.compactMap(\.toolCallId) == ["a", "b"])
    }

    @Test("empty phantom tool entries do not fail an otherwise valid turn")
    func ignoresEmptyPhantomToolEntries() async throws {
        let client = AgentFixtureClient([[
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "real", type: "function", name: "run_command", arguments: "{}"),
            .toolCallFragment(choiceIndex: 0, toolIndex: 1, id: "phantom", type: "function", name: nil, arguments: ""),
            .finishReason(choiceIndex: 0, reason: "tool_calls")
        ], [
            .contentDelta(choiceIndex: 0, text: "done"), .finishReason(choiceIndex: 0, reason: "stop")
        ]])
        let tools = ToolRecorder()
        let events = EventRecorder()

        let result = try await NativeAgentRunner.run(
            prompt: "check", modelId: "test/model", apiKey: "test-key", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            toolExecutor: { try await tools.execute($0) },
            onEvent: { await events.append($0) }
        )

        #expect(result.response == "done")
        #expect(await tools.calls.map(\.id) == ["real"])
        #expect(await !events.values.contains { event in
            guard case .toolCallUpdated(let call) = event else { return false }
            return call.id == "phantom"
        })
    }

    @Test("length-truncated tool calls are never executed")
    func rejectsLengthTruncatedToolCalls() async {
        let client = AgentFixtureClient([
            [
                .toolCallFragment(
                    choiceIndex: 0,
                    toolIndex: 0,
                    id: "unsafe",
                    type: "function",
                    name: "run_command",
                    arguments: "{\"command\":\"touch /tmp/orb-truncated\"}"
                ),
                .finishReason(choiceIndex: 0, reason: "length")
            ],
            [.contentDelta(choiceIndex: 0, text: "done"), .finishReason(choiceIndex: 0, reason: "stop")]
        ])
        let tools = ToolRecorder()

        do {
            _ = try await NativeAgentRunner.run(
                prompt: "run it", modelId: "test/model", apiKey: "test-key", workspace: "/tmp",
                fullComputerAccess: true, history: [], client: client,
                toolExecutor: { try await tools.execute($0) }, onEvent: { _ in }
            )
            Issue.record("Expected a truncated tool-call error")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("truncated"))
        }

        #expect(await tools.calls.isEmpty)
    }

    @Test("a malformed call does not discard valid sibling calls")
    func recoversFromOneBadCall() async throws {
        let client = AgentFixtureClient([[
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "good", type: "function", name: "run_command", arguments: "{\"command\":\"ls\"}"),
            .toolCallFragment(choiceIndex: 0, toolIndex: 1, id: "bad", type: "function", name: "run_command", arguments: "{\"command\":"),
            .finishReason(choiceIndex: 0, reason: "tool_calls")
        ], [
            .contentDelta(choiceIndex: 0, text: "recovered"), .finishReason(choiceIndex: 0, reason: "stop")
        ]])
        let tools = ToolRecorder()

        let result = try await NativeAgentRunner.run(
            prompt: "audit", modelId: "test/model", apiKey: "k", workspace: "/tmp",
            fullComputerAccess: true, history: [], client: client,
            toolExecutor: { try await tools.execute($0) }, onEvent: { _ in }
        )

        #expect(result.response == "recovered")
        #expect(await tools.calls.map(\.id) == ["good"])
        // The bad call is reported back as a tool error so the model can retry.
        let badResult = result.history.first { $0.toolCallId == "bad" }
        #expect(badResult?.content?.contains("rejected") == true)
        #expect(result.toolCallDisplays.first { $0.id == "bad" }?.isError == true)
    }

    @Test("provider argument quirks are normalized before execution")
    func normalizesProviderQuirks() async throws {
        let client = AgentFixtureClient([[
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "a", type: "function", name: "run_command", arguments: "{\"command\":\"uptime\"}   "),
            .toolCallFragment(choiceIndex: 0, toolIndex: 1, id: "b", type: "function", name: "list_directory", arguments: ""),
            .finishReason(choiceIndex: 0, reason: "tool_calls")
        ], [.contentDelta(choiceIndex: 0, text: "ok"), .finishReason(choiceIndex: 0, reason: "stop")]])
        let tools = ToolRecorder()

        _ = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "k", workspace: "/tmp", fullComputerAccess: true,
            history: [], client: client, toolExecutor: { try await tools.execute($0) }, onEvent: { _ in }
        )

        let calls = await tools.calls
        #expect(calls.map(\.id) == ["a", "b"])
        #expect(calls.first?.arguments == "{\"command\":\"uptime\"}")
        #expect(calls.last?.arguments == "{}")
    }

    @Test("usage sums across model turns")
    func summedUsage() async throws {
        let one = ChatUsage(promptTokens: 10, completionTokens: 2, totalTokens: 12, cost: 0.1)
        let two = ChatUsage(promptTokens: 20, completionTokens: 3, totalTokens: 23, cost: 0.2)
        let client = AgentFixtureClient([[
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "a", type: "function", name: "x", arguments: "{}"), .usage(one), .done
        ], [.contentDelta(choiceIndex: 0, text: "ok"), .usage(two), .done]])
        let result = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "fixture", workspace: "/tmp", fullComputerAccess: true,
            history: [], client: client, toolExecutor: { _ in .init(content: "ok", isError: false) }, onEvent: { _ in }
        )
        #expect(result.usage?.promptTokens == 30)
        #expect(result.usage?.completionTokens == 5)
        #expect(result.usage?.totalTokens == 35)
        #expect(abs((result.usage?.cost ?? 0) - 0.3) < 0.000_001)
    }

    @Test("system prompt refreshes workspace/access and appends custom instructions")
    func refreshedSystemPrompt() async throws {
        let old = AgentAPIMessage(role: "system", content: "old unsafe workspace")
        let client = AgentFixtureClient([[.contentDelta(choiceIndex: 0, text: "ok"), .done]])
        _ = try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "fixture", workspace: "/new/workspace",
            fullComputerAccess: false, history: [old], systemPromptOverride: "Use concise prose.",
            client: client, onEvent: { _ in }
        )
        let prompt = await client.requests.first?.messages.first?.content ?? ""
        #expect(prompt.contains("/new/workspace"))
        #expect(prompt.contains("Computer Access is disabled"))
        #expect(prompt.contains("Additional user instructions"))
        #expect(prompt.contains("Use concise prose."))
        #expect(!prompt.contains("old unsafe workspace"))
    }
}

private actor EventRecorder {
    var values: [NativeAgentEvent] = []
    func append(_ event: NativeAgentEvent) { values.append(event) }
}
