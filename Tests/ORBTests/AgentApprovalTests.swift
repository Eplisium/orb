import Testing
import Foundation
@testable import ORB

private actor ScriptClient: OpenRouterClientProtocol {
    private var scripts: [[OpenRouterStreamEvent]]
    init(_ scripts: [[OpenRouterStreamEvent]]) { self.scripts = scripts }
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        let events = scripts.isEmpty ? [OpenRouterStreamEvent.done] : scripts.removeFirst()
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

@MainActor
private final class MemStore: ConversationStore {
    var records: [UUID: StoredConversation] = [:]
    func loadRecords() throws -> [StoredConversation] { Array(records.values) }
    func saveRecord(_ r: StoredConversation) throws { records[r.conversation.id] = r }
    func removeConversation(_ id: UUID) throws { records[id] = nil }
    func removeMessage(_ id: UUID) throws {}
    func recoverInterruptedRecords() throws {}
}

private func request(_ name: String = "run_command") -> ApprovalCoordinator.Request {
    .init(id: UUID(), toolName: name, server: nil, summary: "x")
}

@MainActor
@Suite("Agent approvals: presenter")
struct ApprovalPresenterTests {
    @Test("A presented request waits, shows as current, and resolves with the user's decision")
    func decide() async {
        let presenter = ApprovalPresenter()
        let r = request()
        async let decision = presenter.present(r)
        for _ in 0..<200 where presenter.queue.current == nil { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(presenter.queue.current?.id == r.id)
        presenter.decide(r.id, .approved)
        #expect(await decision == .approved)
        #expect(presenter.queue.current == nil)
    }

    @Test("Requests queue in arrival order, one visible at a time")
    func ordering() async {
        let presenter = ApprovalPresenter()
        let a = request(), b = request()
        async let da = presenter.present(a)
        for _ in 0..<200 where presenter.queue.current == nil { try? await Task.sleep(for: .milliseconds(2)) }
        async let db = presenter.present(b)
        for _ in 0..<200 where presenter.queue.waiting == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(presenter.queue.current?.id == a.id)
        presenter.decide(a.id, .denied)
        #expect(await da == .denied)
        #expect(presenter.queue.current?.id == b.id)
        presenter.decide(b.id, .approved)
        #expect(await db == .approved)
    }

    @Test("denyAll resolves everything as denied and clears the queue")
    func denyAll() async {
        let presenter = ApprovalPresenter()
        let a = request(), b = request()
        async let da = presenter.present(a)
        async let db = presenter.present(b)
        for _ in 0..<200 where presenter.queue.current == nil || presenter.queue.waiting == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        presenter.denyAll()
        #expect(await da == .denied)
        #expect(await db == .denied)
        #expect(presenter.queue.current == nil)
    }

    @Test("Deciding an unknown ID is a no-op")
    func unknown() {
        let presenter = ApprovalPresenter()
        presenter.decide(UUID(), .approved)
        #expect(presenter.queue.current == nil)
    }
}

@MainActor
@Suite("Agent approvals: wired into the agent run")
struct AgentRunApprovalTests {
    private func runCommandScript() -> [[OpenRouterStreamEvent]] {
        [
            [.toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "t1", type: "function", name: "run_command",
                               arguments: #"{"command":"touch approval-must-not-exist"}"#),
             .finishReason(choiceIndex: 0, reason: "tool_calls"), .done],
            [.contentDelta(choiceIndex: 0, text: "Done."), .done],
        ]
    }

    private func start(_ service: ChatService) async {
        await service.sendAgentMessage("go", modelId: "t/m", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: true)
    }

    private func waitForPrompt(_ service: ChatService) async -> ApprovalCoordinator.Request? {
        for _ in 0..<1000 where service.approvalPresenter.queue.current == nil { try? await Task.sleep(for: .milliseconds(2)) }
        return service.approvalPresenter.queue.current
    }

    private func waitIdle(_ service: ChatService) async {
        for _ in 0..<1000 where service.isStreaming { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test("A risky tool call pauses for approval, and denial reaches the model as a tool error")
    func denied() async throws {
        let service = ChatService(client: ScriptClient(runCommandScript()), store: MemStore(), apiKeyProvider: { "k" })
        await start(service)
        let prompt = try #require(await waitForPrompt(service))
        #expect(prompt.toolName == "run_command")
        service.approvalPresenter.decide(prompt.id, .denied)
        await waitIdle(service)
        let toolMessage = service.activeConversation?.messages.first { $0.role == "tool" }
        #expect(toolMessage?.content.contains("Denied: the user did not approve") == true)
    }

    @Test("Stopping the run while a prompt is open denies it and ends the run")
    func stopWhilePending() async throws {
        let service = ChatService(client: ScriptClient(runCommandScript()), store: MemStore(), apiKeyProvider: { "k" })
        await start(service)
        _ = try #require(await waitForPrompt(service))
        service.stopStreaming()
        await waitIdle(service)
        #expect(!service.isStreaming)
        #expect(service.approvalPresenter.queue.current == nil)
    }

    @Test("Web-only sessions never prompt, because risky tools are not permitted at all")
    func webOnly() async {
        let service = ChatService(client: ScriptClient(runCommandScript()), store: MemStore(), apiKeyProvider: { "k" })
        await service.sendAgentMessage("go", modelId: "t/m", workspace: FileManager.default.temporaryDirectory.path, fullComputerAccess: false)
        await waitIdle(service)
        #expect(service.approvalPresenter.queue.current == nil)
        let toolMessage = service.activeConversation?.messages.first { $0.role == "tool" }
        #expect(toolMessage?.content.contains("not permitted") == true)
    }
}
