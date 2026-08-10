import Foundation

struct StoredConversation {
    var conversation: ChatConversation
    var agentHistory: [AgentAPIMessage]
}

@MainActor
protocol ConversationStore: AnyObject {
    func loadRecords() throws -> [StoredConversation]
    func saveRecord(_ record: StoredConversation) throws
    func removeConversation(_ id: UUID) throws
    func removeMessage(_ id: UUID) throws
    func recoverInterruptedRecords() throws
}

@MainActor
final class DatabaseConversationStore: ConversationStore {
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) { self.database = database }

    func loadRecords() throws -> [StoredConversation] {
        database.loadConversations().map { item in
            var conversation = item.conversation
            conversation.messages = database.loadMessages(for: conversation.id)
            let history = (try? JSONDecoder().decode([AgentAPIMessage].self, from: Data(item.agentHistoryJSON.utf8))) ?? []
            return StoredConversation(conversation: conversation, agentHistory: history)
        }
    }

    func saveRecord(_ record: StoredConversation) throws {
        let data = try JSONEncoder().encode(record.agentHistory)
        guard let json = String(data: data, encoding: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try database.saveConversationRecordChecked(record.conversation, agentHistoryJSON: json)
    }

    func removeConversation(_ id: UUID) throws { try database.deleteConversationChecked(id) }
    func removeMessage(_ id: UUID) throws { try database.deleteMessageChecked(id) }
    func recoverInterruptedRecords() throws { try database.markStreamingMessagesInterruptedChecked() }
}
