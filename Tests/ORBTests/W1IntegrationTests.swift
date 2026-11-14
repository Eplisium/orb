import Foundation
import Testing
@testable import ORB

// Wave-1 integration: the cross-track hook-ups applied on main after the
// eight tracks landed. Helpers are prefixed `W1Integ` to stay unique.

private enum W1IntegSource {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ORB")

    static func read(_ relative: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }
}

private final class W1IntegCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct W1IntegCompactFailure: LocalizedError {
    var errorDescription: String? { "disk is busy" }
}

@MainActor
@Suite("W1 integration: Compact Database")
struct W1IntegCompactTests {
    private func locations() -> StorageLocations {
        StorageLocations.inside(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("w1integ-\(UUID().uuidString)"))
    }

    @Test("a successful run reports before/after and re-measures")
    func success() async {
        let model = StorageDiagnosticsModel(
            locations: locations(),
            measure: { _ in var r = StorageReport(); r.databaseBytes = 4; return r },
            compact: { DatabaseCompaction(beforeBytes: 10_000_000, afterBytes: 4_000_000) }
        )
        await model.compactDatabase()
        #expect(model.lastCompaction == DatabaseCompaction(beforeBytes: 10_000_000, afterBytes: 4_000_000))
        #expect(model.compactionError == nil)
        #expect(!model.isCompacting)
        #expect(model.report?.databaseBytes == 4)
        #expect(model.lastCompaction?.summary.contains("freed") == true)
    }

    @Test("a failure is shown inline, not thrown")
    func failure() async {
        let model = StorageDiagnosticsModel(
            locations: locations(),
            measure: { _ in StorageReport() },
            compact: { throw W1IntegCompactFailure() }
        )
        await model.compactDatabase()
        #expect(model.lastCompaction == nil)
        #expect(model.compactionError == "Could not compact the database: disk is busy")
        #expect(!model.isCompacting)
    }

    @Test("nothing reclaimed says so")
    func nothingToReclaim() {
        #expect(DatabaseCompaction(beforeBytes: 5, afterBytes: 5).summary.hasSuffix("(nothing to reclaim)"))
    }

    @Test("compact() really runs on a file database")
    func realCompact() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1integ-db-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = DatabaseManager(path: dir.appendingPathComponent("db.sqlite3").path)
        #expect(db.storageByteCount > 0)
        try db.compact()
    }
}

@MainActor
@Suite("W1 integration: grouped conversation load")
struct W1IntegConversationLoadTests {
    @Test("loadRecords(mode:) returns each conversation's own messages, in order, for that mode only")
    func grouped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1integ-conv-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = DatabaseManager(path: dir.appendingPathComponent("db.sqlite3").path)
        let store = DatabaseConversationStore(database: db)
        var chatA = ChatConversation(title: "a", modelId: "m", mode: .chat)
        chatA.messages = [ChatMessage(role: "user", content: "a1"), ChatMessage(role: "assistant", content: "a2")]
        var chatB = ChatConversation(title: "b", modelId: "m", mode: .chat)
        chatB.messages = [ChatMessage(role: "user", content: "b1")]
        let chatEmpty = ChatConversation(title: "empty", modelId: "m", mode: .chat)
        var agent = ChatConversation(title: "agent", modelId: "m", mode: .agent)
        agent.messages = [ChatMessage(role: "user", content: "g1")]
        for conversation in [chatA, chatB, chatEmpty, agent] {
            try store.saveRecord(.init(conversation: conversation, agentHistory: []))
        }

        let chats = try store.loadRecords(mode: .chat)
        #expect(Set(chats.map(\.conversation.title)) == ["a", "b", "empty"])
        let byTitle = Dictionary(uniqueKeysWithValues: chats.map { ($0.conversation.title, $0.conversation.messages.map(\.content)) })
        #expect(byTitle["a"] == ["a1", "a2"])
        #expect(byTitle["b"] == ["b1"])
        #expect(byTitle["empty"] == [])
        let all = try store.loadRecords()
        #expect(all.count == 4)
        #expect(all.first { $0.conversation.mode == .agent }?.conversation.messages.map(\.content) == ["g1"])
    }
}

