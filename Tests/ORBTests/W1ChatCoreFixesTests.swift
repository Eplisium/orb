import Foundation
import Testing
@testable import ORB

// Wave 1, track chat-core: CHAT-1, CHAT-8, CHAT-10, CHAT-12, CORE-4,
// AGENT-3, AGENT-7, V-1, V-7.

/// Plays scripted streams through `StreamArrivalRelay` like production.
/// `gate` holds a script before its first event until `open()` is called.
private actor W1ChatCoreClient: OpenRouterClientProtocol {
    struct Script: Sendable {
        var events: [OpenRouterStreamEvent]
        var delay: Duration = .milliseconds(1)
        var terminalError: (any Error & Sendable)?
        /// Never finishes after the events (a provider between tokens).
        var hangs = false
    }

    private var scripts: [Script]
    private(set) var requests: [OpenRouterRequest] = []

    init(_ scripts: [Script]) { self.scripts = scripts }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests.append(request)
        let script = scripts.isEmpty ? Script(events: [.done]) : scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in script.events {
                    try? await Task.sleep(for: script.delay)
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                if script.hangs {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    continuation.finish()
                    return
                }
                if let error = script.terminalError { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Mirrors the SQLite store's write semantics: `saveMessages` upserts only
/// the listed rows and `saveConversationMeta` touches no message rows, so a
/// test can see exactly what a crash would leave on disk.
@MainActor
private final class W1ChatCoreIncrementalStore: ConversationStore {
    var records: [UUID: StoredConversation] = [:]
    var fullSaves = 0
    var rowSaves: [Set<UUID>] = []

    func loadRecords() throws -> [StoredConversation] { Array(records.values) }
    func saveRecord(_ record: StoredConversation) throws {
        fullSaves += 1
        records[record.conversation.id] = record
    }
    func saveConversationMeta(_ record: StoredConversation) throws {
        var stored = records[record.conversation.id] ?? StoredConversation(conversation: record.conversation, agentHistory: [])
        let messages = stored.conversation.messages
        stored.conversation = record.conversation
        stored.conversation.messages = messages
        stored.agentHistory = record.agentHistory
        records[record.conversation.id] = stored
    }
    func saveMessages(_ messageIDs: Set<UUID>, of record: StoredConversation) throws {
        rowSaves.append(messageIDs)
        var stored = records[record.conversation.id] ?? StoredConversation(conversation: record.conversation, agentHistory: [])
        var messages = stored.conversation.messages
        for (offset, message) in record.conversation.messages.enumerated() where messageIDs.contains(message.id) {
            if let existing = messages.firstIndex(where: { $0.id == message.id }) {
                messages[existing] = message
            } else {
                messages.insert(message, at: min(offset, messages.count))
            }
        }
        stored.conversation = record.conversation
        stored.conversation.messages = messages
        stored.agentHistory = record.agentHistory
        records[record.conversation.id] = stored
    }
    func removeConversation(_ id: UUID) throws { records[id] = nil }
    func removeMessage(_ id: UUID) throws {
        for key in records.keys { records[key]?.conversation.messages.removeAll { $0.id == id } }
    }
    func recoverInterruptedRecords() throws {}

    func stored(_ id: UUID) -> [ChatMessage] { records[id]?.conversation.messages ?? [] }
}

@MainActor
private enum W1ChatCoreFixture {
    static func service(
        _ scripts: [W1ChatCoreClient.Script], store: (any ConversationStore)? = nil
    ) -> (ChatService, W1ChatCoreClient, any ConversationStore) {
        let store = store ?? W1ChatCoreIncrementalStore()
        let client = W1ChatCoreClient(scripts)
        let ledger = UsageLedger(recordEvent: { _ in })
        return (ChatService(client: client, store: store, apiKeyProvider: { "fixture-key" }, usageLedger: ledger), client, store)
    }

    static func waitUntilIdle(_ service: ChatService, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while service.isStreaming, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!service.isStreaming)
    }

    static func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    static let usage = ChatUsage(promptTokens: 2, completionTokens: 4, totalTokens: 6, cost: 0.02)

    /// One finished exchange: "hello" → "original answer".
    static func answered(_ more: [W1ChatCoreClient.Script], store: (any ConversationStore)? = nil) async throws
        -> (ChatService, W1ChatCoreClient, any ConversationStore) {
        let first = W1ChatCoreClient.Script(events: [.contentDelta(choiceIndex: 0, text: "original answer"), .usage(usage), .done])
        let (service, client, store) = service([first] + more, store: store)
        service.sendMessage("hello", modelId: "test/model")
        try await waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.content == "original answer")
        return (service, client, store)
    }
}

// MARK: - CHAT-1 regeneration keeps the original until new content exists

@Suite("W1 chat-core: regeneration safety (CHAT-1)")
@MainActor
struct W1ChatCoreRegenerationTests {
    private typealias F = W1ChatCoreFixture

    @Test("partial text then a provider error restores the original reply")
    func partialThenProviderError() async throws {
        let error = OpenRouterAPIError(code: 500, message: "provider died", errorType: "provider_error", providerName: nil)
        let (service, _, anyStore) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "new partial"), .usage(F.usage), .apiError(error)])
        ])
        let store = try #require(anyStore as? W1ChatCoreIncrementalStore)
        let id = try #require(service.activeConversation?.id)
        let originalID = try #require(service.activeConversation?.messages.last?.id)

        await service.regenerateLastResponse(modelId: "test/model")
        try await F.waitUntilIdle(service)

        let last = try #require(service.activeConversation?.messages.last)
        #expect(last.id == originalID)
        #expect(last.content == "original answer")
        #expect(last.status == .complete)
        #expect(last.errorMessage == nil)
        #expect(service.activeConversation?.messages.count == 2)
        #expect(service.lastError == "provider died Your previous reply was kept.")
        if case .failed = service.runState.phase {} else { Issue.record("expected a failed phase, got \(service.runState.phase)") }
        // Saved state matches: the original is what a relaunch shows.
        #expect(store.stored(id).last?.content == "original answer")
        #expect(store.stored(id).last?.status == .complete)
        // The failed attempt's spend still counts (two runs × 0.02)…
        #expect(service.activeConversation?.totalCost == 0.04)
        // …but the original reply's own usage footer is not overwritten.
        #expect(last.usage?.totalTokens == 6)
    }

    @Test("partial text then a dropped connection restores the original reply")
    func partialThenThrownError() async throws {
        let (service, _, anyStore) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "new partial")], terminalError: URLError(.networkConnectionLost))
        ])
        let store = try #require(anyStore as? W1ChatCoreIncrementalStore)
        let id = try #require(service.activeConversation?.id)

        await service.regenerateLastResponse(modelId: "test/model")
        try await F.waitUntilIdle(service)

        #expect(service.activeConversation?.messages.last?.content == "original answer")
        #expect(service.activeConversation?.messages.last?.status == .complete)
        #expect(service.lastError?.hasSuffix("Your previous reply was kept.") == true)
        #expect(store.stored(id).last?.content == "original answer")
    }

    @Test("partial text then Stop restores the original reply, without a failure")
    func partialThenStop() async throws {
        let (service, _, anyStore) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "new partial")], hangs: true)
        ])
        let store = try #require(anyStore as? W1ChatCoreIncrementalStore)
        let id = try #require(service.activeConversation?.id)

        await service.regenerateLastResponse(modelId: "test/model")
        try await F.waitFor { service.activeConversation?.messages.last?.content == "new partial" }
        service.stopStreaming()
        try await F.waitUntilIdle(service)

        let last = try #require(service.activeConversation?.messages.last)
        #expect(last.content == "original answer")
        #expect(last.status == .complete)
        #expect(service.runState.phase == .interrupted("cancelled"))
        #expect(service.lastError == "Regeneration stopped. Your previous reply was kept.")
        #expect(store.stored(id).last?.content == "original answer")
        #expect(store.stored(id).last?.status == .complete)
    }

    @Test("the stored original is not overwritten before new output arrives (crash safety)")
    func storedOriginalSurvivesUntilOutput() async throws {
        let (service, _, anyStore) = try await F.answered([
            .init(events: [.metadata(id: "gen", model: nil), .contentDelta(choiceIndex: 0, text: "fresh answer"), .done],
                  delay: .milliseconds(150))
        ])
        let store = try #require(anyStore as? W1ChatCoreIncrementalStore)
        let id = try #require(service.activeConversation?.id)

        await service.regenerateLastResponse(modelId: "test/model")
        // In memory the reply is an empty streaming placeholder…
        #expect(service.activeConversation?.messages.last?.content == "")
        #expect(service.isStreaming)
        // …while storage still has the original: a crash here loses nothing.
        #expect(store.stored(id).last?.content == "original answer")
        #expect(store.stored(id).last?.status == .complete)

        try await F.waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.content == "fresh answer")
        #expect(store.stored(id).last?.content == "fresh answer")
        #expect(store.stored(id).count == 2)
    }

    @Test("crash safety holds against the real SQLite store")
    func sqliteKeepsOriginalDuringRegeneration() async throws {
        let database = DatabaseManager()
        defer { if let path = database.testDatabasePath { DatabaseManager.cleanupTestDatabaseForTesting(at: path) } }
        let store = DatabaseConversationStore(database: database)
        let (service, _, _) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "new partial")], terminalError: URLError(.timedOut)),
        ], store: store)
        let id = try #require(service.activeConversation?.id)
        func onDisk() throws -> [ChatMessage] { try database.loadMessagesChecked(for: id) }

        await service.regenerateLastResponse(modelId: "test/model")
        #expect(try onDisk().last?.content == "original answer")
        try await F.waitUntilIdle(service)
        #expect(try onDisk().map(\.content) == ["hello", "original answer"])
        #expect(try onDisk().last?.status == .complete)
    }

    @Test("a successful regeneration replaces the reply in place")
    func successfulRegenerationReplaces() async throws {
        let (service, _, _) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "second answer"), .done])
        ])
        let originalID = try #require(service.activeConversation?.messages.last?.id)
        await service.regenerateLastResponse(modelId: "test/model")
        try await F.waitUntilIdle(service)
        #expect(service.activeConversation?.messages.last?.id == originalID)
        #expect(service.activeConversation?.messages.last?.content == "second answer")
        #expect(service.lastError == nil)
    }
}

