import Foundation
import SQLite3
import Testing
@testable import ORB

// F07 round-trip coverage: OpenRouter's structured `reasoning_details` must
// survive stream decode → domain message → persistence → next tool turn with
// exact values and order, while opaque signature/encrypted payloads never
// become display text.

/// Raw `reasoning_details` array exactly as a provider might send it: text,
/// summary, signed text (base64 containing `/`), an encrypted payload, an
/// unknown extra key, and unicode in display text.
private let fixtureDetailsJSON = """
[{"type":"reasoning.text","text":"Step one: read the file.","id":"rs_1","format":"openrouter-reasoning","index":0},{"type":"reasoning.summary","summary":"Reading the file.","id":"rs_2","index":1},{"type":"reasoning.text","text":"héllo 🌍 signature blocks stay opaque / ok","signature":"c2ln+X/alph/52/f==","id":"rs_3","index":2},{"type":"reasoning.encrypted","data":"ZXhhY3QtYnl0ZXMt/9j/4AAQSkZJRg==","format":"anthropic-claude","id":"rs_4","index":3,"provider_custom":{"note":"keep-me","flag":true}}]
"""

private let fixtureSignature = "c2ln+X/alph/52/f=="
private let fixtureEncrypted = "ZXhhY3QtYnl0ZXMt/9j/4AAQSkZJRg=="

private func fixtureDetails() -> [ReasoningDetail] {
    // Fixed, deterministic fixture: decoding cannot legitimately fail here.
    try! JSONDecoder().decode([ReasoningDetail].self, from: Data(fixtureDetailsJSON.utf8))
}

private func sse(_ payload: String) -> Data {
    Data("data: \(payload)\n\n".utf8)
}

private func detailsEnvelope(_ arrayJSON: String) -> Data {
    sse("{\"id\":\"gen-1\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_details\":\(arrayJSON)}}]}")
}

/// Canonical JSON bytes for a value: an order-insensitive but value-exact
/// comparison basis across different encoder passes.
private func canonicalJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

// MARK: - Fixtures

private final class ScriptedTurnClient: OpenRouterClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [[OpenRouterStreamEvent]]
    private(set) var requests: [OpenRouterRequest] = []

    init(_ turns: [[OpenRouterStreamEvent]]) { self.turns = turns }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = turns.isEmpty ? [OpenRouterStreamEvent.done] : turns.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor
private final class MemoryConversationStore: ConversationStore {
    var records: [UUID: StoredConversation] = [:]
    func loadRecords() throws -> [StoredConversation] { Array(records.values) }
    func saveRecord(_ record: StoredConversation) throws { records[record.conversation.id] = record }
    func removeConversation(_ id: UUID) throws { records[id] = nil }
    func removeMessage(_ id: UUID) throws {
        for key in records.keys { records[key]?.conversation.messages.removeAll { $0.id == id } }
    }
    func recoverInterruptedRecords() throws {}
}