@Suite("W1 integration: compare hand-off")
struct W1IntegCompareHandoffTests {
    @MainActor
    @Test("staging models tells a visible Test Suite to pick them up")
    func posts() async throws {
        let handoff = CompareHandoff()
        let received = W1IntegCounter()
        let token = NotificationCenter.default.addObserver(forName: .testSuiteCompareHandoffStaged, object: nil, queue: nil) { _ in
            received.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        handoff.stage([])
        handoff.stage(["a/b"])
        let deadline = ContinuousClock.now + .seconds(5)
        while received.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        // Other suites may stage the shared hand-off in parallel, so count >= 1.
        #expect(received.value >= 1)
        #expect(handoff.take() == ["a/b"])
    }
}

@Suite("W1 integration: copy and wiring")
struct W1IntegWiringTests {
    @Test("approval activity text names the tool")
    func approvalLabel() {
        #expect(PlaygroundRunPhase.awaitingApprovalLabel(tool: "write_file") == "Waiting for your approval: write_file")
    }

    @Test("a repeated truncation still reads as truncation, and says the run went on before stopping")
    func truncationCopy() {
        let text = NativeAgentError.truncatedToolCall.errorDescription ?? ""
        #expect(text.contains("truncated"))
        let summary = PlaygroundErrorSummary.summarize(text, mode: .agent)
        #expect(summary.headline == "The model ran out of output room mid-tool-call")
        #expect(summary.hint?.contains("split the work") == true)
    }

    @Test("no view falls back to a hard-coded model id")
    func noHardCodedDefaults() {
        for file in ["AgentView.swift", "ChatView.swift", "TestSuiteView.swift", "ContentView.swift"] {
            #expect(!W1IntegSource.read(file).contains("\"openai/gpt-4o\""), "\(file)")
        }
        let content = W1IntegSource.read("ContentView.swift")
        #expect(content.contains("PlaygroundModelDefaults.chatFallback("))
        #expect(content.contains("PlaygroundModelDefaults.agentFallback("))
        #expect(!content.contains("TODO(wave2)"))
    }

    @Test("Files opens without the key banner; Library is local")
    func filesUngated() {
        let content = W1IntegSource.read("ContentView.swift")
        #expect(content.contains("case .files: FilesView()"))
        #expect(!content.contains("NeedsKeyGate(studio: .generate) { FilesView() }"))
    }

    @Test("quitting stops agent-started processes")
    func terminateHook() {
        let app = W1IntegSource.read("ORBApp.swift")
        #expect(app.contains("func applicationWillTerminate(_ notification: Notification)"))
        #expect(app.contains("NativeAgentTools.terminateAllRunningProcesses()"))
    }

    @Test("Chat and Agent sidebars delete with Undo and use mode-aware banners")
    func undoableSidebars() {
        for (file, mode) in [("ChatView.swift", "chat"), ("AgentView.swift", "agent")] {
            let source = W1IntegSource.read(file)
            #expect(source.contains(".environment(\\.conversationDeleteIsUndoable, true)"), "\(file)")
            #expect(source.contains("PlaygroundErrorBanner(message: error, mode: .\(mode))"), "\(file)")
            #expect(source.contains("deleteMessageUndoable(message.id, from: conversation.id, includingReply: true)"), "\(file)")
            #expect(!source.contains("chatService.deleteConversation($0)"), "\(file)")
        }
    }

    @MainActor
    @Test("the Model menu state defaults to a chat-capable, uncompared model")
    func shellDefaults() {
        let shell = ShellController()
        #expect(!shell.focusedModelIsComparing)
        #expect(shell.focusedModelCanChat)
    }
}
