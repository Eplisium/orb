import Foundation
import Testing
@testable import ORB

@Suite("Agent accounting and explicit permissions")
struct AgentAccountingFixTests {
    @Test("A missing usage frame remains unpriced even after a priced frame")
    func missingFrameIsNotIdentity() {
        for missingFirst in [true, false] {
            var sum = AgentUsageAccumulator()
            let known = ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.02)
            sum.append(missingFirst ? nil : known)
            sum.append(missingFirst ? known : nil)
            #expect(sum.value?.cost == nil)
            #expect(sum.value?.totalTokens == 3)
            #expect(sum.value?.knownCostSubtotal == 0.02)
            #expect(sum.value?.requestCount == 2)
            #expect(sum.value?.unpricedRequestCount == 1)
        }
    }

    @Test("All missing model frames retain request counts and survive Codable")
    func unpricedUsageRoundTrip() throws {
        var sum = AgentUsageAccumulator()
        sum.append(nil)
        sum.append(nil)
        let usage = try #require(sum.value)
        #expect(usage.cost == nil)
        #expect(usage.knownCostSubtotal == 0)
        #expect(usage.requestCount == 2)
        #expect(usage.unpricedRequestCount == 2)
        #expect(try JSONDecoder().decode(ChatUsage.self, from: JSONEncoder().encode(usage)) == usage)
        let legacy = try JSONDecoder().decode(ChatUsage.self, from: Data(#"{"cost":0.02,"total_tokens":3}"#.utf8))
        #expect(legacy.knownCostSubtotal == 0.02)
        #expect(legacy.accountedRequestCount == 1)
        #expect(legacy.unpricedRequests == 0)
    }

    @Test("Message usage persists the lower bound and labels incomplete pricing")
    func messageUsageSubtotal() throws {
        var sum = AgentUsageAccumulator()
        sum.append(ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.02))
        sum.append(nil)
        let messageUsage = MessageUsage(try #require(sum.value), elapsed: 1)
        let restored = try JSONDecoder().decode(MessageUsage.self, from: JSONEncoder().encode(messageUsage))
        #expect(restored.cost == nil)
        #expect(restored.knownCostSubtotal == 0.02)
        #expect(restored.requestCount == 2)
        #expect(restored.unpricedRequestCount == 1)
        #expect(restored.summary.contains("$0.02 known"))
        #expect(restored.summary.contains("1 unpriced"))
        let legacy = try JSONDecoder().decode(MessageUsage.self, from: Data(#"{"cost":0.02}"#.utf8))
        #expect(legacy.knownCostSubtotal == 0.02)
        #expect(legacy.requestCount == nil)
    }

    @Test("Mixed usage retains known spend and counts exactly once in the ledger")
    @MainActor func mixedLedgerEvents() throws {
        var events: [String: UsageEvent] = [:]
        let ledger = UsageLedger(recordEvent: { event in
            if events[event.id] == nil { events[event.id] = event }
        })
        var sum = AgentUsageAccumulator()
        sum.append(ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.02))
        sum.append(nil)
        let usage = try #require(sum.value)
        #expect(try JSONDecoder().decode(ChatUsage.self, from: JSONEncoder().encode(usage)) == usage)
        for _ in 0..<2 { ledger.record(.agent, model: "fixture", usage: usage, eventID: "run") }
        #expect(events.count == 2)
        #expect(events.values.compactMap(\.cost).reduce(0, +) == 0.02)
        #expect(events.values.reduce(0) { $0 + $1.requests } == 2)
        #expect(events.values.filter { $0.cost == nil }.reduce(0) { $0 + $1.requests } == 1)
        #expect(events.values.compactMap(\.totalTokens).reduce(0, +) == 3)
    }

    @Test("Known model costs and detailed token fields accumulate")
    func fullyKnownUsage() {
        var sum = AgentUsageAccumulator()
        var first = ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.02)
        first.cachedTokens = 1
        first.reasoningTokens = 1
        sum.append(first)
        sum.append(first)
        #expect(sum.value?.cost == 0.04)
        #expect(sum.value?.totalTokens == 6)
        #expect(sum.value?.cachedTokens == 2)
        #expect(sum.value?.reasoningTokens == 2)
    }

    @Test("Web search records exactly one independently billed helper event", arguments: [true, false])
    func webSearchUsage(known: Bool) async throws {
        let sink = AgentUsageSink()
        let usage = ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: known ? 0.02 : nil)
        let result = try await NativeAgentTools.agentWebSearch(
            ["query": "fixture"], client: AgentSearchClient(usage: usage), credential: { "fixture" },
            recordUsage: { await sink.append($0) })
        #expect(result.content == "Fixture answer.")
        let values = await sink.values
        #expect(values.count == 1)
        #expect(values.first! == usage)
    }

    @Test("Web search preserves received usage when its stream fails")
    func failedWebSearchUsage() async {
        let sink = AgentUsageSink()
        let usage = ChatUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.02)
        do {
            _ = try await NativeAgentTools.agentWebSearch(
                ["query": "fixture"], client: AgentSearchClient(usage: usage, fails: true), credential: { "fixture" },
                recordUsage: { await sink.append($0) })
            Issue.record("Expected fixture stream failure")
        } catch {}
        let values = await sink.values
        #expect(values.count == 1)
        #expect(values.first! == usage)
    }

    @Test("Only explicit unattended mode bypasses an absent coordinator")
    func explicitAutoApproval() async throws {
        let calls = AgentExecutionCounter()
        _ = try await NativeAgentRunner.run(prompt: "fixture", modelId: "mock", apiKey: "fixture",
            workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false, history: [],
            client: AgentPermissionClient(), toolExecutor: { _ in
                await calls.increment()
                return .init(content: "fixture", isError: false)
            }, policy: .projectBuild, missingApproval: .autoApprove, onEvent: { _ in })
        #expect(await calls.value == 1)
    }

    @Test("An installed coordinator remains authoritative even in explicit unattended mode")
    func coordinatorDenialWins() async throws {
        let calls = AgentExecutionCounter()
        _ = try await NativeAgentRunner.run(prompt: "fixture", modelId: "mock", apiKey: "fixture",
            workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false, history: [],
            client: AgentPermissionClient(), toolExecutor: { _ in
                await calls.increment()
                return .init(content: "fixture", isError: false)
            }, policy: .projectBuild, approvals: ApprovalCoordinator(), missingApproval: .autoApprove, onEvent: { _ in })
        #expect(await calls.value == 0)
    }
}

private actor AgentExecutionCounter {
    var value = 0
    func increment() { value += 1 }
}
private actor AgentUsageSink {
    var values: [ChatUsage?] = []
    func append(_ usage: ChatUsage?) { values.append(usage) }
}
private struct AgentSearchClient: OpenRouterClientProtocol {
    let usage: ChatUsage
    var fails = false
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.usage(usage))
            if fails {
                continuation.finish(throwing: URLError(.networkConnectionLost))
            } else {
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Fixture answer."))
                continuation.finish()
            }
        }
    }
}
private actor AgentPermissionClient: OpenRouterClientProtocol {
    private var turn = 0
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        turn += 1
        let first = turn == 1
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(.toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "fixture", type: "function", name: "run_command", arguments: "{}"))
                continuation.yield(.finishReason(choiceIndex: 0, reason: "tool_calls"))
            } else {
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Done."))
            }
            continuation.finish()
        }
    }
}
