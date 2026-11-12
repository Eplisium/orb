import Foundation
import Testing
@testable import ORB

private actor AgentBackendFixScriptClient: OpenRouterClientProtocol {
    var turn = 0
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        turn += 1
        let events: [OpenRouterStreamEvent] = turn == 1 ? [
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "audit-1", type: "function", name: "run_command", arguments: #"{"command":"audit-placeholder-never-executed"}"#),
            .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
        ] : [.contentDelta(choiceIndex: 0, text: "Done."), .done]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor AgentBackendFixPartialUsageClient: OpenRouterClientProtocol {
    var turn = 0
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        turn += 1
        let events: [OpenRouterStreamEvent] = turn == 1 ? [
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "cost-1", type: "function", name: "fetch_url", arguments: #"{"url":"https://example.invalid/"}"#),
            .usage(ChatUsage(promptTokens: 10, completionTokens: 10, totalTokens: 20, cost: nil)),
            .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
        ] : [.contentDelta(choiceIndex: 0, text: "Done."),
             .usage(ChatUsage(promptTokens: 10, completionTokens: 10, totalTokens: 20, cost: 0.02)), .done]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor AgentBackendFixCounter {
    var calls = 0
    func increment() { calls += 1 }
}

@Suite("Agent backend safety regressions")
struct AgentBackendFixReproTests {
    @Test("An absent approval coordinator must not execute shell tools")
    func missingApprovalCoordinator() async throws {
        let counter = AgentBackendFixCounter()
        _ = try await NativeAgentRunner.run(
            prompt: "audit", modelId: "mock/audit", apiKey: "mock-only-not-a-secret",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false, history: [], client: AgentBackendFixScriptClient(),
            toolExecutor: { _ in
                await counter.increment()
                return NativeAgentToolResult(content: "mock executor only; no command launched", isError: false)
            },
            policy: .projectBuild, approvals: nil, onEvent: { _ in }
        )
        let calls = await counter.calls
        print("AUDIT_MISSING_APPROVAL_EXECUTOR_CALLS=\(calls)")
        #expect(calls == 0)
    }

    @Test("An installed coordinator without a handler denies the same tool")
    func approvalControl() async throws {
        let counter = AgentBackendFixCounter()
        _ = try await NativeAgentRunner.run(
            prompt: "audit", modelId: "mock/audit", apiKey: "mock-only-not-a-secret",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false, history: [], client: AgentBackendFixScriptClient(),
            toolExecutor: { _ in
                await counter.increment()
                return NativeAgentToolResult(content: "mock executor", isError: false)
            },
            policy: .projectBuild, approvals: ApprovalCoordinator(), onEvent: { _ in }
        )
        let calls = await counter.calls
        print("AUDIT_PRESENT_APPROVAL_EXECUTOR_CALLS=\(calls)")
        #expect(calls == 0)
    }

    @Test("A partly unpriced agent run must not present a fully known total")
    func partialUsageMustRemainUnknown() async throws {
        let result = try await NativeAgentRunner.run(
            prompt: "audit", modelId: "mock/audit", apiKey: "mock-only-not-a-secret",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false, history: [], client: AgentBackendFixPartialUsageClient(),
            toolExecutor: { _ in NativeAgentToolResult(content: "mock response", isError: false) },
            policy: .webOnly, onEvent: { _ in }
        )
        print("AUDIT_PARTIAL_USAGE_COST=\(String(describing: result.usage?.cost))")
        #expect(result.usage?.cost == nil)
    }

    @Test("File offsets handle zero, negative, maximum and ordinary bounds", arguments: [0, -1, 1, 2, Int.max])
    func offsetBounds(offset: Int) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orb-offset-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "first\nsecond".write(to: dir.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        let result = try await NativeAgentTools.execute(name: "read_file",
            argumentsJSON: "{\"path\":\"fixture.txt\",\"offset\":\(offset),\"limit\":\(Int.max)}",
            workspace: dir.path, fullComputerAccess: true, constrainPathsToWorkspace: true)
        #expect(result.isError == (offset < 1))
        if offset == 1 { #expect(result.content.contains("1|first\n2|second")) }
        if offset == 2 { #expect(result.content.contains("2|second")) }
        if offset == Int.max { #expect(result.content.contains("past the end")) }
    }

    @Test("Model-supplied minimum integer offset must not crash read_file")
    func minimumOffset() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orb-offset-audit-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "fixture\n".write(to: dir.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        let arguments = "{\"path\":\"fixture.txt\",\"offset\":\(Int.min)}"
        let result = try await NativeAgentTools.execute(
            name: "read_file", argumentsJSON: arguments, workspace: dir.path,
            fullComputerAccess: true, constrainPathsToWorkspace: true
        )
        #expect(result.isError)
        #expect(result.content.contains("offset must be a positive"))
    }
}
