import Foundation
import Testing
@testable import ORB

// Shared fixtures for the Wave 1 chat-core behaviors: MCP policy wiring,
// incremental persistence, model switching, wire-history hygiene.

actor WaveScriptedClient: TimedOpenRouterStreaming {
    struct Script: Sendable {
        var events: [OpenRouterStreamEvent]
        var delay: Duration = .zero
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

    func timedStream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<TimedStreamEvent<OpenRouterStreamEvent>, Error> {
        requests.append(request)
        let script = scripts.isEmpty ? Script(events: [.contentDelta(choiceIndex: 0, text: "ok"), .done]) : scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in script.events {
                    if script.delay != .zero { try await Task.sleep(for: script.delay) }
                    try Task.checkCancellation()
                    continuation.yield(.init(event: event, arrivedAt: Date()))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Distinguishes full rewrites from incremental saves.
@MainActor
final class CountingConversationStore: ConversationStore {
    var records: [UUID: StoredConversation] = [:]
    var fullSaves = 0
    var metaSaves = 0
    var messageSaves: [Set<UUID>] = []

    func loadRecords() throws -> [StoredConversation] { Array(records.values) }
    func saveRecord(_ record: StoredConversation) throws {
        fullSaves += 1
        records[record.conversation.id] = record
    }
    func saveConversationMeta(_ record: StoredConversation) throws {
        metaSaves += 1
        var existing = records[record.conversation.id] ?? record
        let messages = existing.conversation.messages
        existing = record
        existing.conversation.messages = messages
        records[record.conversation.id] = existing
    }
    func saveMessages(_ messageIDs: Set<UUID>, of record: StoredConversation) throws {
        messageSaves.append(messageIDs)
        var existing = records[record.conversation.id] ?? record
        for message in record.conversation.messages where messageIDs.contains(message.id) {
            if let index = existing.conversation.messages.firstIndex(where: { $0.id == message.id }) {
                existing.conversation.messages[index] = message
            } else {
                existing.conversation.messages.append(message)
            }
        }
        records[record.conversation.id] = existing
    }
    func removeConversation(_ id: UUID) throws { records[id] = nil }
    func removeMessage(_ id: UUID) throws {
        for key in records.keys { records[key]?.conversation.messages.removeAll { $0.id == id } }
    }
    func recoverInterruptedRecords() throws {}
}

@MainActor
func waitUntilIdle(_ service: ChatService) async throws {
    for _ in 0..<1_000 where service.isStreaming { try await Task.sleep(for: .milliseconds(2)) }
    #expect(!service.isStreaming)
}

private let workspace = FileManager.default.temporaryDirectory.path

// MARK: - Item 1: MCP tools reach the Agent

@Suite("Wave1: Agent MCP policy")
@MainActor
struct AgentMCPPolicyTests {
    private let servers = [
        MCPServerConfig(name: "File System", command: "true"),
        MCPServerConfig(name: "off", command: "true", isEnabled: false),
    ]

    @Test("agentSession approves enabled servers by sanitized slug, only with computer access")
    func policyFromConfigs() {
        let full = ToolPolicy.agentSession(fullComputerAccess: true, mcpServers: servers)
        #expect(full.approvedMCPServers == ["File-System"])
        #expect(full.allowsDefinition(name: "mcp__File-System__read"))
        #expect(!full.allowsDefinition(name: "mcp__off__read"))
        let webOnly = ToolPolicy.agentSession(fullComputerAccess: false, mcpServers: servers)
        #expect(webOnly.approvedMCPServers.isEmpty)
        #expect(!webOnly.allowsDefinition(name: "mcp__File-System__read"))
    }

    @Test("sendAgentMessage passes a policy populated from MCP settings into the run")
    func serviceWiresPolicy() async throws {
        let client = WaveScriptedClient([])
        let service = ChatService(
            client: client, store: CountingConversationStore(), apiKeyProvider: { "fixture" },
            mcpServerProvider: { servers }
        )
        await service.sendAgentMessage("hi", modelId: "test/model", workspace: workspace, fullComputerAccess: true)
        try await waitUntilIdle(service)
        #expect(service.lastAgentPolicy?.approvedMCPServers == ["File-System"])
        #expect(service.lastAgentPolicy?.capabilities.contains(.mcp) == true)
    }
}

// MARK: - Item 2: incremental streaming persistence

@Suite("Wave1: incremental persistence")
@MainActor
struct IncrementalPersistenceTests {
    @Test("streaming checkpoints upsert only the assistant row, never rewrite the conversation")
    func checkpointsAreIncremental() async throws {
        let store = CountingConversationStore()
        let client = WaveScriptedClient([.init(events: [
            .contentDelta(choiceIndex: 0, text: "one "),
            .contentDelta(choiceIndex: 0, text: "two "),
            .contentDelta(choiceIndex: 0, text: "three"), .done
        ], delay: .milliseconds(20))])
        let service = ChatService(client: client, store: store, apiKeyProvider: { "fixture" })
        service.sendMessage("hello", modelId: "test/model")
        let assistantID = try #require(service.activeConversation?.messages.last?.id)
        let fullBefore = store.fullSaves
        for _ in 0..<500 where store.messageSaves.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(store.fullSaves == fullBefore, "no full rewrite while streaming")
        #expect(!store.messageSaves.isEmpty)
        #expect(store.messageSaves.allSatisfy { $0 == [assistantID] })
        try await waitUntilIdle(service)
        // Exactly one full save at the terminal transition.
        #expect(store.fullSaves == fullBefore + 1)
        #expect(store.records.values.first?.conversation.messages.last?.content == "one two three")
    }

    @Test("Agent checkpoints include the tool rows inserted during the run")
    func agentCheckpointsIncludeToolRows() async throws {
        let store = CountingConversationStore()
        let client = WaveScriptedClient([
            .init(events: [
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "c1", type: "function", name: "unknown_tool", arguments: "{}"),
                .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "done"), .done], delay: .milliseconds(5))
        ])
        let service = ChatService(client: client, store: store, apiKeyProvider: { "fixture" })
        await service.sendAgentMessage("go", modelId: "test/model", workspace: workspace, fullComputerAccess: false)
        try await waitUntilIdle(service)
        let toolID = try #require(service.activeConversation?.messages.first(where: { $0.role == "tool" })?.id)
        #expect(store.messageSaves.contains { $0.contains(toolID) })
    }

    @Test("system prompt edits are debounced to one meta save")
    func systemPromptDebounced() async throws {
        let store = CountingConversationStore()
        let service = ChatService(client: WaveScriptedClient([]), store: store, apiKeyProvider: { "fixture" })
        let conversation = service.newConversation(modelId: "test/model", mode: .chat)
        let fullBefore = store.fullSaves
        var prompt = ""
        for character in "Be concise." {
            prompt.append(character)
            service.updateSystemPrompt(prompt, for: conversation)
        }
        #expect(store.fullSaves == fullBefore)
        #expect(store.metaSaves == 0)
        #expect(service.activeConversation?.systemPrompt == "Be concise.")
        service.flushPendingEdits()
        #expect(store.metaSaves == 1)
        #expect(store.records[conversation.id]?.conversation.systemPrompt == "Be concise.")
        service.flushPendingEdits()
        #expect(store.metaSaves == 1, "flush is idempotent")
    }

    @Test("a debounced prompt save lands after the delay")
    func systemPromptSavesAfterDelay() async throws {
        let store = CountingConversationStore()
        let service = ChatService(client: WaveScriptedClient([]), store: store, apiKeyProvider: { "fixture" })
        let conversation = service.newConversation(modelId: "test/model", mode: .chat)
        service.updateSystemPrompt("x", for: conversation)
        for _ in 0..<1_000 where store.metaSaves == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.metaSaves == 1)
    }

    @Test("SQLite incremental save updates one row and leaves the others intact")
    func databaseIncrementalSave() throws {
        let database = DatabaseManager()
        let store = DatabaseConversationStore(database: database)
        var conversation = ChatConversation(modelId: "test/model", mode: .chat)
        conversation.messages = [
            ChatMessage(role: "user", content: "a"),
            ChatMessage(role: "assistant", content: "b"),
            ChatMessage(role: "user", content: "c"),
        ]
        try store.saveRecord(.init(conversation: conversation, agentHistory: []))
        conversation.messages[1].content = "b-updated"
        conversation.title = "Renamed"
        try store.saveMessages([conversation.messages[1].id], of: .init(conversation: conversation, agentHistory: []))
        let loaded = try #require(try store.loadRecords().first { $0.conversation.id == conversation.id })
        #expect(loaded.conversation.messages.map(\.content) == ["a", "b-updated", "c"])
        #expect(loaded.conversation.title == "Renamed")
        conversation.systemPrompt = "meta only"
        try store.saveConversationMeta(.init(conversation: conversation, agentHistory: []))
        let reloaded = try #require(try store.loadRecords().first { $0.conversation.id == conversation.id })
        #expect(reloaded.conversation.systemPrompt == "meta only")
        #expect(reloaded.conversation.messages.count == 3)
    }
}

// MARK: - Item 3: switching model keeps the conversation

@Suite("Wave1: model switch mid-conversation")
@MainActor
struct ModelSwitchTests {
    @Test("Chat: a second send with a different model continues the same conversation", arguments: [PlaygroundMode.chat, .agent])
    func switchKeepsConversation(mode: PlaygroundMode) async throws {
        let store = CountingConversationStore()
        let client = WaveScriptedClient([])
        let service = ChatService(client: client, store: store, apiKeyProvider: { "fixture" })
        func send(_ text: String, _ model: String) async throws {
            if mode == .chat { service.sendMessage(text, modelId: model) }
            else { await service.sendAgentMessage(text, modelId: model, workspace: workspace, fullComputerAccess: false) }
            try await waitUntilIdle(service)
        }
        try await send("one", "test/a")
        let firstID = try #require(service.activeConversation?.id)
        try await send("two", "test/b")
        #expect(service.activeConversation?.id == firstID)
        #expect(service.conversations.filter { $0.mode == mode }.count == 1)
        #expect(service.activeConversation?.messages.count == 4)
        #expect(service.activeConversation?.modelId == "test/b")
        #expect(store.records[firstID]?.conversation.modelId == "test/b")
        let lastRequest = await client.requests.last
        #expect(lastRequest?.model == "test/b")
        #expect(lastRequest?.messages.contains { $0.role == "user" && $0.content == "one" } == true)
    }

    @Test("switchModel persists without touching messages and is refused while running")
    func explicitSwitch() async throws {
        let store = CountingConversationStore()
        let service = ChatService(client: WaveScriptedClient([.init(events: [.contentDelta(choiceIndex: 0, text: "x"), .done], delay: .milliseconds(30))]), store: store, apiKeyProvider: { "fixture" })
        let conversation = service.newConversation(modelId: "test/a", mode: .chat)
        service.switchModel("test/b", for: conversation.id)
        #expect(service.activeConversation?.modelId == "test/b")
        #expect(store.records[conversation.id]?.conversation.modelId == "test/b")
        service.sendMessage("hi", modelId: "test/b")
        service.switchModel("test/c", for: conversation.id)
        #expect(service.activeConversation?.modelId == "test/b")
        try await waitUntilIdle(service)
    }
}

// MARK: - Item 4: failed/empty assistant turns stay off the wire

@Suite("Wave1: wire history hygiene")
@MainActor
struct WireHistoryTests {
    @Test("failed and empty assistant rows are not replayed to the API")
    func failedTurnsFiltered() async throws {
        let client = WaveScriptedClient([
            .init(events: [.done]),                                        // empty → failed placeholder
            .init(events: [.contentDelta(choiceIndex: 0, text: "partial"),
                           .apiError(OpenRouterAPIError(code: 500, message: "died", errorType: nil, providerName: nil))]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "good"), .done]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "final"), .done]),
        ])
        let service = ChatService(client: client, store: CountingConversationStore(), apiKeyProvider: { "fixture" })
        for text in ["q1", "q2", "q3", "q4"] {
            service.sendMessage(text, modelId: "test/model")
            try await waitUntilIdle(service)
        }
        let wire = try #require(await client.requests.last?.messages)
        let assistants = wire.filter { $0.role == "assistant" }
        #expect(assistants.map(\.content) == ["good"])
        #expect(wire.filter { $0.role == "user" }.map(\.content) == ["q1", "q2", "q3", "q4"])
        // Display rows are untouched.
        #expect(service.activeConversation?.messages.count == 8)
    }

    @Test("wireHistory keeps users and non-empty successful assistants only")
    func pureFilter() {
        let messages = [
            ChatMessage(role: "user", content: "a"),
            ChatMessage(role: "assistant", content: "  ", status: .complete),
            ChatMessage(role: "assistant", content: "x", status: .failed),
            ChatMessage(role: "tool", content: "t"),
            ChatMessage(role: "assistant", content: "ok", status: .truncated),
            ChatMessage(role: "assistant", content: "stopped", status: .interrupted),
        ]
        #expect(ChatService.wireHistory(messages).map(\.content) == ["a", "ok", "stopped"])
    }
}