@Suite("Reasoning details stream decoding (F07)")
struct ReasoningDetailsStreamTests {
    @Test("structured blocks decode in wire order with exact opaque bytes")
    func structuredDecode() throws {
        var decoder = ServerSentEventDecoder()
        let events = try decoder.consume(detailsEnvelope(fixtureDetailsJSON)) + (try decoder.finish())
        let details = fixtureDetails()

        // Display delta first (flattened extraction, unchanged behavior),
        // then the full structured array.
        #expect(events == [
            .reasoningDelta(choiceIndex: 0, text: "héllo 🌍 signature blocks stay opaque / ok"),
            .reasoningDetails(choiceIndex: 0, details: details),
        ])
        #expect(details.count == 4)
        #expect(details.map(\.type) == ["reasoning.text", "reasoning.summary", "reasoning.text", "reasoning.encrypted"])
        // Exact opaque bytes: signature (with a `/`) and encrypted payload.
        #expect(details[2].signature == fixtureSignature)
        #expect(details[3].data == fixtureEncrypted)
        #expect(details[3].format == "anthropic-claude")
        // Unknown extra keys survive verbatim.
        #expect(details[3].extra["provider_custom"]?.objectValue?["note"]?.stringValue == "keep-me")
        #expect(details[3].extra["provider_custom"]?.objectValue?["flag"]?.boolValue == true)
    }

    @Test("details survive byte-by-byte fragmented streaming")
    func fragmentedDecode() throws {
        let envelope = detailsEnvelope(fixtureDetailsJSON)
        var output: [OpenRouterStreamEvent] = []
        var decoder = ServerSentEventDecoder()
        for byte in envelope { output += try decoder.consume(Data([byte])) }
        output += try decoder.finish()
        #expect(output == [
            .reasoningDelta(choiceIndex: 0, text: "héllo 🌍 signature blocks stay opaque / ok"),
            .reasoningDetails(choiceIndex: 0, details: fixtureDetails()),
        ])
    }

    @Test("interleaved chunks assemble in wire order alongside text")
    func interleavedAssembly() throws {
        let firstChunk = """
        [{"type":"reasoning.text","text":"thinking part one","id":"a","index":0}]
        """
        let secondChunk = """
        [{"type":"reasoning.summary","summary":"summary","id":"b","index":1},{"type":"reasoning.encrypted","data":"\(fixtureEncrypted)","id":"c","index":2}]
        """
        var decoder = ServerSentEventDecoder()
        var events: [OpenRouterStreamEvent] = []
        events += try decoder.consume(sse("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"A\"}}]}"))
        events += try decoder.consume(detailsEnvelope(firstChunk))
        events += try decoder.consume(sse("{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"plain think\"}}]}"))
        events += try decoder.consume(detailsEnvelope(secondChunk))
        events += try decoder.consume(sse("{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"B\"}}]}"))
        events += try decoder.finish()

        // Content and display reasoning are untouched.
        #expect(events.contains(.contentDelta(choiceIndex: 0, text: "A")))
        #expect(events.contains(.contentDelta(choiceIndex: 0, text: "B")))
        #expect(events.contains(.reasoningDelta(choiceIndex: 0, text: "thinking part one")))
        #expect(events.contains(.reasoningDelta(choiceIndex: 0, text: "plain think")))
        // Details arrive chunk by chunk in wire order.
        let detailEvents = events.compactMap { event -> [ReasoningDetail]? in
            if case .reasoningDetails(_, let details) = event { return details }
            return nil
        }
        #expect(detailEvents.count == 2)
        #expect(detailEvents[0].map(\.id) == ["a"])
        #expect(detailEvents[1].map(\.id) == ["b", "c"])
        #expect(detailEvents[1][1].data == fixtureEncrypted)
    }

    @Test("display text keeps text/summary extraction and never contains payloads")
    func displayExtraction() throws {
        var decoder = ServerSentEventDecoder()
        let events = try decoder.consume(detailsEnvelope(fixtureDetailsJSON)) + (try decoder.finish())

        // Newest displayable block wins, exactly as before F07 for text/summary.
        guard case .reasoningDelta(_, let display) = events.first(where: { if case .reasoningDelta = $0 { true } else { false } }) else {
            Issue.record("Expected a reasoning delta for display")
            return
        }
        #expect(display == "héllo 🌍 signature blocks stay opaque / ok")
        #expect(!display.contains(fixtureSignature))
        #expect(!display.contains(fixtureEncrypted))

        // An encrypted-only chunk produces structure but no display text.
        let encryptedOnly = """
        [{"type":"reasoning.encrypted","data":"\(fixtureEncrypted)","id":"e","index":0}]
        """
        var second = ServerSentEventDecoder()
        let encryptedEvents = try second.consume(detailsEnvelope(encryptedOnly)) + (try second.finish())
        #expect(encryptedEvents.count == 1)
        guard case .reasoningDetails(0, let only) = encryptedEvents[0] else {
            Issue.record("Expected a reasoningDetails event")
            return
        }
        #expect(only[0].data == fixtureEncrypted)
        #expect(only[0].displayText == nil)
        #expect(only[0].isOpaqueOnly)
    }

    @Test("opaque-only detail blocks are preserved and never rendered")
    func opaqueBlocksStayOpaque() {
        let encrypted = ReasoningDetail(type: "reasoning.encrypted", data: fixtureEncrypted)
        #expect(encrypted.displayText == nil)
        let signed = ReasoningDetail(type: "reasoning.text", text: "visible", signature: fixtureSignature)
        #expect(signed.displayText == "visible")
        #expect(!signed.isOpaqueOnly)
    }
}

@Suite("Reasoning details chat persistence (F07)")
@MainActor
struct ReasoningDetailsChatTests {
    private func waitUntilIdle(_ service: ChatService) async throws {
        for _ in 0..<500 where service.isStreaming { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!service.isStreaming)
    }

    @Test("chat path stores structured details without touching display text")
    func chatPathStoresDetails() async throws {
        // Feed the raw SSE through the real decoder so the script matches the
        // wire exactly: display delta + structured details.
        var decoder = ServerSentEventDecoder()
        let decoded = try decoder.consume(detailsEnvelope(fixtureDetailsJSON)) + (try decoder.finish())
        let client = ScriptedTurnClient([decoded + [.contentDelta(choiceIndex: 0, text: "Answer"), .done]])
        let store = MemoryConversationStore()
        let service = ChatService(client: client, store: store, apiKeyProvider: { "fixture-key" })

        await service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)

