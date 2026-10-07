import Foundation
import Combine
import Testing
@testable import ORB

private actor ScriptedOpenRouterClient: TimedOpenRouterStreaming {
    struct Script: Sendable {
        let events: [OpenRouterStreamEvent]
        var delay: Duration = .zero
        var terminalError: (any Error & Sendable)? = nil
    }
    private var scripts: [Script]
    private(set) var requests: [OpenRouterRequest] = []

    init(_ scripts: [Script]) { self.scripts = scripts }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        let timed = try await timedStream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await item in timed { continuation.yield(item.event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stamps each event when the script emits it — the fixture's stand-in for
    /// "when the provider sent it" — so timing assertions do not depend on how
    /// quickly a loaded test process schedules the consumer.
    func timedStream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<TimedStreamEvent<OpenRouterStreamEvent>, Error> {
        requests.append(request)
        let script = scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in script.events {
                    if script.delay != .zero { try await Task.sleep(for: script.delay) }
                    try Task.checkCancellation()
                    continuation.yield(.init(event: event, arrivedAt: Date()))
                }
                if let error = script.terminalError { continuation.finish(throwing: error) }
                else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private final class MemoryConversationStore: ConversationStore {
    var records: [UUID: StoredConversation] = [:]
    var deletedMessageIDs: [UUID] = []
    var saveCount = 0
    var failConversationRemoval = false
    var failMessageRemoval = false

    func loadRecords() throws -> [StoredConversation] { Array(records.values) }
    func saveRecord(_ record: StoredConversation) throws {
        records[record.conversation.id] = record
        saveCount += 1
    }
    func removeConversation(_ id: UUID) throws {
        if failConversationRemoval { throw CocoaError(.fileWriteUnknown) }
        records[id] = nil
    }
    func removeMessage(_ id: UUID) throws {
        if failMessageRemoval { throw CocoaError(.fileWriteUnknown) }
        deletedMessageIDs.append(id)
        for key in records.keys { records[key]?.conversation.messages.removeAll { $0.id == id } }
    }
    func recoverInterruptedRecords() throws {}
}

@Suite("ChatService streaming lifecycle")
@MainActor
struct ChatServiceTests {
    private func service(
        scripts: [ScriptedOpenRouterClient.Script],
        store suppliedStore: MemoryConversationStore? = nil,
        apiKey: String? = "fixture-key",
        agentMaximumTurns: Int = 100
    ) -> (ChatService, ScriptedOpenRouterClient, MemoryConversationStore) {
        let store = suppliedStore ?? MemoryConversationStore()
        let client = ScriptedOpenRouterClient(scripts)
        return (ChatService(client: client, store: store, apiKeyProvider: { apiKey }, agentMaximumTurns: agentMaximumTurns), client, store)
    }

    private func waitUntilIdle(_ service: ChatService) async throws {
        for _ in 0..<500 where service.isStreaming { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!service.isStreaming)
    }

    @Test("Agent transcript preserves reasoning, commentary, tool, reasoning, answer order")
    func inlineTranscriptOrder() async throws {
        let (service, _, store) = service(scripts: [
            .init(events: [
                .reasoningDelta(choiceIndex: 0, text: "First thought"),
                .contentDelta(choiceIndex: 0, text: "Checking now."),
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "inline-tool", type: "function", name: "unknown_tool", arguments: "{}"),
                .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
            ]),
            .init(events: [.reasoningDelta(choiceIndex: 0, text: "Second thought"), .contentDelta(choiceIndex: 0, text: "Final answer."), .done])
        ])
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        try await waitUntilIdle(service)
        let message = try #require(service.activeConversation?.messages.last)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        let segments = json["transcript"] as? [[String: Any]] ?? []
        #expect(segments.compactMap { $0["kind"] as? String } == ["reasoning", "text", "tool", "reasoning", "text"])
        #expect(segments.compactMap { $0["text"] as? String }.filter { !$0.isEmpty } == ["First thought", "Checking now.", "Second thought", "\n\nFinal answer."])
        #expect(store.records.values.first?.conversation.messages.last == message)
    }

    @Test("Agent activity switches from thinking to writing with answer text")
    func inlineActivityMatchesPhase() async throws {
        let (service, _, _) = service(scripts: [.init(events: [
            .reasoningDelta(choiceIndex: 0, text: "Thinking"),
            .contentDelta(choiceIndex: 0, text: "Answer"), .done
        ], delay: .milliseconds(100))])
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        for _ in 0..<200 {
            if service.activeConversation?.messages.last?.content == "Answer" { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(service.isStreaming)
        #expect(service.activityLabel == "Writing response…")
        try await waitUntilIdle(service)
    }

    @Test("Chat transcript keeps alternating channels and exact whitespace")
    func directTranscriptOrder() async throws {
        let (service, _, _) = service(scripts: [.init(events: [
            .reasoningDelta(choiceIndex: 0, text: "First"),
            .contentDelta(choiceIndex: 0, text: "One\n"),
            .contentDelta(choiceIndex: 0, text: "\nTwo"),
            .reasoningDelta(choiceIndex: 0, text: "Next"),
            .contentDelta(choiceIndex: 0, text: "Three"), .done
        ])])
        service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        let message = try #require(service.activeConversation?.messages.last)
        #expect(message.displayTranscript.map(\.kind) == [.reasoning, .text, .reasoning, .text])
        #expect(message.displayTranscript.filter { $0.kind == .text }.map(\.text).joined() == message.content)
    }

    @Test("first Chat send creates a Chat conversation")
    func firstChatSendCreatesChatModeConversation() async throws {
        let (service, _, _) = service(scripts: [.init(events: [.contentDelta(choiceIndex: 0, text: "ok"), .done])])
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.conversations.first?.mode == .chat)
    }

    @Test("new session reuses the active empty conversation")
    func newSessionReusesActiveEmptyConversation() {
        let (service, _, _) = service(scripts: [])
        let first = service.newConversation(modelId: "test/old", mode: .chat)

        let second = service.newConversation(modelId: "test/default", mode: .chat)

        #expect(second.id == first.id)
        #expect(service.conversations.count == 1)
        #expect(service.activeConversation?.modelId == "test/default")
    }

    @Test("stream updates its captured conversation after selection changes")
    func streamUpdatesCapturedConversationAfterSelectionChanges() async throws {
        let (service, _, _) = service(scripts: [.init(events: [.contentDelta(choiceIndex: 0, text: "A"), .contentDelta(choiceIndex: 0, text: "B"), .done], delay: .milliseconds(15))])
        let target = service.newConversation(modelId: "test/model", mode: .chat)
        await service.sendMessage("hello", modelId: "test/model")
        let other = service.newConversation(modelId: "other/model", mode: .chat)
        service.selectConversation(other)
        try await waitUntilIdle(service)
        #expect(service.conversations.first(where: { $0.id == target.id })?.messages.last?.content == "AB")
        #expect(service.activeConversation?.id == other.id)
        #expect(service.activeConversation?.messages.isEmpty == true)
    }

    @Test("run ownership identifies only the captured conversation and message")
    func runOwnershipIsConversationScoped() async throws {
        let (service, _, _) = service(scripts: [.init(
            events: [.contentDelta(choiceIndex: 0, text: "done"), .done],
            delay: .milliseconds(50)
        )])
        let running = service.newConversation(modelId: "test/model", mode: .chat)
        await service.sendMessage("hello", modelId: "test/model")
        let assistantID = service.activeConversation!.messages.last!.id
        let other = service.newConversation(modelId: "other/model", mode: .chat)

        #expect(service.isRunning(conversationID: running.id))
        #expect(!service.isRunning(conversationID: other.id))
        #expect(service.isStreamingMessage(assistantID, conversationID: running.id))
        #expect(!service.isStreamingMessage(assistantID, conversationID: other.id))

        service.stopStreaming()
        try await waitUntilIdle(service)
    }

    @Test("failed conversation deletion preserves the in-memory session")
    func failedConversationDeletionRollsBack() {
        let store = MemoryConversationStore()
        let (service, _, _) = service(scripts: [], store: store)
        let conversation = service.newConversation(modelId: "test/model", mode: .chat)
        store.failConversationRemoval = true

        service.deleteConversation(conversation)

        #expect(service.conversations.contains { $0.id == conversation.id })
        #expect(service.activeConversation?.id == conversation.id)
        #expect(service.lastError?.contains("Could not delete") == true)
    }

    @Test("failed message deletion preserves the in-memory message")
    func failedMessageDeletionRollsBack() {
        let store = MemoryConversationStore()
        var conversation = ChatConversation(modelId: "test/model", mode: .chat)
        let message = ChatMessage(role: "user", content: "keep me")
        conversation.messages = [message]
        store.records[conversation.id] = .init(conversation: conversation, agentHistory: [])
        let (service, _, _) = service(scripts: [], store: store)
        service.selectConversation(conversation)
        store.failMessageRemoval = true

        service.deleteMessage(message.id, from: conversation)

        #expect(service.activeConversation?.messages.contains { $0.id == message.id } == true)
        #expect(service.lastError?.contains("Could not delete") == true)
    }


    @Test("regenerate without an API key preserves the previous response")
    func regenerateWithoutKeyPreservesResponse() async {
        let store = MemoryConversationStore()
        var conversation = ChatConversation(modelId: "test/model", mode: .chat)
        let user = ChatMessage(role: "user", content: "question")
        let assistant = ChatMessage(role: "assistant", content: "previous answer")
        conversation.messages = [user, assistant]
        store.records[conversation.id] = .init(conversation: conversation, agentHistory: [])
        let (service, client, _) = service(scripts: [], store: store, apiKey: nil)
        service.selectConversation(conversation)

        await service.regenerateLastResponse(modelId: "test/model")

        #expect(service.activeConversation?.messages.last?.id == assistant.id)
        #expect(service.activeConversation?.messages.last?.content == "previous answer")
        #expect(await client.requests.isEmpty)
    }

    @Test("an Agent run continues while a separate Chat coordinator responds")
    func agentContinuesWhileChatResponds() async throws {
        let store = MemoryConversationStore()
        let (agentService, _, _) = service(
            scripts: [.init(
                events: [.contentDelta(choiceIndex: 0, text: "agent finished"), .done],
                delay: .milliseconds(75)
            )],
            store: store
        )
        let (chatService, _, _) = service(
            scripts: [.init(events: [.contentDelta(choiceIndex: 0, text: "chat finished"), .done])],
            store: store
        )

        await agentService.sendAgentMessage(
            "work in the background",
            modelId: "test/agent",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false
        )
        #expect(agentService.isStreaming)

        await chatService.sendMessage("talk to me", modelId: "test/chat")
        try await waitUntilIdle(chatService)

        #expect(chatService.activeConversation?.messages.last?.content == "chat finished")
        #expect(agentService.isStreaming)

        try await waitUntilIdle(agentService)
        #expect(agentService.activeConversation?.messages.last?.content == "agent finished")
        #expect(store.records.values.contains { $0.conversation.mode == .agent })
        #expect(store.records.values.contains { $0.conversation.mode == .chat })
    }

    @Test("regenerate reuses the assistant and store row")
    func regenerateDoesNotDuplicateUserMessage() async throws {
        let store = MemoryConversationStore()
        let (service, _, _) = service(scripts: [
            .init(events: [.contentDelta(choiceIndex: 0, text: "old"), .done]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "new"), .done])
        ], store: store)
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        let oldID = service.activeConversation!.messages.last!.id
        await service.regenerateLastResponse(modelId: "test/model")
        try await waitUntilIdle(service)
        let messages = service.activeConversation!.messages
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(messages.map(\.content) == ["hello", "new"])
        #expect(messages.last?.id == oldID)
        #expect(store.deletedMessageIDs.isEmpty)
        #expect(store.records[service.activeConversation!.id]?.conversation.messages.count == 2)
    }

    @Test("regenerating with a different model stays in the same conversation")
    func regenerateWithDifferentModelStaysInConversation() async throws {
        let (service, client, _) = service(scripts: [
            .init(events: [.contentDelta(choiceIndex: 0, text: "old"), .done]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "new"), .done])
        ])
        await service.sendMessage("hello", modelId: "test/old")
        try await waitUntilIdle(service)
        let conversationID = service.activeConversation!.id

        await service.regenerateLastResponse(modelId: "test/new")
        try await waitUntilIdle(service)

        #expect(service.activeConversation?.id == conversationID)
        #expect(service.activeConversation?.modelId == "test/new")
        #expect(service.activeConversation?.messages.map(\.content) == ["hello", "new"])
        #expect(await client.requests.last?.messages.contains { $0.role == "user" && $0.content == "hello" } == true)
    }

    @Test("regenerate startup failure restores the previous response")
    func regenerateStartupFailureRestoresResponse() async throws {
        let (service, _, store) = service(scripts: [
            .init(events: [.contentDelta(choiceIndex: 0, text: "old"), .done]),
            .init(events: [], terminalError: URLError(.cannotConnectToHost))
        ])
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        let previous = service.activeConversation!.messages.last!

        await service.regenerateLastResponse(modelId: "test/model")
        try await waitUntilIdle(service)

        #expect(service.activeConversation?.messages.last?.id == previous.id)
        #expect(service.activeConversation?.messages.last?.content == "old")
        #expect(store.records[service.activeConversation!.id]?.conversation.messages.last?.id == previous.id)
        #expect(service.lastError != nil)
    }

    @Test("latest cumulative usage is applied once")
    func usageIsAppliedOnlyOncePerRun() async throws {
        let first = ChatUsage(promptTokens: 2, completionTokens: 3, totalTokens: 5, cost: 0.01)
        let final = ChatUsage(promptTokens: 2, completionTokens: 4, totalTokens: 6, cost: 0.02)
        let (service, _, _) = service(scripts: [.init(events: [.contentDelta(choiceIndex: 0, text: "ok"), .usage(first), .usage(final), .done])])
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.totalTokens == 6)
        #expect(service.activeConversation?.totalCost == 0.02)
        #expect(service.lastUsage == final)
        #expect(service.tokensPerSecond > 0)
    }

    @Test("fast bursts of medium deltas stay lossless and below display cadence")
    func coalescedDeltas() async throws {
        let pieces = (0..<1_000).map { "segment-\($0)-body," }
        let events = pieces.map { OpenRouterStreamEvent.contentDelta(choiceIndex: 0, text: $0) } + [.done]
        let (service, _, _) = service(scripts: [.init(events: events)])
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.content == pieces.joined())
        #expect(service.contentPublishCount < 60)
    }

    @Test("visible partial content is checkpointed before completion")
    func partialContentIsCheckpointed() async throws {
        let store = MemoryConversationStore()
        let (service, _, _) = service(
            scripts: [.init(
                events: [.contentDelta(choiceIndex: 0, text: "partial"), .done],
                delay: .milliseconds(75)
            )],
            store: store
        )
        await service.sendMessage("hello", modelId: "test/model")
        let conversationID = service.activeConversation!.id

        for _ in 0..<100 where service.streamingContent != "partial" {
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(service.isStreaming)
        #expect(store.records[conversationID]?.conversation.messages.last?.content == "partial")
        service.stopStreaming()
        try await waitUntilIdle(service)
    }

    @Test("agent fast bursts stay lossless and below display cadence")
    func coalescedAgentDeltas() async throws {
        let pieces = (0..<1_000).map { "segment-\($0)-body," }
        let events = pieces.map { OpenRouterStreamEvent.contentDelta(choiceIndex: 0, text: $0) } + [.done]
        let (service, _, _) = service(scripts: [.init(events: events)])
        var phasePublishes = 0
        let subscription = service.$runState.sink { _ in phasePublishes += 1 }
        defer { subscription.cancel() }

        await service.sendAgentMessage(
            "hello",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false
        )
        try await waitUntilIdle(service)

        #expect(service.activeConversation?.messages.last?.content == pieces.joined())
        #expect(service.contentPublishCount < 60)
        #expect(phasePublishes < 20, "An unchanged phase must not invalidate the view per token")
    }

    @Test("Agent preserves visible prose from earlier tool turns")
    func agentKeepsEarlierProse() async throws {
        let (service, _, _) = service(scripts: [
            .init(events: [
                .contentDelta(choiceIndex: 0, text: "I will check."),
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "unknown_tool", arguments: "{}"),
                .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "Done."), .done])
        ])
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.content == "I will check.\n\nDone.")
    }

    @Test("budget summary remains separate from earlier tool-turn prose")
    func agentBudgetSummaryKeepsParagraphBoundary() async throws {
        let (service, _, _) = service(scripts: [
            .init(events: [
                .contentDelta(choiceIndex: 0, text: "Need to check."),
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "unknown_tool", arguments: "{}"),
                .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "Summary."), .done])
        ], agentMaximumTurns: 1)
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        try await waitUntilIdle(service)
        let body = try #require(service.activeConversation?.messages.last?.content)
        #expect(body.hasPrefix("Need to check.\n\nSummary.\n\n---"))
        #expect(body.contains("tool-call budget"))
    }

    @Test("tool argument fragments are lossless without publishing every fragment")
    func coalescedToolPreviews() async throws {
        let start = OpenRouterStreamEvent.toolCallFragment(
            choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function",
            name: "unknown_tool", arguments: "{\"value\":\""
        )
        let fragment = OpenRouterStreamEvent.toolCallFragment(
            choiceIndex: 0, toolIndex: 0, id: nil, type: nil, name: nil, arguments: "a"
        )
        let end = OpenRouterStreamEvent.toolCallFragment(
            choiceIndex: 0, toolIndex: 0, id: nil, type: nil, name: nil, arguments: "\"}"
        )
        let events = [start] + Array(repeating: fragment, count: 1_000) + [
            end, .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
        ]
        let (service, _, _) = service(scripts: [
            .init(events: events),
            .init(events: [.contentDelta(choiceIndex: 0, text: "done"), .done])
        ])
        var conversationPublishes = 0
        let subscription = service.$activeConversation.sink { _ in conversationPublishes += 1 }
        defer { subscription.cancel() }
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        try await waitUntilIdle(service)
        let call = try #require(service.activeConversation?.messages.last?.toolCalls?.first)
        #expect(call.arguments == "{\"value\":\"\(String(repeating: "a", count: 1_000))\"}")
        #expect(conversationPublishes < 80, "Tool previews should follow the frame cadence")
    }

    @Test("Agent flushes the trailing reasoning delta before completion")
    func agentReasoningIsLossless() async throws {
        let (service, _, _) = service(scripts: [.init(events: [
            .reasoningDelta(choiceIndex: 0, text: "first "),
            .reasoningDelta(choiceIndex: 0, text: "second"),
            .contentDelta(choiceIndex: 0, text: "answer"),
            .done
        ])])

        await service.sendAgentMessage(
            "hello",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false
        )
        try await waitUntilIdle(service)

        #expect(service.activeConversation?.messages.last?.reasoning == "first second")
    }

    @Test("cancelled Agent preserves usage from completed turns exactly once")
    func cancelledAgentKeepsUsage() async throws {
        let usage = ChatUsage(promptTokens: 7, completionTokens: 5, totalTokens: 12, cost: 0.02)
        let (service, _, _) = service(scripts: [
            .init(events: [
                .reasoningDelta(choiceIndex: 0, text: "considering"),
                .usage(usage), .finishReason(choiceIndex: 0, reason: "stop")
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "late"), .done], delay: .seconds(5))
        ])
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        for _ in 0..<200 where service.agentCumulativeUsage == nil {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(service.agentCumulativeUsage == usage)
        service.stopStreaming()
        try await waitUntilIdle(service)
        #expect(service.lastUsage == usage)
        #expect(service.activeConversation?.totalTokens == 12)
        #expect(service.activeConversation?.totalCost == 0.02)
    }

    @Test("reasoning bursts do not publish the conversation for every token", arguments: [PlaygroundMode.chat, .agent])
    func coalescedReasoningObservations(mode: PlaygroundMode) async throws {
        let events: [OpenRouterStreamEvent] = (0..<1_000).map { _ in .reasoningDelta(choiceIndex: 0, text: "step,") }
            + [.contentDelta(choiceIndex: 0, text: "done"), .done]
        let (service, _, _) = service(scripts: [.init(events: events)])
        var publishes = 0
        let subscription = service.$conversations.sink { _ in publishes += 1 }
        defer { subscription.cancel() }
        if mode == .chat {
            await service.sendMessage("hello", modelId: "test/model")
        } else {
            await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        }
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.reasoning == String(repeating: "step,", count: 1_000))
        #expect(publishes < 60, "reasoning should be coalesced before observable mutations")
    }

    @Test("opaque reasoning details are lossless without per-token conversation publishes", arguments: [PlaygroundMode.chat, .agent])
    func coalescedStructuredReasoning(mode: PlaygroundMode) async throws {
        let blocks = (0..<500).map { ReasoningDetail(type: "reasoning.text", text: "part-\($0)") }
        let events: [OpenRouterStreamEvent] = blocks.flatMap { block in
            [.reasoningDelta(choiceIndex: 0, text: "step,"),
             .reasoningDetails(choiceIndex: 0, details: [block])]
        } + [.contentDelta(choiceIndex: 0, text: "answer"), .done]
        let (service, _, _) = service(scripts: [.init(events: events)])
        var publishes = 0
        let subscription = service.$conversations.sink { _ in publishes += 1 }
        defer { subscription.cancel() }
        if mode == .chat {
            service.sendMessage("hello", modelId: "test/model")
        } else {
            await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        }
        try await waitUntilIdle(service)
        let assistant = try #require(service.activeConversation?.messages.last)
        #expect(assistant.reasoning == String(repeating: "step,", count: 500))
        #expect(assistant.reasoningDetails == blocks)
        #expect(publishes < 80, "opaque detail fragments must share the frame cadence")
    }

    @Test("Agent marks a text answer cut off by the model as truncated")
    func agentTruncatedText() async throws {
        let (service, _, _) = service(scripts: [.init(events: [
            .contentDelta(choiceIndex: 0, text: "partial answer"),
            .finishReason(choiceIndex: 0, reason: "length"), .done
        ])])
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.content == "partial answer")
        #expect(service.activeConversation?.messages.last?.status == .truncated)
        #expect(service.activeConversation?.messages.last?.finishReason == "length")
    }

    @Test("a mixed SSE delta finishes thinking before the answer remains visible", arguments: [PlaygroundMode.chat, .agent])
    func mixedReasoningAndAnswerFrame(mode: PlaygroundMode) async throws {
        var decoder = ServerSentEventDecoder()
        let frame = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"thinking\",\"content\":\"answer\"}}]}\n\n".utf8)
        let events = try decoder.consume(frame) + [.done]
        let (service, _, _) = service(scripts: [.init(events: events, delay: .milliseconds(80))])
        if mode == .chat {
            service.sendMessage("hello", modelId: "test/model")
        } else {
            await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        }
        let conversationID = try #require(service.activeConversation?.id)
        let assistantID = try #require(service.activeConversation?.messages.last?.id)
        for _ in 0..<150 where service.isStreaming {
            let message = service.activeConversation?.messages.last
            if message?.reasoning == "thinking", message?.content == "answer" { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let visible = try #require(service.activeConversation?.messages.last)
        #expect(visible.reasoning == "thinking")
        #expect(visible.content == "answer")
        #expect(service.isStreaming)
        #expect(!service.isReasoningMessage(assistantID, conversationID: conversationID))
        #expect((visible.reasoningDuration ?? 0) >= 0.06)
        try await waitUntilIdle(service)
    }

    @Test("reasoning duration measures the stream, survives completion and storage in both modes")
    func reasoningDurationTracksEvents() async throws {
        let script = ScriptedOpenRouterClient.Script(events: [
            .reasoningDelta(choiceIndex: 0, text: "considering"),
            .contentDelta(choiceIndex: 0, text: "answer"),
            .done
        ], delay: .milliseconds(45))
        let (chat, _, chatStore) = service(scripts: [script])
        chat.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(chat)
        let chatMessage = try #require(chat.activeConversation?.messages.last)
        #expect(chatMessage.reasoningStartedAt != nil)
        #expect((chatMessage.reasoningDuration ?? 0) >= 0.03)
        #expect(chatStore.records[chat.activeConversation!.id]?.conversation.messages.last?.reasoningDuration == chatMessage.reasoningDuration)

        let (agent, _, _) = service(scripts: [script])
        await agent.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        try await waitUntilIdle(agent)
        let agentMessage = try #require(agent.activeConversation?.messages.last)
        #expect(agentMessage.reasoningStartedAt != nil)
        #expect((agentMessage.reasoningDuration ?? 0) >= 0.03)
    }

    @Test("Agent counts thinking in later tool turns without counting tool execution")
    func agentReasoningAcrossTurns() async throws {
        let first = ScriptedOpenRouterClient.Script(events: [
            .reasoningDelta(choiceIndex: 0, text: "first thought"),
            .contentDelta(choiceIndex: 0, text: "Need to check."),
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "unknown_tool", arguments: "{}"),
            .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
        ], delay: .milliseconds(50))
        let second = ScriptedOpenRouterClient.Script(events: [
            .reasoningDelta(choiceIndex: 0, text: "second thought"),
            .contentDelta(choiceIndex: 0, text: "Done."), .done
        ], delay: .milliseconds(50))
        let (service, _, _) = service(scripts: [first, second])
        await service.sendAgentMessage("hello", modelId: "test/model", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        let conversationID = try #require(service.activeConversation?.id)
        let assistantID = try #require(service.activeConversation?.messages.last?.id)
        var laterThinkingWasVisible = false
        for _ in 0..<400 where service.isStreaming {
            if service.isReasoningMessage(assistantID, conversationID: conversationID),
               service.activeConversation?.messages.last?.content.contains("Need to check.") == true {
                laterThinkingWasVisible = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(laterThinkingWasVisible)
        try await waitUntilIdle(service)
        let message = try #require(service.activeConversation?.messages.last)
        #expect(message.reasoning == "first thoughtsecond thought")
        #expect(message.content == "Need to check.\n\nDone.")
        #expect((message.reasoningDuration ?? 0) >= 0.085)
        #expect((message.reasoningDuration ?? 0) < 0.25, "do not count the time spent using tools or awaiting a new turn")
    }

    @Test("agent recovers when a turn streams only reasoning")
    func agentReasoningOnlyTurnRecovers() async throws {
        let (service, _, _) = service(scripts: [
            .init(events: [
                .reasoningDelta(choiceIndex: 0, text: "let me think about this"),
                .finishReason(choiceIndex: 0, reason: "stop")
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "final answer"), .done])
        ])

        await service.sendAgentMessage(
            "think it through",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false
        )
        try await waitUntilIdle(service)

        #expect(service.lastError == nil)
        #expect(service.activeConversation?.messages.last?.content == "final answer")
    }

    @Test("agent fails clearly when every turn is reasoning-only")
    func agentPersistentReasoningOnlyFails() async throws {
        let script = ScriptedOpenRouterClient.Script(events: [
            .reasoningDelta(choiceIndex: 0, text: "thinking"),
            .finishReason(choiceIndex: 0, reason: "stop")
        ])
        let (service, _, _) = service(scripts: [script, script, script])

        await service.sendAgentMessage(
            "think",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false
        )
        try await waitUntilIdle(service)

        #expect(service.lastError?.contains("only reasoning") == true)
    }

    @Test("agent tool cards retain execution result state")
    func agentToolCardLifecycle() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-tool-card-\(UUID().uuidString).txt")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = "{\"path\":\"\(file.path)\"}"
        let (service, _, _) = service(scripts: [
            .init(events: [
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "read_file", arguments: arguments),
                .finishReason(choiceIndex: 0, reason: "tool_calls")
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "done"), .done])
        ])

        await service.sendAgentMessage(
            "read it",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: true
        )
        try await waitUntilIdle(service)

        let card = service.activeConversation?.messages.last(where: { $0.role == "assistant" })?.toolCalls?.first
        #expect(card?.isExecuting == false)
        #expect(card?.isError == false)
        #expect(card?.result?.contains("fixture") == true)
    }

    @Test("cancelled Agent turns retain completed tool history")
    func cancelledAgentRetainsToolHistory() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-history-\(UUID().uuidString).txt")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = "{\"path\":\"\(file.path)\"}"
        let (service, client, _) = service(scripts: [
            .init(events: [
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-history", type: "function", name: "read_file", arguments: arguments),
                .finishReason(choiceIndex: 0, reason: "tool_calls")
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "late"), .done], delay: .milliseconds(200)),
            .init(events: [.contentDelta(choiceIndex: 0, text: "next"), .done])
        ])

        await service.sendAgentMessage(
            "first",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: true
        )
        for _ in 0..<200 where service.activeConversation?.messages.contains(where: { $0.role == "tool" }) != true {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(service.activeConversation?.messages.contains(where: { $0.role == "tool" }) == true)
        service.stopStreaming()
        try await waitUntilIdle(service)

        await service.sendAgentMessage(
            "second",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: true
        )
        try await waitUntilIdle(service)

        let messages = await client.requests.last?.messages ?? []
        #expect(messages.contains { $0.role == "user" && $0.content == "first" })
        #expect(messages.contains { $0.role == "assistant" && $0.toolCalls?.first?.id == "call-history" })
        #expect(messages.contains { $0.role == "tool" && $0.toolCallId == "call-history" })
        #expect(messages.contains { $0.role == "user" && $0.content == "second" })
    }

    @Test("messages cannot be deleted from a conversation with an active run")
    func activeRunRejectsMessageDeletion() async throws {
        let store = MemoryConversationStore()
        let (service, _, _) = service(
            scripts: [.init(events: [.contentDelta(choiceIndex: 0, text: "late"), .done], delay: .milliseconds(150))],
            store: store
        )
        await service.sendAgentMessage(
            "keep me",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false
        )
        let conversation = try #require(service.activeConversation)
        let userMessage = try #require(conversation.messages.first(where: { $0.role == "user" }))

        service.deleteMessage(userMessage.id, from: conversation)

        #expect(service.activeConversation?.messages.contains(where: { $0.id == userMessage.id }) == true)
        #expect(store.deletedMessageIDs.contains(userMessage.id) == false)
        #expect(service.lastError?.contains("cannot be deleted") == true)
        service.stopStreaming()
        try await waitUntilIdle(service)
    }

    @Test("background stream failures retain the run owner for banner scoping")
    func errorOwnerFollowsRun() async throws {
        let error = OpenRouterAPIError(code: 500, message: "A failed", errorType: "provider_error", providerName: nil)
        let (service, _, _) = service(scripts: [.init(events: [.apiError(error)], delay: .milliseconds(25))])
        let owner = service.newConversation(modelId: "test/model", mode: .chat)
        await service.sendMessage("hello", modelId: "test/model")
        let other = service.newConversation(modelId: "other/model", mode: .chat)
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.id == other.id)
        #expect(service.lastError == "A failed")
        #expect(service.lastErrorConversationID == owner.id)
        service.lastError = "This view's local error"
        #expect(service.lastErrorConversationID == nil)
    }

    @Test("partial provider errors are retained and marked failed")
    func partialProviderError() async throws {
        let providerError = OpenRouterAPIError(code: 500, message: "provider died", errorType: "provider_error", providerName: nil)
        let (service, _, _) = service(scripts: [.init(events: [.contentDelta(choiceIndex: 0, text: "partial"), .apiError(providerError)])])
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.content == "partial")
        #expect(service.activeConversation?.messages.last?.status == .failed)
        #expect(service.activeConversation?.messages.last?.errorMessage == "provider died")
    }

    @Test("abrupt EOF is interrupted, length finish is truncated")
    func terminalStates() async throws {
        let (service, _, _) = service(scripts: [
            .init(events: [.contentDelta(choiceIndex: 0, text: "partial")], terminalError: OpenRouterClientError.abruptEOF),
            .init(events: [.contentDelta(choiceIndex: 0, text: "short"), .finishReason(choiceIndex: 0, reason: "length")])
        ])
        await service.sendMessage("one", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.status == .interrupted)
        await service.sendMessage("two", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.status == .truncated)
        #expect(service.activeConversation?.messages.last?.finishReason == "length")
    }

    @Test("empty successful content becomes a failed placeholder")
    func emptyAssistantIsRemovedOrMarkedFailedWhenNoContentArrives() async throws {
        let (service, _, _) = service(scripts: [.init(events: [.done])])
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.status == .failed)
        #expect(service.activeConversation?.messages.last?.content.isEmpty == true)
    }

    @Test("stop is idempotent and a busy run cannot be replaced")
    func stopAndBusy() async throws {
        let (service, _, _) = service(scripts: [.init(events: [.contentDelta(choiceIndex: 0, text: "late"), .done], delay: .milliseconds(50))])
        await service.sendMessage("one", modelId: "test/model")
        await service.sendMessage("two", modelId: "test/model")
        #expect(service.lastError?.contains("already") == true)
        service.stopStreaming()
        service.stopStreaming()
        // Bounded polling: a fixed sleep flaked when the suite loaded the main actor.
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.filter { $0.role == "user" }.count == 1)
    }
}