// MARK: - CORE-4 incremental saves on send / finish

@Suite("W1 chat-core: incremental saves (CORE-4)")
@MainActor
struct W1ChatCoreIncrementalSaveTests {
    private typealias F = W1ChatCoreFixture

    @Test("send and finish write only the run's rows, never the whole conversation")
    func sendAndFinishAreIncremental() async throws {
        let (service, _, anyStore) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "two"), .done])
        ])
        let store = try #require(anyStore as? W1ChatCoreIncrementalStore)
        let id = try #require(service.activeConversation?.id)
        let before = Set(service.activeConversation?.messages.map(\.id) ?? [])
        let fullBefore = store.fullSaves
        store.rowSaves = []

        service.sendMessage("again", modelId: "test/model")
        try await F.waitUntilIdle(service)

        #expect(store.fullSaves == fullBefore, "a send must not rewrite every message")
        let touched = store.rowSaves.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        #expect(touched.isDisjoint(with: before), "earlier messages are not rewritten")
        #expect(touched.count == 2)
        #expect(store.stored(id).map(\.content) == ["hello", "original answer", "again", "two"])
    }

    @Test("the first send of a new chat saves the title with the rows")
    func firstSendSavesTitle() async throws {
        let (service, _, anyStore) = F.service([.init(events: [.contentDelta(choiceIndex: 0, text: "hi"), .done])])
        let store = try #require(anyStore as? W1ChatCoreIncrementalStore)
        service.sendMessage("Plan a trip to Lisbon", modelId: "test/model")
        try await F.waitUntilIdle(service)
        let id = try #require(service.activeConversation?.id)
        #expect(store.records[id]?.conversation.title == service.activeConversation?.title)
        #expect(store.stored(id).map(\.content) == ["Plan a trip to Lisbon", "hi"])
        #expect(store.stored(id).last?.status == .complete)
    }

    @Test("SQLite: sends keep sort order and survive a reload")
    func sqliteIncrementalRoundTrip() async throws {
        let database = DatabaseManager()
        defer { if let path = database.testDatabasePath { DatabaseManager.cleanupTestDatabaseForTesting(at: path) } }
        let store = DatabaseConversationStore(database: database)
        let (service, _, _) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "two"), .done]),
        ], store: store)
        service.sendMessage("again", modelId: "test/model")
        try await F.waitUntilIdle(service)
        let id = try #require(service.activeConversation?.id)
        let reloaded = try #require(try store.loadRecords().first { $0.conversation.id == id })
        #expect(reloaded.conversation.messages.map(\.content) == ["hello", "original answer", "again", "two"])
        #expect(reloaded.conversation.totalTokens == service.activeConversation?.totalTokens)
    }
}

