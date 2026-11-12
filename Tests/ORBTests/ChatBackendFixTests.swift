import Foundation
import Testing
@testable import ORB

/// Regressions promoted from the isolated backend audit. All storage is
/// in-memory SQLite; clients and credentials are fixtures, never live services.
@Suite("Chat backend audit fixes")
struct ChatBackendFixTests {
    // These overflow cases must run separately when probing the unfixed tree:
    // the old Int(Double(Int.max)) conversion traps rather than throwing.
    @Test("B21: Responses safely rejects invalid numeric indices",
          arguments: [Double(Int.max), 1e100, -1, 1.5])
    func responsesIndexBoundaryDoesNotTrap(index: Double) throws {
        let payload = try JSONEncoder().encode(JSONValue.object([
            "type": .string("response.output_text.delta"),
            "output_index": .number(index), "content_index": .number(index),
            "delta": .string("fixture")
        ]))
        let events = try ResponsesStreamDecoder.decode(payload)
        #expect(events == [.textDelta(outputIndex: nil, contentIndex: nil, itemID: nil, text: "fixture")])
    }

    @Test("B21: Messages safely rejects invalid numeric indices",
          arguments: [Double(Int.max), 1e100, -1, 1.5])
    func messagesIndexBoundaryDoesNotTrap(index: Double) throws {
        let payload = try JSONEncoder().encode(JSONValue.object([
            "type": .string("content_block_stop"), "index": .number(index)
        ]))
        let events = try MessagesStreamDecoder.decode(payload)
        #expect(events == [.contentBlockStop(index: 0)])
    }

    @Test("B21: both decoders retain representable nonnegative indices",
          arguments: [0.0, 1.0, Double(Int.max).nextDown])
    func validIndexBoundaries(index: Double) throws {
        let expected = try #require(Int(exactly: index))
        let responsesPayload = try JSONEncoder().encode(JSONValue.object([
            "type": .string("response.output_text.delta"),
            "output_index": .number(index), "content_index": .number(index),
            "delta": .string("fixture")
        ]))
        #expect(try ResponsesStreamDecoder.decode(responsesPayload) == [.textDelta(outputIndex: expected, contentIndex: expected, itemID: nil, text: "fixture")])
        let messagesPayload = try JSONEncoder().encode(JSONValue.object([
            "type": .string("content_block_stop"), "index": .number(index)
        ]))
        #expect(try MessagesStreamDecoder.decode(messagesPayload) == [.contentBlockStop(index: expected)])
    }

    @Test("B16: Messages terminal event ignores a fragmented trailing sentinel")
    func messagesTerminalBeforePartialSentinel() async throws {
        let stream = try await AdapterStreamPump.run(
            response: adapterResponse(), body: adapterBody("message_stop"),
            map: { try MessagesStreamDecoder.decode($0) },
            isTerminal: { event in
                switch event {
                case .messageStop, .done, .streamError: return true
                default: return false
                }
            }
        )
        var events: [MessagesStreamEvent] = []
        for try await event in stream { events.append(event) }
        #expect(events == [.messageStop(metadata: nil)])
    }

    @Test("B16: Responses terminal event ignores a fragmented trailing sentinel")
    func responsesTerminalBeforePartialSentinel() async throws {
        let stream = try await AdapterStreamPump.run(
            response: adapterResponse(), body: adapterBody("response.completed"),
            map: { try ResponsesStreamDecoder.decode($0) },
            isTerminal: { event in
                switch event {
                case .completed, .incomplete, .failed, .done, .streamError: return true
                default: return false
                }
            }
        )
        var events: [ResponsesStreamEvent] = []
        for try await event in stream { events.append(event) }
        #expect(events == [.completed(nil)])
    }

