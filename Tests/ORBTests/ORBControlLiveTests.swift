import Foundation
import Testing
@testable import ORB

/// Live OP Mode check against a real model. Opt-in: ORB_LIVE=1. Takes the
/// key from ORB_LIVE_KEY (never ORB's Keychain), an in-memory conversation store, and the test
/// process's own UserDefaults (never the app's). Spends a few cents.
@Suite("Live: OP Mode ORB control", .enabled(if: ProcessInfo.processInfo.environment["ORB_LIVE"] == "1"))
@MainActor
struct ORBControlLiveTests {
    static let model = ProcessInfo.processInfo.environment["ORB_LIVE_MODEL"] ?? "openai/gpt-4o-mini"

    @Test("agent inspects and manages ORB through real tool calls")
    func live() async throws {
        guard let key = ProcessInfo.processInfo.environment["ORB_LIVE_KEY"], !key.isEmpty else {
            Issue.record("Set ORB_LIVE_KEY (the test never reads ORB's Keychain: its ACL would raise a dialog)"); return
        }
        UserDefaults.standard.set(true, forKey: OPMode.key)
        defer { UserDefaults.standard.removeObject(forKey: OPMode.key)
                UserDefaults.standard.removeObject(forKey: "playground.agentTemperature") }

        let store = CountingConversationStore()
        let service = ChatService(client: OpenRouterClient(), store: store, apiKeyProvider: { key })
        var seeded = ChatConversation(modelId: "x/y", mode: .chat)
        seeded.title = "Zebra recipes"; seeded.totalTokens = 321; seeded.totalCost = 0.0123
        seeded.messages = [ChatMessage(role: "user", content: "How do I cook a zebra? The secret word is PINEAPPLE-7.")]
        var junk = ChatConversation(modelId: "x/y", mode: .chat)
        junk.title = "DELETE ME junk"
        service.restore([StoredConversation(conversation: seeded, agentHistory: []), StoredConversation(conversation: junk, agentHistory: [])])

        let prompt = """
        Use your orb_* tools (do not guess). 1) Find the session containing the secret word and tell me its exact secret word and title. \
        2) Rename that session to "Zebra Cookbook". 3) Delete the session titled "DELETE ME junk". \
        4) Set the setting playground.agentTemperature to 0.4. 5) Try to set the setting orb.opMode to false, and report whether it was allowed. \
        Finish with a short report.
        """
        let workspace = FileManager.default.temporaryDirectory.path
        await service.sendAgentMessage(prompt, modelId: Self.model, workspace: workspace, fullComputerAccess: false)
        for _ in 0..<2_400 where service.isStreaming { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!service.isStreaming, "agent run did not finish in 120s")

        let conversation = try #require(service.activeConversation)
        let calls = conversation.messages.flatMap { $0.toolCalls ?? [] }
        print("LIVE tools:", calls.map { "\($0.name)\($0.isError ? "!" : "")" })
        for call in calls { print("LIVE call:", call.name, call.arguments ?? "", "=>", (call.result ?? "").prefix(300)) }
        print("LIVE reply:", conversation.messages.filter { $0.role == "assistant" }.map(\.content).joined(separator: "\n---\n"))
        print("LIVE error:", service.lastError ?? "none")

        #expect(calls.contains { $0.name == "orb_search_sessions" || $0.name == "orb_read_session" })
        #expect(service.conversations.contains { $0.title == "Zebra Cookbook" })
        #expect(!service.conversations.contains { $0.title == "DELETE ME junk" })
        #expect(UserDefaults.standard.double(forKey: "playground.agentTemperature") == 0.4)
        #expect(UserDefaults.standard.bool(forKey: OPMode.key) == true, "OP Mode must stay on: the agent cannot disable it")
    }
}