// MARK: - CHAT-10 undoable message delete, no orphaned replies

@Suite("W1 chat-core: message delete (CHAT-10)")
@MainActor
struct W1ChatCoreMessageDeleteTests {
    private typealias F = W1ChatCoreFixture

    private func twoExchanges() async throws -> (ChatService, W1ChatCoreIncrementalStore) {
        let (service, _, anyStore) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "second answer"), .done]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "third answer"), .done]),
        ])
        service.sendMessage("second question", modelId: "test/model")
        try await F.waitUntilIdle(service)
        return (service, try #require(anyStore as? W1ChatCoreIncrementalStore))
    }

    @Test("delete then Undo puts the message back where it was, in memory and on disk")
    func deleteAndUndo() async throws {
        let (service, store) = try await twoExchanges()
        let conversation = try #require(service.activeConversation)
        let target = conversation.messages[1]
        let deletion = try #require(service.deleteMessageUndoable(target.id, from: conversation.id))
        #expect(deletion.count == 1)
        #expect(service.activeConversation?.messages.map(\.content) == ["hello", "second question", "second answer"])
        #expect(store.stored(conversation.id).count == 3)

        #expect(service.restoreMessages(deletion))
        #expect(service.activeConversation?.messages == conversation.messages)
        #expect(store.stored(conversation.id) == conversation.messages)
        // Idempotent.
        #expect(service.restoreMessages(deletion))
        #expect(service.activeConversation?.messages.count == 4)
    }

    @Test("Delete with reply removes the user message and its answer, and Undo restores both")
    func deleteWithReply() async throws {
        let (service, store) = try await twoExchanges()
        let conversation = try #require(service.activeConversation)
        let deletion = try #require(service.deleteMessageUndoable(conversation.messages[0].id, from: conversation.id, includingReply: true))
        #expect(deletion.rows.map(\.message.content) == ["hello", "original answer"])
        #expect(service.activeConversation?.messages.map(\.content) == ["second question", "second answer"])
        #expect(store.stored(conversation.id).map(\.content) == ["second question", "second answer"])
        #expect(service.restoreMessages(deletion))
        #expect(service.activeConversation?.messages.map(\.content) == conversation.messages.map(\.content))
    }

    @Test("deletion range: a reply is everything up to the next user message")
    func deletionRange() {
        let messages = [
            ChatMessage(role: "user", content: "q1"), ChatMessage(role: "tool", content: "t"),
            ChatMessage(role: "assistant", content: "a1"), ChatMessage(role: "user", content: "q2"),
            ChatMessage(role: "assistant", content: "a2"),
        ]
        #expect(ChatService.messagesDeleted(by: messages[0].id, in: messages, includingReply: true) == [0, 1, 2])
        #expect(ChatService.messagesDeleted(by: messages[0].id, in: messages, includingReply: false) == [0])
        #expect(ChatService.messagesDeleted(by: messages[3].id, in: messages, includingReply: true) == [3, 4])
        // An assistant message never takes neighbours with it.
        #expect(ChatService.messagesDeleted(by: messages[2].id, in: messages, includingReply: true) == [2])
        #expect(ChatService.messagesDeleted(by: UUID(), in: messages, includingReply: true).isEmpty)
    }

    @Test("an orphaned reply (its question deleted) is not sent to the model")
    func orphanedReplyNotSent() async throws {
        let (service, client, _) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "second answer"), .done]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "third answer"), .done]),
        ])
        service.sendMessage("second question", modelId: "test/model")
        try await F.waitUntilIdle(service)
        let conversation = try #require(service.activeConversation)
        // Plain delete of the second question leaves two assistant turns in a row.
        #expect(service.deleteMessageUndoable(conversation.messages[2].id, from: conversation.id) != nil)
        service.sendMessage("third question", modelId: "test/model")
        try await F.waitUntilIdle(service)

        let request = try #require(await client.requests.last)
        let sent = request.messages.map { "\($0.role):\($0.content ?? "")" }
        #expect(sent == ["user:hello", "assistant:original answer", "user:third question"])
    }

    @Test("wire history drops leading and consecutive assistant turns only")
    func wireHistoryOrphans() {
        let history = ChatService.wireHistory([
            ChatMessage(role: "assistant", content: "leading"),
            ChatMessage(role: "user", content: "q1"),
            ChatMessage(role: "assistant", content: "a1"),
            ChatMessage(role: "assistant", content: "orphan"),
            ChatMessage(role: "user", content: "q2"),
            ChatMessage(role: "assistant", content: "a2"),
        ])
        #expect(history.map(\.content) == ["q1", "a1", "q2", "a2"])
    }

    @Test("deleting is refused while the conversation runs")
    func refusedWhileRunning() async throws {
        let (service, _, _) = try await F.answered([.init(events: [.contentDelta(choiceIndex: 0, text: "x")], hangs: true)])
        service.sendMessage("more", modelId: "test/model")
        let conversation = try #require(service.activeConversation)
        #expect(service.deleteMessageUndoable(conversation.messages[0].id, from: conversation.id) == nil)
        #expect(service.lastError?.contains("Stop it first") == true)
        service.stopStreaming()
        try await F.waitUntilIdle(service)
    }

    @Test("toast copy and sidebar delete policy")
    func toastAndPolicy() {
        #expect(UndoToast.message(deletedMessages: 1) == "Deleted message")
        #expect(UndoToast.message(deletedMessages: 2) == "Deleted 2 messages")
        // Undoable hosts delete at once (toast offers Undo); others confirm.
        #expect(ConversationRowDeletePolicy.needsConfirmation(undoable: true) == false)
        #expect(ConversationRowDeletePolicy.needsConfirmation(undoable: false))
    }
}