    @Test("B16: EOF before a terminal event still rejects incomplete framing")
    func partialPreterminalEventStillFails() async throws {
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data: {\"type\":\"message_stop\"}".utf8))
            continuation.finish()
        }
        let stream = try await AdapterStreamPump.run(
            response: adapterResponse(), body: body,
            map: { try MessagesStreamDecoder.decode($0) },
            isTerminal: { if case .messageStop = $0 { return true }; return false }
        )
        do {
            for try await _ in stream {}
            Issue.record("Incomplete preterminal framing must fail")
        } catch let error as AdapterStreamError {
            guard case .incompleteEventAtEOF = error else {
                Issue.record("Wrong stream failure: \(error)")
                return
            }
        }
    }

    private func adapterResponse() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://fixture.invalid/stream")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func adapterBody(_ terminalType: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data("data: {\"type\":\"\(terminalType)\"}\n\ndata: [DO".utf8))
            continuation.yield(Data("NE]\n\n".utf8))
            continuation.finish()
        }
    }

    @Test("B08: invalid or oversized retry hints have nontrapping descriptions",
          arguments: [1e100, Double(Int.max), .infinity, -.infinity, .nan, -1])
    func retryDescriptionIsSafe(hint: Double) {
        let error = OpenRouterClientError.http(status: 429, message: "fixture", retryAfter: hint)
        #expect(error.errorDescription == "OpenRouter rate limit reached. Try again shortly. fixture")
    }

    @Test("B08: ordinary retry hints still round up to whole seconds")
    func retryDescriptionRoundsUp() {
        let error = OpenRouterClientError.http(status: 429, message: "fixture", retryAfter: 1.2)
        #expect(error.errorDescription == "OpenRouter rate limit reached. Try again in about 2 seconds. fixture")
    }

    @Test("B11: streamed transcript preserves split graphemes in Chat and Agent",
          arguments: [["e", "\u{301}"], ["👍", "🏽"], ["👩", "\u{200D}💻"], ["line\r", "\nnext"]], [false, true])
    @MainActor
    func splitGraphemes(chunks: [String], agent: Bool) async throws {
        let events: [OpenRouterStreamEvent] = chunks.map { .reasoningDelta(choiceIndex: 0, text: $0) }
            + chunks.map { .contentDelta(choiceIndex: 0, text: $0) } + [.done]
        let store = CountingConversationStore()
        let service = ChatService(client: WaveScriptedClient([.init(events: events)]), store: store, apiKeyProvider: { "fixture" }, mcpServerProvider: { [] })
        if agent {
            await service.sendAgentMessage("fixture", modelId: "fixture/model", workspace: "/unused-fixture", fullComputerAccess: false)
        } else {
            service.sendMessage("fixture", modelId: "fixture/model")
        }
        try await waitUntilIdle(service)
        let conversation = try #require(service.activeConversation)
        let message = try #require(conversation.messages.last)
        let stored = try #require(store.records[conversation.id]?.conversation.messages.last)
        let expected = Data(chunks.joined().utf8)
        #expect(message.status == .complete)
        for value in [message, stored] {
            #expect(Data(value.content.utf8) == expected)
            #expect(Data((value.reasoning ?? "").utf8) == expected)
            #expect(Data(value.displayTranscript.filter { $0.kind == .text }.map(\.text).joined().utf8) == expected)
            #expect(Data(value.displayTranscript.filter { $0.kind == .reasoning }.map(\.text).joined().utf8) == expected)
        }
    }

    @Test("B11: final budget notice preserves the newline after a trailing CR")
    @MainActor
    func finalTranscriptReconciliationPreservesScalars() async throws {
        let client = WaveScriptedClient([
            .init(events: [
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "fixture-call", type: "function", name: "unknown_tool", arguments: "{}"),
                .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "Summary\r"), .done])
        ])
        let service = ChatService(client: client, store: CountingConversationStore(), apiKeyProvider: { "fixture" }, agentMaximumTurns: 1, mcpServerProvider: { [] })
        await service.sendAgentMessage("fixture", modelId: "fixture/model", workspace: "/unused-fixture", fullComputerAccess: false)
        try await waitUntilIdle(service)
        let message = try #require(service.activeConversation?.messages.last)
        #expect(message.content.contains("tool-call budget"))
        let displayed = message.displayTranscript.filter { $0.kind == .text }.map(\.text).joined()
        #expect(Data(displayed.utf8) == Data(message.content.utf8))
    }

    @Test("B05: a later deletion failure rolls back the entire edit")
    @MainActor
    func partialTruncationMustRollBack() throws {
        let database = DatabaseManager(path: ":memory:")
        let store = DatabaseConversationStore(database: database)
        var conversation = ChatConversation(modelId: "fixture/model", mode: .agent)
        conversation.messages = [
            ChatMessage(role: "user", content: "question"),
            ChatMessage(role: "assistant", content: "answer")
        ]
        let history = [AgentAPIMessage(role: "user", content: "question")]
        try store.saveRecord(.init(conversation: conversation, agentHistory: history))
        let service = ChatService(client: WaveScriptedClient([]), store: store, apiKeyProvider: { nil })
        service.selectConversation(conversation)
        let blockedID = conversation.messages[1].id.uuidString
        try database.execChecked("CREATE TRIGGER deny_second_delete BEFORE DELETE ON messages WHEN OLD.id = '\(blockedID)' BEGIN SELECT RAISE(ABORT, 'injected second-delete failure'); END;")

        #expect(service.truncateConversation(from: conversation.messages[0].id, in: conversation.id) == nil)
        #expect(service.activeConversation?.messages == conversation.messages)
        #expect(service.lastError?.contains("Could not edit the conversation") == true)
        let stored = try #require(store.loadRecords().first)
        #expect(stored.conversation.messages == conversation.messages)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(stored.agentHistory) == encoder.encode(history))

        // A retry after clearing the fault commits messages and history together.
        try database.execChecked("DROP TRIGGER deny_second_delete;")
        #expect(service.truncateConversation(from: conversation.messages[0].id, in: conversation.id) == "question")
        #expect(service.activeConversation?.messages.isEmpty == true)
        let retried = try #require(store.loadRecords().first)
        #expect(retried.conversation.messages.isEmpty)
        #expect(retried.agentHistory.isEmpty)
    }

    @Test("B05: replacement write failure preserves the in-memory prefix and suffix")
    @MainActor
    func replacementFailurePreservesMemory() throws {
        let database = DatabaseManager(path: ":memory:")
        let store = DatabaseConversationStore(database: database)
        var conversation = ChatConversation(modelId: "fixture/model", mode: .chat)
        conversation.messages = [
            ChatMessage(role: "user", content: "q1"),
            ChatMessage(role: "assistant", content: "a1"),
            ChatMessage(role: "user", content: "q2"),
            ChatMessage(role: "assistant", content: "a2")
        ]
        try store.saveRecord(.init(conversation: conversation, agentHistory: []))
        let service = ChatService(client: WaveScriptedClient([]), store: store, apiKeyProvider: { nil })
        service.selectConversation(conversation)
        try database.execChecked("CREATE TRIGGER deny_replacement BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'injected replacement failure'); END;")

        #expect(service.truncateConversation(from: conversation.messages[2].id, in: conversation.id) == nil)
        #expect(service.activeConversation?.messages == conversation.messages)
        #expect(try store.loadRecords().first?.conversation.messages == conversation.messages)
    }
}
