import Foundation
import Testing
@testable import ORB

@Suite("Inline message transcript")
struct MessageTranscriptTests {
    @Test("Chronology survives SQLite and Codable round trips")
    func persistence() throws {
        let db = DatabaseManager()
        var message = ChatMessage(role: "assistant", content: "Before\n\nAfter", reasoning: "Think")
        message.recordTranscript(.reasoning, text: "Think")
        message.recordTranscript(.text, text: "Before")
        message.recordTranscriptTool("call-1")
        message.recordTranscript(.text, text: "\n\nAfter")
        var conversation = ChatConversation(modelId: "test/model", mode: .agent)
        conversation.messages = [message]
        try db.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")
        #expect(db.loadMessages(for: conversation.id).first == message)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)) == message)
    }

    @Test("Chunks preserve whitespace and repeated tool previews preserve identity")
    func identityAndWhitespace() {
        var message = ChatMessage(role: "assistant", content: "")
        message.recordTranscript(.text, text: "line one\n")
        let id = message.transcript?.first?.id
        message.recordTranscript(.text, text: "\nline two")
        #expect(message.transcript?.first?.id == id)
        #expect(message.transcript?.first?.text == "line one\n\nline two")
        message.recordTranscriptTool("a")
        message.recordTranscriptTool("a")
        message.recordTranscriptTool("b")
        #expect(message.transcript?.count == 3)
    }

    @Test("Legacy messages keep all content and stable row identities")
    func legacy() throws {
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"assistant","content":"Answer","reasoning":"Thought"}"#.utf8))
        #expect(message.displayTranscript.map(\.kind) == [.reasoning, .text])
        #expect(message.displayTranscript.map(\.id) == message.displayTranscript.map(\.id))
    }
}