        let conversation = try #require(service.conversations.first)
        let assistant = try #require(conversation.messages.last)
        #expect(assistant.role == "assistant")
        #expect(assistant.reasoningDetails == fixtureDetails())
        // Display reasoning stays the human-readable extraction.
        #expect(assistant.reasoning == "héllo 🌍 signature blocks stay opaque / ok")
        // The persisted record carries the same wire state.
        let saved = try #require(store.records[conversation.id]?.conversation.messages.last)
        #expect(saved.reasoningDetails == fixtureDetails())
    }

    @Test("agent path surfaces the same details (pitfall 28)")
    func agentPathSurfacesDetails() async throws {
        let details = fixtureDetails()
        let turn1: [OpenRouterStreamEvent] = [
            .reasoningDetails(choiceIndex: 0, details: details),
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "read_file", arguments: "{\"path\":\"a.txt\"}"),
            .finishReason(choiceIndex: 0, reason: "tool_calls"),
        ]
        let client = ScriptedTurnClient([
            turn1,
            [.contentDelta(choiceIndex: 0, text: "Done."), .finishReason(choiceIndex: 0, reason: "stop")],
        ])
        let store = MemoryConversationStore()
        let service = ChatService(client: client, store: store, apiKeyProvider: { "fixture-key" })

        // Web Only policy denies the tool call (no real execution in tests);
        // the run still continues to the scripted final answer.
        await service.sendAgentMessage("go", modelId: "test/model", workspace: "/tmp", fullComputerAccess: false)
        try await waitUntilIdle(service)

        let conversation = try #require(service.conversations.first)
        let assistant = try #require(conversation.messages.last)
        #expect(assistant.role == "assistant")
        #expect(assistant.reasoningDetails == fixtureDetails())
        // The agent wire history kept for the next send retains the blocks.
        let history = try #require(store.records[conversation.id]?.agentHistory)
        let historyAssistant = history.filter { $0.role == "assistant" && $0.toolCalls != nil }
        #expect(historyAssistant.count == 1)
        #expect(historyAssistant[0].reasoningDetails == fixtureDetails())
    }
}

@Suite("Reasoning details database round-trip (F07)")
struct ReasoningDetailsDatabaseTests {
    @Test("details round-trip through SQLite byte-exact")
    func databaseRoundTrip() throws {
        let db = DatabaseManager()
        let details = fixtureDetails()
        var conversation = ChatConversation(modelId: "test/model", mode: .chat)
        conversation.messages = [
            ChatMessage(role: "user", content: "hi"),
            ChatMessage(role: "assistant", content: "answer", reasoning: "Step one: read the file.",
                        reasoningStartedAt: Date(timeIntervalSince1970: 1_000), reasoningDuration: 3.25,
                        reasoningDetails: details),
        ]
        try db.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")

        let loaded = db.loadMessages(for: conversation.id)
        #expect(loaded.count == 2)
        // A message without reasoning details is unaffected.
        #expect(loaded[0].reasoningDetails == nil)
        #expect(loaded[1].reasoningDetails == details)
        #expect(loaded[1].reasoning == "Step one: read the file.")
        #expect(loaded[1].reasoningStartedAt == Date(timeIntervalSince1970: 1_000))
        #expect(loaded[1].reasoningDuration == 3.25)

        // Canonical JSON equality: order, unknown keys, and opaque values exact.
        let original = try canonicalJSON(try JSONSerialization.jsonObject(with: Data(fixtureDetailsJSON.utf8)))
        let roundTripped = try canonicalJSON(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(loaded[1].reasoningDetails!))
        )
        #expect(roundTripped == original)
    }

    @Test("legacy schema migrates additively and old rows load without details")
    func legacySchemaMigrates() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-reasoning-legacy-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let legacySQL = """
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY, mode TEXT NOT NULL, model_id TEXT NOT NULL,
            title TEXT NOT NULL, system_prompt TEXT DEFAULT '', total_cost REAL DEFAULT 0,
            total_tokens INTEGER DEFAULT 0, agent_history_json TEXT DEFAULT '[]', created_at REAL NOT NULL
        );
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
            content TEXT NOT NULL, tool_calls_json TEXT, tool_call_id TEXT, tool_name TEXT,
            sort_order INTEGER NOT NULL, created_at REAL NOT NULL,
            FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        );
        INSERT INTO conversations (id, mode, model_id, title, created_at)
        VALUES ('11111111-1111-1111-1111-111111111111', 'chat', 'legacy/model', 'legacy', 0);
        INSERT INTO messages (id, conversation_id, role, content, sort_order, created_at)
        VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'user', 'legacy row', 0, 0);
        """
        #expect(sqlite3_exec(handle, legacySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let migrated = DatabaseManager(path: url.path)
        let legacyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let legacyMessages = migrated.loadMessages(for: legacyID)
        #expect(legacyMessages.count == 1)
        #expect(legacyMessages[0].content == "legacy row")
        #expect(legacyMessages[0].reasoningDetails == nil)

        // New messages with details save and reload through the migrated schema.
        var conversation = ChatConversation(id: legacyID, modelId: "test/model", mode: .chat)
        conversation.messages = [ChatMessage(role: "assistant", content: "new", reasoningDetails: fixtureDetails())]
        try migrated.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")
        let reloaded = migrated.loadMessages(for: legacyID)
        #expect(reloaded.count == 1)
        #expect(reloaded[0].reasoningDetails == fixtureDetails())
    }
}

