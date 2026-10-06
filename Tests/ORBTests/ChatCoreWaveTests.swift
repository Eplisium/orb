import Foundation
import Testing
import SwiftUI
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

// MARK: - Item 5: approvals carry the full arguments

private actor SummaryBox {
    var summaries: [String] = []
    func add(_ value: String) { summaries.append(value) }
}

@Suite("Wave1: approval arguments")
struct ApprovalArgumentsTests {
    @Test("the approval request receives the complete arguments, not a 300-char prefix")
    func fullArguments() async throws {
        let box = SummaryBox()
        let approvals = ApprovalCoordinator()
        await approvals.setHandler { request in
            await box.add(request.summary)
            return .denied
        }
        let command = "echo " + String(repeating: "z", count: 1_000)
        let arguments = "{\"command\":\"\(command)\"}"
        let client = WaveScriptedClient([
            .init(events: [
                .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "c", type: "function", name: "run_command", arguments: arguments),
                .finishReason(choiceIndex: 0, reason: "tool_calls"), .done
            ]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "ok"), .done]),
        ])
        _ = try await NativeAgentRunner.run(
            prompt: "go", modelId: "test/model", apiKey: "fixture", workspace: workspace,
            fullComputerAccess: false, history: [], client: client,
            toolExecutor: { _ in .init(content: "never", isError: true) },
            policy: .projectBuild, approvals: approvals, onEvent: { _ in }
        )
        let summary = try #require(await box.summaries.first)
        #expect(summary.count >= command.count)
        #expect(ApprovalPresentation.make(toolName: "run_command", server: nil, summary: summary).primary == command)
    }
}

// MARK: - Item 6: attachment parts build off-main and fail without side effects

@Suite("Wave1: attachment build")
struct AttachmentBuildTests {
    @Test("buildParts encodes off the main actor and throws for unreadable files")
    func buildParts() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wave1-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let draft = ChatAttachmentDraft(url: url, kind: .file(mimeType: "text/plain"), byteCount: 5)
        let parts = try await ChatAttachmentBuilder.buildParts(for: [draft])
        #expect(parts.count == 1)
        let missing = ChatAttachmentDraft(url: url.appendingPathExtension("gone"), kind: .file(mimeType: "text/plain"), byteCount: 5)
        await #expect(throws: (any Error).self) { try await ChatAttachmentBuilder.buildParts(for: [draft, missing]) }
    }
}

// MARK: - Item 7: render/perf hygiene

@Suite("Wave1: perf")
@MainActor
struct PlaygroundPerfTests {
    private func row(_ message: ChatMessage, streaming: Bool = false, onDelete: (() -> Void)? = {}) -> PlaygroundMessageView {
        PlaygroundMessageView(message: message, isStreaming: streaming, assistantName: "A", accent: .blue, onDelete: onDelete)
    }

    @Test("message rows compare by content, ignoring fresh closure identity")
    func rowEquality() {
        let message = ChatMessage(role: "assistant", content: "hi")
        #expect(row(message) == row(message))
        var changed = message; changed.content = "hi!"
        #expect(row(message) != row(changed))
        #expect(row(message) != row(message, streaming: true))
        #expect(row(message) != row(message, onDelete: nil))
    }

    @Test("sidebar sections recompute only when inputs change")
    func sectionsMemoized() {
        let cache = ConversationSectionsCache()
        var conversation = ChatConversation(modelId: "m", mode: .chat)
        _ = cache.sections([conversation], query: "", pinned: [], pinOrder: [])
        conversation.messages.append(ChatMessage(role: "assistant", content: "token"))
        _ = cache.sections([conversation], query: "", pinned: [], pinOrder: [])
        #expect(cache.computeCount == 1, "streaming text does not affect sections without a query")
        conversation.title = "New"
        let sections = cache.sections([conversation], query: "", pinned: [], pinOrder: [])
        #expect(cache.computeCount == 2)
        #expect(sections.first?.items.first?.title == "New")
        _ = cache.sections([conversation], query: "tok", pinned: [], pinOrder: [])
        conversation.messages[0].content = "tokens"
        _ = cache.sections([conversation], query: "tok", pinned: [], pinOrder: [])
        #expect(cache.computeCount == 4, "with a query, message changes recompute")
    }

