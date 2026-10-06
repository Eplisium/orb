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
    /// Writes only the conversation row (title, model, prompt, totals,
    /// agent history) — never the message rows.
    func saveConversationMeta(_ record: StoredConversation) throws
    /// Upserts the conversation row plus just the listed messages at their
    /// current positions. Streaming checkpoints use this so a long chat with
    /// base64 attachments is not deleted and rewritten every 750ms.
    func saveMessages(_ messageIDs: Set<UUID>, of record: StoredConversation) throws
    /// Loads only one mode's conversations (nil = all).
    func loadRecords(mode: PlaygroundMode?) throws -> [StoredConversation]
}

extension ConversationStore {
    // Conservative fallbacks for simple stores (tests): a full rewrite is
    // always correct, just slower.
    func saveConversationMeta(_ record: StoredConversation) throws { try saveRecord(record) }
    func saveMessages(_ messageIDs: Set<UUID>, of record: StoredConversation) throws { try saveRecord(record) }
    func loadRecords(mode: PlaygroundMode?) throws -> [StoredConversation] {
        let all = try loadRecords()
        guard let mode else { return all }
        return all.filter { $0.conversation.mode == mode }
    }
}

@MainActor
final class DatabaseConversationStore: ConversationStore {
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) { self.database = database }

    func loadRecords() throws -> [StoredConversation] { try loadRecords(mode: nil) }

    func loadRecords(mode: PlaygroundMode?) throws -> [StoredConversation] {
        database.loadConversations(mode: mode).map { item in
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

    func saveConversationMeta(_ record: StoredConversation) throws {
        try database.saveConversationChecked(record.conversation, agentHistoryJSON: try Self.historyJSON(record.agentHistory))
    }

    func saveMessages(_ messageIDs: Set<UUID>, of record: StoredConversation) throws {
        let rows = record.conversation.messages.enumerated()
            .filter { messageIDs.contains($0.element.id) }
            .map { (message: $0.element, sortOrder: $0.offset) }
        try database.saveConversationMessagesChecked(
            record.conversation, agentHistoryJSON: try Self.historyJSON(record.agentHistory), messages: rows
        )
    }

    private static func historyJSON(_ history: [AgentAPIMessage]) throws -> String {
        let data = try JSONEncoder().encode(history)
        guard let json = String(data: data, encoding: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return json
    }

    func removeConversation(_ id: UUID) throws { try database.deleteConversationChecked(id) }
    func removeMessage(_ id: UUID) throws { try database.deleteMessageChecked(id) }
    func recoverInterruptedRecords() throws { try database.markStreamingMessagesInterruptedChecked() }
}