@Suite("Reasoning details tool continuation (F07)")
struct ReasoningDetailsContinuationTests {
    @Test("next tool-turn request carries the blocks unmodified")
    func toolContinuationWireFidelity() async throws {
        // Chain the whole path: raw SSE bytes → decoder → agent wire history.
        var decoder = ServerSentEventDecoder()
        let decoded = try decoder.consume(detailsEnvelope(fixtureDetailsJSON)) + (try decoder.finish())
        let detailEvents = decoded.compactMap { event -> [ReasoningDetail]? in
            if case .reasoningDetails(_, let details) = event { return details }
            return nil
        }
        #expect(detailEvents.count == 1)

        let client = ScriptedTurnClient([
            [.reasoningDetails(choiceIndex: 0, details: fixtureDetails())]
                + [
                    .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "read_file", arguments: "{\"path\":\"a.txt\"}"),
                    .finishReason(choiceIndex: 0, reason: "tool_calls"),
                ],
            [.contentDelta(choiceIndex: 0, text: "All done."), .finishReason(choiceIndex: 0, reason: "stop")],
        ])

        let result = try await NativeAgentRunner.run(
            prompt: "read it", modelId: "test/model", apiKey: "fixture-key",
            workspace: "/tmp", fullComputerAccess: false, history: [],
            client: client,
            toolExecutor: { _ in NativeAgentToolResult(content: "file body", isError: false) },
            onEvent: { _ in }
        )
        #expect(result.response == "All done.")

        // The follow-up request the runner built for turn 2.
        #expect(client.requests.count == 2)
        let followUp = client.requests[1]
        let assistantIndex = try #require(followUp.messages.firstIndex { $0.role == "assistant" && $0.toolCalls != nil })
        let assistant = followUp.messages[assistantIndex]
        #expect(assistant.toolCalls?.first?.id == "call-1")
        // Domain message: exact same blocks, same order.
        #expect(assistant.reasoningDetails == fixtureDetails())
        // The tool result follows immediately after the assistant turn.
        #expect(followUp.messages[assistantIndex + 1].role == "tool")

        // Wire bytes: the encoded request body's reasoning_details JSON is
        // value-exact (order, unknown keys, opaque strings) to the fixture.
        let body = try OpenRouterRequestEncoder.encodeBody(followUp, stream: true)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let wireAssistant = try #require(messages.first { $0["reasoning_details"] != nil })
        let wireDetails = try #require(wireAssistant["reasoning_details"] as? [[String: Any]])
        let fixtureParsed = try #require(try JSONSerialization.jsonObject(with: Data(fixtureDetailsJSON.utf8)) as? [[String: Any]])
        let wireCanonical = try canonicalJSON(wireDetails)
        let fixtureCanonical = try canonicalJSON(fixtureParsed)
        #expect(wireCanonical == fixtureCanonical)
    }

    @Test("messages without details keep their previous wire shape")
    func absentDetailsOmitWireKey() throws {
        let request = OpenRouterRequest(
            apiKey: "fixture-key", model: "test/model",
            messages: [
                .init(role: "user", content: "hi"),
                .init(role: "assistant", content: "hello"),
            ]
        )
        let body = try OpenRouterRequestEncoder.encodeBody(request, stream: true)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        for message in messages {
            #expect(message["reasoning_details"] == nil)
        }

        // ChatMessage Codable payload likewise omits the key.
        let encoded = try JSONEncoder().encode(ChatMessage(role: "assistant", content: "x"))
        let decoded = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(decoded["reasoning_details"] == nil)
    }
}
