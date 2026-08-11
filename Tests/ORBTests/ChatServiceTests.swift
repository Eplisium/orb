import Foundation
import Testing
@testable import ORB

private actor ScriptedOpenRouterClient: OpenRouterClientProtocol {
    struct Script: Sendable {
        let events: [OpenRouterStreamEvent]
        var delay: Duration = .zero
        var terminalError: (any Error & Sendable)? = nil
    }
    private var scripts: [Script]
    private(set) var requests: [OpenRouterRequest] = []

    init(_ scripts: [Script]) { self.scripts = scripts }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests.append(request)
        let script = scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in script.events {
                    if script.delay != .zero { try await Task.sleep(for: script.delay) }
                    try Task.checkCancellation()
                    continuation.yield(event)
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
        apiKey: String? = "fixture-key"
    ) -> (ChatService, ScriptedOpenRouterClient, MemoryConversationStore) {
        let store = suppliedStore ?? MemoryConversationStore()
        let client = ScriptedOpenRouterClient(scripts)
        return (ChatService(client: client, store: store, apiKeyProvider: { apiKey }), client, store)
    }

    private func waitUntilIdle(_ service: ChatService) async throws {
        for _ in 0..<500 where service.isStreaming { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!service.isStreaming)
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

    @Test("hundreds of deltas are lossless and coalesced")
    func coalescedDeltas() async throws {
        let pieces = (0..<1_000).map { "\($0)," }
        let events = pieces.map { OpenRouterStreamEvent.contentDelta(choiceIndex: 0, text: $0) } + [.done]
        let (service, _, _) = service(scripts: [.init(events: events)])
        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.content == pieces.joined())
        #expect(service.contentPublishCount < 20)
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

    @Test("agent deltas are lossless and coalesced")
    func coalescedAgentDeltas() async throws {
        let pieces = (0..<1_000).map { "\($0)," }
        let events = pieces.map { OpenRouterStreamEvent.contentDelta(choiceIndex: 0, text: $0) } + [.done]
        let (service, _, _) = service(scripts: [.init(events: events)])

        await service.sendAgentMessage(
            "hello",
            modelId: "test/model",
            workspace: FileManager.default.temporaryDirectory.path,
            fullComputerAccess: false
        )
        try await waitUntilIdle(service)

        #expect(service.activeConversation?.messages.last?.content == pieces.joined())
        #expect(service.contentPublishCount < 20)
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
        try await Task.sleep(for: .milliseconds(80))
        #expect(!service.isStreaming)
        #expect(service.activeConversation?.messages.filter { $0.role == "user" }.count == 1)
    }
}
