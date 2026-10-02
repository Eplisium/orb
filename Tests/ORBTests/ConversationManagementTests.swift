import Testing
import Foundation
@testable import ORB

@MainActor
private final class RecordingStore: ConversationStore {
    var records: [UUID: StoredConversation] = [:]
    var failRemoval = false
    var failSave = false
    var failMessageRemoval = false
    var removed: [UUID] = []

    func loadRecords() throws -> [StoredConversation] { Array(records.values) }
    func saveRecord(_ record: StoredConversation) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        records[record.conversation.id] = record
    }
    func removeConversation(_ id: UUID) throws {
        if failRemoval { throw CocoaError(.fileWriteUnknown) }
        records[id] = nil
        removed.append(id)
    }
    func removeMessage(_ id: UUID) throws {
        if failMessageRemoval { throw CocoaError(.fileWriteUnknown) }
        for key in records.keys { records[key]?.conversation.messages.removeAll { $0.id == id } }
    }
    func recoverInterruptedRecords() throws {}
}

private struct NoClient: OpenRouterClientProtocol {
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private func makeService() -> (ChatService, RecordingStore) {
    let store = RecordingStore()
    return (ChatService(client: NoClient(), store: store, apiKeyProvider: { "fixture" }), store)
}

@MainActor
private func seed(_ service: ChatService, mode: PlaygroundMode = .chat, count: Int = 4, createdAt: Date = Date()) -> ChatConversation {
    var messages: [ChatMessage] = []
    for i in 0..<count {
        messages.append(ChatMessage(role: i % 2 == 0 ? "user" : "assistant", content: "m\(i)"))
    }
    let conv = ChatConversation(modelId: "a/b", mode: mode, messages: messages, createdAt: createdAt)
    service.restore([StoredConversation(conversation: conv, agentHistory: [])])
    service.selectConversation(conv)
    return conv
}

@Suite("Phase 5 management: rename")
@MainActor
struct RenameConversationTests {
    @Test("Rename trims, persists and updates the active conversation")
    func rename() {
        let (service, store) = makeService()
        let c = seed(service)
        #expect(service.renameConversation(c.id, to: "  Planning  "))
        #expect(service.conversations.first?.title == "Planning")
        #expect(service.activeConversation?.title == "Planning")
        #expect(store.records[c.id]?.conversation.title == "Planning")
    }

    @Test("Empty or whitespace names are rejected and the title is unchanged")
    func empty() {
        let (service, _) = makeService()
        let c = seed(service)
        let before = service.conversations.first!.title
        #expect(!service.renameConversation(c.id, to: "   "))
        #expect(service.conversations.first?.title == before)
    }

    @Test("Titles are capped at 120 characters")
    func cap() {
        let (service, _) = makeService()
        let c = seed(service)
        #expect(service.renameConversation(c.id, to: String(repeating: "x", count: 300)))
        #expect(service.conversations.first?.title.count == 120)
    }

    @Test("Unknown IDs are a no-op")
    func unknown() {
        let (service, _) = makeService()
        #expect(!service.renameConversation(UUID(), to: "x"))
    }
}

@Suite("Phase 5 management: duplicate and branch")
@MainActor
struct BranchConversationTests {
    @Test("Duplicate copies messages with fresh IDs, keeps mode/model/system prompt, and selects it")
    func duplicate() throws {
        let (service, store) = makeService()
        let c = seed(service)
        service.updateSystemPrompt("Be brief", for: c)
        let copy = try #require(service.duplicateConversation(c.id))
        #expect(copy.id != c.id)
        #expect(copy.title == "\(c.title) (copy)")
        #expect(copy.messages.map(\.content) == c.messages.map(\.content))
        #expect(Set(copy.messages.map(\.id)).isDisjoint(with: c.messages.map(\.id)))
        #expect(copy.systemPrompt == "Be brief")
        #expect(copy.mode == c.mode && copy.modelId == c.modelId)
        #expect(service.activeConversation?.id == copy.id)
        #expect(store.records[copy.id] != nil)
        #expect(service.conversations.first { $0.id == c.id }?.messages.count == 4, "original untouched")
    }