// MARK: - CHAT-12 copy cost, CHAT-8 last activity

@Suite("W1 chat-core: branch cost and activity order (CHAT-12, CHAT-8)")
@MainActor
struct W1ChatCoreBranchAndOrderTests {
    private typealias F = W1ChatCoreFixture

    @Test("a branch carries only the usage of the messages it copies")
    func branchCostIsCopiedUsage() async throws {
        let second = ChatUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30, cost: 0.5)
        let (service, _, _) = try await F.answered([
            .init(events: [.contentDelta(choiceIndex: 0, text: "second answer"), .usage(second), .done]),
        ])
        service.sendMessage("second question", modelId: "test/model")
        try await F.waitUntilIdle(service)
        let source = try #require(service.activeConversation)
        #expect(source.totalCost == 0.52)

        let branch = try #require(service.branchConversation(from: source.messages[1].id, in: source.id))
        #expect(branch.messages.count == 2)
        #expect(branch.totalCost == 0.02)
        #expect(branch.totalTokens == 6)

        let duplicate = try #require(service.duplicateConversation(source.id))
        #expect(abs(duplicate.totalCost - 0.52) < 1e-9)
        #expect(duplicate.totalTokens == 36)
    }

    @Test("copied totals ignore messages without usage")
    func copiedTotals() {
        let messages = [
            ChatMessage(role: "user", content: "q"),
            ChatMessage(role: "assistant", content: "a", usage: MessageUsage(totalTokens: 9, cost: 0.25)),
            ChatMessage(role: "assistant", content: "b", usage: MessageUsage(cost: nil)),
        ]
        let totals = ChatService.copiedUsageTotals(messages)
        #expect(totals.cost == 0.25)
        #expect(totals.tokens == 9)
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test("last activity is the newest message, or creation when empty")
    func lastActivity() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        var conversation = ChatConversation(modelId: "m", mode: .chat, createdAt: created)
        #expect(conversation.lastActivity == created)
        conversation.messages = [ChatMessage(role: "user", content: "q", createdAt: created.addingTimeInterval(500))]
        #expect(conversation.lastActivity == created.addingTimeInterval(500))
        // Imported messages older than the conversation never move it back.
        conversation.messages = [ChatMessage(role: "user", content: "q", createdAt: created.addingTimeInterval(-500))]
        #expect(conversation.lastActivity == created)
    }

    @Test("an old chat continued today sorts into Today, above newer idle chats; pins stay on top")
    func sectionsUseLastActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        var revived = ChatConversation(title: "revived", modelId: "m", mode: .chat, createdAt: now.addingTimeInterval(-30 * day))
        revived.messages = [ChatMessage(role: "user", content: "q", createdAt: now.addingTimeInterval(-60))]
        let idleToday = ChatConversation(title: "idle", modelId: "m", mode: .chat, createdAt: now.addingTimeInterval(-3_600))
        let pinned = ChatConversation(title: "pinned", modelId: "m", mode: .chat, createdAt: now.addingTimeInterval(-90 * day))
        let old = ChatConversation(title: "old", modelId: "m", mode: .chat, createdAt: now.addingTimeInterval(-40 * day))

        let sections = ConversationListModel.sections(
            [old, idleToday, revived, pinned], pinned: [pinned.id], now: now, calendar: calendar
        )
        #expect(sections.map(\.title) == ["Pinned", "Today", "Older"])
        #expect(sections[0].items.map(\.title) == ["pinned"])
        #expect(sections[1].items.map(\.title) == ["revived", "idle"])
        #expect(sections[2].items.map(\.title) == ["old"])
    }

    @Test("the service lists sessions by last activity after a load")
    func serviceLoadOrder() throws {
        let store = W1ChatCoreIncrementalStore()
        let now = Date()
        var revived = ChatConversation(title: "revived", modelId: "m", mode: .chat, createdAt: now.addingTimeInterval(-10_000))
        revived.messages = [ChatMessage(role: "user", content: "q", createdAt: now)]
        let newer = ChatConversation(title: "newer", modelId: "m", mode: .chat, createdAt: now.addingTimeInterval(-100))
        try store.saveRecord(.init(conversation: revived, agentHistory: []))
        try store.saveRecord(.init(conversation: newer, agentHistory: []))
        let (service, _, _) = F.service([], store: store)
        #expect(service.conversations.map(\.title) == ["revived", "newer"])
    }
}