    @Test("a service loads only its own mode's conversations")
    func loadByMode() throws {
        let store = CountingConversationStore()
        let chat = ChatConversation(modelId: "m", mode: .chat)
        let agent = ChatConversation(modelId: "m", mode: .agent)
        try store.saveRecord(.init(conversation: chat, agentHistory: []))
        try store.saveRecord(.init(conversation: agent, agentHistory: []))
        let service = ChatService(client: WaveScriptedClient([]), store: store, apiKeyProvider: { nil }, loadMode: .agent)
        #expect(service.conversations.map(\.id) == [agent.id])

        let database = DatabaseManager()
        let dbStore = DatabaseConversationStore(database: database)
        try dbStore.saveRecord(.init(conversation: chat, agentHistory: []))
        try dbStore.saveRecord(.init(conversation: agent, agentHistory: []))
        #expect(try dbStore.loadRecords(mode: .chat).map(\.conversation.id).contains(chat.id))
        #expect(!(try dbStore.loadRecords(mode: .chat).map(\.conversation.id).contains(agent.id)))
    }
}

// MARK: - Items 8/9/14: timestamps, per-message usage, unified export

@Suite("Wave1: message metadata and export")
@MainActor
struct MessageMetadataTests {
    @Test("createdAt survives a rewrite; usage round-trips through SQLite")
    func persistence() throws {
        let database = DatabaseManager()
        let store = DatabaseConversationStore(database: database)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var conversation = ChatConversation(modelId: "m", mode: .chat)
        let usage = MessageUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30, cost: 0.002, tokensPerSecond: 40)
        conversation.messages = [
            ChatMessage(role: "user", content: "q", createdAt: created),
            ChatMessage(role: "assistant", content: "a", createdAt: created.addingTimeInterval(5), usage: usage),
        ]
        try store.saveRecord(.init(conversation: conversation, agentHistory: []))
        try store.saveRecord(.init(conversation: conversation, agentHistory: []))
        let loaded = try #require(try store.loadRecords().first { $0.conversation.id == conversation.id })
        #expect(loaded.conversation.messages.map(\.createdAt) == [created, created.addingTimeInterval(5)])
        #expect(loaded.conversation.messages[1].usage == usage)
    }

    @Test("usage from the stream is stored on the assistant message")
    func usageStored() async throws {
        let usage = ChatUsage(promptTokens: 5, completionTokens: 7, totalTokens: 12, cost: 0.01)
        let client = WaveScriptedClient([.init(events: [.contentDelta(choiceIndex: 0, text: "hi"), .usage(usage), .done])])
        let service = ChatService(client: client, store: CountingConversationStore(), apiKeyProvider: { "fixture" })
        service.sendMessage("q", modelId: "test/model")
        try await waitUntilIdle(service)
        let stored = try #require(service.activeConversation?.messages.last?.usage)
        #expect(stored.totalTokens == 12)
        #expect(stored.cost == 0.01)
        #expect(stored.tokensPerSecond != nil)
        #expect(stored.summary.contains("12 tokens"))
    }

    @Test("exports include timestamps, reasoning, tool calls, and usage")
    func exportContents() throws {
        var conversation = ChatConversation(modelId: "m", mode: .agent)
        conversation.title = "T"
        conversation.messages = [
            ChatMessage(role: "user", content: "q"),
            ChatMessage(role: "assistant", content: "a",
                        toolCalls: [ToolCallDisplay(id: "1", name: "read_file", argumentsSummary: "{}", arguments: "{\"path\":\"x\"}", result: "data")],
                        reasoning: "think", reasoningDuration: 1.5,
                        usage: MessageUsage(totalTokens: 30, cost: 0.002)),
        ]
        let md = ConversationExporter.markdown(conversation)
        #expect(md.contains("Reasoning (1.5s)"))
        #expect(md.contains("`read_file`"))
        #expect(md.contains("\"path\":\"x\""))
        #expect(md.contains("30 tokens"))
        let json = try JSONSerialization.jsonObject(with: ConversationExporter.json(conversation)) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: Any]])
        #expect(messages[0]["createdAt"] is String)
        #expect(messages[1]["reasoning"] as? String == "think")
        #expect((messages[1]["toolCalls"] as? [[String: Any]])?.first?["result"] as? String == "data")
        #expect((messages[1]["usage"] as? [String: Any])?["totalTokens"] as? Int == 30)
    }
}