    @Test("Branch keeps everything up to and including the chosen message")
    func branch() throws {
        let (service, store) = makeService()
        let c = seed(service)
        let branch = try #require(service.branchConversation(from: c.messages[1].id, in: c.id))
        #expect(branch.messages.map(\.content) == ["m0", "m1"])
        #expect(branch.title.hasSuffix("(branch)"))
        #expect(store.records[branch.id]?.conversation.messages.count == 2)
        #expect(service.conversations.first { $0.id == c.id }?.messages.count == 4)
    }

    @Test("Branch with an unknown message ID returns nil and creates nothing")
    func branchUnknown() {
        let (service, _) = makeService()
        let c = seed(service)
        let count = service.conversations.count
        #expect(service.branchConversation(from: UUID(), in: c.id) == nil)
        #expect(service.conversations.count == count)
    }

    @Test("Failed save leaves no phantom conversation and reports the error")
    func saveFailure() {
        let (service, store) = makeService()
        let c = seed(service)
        store.failSave = true
        let count = service.conversations.count
        #expect(service.duplicateConversation(c.id) == nil)
        #expect(service.conversations.count == count)
        #expect(service.lastError != nil)
    }
}

@Suite("Phase 5 management: edit and resend")
@MainActor
struct TruncateConversationTests {
    @Test("Truncate removes the message and everything after it, returning the original text")
    func truncate() throws {
        let (service, store) = makeService()
        let c = seed(service)
        let text = try #require(service.truncateConversation(from: c.messages[2].id, in: c.id))
        #expect(text == "m2")
        #expect(service.conversations.first { $0.id == c.id }?.messages.map(\.content) == ["m0", "m1"])
        #expect(store.records[c.id]?.conversation.messages.count == 2)
    }

    @Test("Only user messages can be edited")
    func userOnly() {
        let (service, _) = makeService()
        let c = seed(service)
        #expect(service.truncateConversation(from: c.messages[1].id, in: c.id) == nil)
        #expect(service.conversations.first { $0.id == c.id }?.messages.count == 4)
    }

    @Test("Storage-first: a failed database removal keeps the in-memory transcript intact")
    func failure() {
        let (service, store) = makeService()
        let c = seed(service)
        store.failMessageRemoval = true
        #expect(service.truncateConversation(from: c.messages[2].id, in: c.id) == nil)
        #expect(service.conversations.first { $0.id == c.id }?.messages.count == 4)
        #expect(service.lastError != nil)
    }
}

@Suite("Phase 5 management: undoable bulk delete")
@MainActor
struct UndoDeleteTests {
    @Test("Deleting returns a snapshot; undo restores messages, order and agent history")
    func undo() throws {
        let (service, store) = makeService()
        let a = seed(service, mode: .agent)
        let b = seed(service, mode: .agent)
        let snapshot = try #require(service.deleteConversationsUndoable(ids: [a.id]))
        #expect(snapshot.count == 1)
        #expect(!service.conversations.contains { $0.id == a.id })
        #expect(store.records[a.id] == nil)
        service.restore(snapshot)
        let restored = try #require(service.conversations.first { $0.id == a.id })
        #expect(restored.messages.map(\.content) == a.messages.map(\.content))
        #expect(store.records[a.id] != nil)
        #expect(service.conversations.contains { $0.id == b.id })
    }

    @Test("Storage-first: failed removal keeps the conversation and returns no snapshot for it")
    func failure() {
        let (service, store) = makeService()
        let a = seed(service)
        store.failRemoval = true
        let snapshot = service.deleteConversationsUndoable(ids: [a.id])
        #expect(snapshot == nil)
        #expect(service.conversations.contains { $0.id == a.id })
        #expect(service.lastError != nil)
    }

    @Test("Restoring twice does not duplicate")
    func idempotent() throws {
        let (service, _) = makeService()
        let a = seed(service)
        let snapshot = try #require(service.deleteConversationsUndoable(ids: [a.id]))
        service.restore(snapshot)
        service.restore(snapshot)
        #expect(service.conversations.filter { $0.id == a.id }.count == 1)
    }