// MARK: - AGENT-3 approval status, AGENT-7 banner copy

@Suite("W1 chat-core: agent status and error copy (AGENT-3, AGENT-7)")
@MainActor
struct W1ChatCoreAgentCopyTests {
    @Test("a pending approval reads as waiting, not running")
    func approvalPhaseText() {
        #expect(PlaygroundRunPhase.awaitingApproval("write_file").agentStatusText == "Waiting for your approval")
        #expect(PlaygroundRunPhase.executingTool("write_file").agentStatusText == "Running tool")
        #expect(PlaygroundRunPhase.streaming.agentStatusText == "Agent working")
        #expect(PlaygroundRunState(context: nil, phase: .awaitingApproval("x")).isActive)
        #expect(PlaygroundRunPhase.awaitingApproval("x").isAwaitingApproval)
        #expect(!PlaygroundRunPhase.executingTool("x").isAwaitingApproval)
    }

    @Test("Agent run waits for approval with the right status, then resumes")
    func agentApprovalStatus() async throws {
        let call = OpenRouterStreamEvent.toolCallFragment(
            choiceIndex: 0, toolIndex: 0, id: "t1", type: "function", name: "run_command",
            arguments: #"{"command":"touch w1-chatcore-approval-must-not-exist"}"#
        )
        let (service, _, _) = W1ChatCoreFixture.service([
            .init(events: [call, .finishReason(choiceIndex: 0, reason: "tool_calls"), .done]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "Done."), .done]),
        ])
        await service.sendAgentMessage("go", modelId: "t/m", workspace: FileManager.default.temporaryDirectory.path,
                                       fullComputerAccess: true)
        try await W1ChatCoreFixture.waitFor { service.approvalPresenter.queue.current != nil }
        let request = try #require(service.approvalPresenter.queue.current)
        try await W1ChatCoreFixture.waitFor { service.runState.phase.isAwaitingApproval }
        #expect(service.runState.phase == .awaitingApproval("run_command"))
        #expect(service.runState.phase.agentStatusText == "Waiting for your approval")
        #expect(service.activityLabel == "Waiting for your approval: run_command")
        #expect(service.runState.isActive)

        service.approvalPresenter.decide(request.id, .denied)
        try await W1ChatCoreFixture.waitUntilIdle(service)
        #expect(!service.runState.phase.isAwaitingApproval)
        #expect(service.activeConversation?.messages.last?.content == "Done.")
    }

    @Test("Stop while waiting for approval ends the run")
    func stopWhileAwaitingApproval() async throws {
        let call = OpenRouterStreamEvent.toolCallFragment(
            choiceIndex: 0, toolIndex: 0, id: "t1", type: "function", name: "run_command",
            arguments: #"{"command":"touch w1-chatcore-approval-must-not-exist"}"#
        )
        let (service, _, _) = W1ChatCoreFixture.service([
            .init(events: [call, .finishReason(choiceIndex: 0, reason: "tool_calls"), .done]),
        ])
        await service.sendAgentMessage("go", modelId: "t/m", workspace: FileManager.default.temporaryDirectory.path,
                                       fullComputerAccess: true)
        try await W1ChatCoreFixture.waitFor { service.runState.phase.isAwaitingApproval }
        service.stopStreaming()
        try await W1ChatCoreFixture.waitUntilIdle(service)
        #expect(service.approvalPresenter.queue.current == nil)
        #expect(!service.runState.isActive)
    }

    @Test("a running command's card shows its live output, then the final result")
    func liveToolOutput() async throws {
        let call = OpenRouterStreamEvent.toolCallFragment(
            choiceIndex: 0, toolIndex: 0, id: "t1", type: "function", name: "run_command",
            arguments: #"{"command":"printf w1-integ-live; sleep 2; printf ' w1-integ-done'"}"#
        )
        let (service, _, _) = W1ChatCoreFixture.service([
            .init(events: [call, .finishReason(choiceIndex: 0, reason: "tool_calls"), .done]),
            .init(events: [.contentDelta(choiceIndex: 0, text: "Done."), .done]),
        ])
        await service.sendAgentMessage("go", modelId: "t/m", workspace: FileManager.default.temporaryDirectory.path,
                                       fullComputerAccess: true)
        try await W1ChatCoreFixture.waitFor { service.approvalPresenter.queue.current != nil }
        #expect(service.activityLabel == PlaygroundRunPhase.awaitingApprovalLabel(tool: "run_command"))
        let request = try #require(service.approvalPresenter.queue.current)
        service.approvalPresenter.decide(request.id, .approved)
        func card() -> ToolCallDisplay? { service.activeConversation?.messages.last?.toolCalls?.first }
        try await W1ChatCoreFixture.waitFor({ card()?.result?.contains("w1-integ-live") == true }, timeout: .seconds(20))
        #expect(card()?.isExecuting == true, "the tail arrives while the command still runs")
        try await W1ChatCoreFixture.waitUntilIdle(service)
        #expect(card()?.isExecuting == false)
        #expect(card()?.result?.contains("w1-integ-done") == true)
    }

    @Test("error hints name only controls that exist in each mode")
    func modeAwareHints() {
        let truncated = "The model's tool call was truncated at the output limit."
        let agent = PlaygroundErrorSummary.summarize(truncated, mode: .agent)
        #expect(agent.headline == "The model ran out of output room mid-tool-call")
        #expect(agent.hint?.localizedCaseInsensitiveContains("max") == false)
        #expect(agent.hint?.localizedCaseInsensitiveContains("retry") == false)
        #expect(agent.hint?.localizedCaseInsensitiveContains("regenerate") == false)
        let chat = PlaygroundErrorSummary.summarize(truncated, mode: .chat)
        #expect(chat.hint == "Raise Max tokens in the chat settings, then regenerate.")

        for message in ["HTTP 429 rate limit", "network connection lost", "402 insufficient credits", "invalid json arguments in tool call"] {
            let agentHint = PlaygroundErrorSummary.summarize(message, mode: .agent).hint ?? ""
            #expect(!agentHint.localizedCaseInsensitiveContains("retry"), "\(message): \(agentHint)")
            #expect(!agentHint.localizedCaseInsensitiveContains("regenerate"), "\(message): \(agentHint)")
            #expect(agentHint.contains("send your message again") || agentHint.contains("Send your message again"), "\(message): \(agentHint)")
            let chatHint = PlaygroundErrorSummary.summarize(message, mode: .chat).hint ?? ""
            #expect(chatHint.localizedCaseInsensitiveContains("regenerate"), "\(message): \(chatHint)")
            let neutral = PlaygroundErrorSummary.summarize(message).hint ?? ""
            #expect(!neutral.localizedCaseInsensitiveContains("retry"), "\(message): \(neutral)")
        }
    }
}