// MARK: - Item 10: non-destructive edit & resend

@Suite("Wave1: edit and resend")
@MainActor
struct EditResendTests {
    @Test("an edit can be undone and carries the original attachments")
    func undoAndParts() async throws {
        let store = CountingConversationStore()
        let service = ChatService(client: WaveScriptedClient([]), store: store, apiKeyProvider: { "fixture" })
        let image = MessageContentPart.image(url: "data:image/png;base64,AA==")
        service.sendMessage("look", modelId: "test/model", parts: [image])
        try await waitUntilIdle(service)
        service.sendMessage("more", modelId: "test/model")
        try await waitUntilIdle(service)
        let conversation = try #require(service.activeConversation)
        #expect(conversation.messages.count == 4)

        let edit = try #require(service.beginEdit(from: conversation.messages[0].id, in: conversation.id))
        #expect(edit.text == "look")
        #expect(edit.parts == [image])
        #expect(edit.removedCount == 4)
        #expect(service.activeConversation?.messages.isEmpty == true)

        #expect(service.undoEdit(edit))
        #expect(service.activeConversation?.messages.map(\.id) == conversation.messages.map(\.id))
        #expect(store.records[conversation.id]?.conversation.messages.count == 4)
        #expect(!service.undoEdit(edit), "undo is idempotent")
    }

    @Test("undo is refused once the edited conversation moved on")
    func undoRefusedAfterResend() async throws {
        let service = ChatService(client: WaveScriptedClient([]), store: CountingConversationStore(), apiKeyProvider: { "fixture" })
        service.sendMessage("a", modelId: "test/model")
        try await waitUntilIdle(service)
        let conversation = try #require(service.activeConversation)
        let edit = try #require(service.beginEdit(from: conversation.messages[0].id, in: conversation.id))
        service.sendMessage("a2", modelId: "test/model", parts: edit.parts)
        try await waitUntilIdle(service)
        #expect(!service.undoEdit(edit), "restoring would interleave old and new turns")
        #expect(service.activeConversation?.messages.map(\.content) == ["a2", "ok"])
    }
}

// MARK: - Item 11: conversation commands

@Suite("Wave1: conversation commands")
struct ConversationCommandsTests {
    @Test("shortcuts do not collide with shell or Model-menu shortcuts")
    func noCollisions() {
        let taken: [KeyboardShortcut] = [
            .init("n", modifiers: .command), .init("n", modifiers: [.command, .shift]),
            .init("f", modifiers: .command), .init("k", modifiers: .command), .init("r", modifiers: .command),
            .init("/", modifiers: .command), .init("d", modifiers: .command), .init("c", modifiers: [.command, .shift]),
            .init(.return, modifiers: .command), .init("z", modifiers: .command),
        ] + (1...9).map { .init(KeyEquivalent(Character("\($0)")), modifiers: .command) }
        let ours = [ConversationShortcuts.stop, ConversationShortcuts.regenerate, ConversationShortcuts.copyLastReply,
                    ConversationShortcuts.export, ConversationShortcuts.searchSessions]
        func key(_ s: KeyboardShortcut) -> String { "\(s.key.character)-\(s.modifiers.rawValue)" }
        #expect(Set(ours.map(key)).count == ours.count)
        #expect(Set(ours.map(key)).isDisjoint(with: taken.map(key)))
    }

    @Test("last reply skips empty and non-assistant rows")
    func lastReply() {
        var conversation = ChatConversation(modelId: "m", mode: .chat)
        conversation.messages = [
            ChatMessage(role: "assistant", content: "first"),
            ChatMessage(role: "user", content: "q"),
            ChatMessage(role: "assistant", content: "", status: .failed),
        ]
        #expect(ConversationActionLogic.lastReply(in: conversation) == "first")
        #expect(ConversationActionLogic.lastReply(in: nil) == nil)
    }
}