    @Test("Restored conversations sort back by creation date, newest first")
    func ordering() throws {
        let (service, _) = makeService()
        let older = seed(service, createdAt: Date(timeIntervalSinceNow: -100))
        let newer = seed(service, createdAt: Date())
        let snapshot = try #require(service.deleteConversationsUndoable(ids: [older.id]))
        service.restore(snapshot)
        #expect(service.conversations.map(\.id) == [newer.id, older.id])
    }
}

@Suite("Phase 5 management: toast and undo timing")
struct UndoToastModelTests {
    @Test("Message wording pluralises and offers Undo")
    func wording() {
        #expect(UndoToast.message(deleted: 1) == "Deleted 1 session")
        #expect(UndoToast.message(deleted: 3) == "Deleted 3 sessions")
        #expect(UndoToast.visibleDuration > 0 && UndoToast.visibleDuration <= 10)
    }
}

@Suite("Phase 5 management: reset to model default")
struct ResetTemperatureTests {
    @Test("A nil temperature is omitted from the request, never defaulted")
    func omitted() {
        var s = GenerationSettings.default
        s.temperature = nil
        #expect(s.validated().temperature == nil)
    }

    @Test("Quick-sliders state resolves to nil when the user chose model default")
    func quickState() {
        #expect(QuickSampling(temperature: nil).requestTemperature == nil)
        #expect(QuickSampling(temperature: 0.4).requestTemperature == 0.4)
        #expect(QuickSampling(temperature: nil).display == "Model default")
        #expect(QuickSampling(temperature: 0.4).display == "0.40")
        #expect(QuickSampling(temperature: nil).sliderValue == 0.7)
    }
}

@Suite("Phase 5 management: approval presentation")
struct ApprovalPresentationTests {
    @Test("Risk level and wording per tool; symbol is always present")
    func levels() {
        let terminal = ApprovalPresentation.make(toolName: "run_command", server: nil, summary: "rm -rf build")
        #expect(terminal.risk == .high)
        #expect(terminal.title.contains("command"))
        let computer = ApprovalPresentation.make(toolName: "computer_action", server: nil, summary: "click")
        #expect(computer.risk == .high)
        let mcp = ApprovalPresentation.make(toolName: "mcp__files__read", server: "files", summary: "")
        #expect(mcp.risk == .elevated)
        #expect(mcp.title.contains("files"))
        #expect([terminal, computer, mcp].allSatisfy { !$0.symbol.isEmpty && !$0.riskWord.isEmpty })
    }

    @Test("Long summaries are truncated for display but never emptied")
    func truncation() {
        let long = String(repeating: "x", count: 5_000)
        let p = ApprovalPresentation.make(toolName: "run_command", server: nil, summary: long)
        #expect(p.displaySummary.count <= 600)
        #expect(!p.displaySummary.isEmpty)
        #expect(ApprovalPresentation.make(toolName: "run_command", server: nil, summary: "").displaySummary == "No arguments shown.")
    }

    @Test("Request queue shows one prompt at a time, in arrival order, and resolves by ID")
    func queue() {
        var q = ApprovalQueue()
        let a = ApprovalCoordinator.Request(id: UUID(), toolName: "run_command", server: nil, summary: "a")
        let b = ApprovalCoordinator.Request(id: UUID(), toolName: "run_command", server: nil, summary: "b")
        q.enqueue(a); q.enqueue(b)
        #expect(q.current?.id == a.id)
        #expect(q.waiting == 1)
        q.resolve(a.id)
        #expect(q.current?.id == b.id)
        q.resolve(UUID())
        #expect(q.current?.id == b.id)
        q.resolve(b.id)
        #expect(q.current == nil)
    }
}

@Suite("Phase 5 management: composer keys and drop")
struct ComposerKeyTests {
    @Test("Return sends only for Command+Return when the setting requires it; plain Return otherwise")
    func send() {
        #expect(ComposerKeyPolicy.shouldSend(command: false, shift: false, requireCommand: false))
        #expect(!ComposerKeyPolicy.shouldSend(command: false, shift: true, requireCommand: false), "shift-return is a newline")
        #expect(ComposerKeyPolicy.shouldSend(command: true, shift: false, requireCommand: false))
        #expect(!ComposerKeyPolicy.shouldSend(command: false, shift: false, requireCommand: true))
        #expect(ComposerKeyPolicy.shouldSend(command: true, shift: false, requireCommand: true))
    }

    @Test("Send hint reflects the setting")
    func hint() {
        #expect(ComposerKeyPolicy.hint(requireCommand: false) == "↩ send · ⇧↩ new line")
        #expect(ComposerKeyPolicy.hint(requireCommand: true) == "⌘↩ send · ↩ new line")
    }
}