// MARK: - V-1 catalog-backed default model

@Suite("W1 chat-core: catalog model preference (V-1)")
struct W1ChatCoreModelPreferenceTests {
    typealias P = CatalogModelPreference
    typealias C = CatalogModelPreference.Candidate

    private func text(_ id: String, tools: Bool = true, created: Double? = nil) -> C {
        C(id: id, inputModalities: ["text"], outputModalities: ["text"], supportsTools: tools, created: created)
    }

    @Test("pinned beats recents beats curated beats catalog head")
    func precedence() {
        let catalog = [text("z/head"), text("openai/gpt-5.1"), text("x/recent"), text("y/pinned")]
        #expect(P.resolve(catalog: catalog, pinned: "y/pinned", recents: ["x/recent"], requirement: .textChat) == "y/pinned")
        #expect(P.resolve(catalog: catalog, pinned: "gone/model", recents: ["x/recent"], requirement: .textChat) == "x/recent")
        #expect(P.resolve(catalog: catalog, pinned: nil, recents: ["gone/one", "x/recent"], requirement: .textChat) == "x/recent")
        #expect(P.resolve(catalog: catalog, requirement: .textChat) == "openai/gpt-5.1")
        #expect(P.resolve(catalog: [text("z/head"), text("q/other")], requirement: .textChat) == "z/head")
    }

    @Test("never an ID absent from the catalog; nil only when nothing qualifies")
    func neverInvents() {
        #expect(P.resolve(catalog: [], pinned: "a/b", recents: ["c/d"], requirement: .textChat) == nil)
        let imageOnly = C(id: "img/model", inputModalities: ["text"], outputModalities: ["image"])
        #expect(P.resolve(catalog: [imageOnly], pinned: "img/model", requirement: .textChat) == nil)
        let catalog = [text("a/one"), text("b/two")]
        for pinned in [nil, "a/one", "missing/x"] {
            let result = P.resolve(catalog: catalog, pinned: pinned, recents: ["missing/y"], requirement: .textChat)
            #expect(result.map { id in catalog.contains { $0.id == id } } == true)
        }
    }

    @Test("tool-calling requirement skips non-tool models at every step")
    func toolRequirement() {
        let catalog = [
            text("anthropic/claude-sonnet-5", tools: false), text("y/pinned", tools: false),
            text("x/recent", tools: false), text("openai/gpt-5.1", tools: true), text("z/tools", tools: true),
        ]
        #expect(P.resolve(catalog: catalog, pinned: "y/pinned", recents: ["x/recent"], requirement: .toolCalling) == "openai/gpt-5.1")
        #expect(P.resolve(catalog: catalog, pinned: "y/pinned", requirement: .textChat) == "y/pinned")
        #expect(P.resolve(catalog: [text("a/x", tools: false)], requirement: .toolCalling) == nil)
    }

    @Test("newest family member wins; variants and specialised builds are skipped")
    func familyMatching() {
        let catalog = [
            text("anthropic/claude-sonnet-4.5", created: 100),
            text("anthropic/claude-sonnet-5", created: 300),
            text("anthropic/claude-sonnet-5:free", created: 400),
            text("anthropic/claude-sonnet-5:batch", created: 500),
            text("openai/gpt-5.5", created: 600),
        ]
        #expect(P.resolve(catalog: catalog, requirement: .textChat) == "anthropic/claude-sonnet-5")
        // Undated members: higher version wins by numeric ID order.
        #expect(P.resolve(catalog: [text("anthropic/claude-sonnet-4.5"), text("anthropic/claude-sonnet-4.10")], requirement: .textChat)
            == "anthropic/claude-sonnet-4.10")
        // The Gemini family only takes Flash, not Pro or image builds.
        let gemini = [text("google/gemini-3-pro"), text("google/gemini-3-flash-image"), text("google/gemini-2.5-flash", created: 1)]
        #expect(P.resolve(catalog: gemini, requirement: .textChat) == "google/gemini-2.5-flash")
        #expect(!P.Family("openai/gpt-5").matches("openai/gpt-5-codex"))
        #expect(P.Family("openai/gpt-5").matches("openai/gpt-5.1"))
    }

    @Test("batch-only and non-text models are never defaults")
    func eligibility() {
        #expect(!C(id: "a/b:batch").satisfies(.textChat))
        #expect(C(id: "a/b").satisfies(.textChat), "unknown modalities are permissive")
        #expect(!C(id: "a/embed", inputModalities: ["text"], outputModalities: ["embeddings"]).satisfies(.textChat))
        #expect(!C(id: "a/audio-in", inputModalities: ["audio"], outputModalities: ["text"]).satisfies(.textChat))
    }

    @Test("every curated family resolves in a catalog shaped like OpenRouter's")
    func curatedFamiliesAreLive() {
        // Snapshot of real IDs (GET /api/v1/models, 2026-11), one per family.
        let ids = [
            "anthropic/claude-sonnet-4.5", "openai/gpt-5.1", "google/gemini-2.5-flash", "anthropic/claude-haiku-4.5",
            "x-ai/grok-4", "deepseek/deepseek-chat-v3.1", "qwen/qwen3-max", "moonshotai/kimi-k2",
            "z-ai/glm-4.6", "mistralai/mistral-medium-3.1",
        ]
        for family in P.curatedFamilies {
            #expect(ids.contains(where: family.matches), "\(family.prefix) matches nothing")
        }
    }

    @Test("Chat fallback order: favourite, selection, then the resolver")
    @MainActor
    func chatFallback() {
        let catalog = ["a/first", "openai/gpt-5.1", "b/second"]
        #expect(PlaygroundModelDefaults.chatFallback(catalogIds: catalog, favoriteIds: ["b/second"], selectedModelId: "a/first") == "b/second")
        #expect(PlaygroundModelDefaults.chatFallback(catalogIds: catalog, favoriteIds: [], selectedModelId: "a/first") == "a/first")
        #expect(PlaygroundModelDefaults.chatFallback(catalogIds: catalog, favoriteIds: [], selectedModelId: nil, recentIds: ["b/second"]) == "b/second")
        #expect(PlaygroundModelDefaults.chatFallback(catalogIds: catalog, favoriteIds: [], selectedModelId: "gone/x") == "openai/gpt-5.1")
        #expect(PlaygroundModelDefaults.chatFallback(catalogIds: [], favoriteIds: [], selectedModelId: nil) == "")
    }
}
