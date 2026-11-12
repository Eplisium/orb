import Foundation
import SQLite3
import Testing
@testable import ORB

private struct StorageBackendNeverNetworkClient: OpenRouterClientProtocol {
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        throw CocoaError(.featureUnsupported)
    }
}

@Suite("Storage backend fixes", .serialized)
@MainActor
struct StorageBackendFixTests {
    // B02/B12 reproduce the audit's already-executed red tests. All fixtures
    // are in-memory; no real databases, credentials, files, or requests.
    private func seed(_ db: DatabaseManager) throws -> ChatConversation {
        var conversation = ChatConversation(modelId: "fixture/model", mode: .chat)
        conversation.messages = [ChatMessage(role: "user", content: "must survive")]
        try DatabaseConversationStore(database: db).saveRecord(.init(conversation: conversation, agentHistory: []))
        return conversation
    }

    private func denyTranscriptReads(_ db: DatabaseManager) {
        #expect(sqlite3_set_authorizer(db.db, { _, action, table, column, _, _ in
            if action == SQLITE_READ,
               let table, String(cString: table) == "messages",
               let column, String(cString: column) == "content" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil) == SQLITE_OK)
    }

    @Test("B02: transcript prepare errors propagate through the real store")
    func failedTranscriptReadMustThrow() throws {
        let db = DatabaseManager(path: ":memory:")
        _ = try seed(db)
        denyTranscriptReads(db)
        defer { sqlite3_set_authorizer(db.db, nil, nil) }
        #expect(throws: (any Error).self) { _ = try DatabaseConversationStore(database: db).loadRecords() }
    }

    @Test("B02: failed loading cannot expose an empty transcript to New")
    func failedReadCannotEraseTranscript() throws {
        let db = DatabaseManager(path: ":memory:")
        let conversation = try seed(db)
        denyTranscriptReads(db)
        defer { sqlite3_set_authorizer(db.db, nil, nil) }
        let service = ChatService(client: StorageBackendNeverNetworkClient(),
                                  store: DatabaseConversationStore(database: db), apiKeyProvider: { nil })
        sqlite3_set_authorizer(db.db, nil, nil)
        if let loaded = service.conversations.first {
            service.selectConversation(loaded)
            _ = service.newConversation(modelId: "fixture/model", mode: .chat)
        }
        #expect(db.loadMessages(for: conversation.id).map(\.content) == ["must survive"])
        #expect(service.lastError != nil)
    }

    @Test("B02: conversation prepare errors propagate, rather than reporting no sessions")
    func failedConversationReadMustThrow() throws {
        let db = DatabaseManager(path: ":memory:")
        _ = try seed(db)
        #expect(sqlite3_set_authorizer(db.db, { _, action, table, _, _, _ in
            if action == SQLITE_READ, let table, String(cString: table) == "conversations" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil) == SQLITE_OK)
        defer { sqlite3_set_authorizer(db.db, nil, nil) }
        #expect(throws: (any Error).self) { _ = try DatabaseConversationStore(database: db).loadRecords() }
    }

    @Test("B02: a message step failure after one row never returns a partial transcript")
    func messageStepFailureMustThrow() throws {
        let db = DatabaseManager(path: ":memory:")
        var conversation = try seed(db)
        conversation.messages.append(ChatMessage(role: "assistant", content: "second"))
        try db.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")
        try db.execChecked("ALTER TABLE messages RENAME TO stored_messages;")
        // Index avoids an eager sorter, so the first row is delivered before
        // abs(Int64.min) raises SQLITE_ERROR on the second row.
        try db.execChecked("CREATE INDEX audit_message_order ON stored_messages(conversation_id, sort_order);")
        try db.execChecked("CREATE VIEW messages AS SELECT *, abs(CASE WHEN sort_order = 1 THEN -9223372036854775808 ELSE 0 END) AS audit_fault FROM stored_messages;")
        let probe = try #require(db.prepare("SELECT * FROM messages WHERE conversation_id = '\(conversation.id.uuidString)' ORDER BY sort_order ASC;"))
        #expect(sqlite3_step(probe) == SQLITE_ROW)
        #expect(sqlite3_step(probe) == SQLITE_ERROR)
        sqlite3_finalize(probe)
        #expect(throws: (any Error).self) { _ = try DatabaseConversationStore(database: db).loadRecords() }
    }

    @Test("B02: a conversation step failure never returns a partial session list")
    func conversationStepFailureMustThrow() throws {
        let db = DatabaseManager(path: ":memory:")
        let first = ChatConversation(modelId: "fixture/first", mode: .chat, createdAt: Date(timeIntervalSince1970: 2))
        let second = ChatConversation(modelId: "fixture/second", mode: .chat, createdAt: Date(timeIntervalSince1970: 1))
        try db.saveConversationRecordChecked(first, agentHistoryJSON: "[]")
        try db.saveConversationRecordChecked(second, agentHistoryJSON: "[]")
        try db.execChecked("ALTER TABLE conversations RENAME TO stored_conversations;")
        try db.execChecked("CREATE INDEX audit_conversation_order ON stored_conversations(created_at DESC);")
        try db.execChecked("CREATE VIEW conversations AS SELECT *, abs(CASE WHEN created_at = 1 THEN -9223372036854775808 ELSE 0 END) AS audit_fault FROM stored_conversations;")
        let probe = try #require(db.prepare("SELECT * FROM conversations ORDER BY created_at DESC;"))
        #expect(sqlite3_step(probe) == SQLITE_ROW)
        #expect(sqlite3_step(probe) == SQLITE_ERROR)
        sqlite3_finalize(probe)
        #expect(throws: (any Error).self) { _ = try DatabaseConversationStore(database: db).loadRecords() }
    }

    @Test("B10: rejected writes retain original events and expose an exactly-once retry")
    func ledgerFailureRetainsAndRetriesOriginalEvent() throws {
        let db = DatabaseManager(path: ":memory:")
        let ledger = UsageLedger(database: { db })
        try db.execChecked("CREATE TRIGGER deny_usage_insert BEFORE INSERT ON usage_events BEGIN SELECT RAISE(ABORT, 'injected ledger failure'); END;")
        ledger.record(.chat, model: "fixture/model", cost: 1.25, totalTokens: 42, eventID: "paid-run")
        let pending = try #require(ledger.pendingEvents.first)
        #expect(pending.id == "Chat:paid-run")
        #expect(ledger.pendingEvents.count == 1)
        #expect(ledger.persistenceError != nil)
        #expect(ledger.persistenceWarning?.contains("until ORB quits") == true)
        #expect(ledger.buckets(.feature).isEmpty)
        #expect(ledger.revision == 0)
        // Redelivery must not replace the original timestamp, price, or ID.
        ledger.record(.chat, model: "fixture/model", cost: 99, eventID: "paid-run")
        ledger.retryPendingEvents()
        #expect(ledger.pendingEvents == [pending])
        #expect(ledger.persistenceError != nil)
        try db.execChecked("DROP TRIGGER deny_usage_insert;")
        ledger.retryPendingEvents()
        #expect(ledger.pendingEvents.isEmpty)
        #expect(ledger.persistenceError == nil)
        #expect(ledger.persistenceWarning == nil)
        #expect(ledger.revision == 1)
        #expect(ledger.buckets(.feature).first?.cost == 1.25)
        #expect(ledger.buckets(.feature).first?.tokens == 42)
        #expect(ledger.buckets(.feature).first?.requests == 1)
        let row = try #require(db.prepare("SELECT id, timestamp FROM usage_events;"))
        defer { sqlite3_finalize(row) }
        #expect(sqlite3_step(row) == SQLITE_ROW)
        #expect(db.columnTextOrNil(row, 0) == pending.id)
        #expect(sqlite3_column_double(row, 1) == pending.timestamp.timeIntervalSince1970)
        #expect(sqlite3_step(row) == SQLITE_DONE)
        ledger.retryPendingEvents()
        ledger.record(.chat, model: "fixture/model", cost: 1.25, eventID: "paid-run")
        #expect(ledger.buckets(.feature).first?.requests == 1)
    }

    @Test("B10: prepare failures also retain events until a later retry")
    func ledgerPrepareFailureRetainsEvent() throws {
        let db = DatabaseManager(path: ":memory:")
        let ledger = UsageLedger(database: { db })
        #expect(sqlite3_set_authorizer(db.db, { _, action, table, _, _, _ in
            if action == SQLITE_INSERT, let table, String(cString: table) == "usage_events" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil) == SQLITE_OK)
        defer { sqlite3_set_authorizer(db.db, nil, nil) }
        ledger.record(.agentWebSearch, model: "fixture/search", cost: nil)
        let original = try #require(ledger.pendingEvents.first)
        #expect(ledger.persistenceError != nil)
        sqlite3_set_authorizer(db.db, nil, nil)
        ledger.retryPendingEvents()
        #expect(ledger.pendingEvents.isEmpty)
        #expect(ledger.persistenceError == nil)
        #expect(ledger.buckets(.feature).first?.key == "Agent Web Search")
        #expect(ledger.buckets(.feature).first?.unpricedRequests == 1)
        let row = try #require(db.prepare("SELECT id FROM usage_events;"))
        defer { sqlite3_finalize(row) }
        #expect(sqlite3_step(row) == SQLITE_ROW)
        #expect(db.columnTextOrNil(row, 0) == original.id)
    }

    @Test("B10: partial retries remove only saved events and keep the warning")
    func ledgerPartialRetryKeepsFailures() throws {
        let db = DatabaseManager(path: ":memory:")
        let ledger = UsageLedger(database: { db })
        try db.execChecked("CREATE TRIGGER deny_usage_insert BEFORE INSERT ON usage_events BEGIN SELECT RAISE(ABORT, 'injected ledger failure'); END;")
        ledger.record(.speech, model: "fixture/speech", cost: nil)
        ledger.record(.chat, model: "fixture/chat", cost: 2)
        let original = ledger.pendingEvents
        #expect(original.count == 2)
        try db.execChecked("DROP TRIGGER deny_usage_insert;")
        try db.execChecked("CREATE TRIGGER deny_usage_insert BEFORE INSERT ON usage_events WHEN NEW.feature = 'Chat' BEGIN SELECT RAISE(ABORT, 'injected chat failure'); END;")
        ledger.retryPendingEvents()
        #expect(ledger.pendingEvents == original.filter { $0.feature == "Chat" })
        #expect(ledger.persistenceError != nil)
        #expect(ledger.buckets(.feature).first?.unpricedRequests == 1)
        try db.execChecked("DROP TRIGGER deny_usage_insert;")
        ledger.retryPendingEvents()
        #expect(ledger.pendingEvents.isEmpty)
        #expect(ledger.persistenceError == nil)
        #expect(ledger.buckets(.feature).reduce(0) { $0 + $1.requests } == 2)
    }

    @Test("B12: plain SQLite text preserves embedded NUL and UTF-8", arguments: ["", "\u{0}", "before\u{0}after", "é🧪\u{0}e\u{301}終\u{0}"])
    func textRoundTripsLosslessly(payload: String) throws {
        let db = DatabaseManager(path: ":memory:")
        var conversation = ChatConversation(modelId: "fixture/model", mode: .chat)
        conversation.title = payload
        conversation.systemPrompt = payload
        conversation.messages = [ChatMessage(role: "user", content: payload, reasoning: payload)]
        try db.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")
        #expect(db.loadMessages(for: conversation.id).first?.content == payload)
        #expect(db.loadMessages(for: conversation.id).first?.reasoning == payload)
        #expect(db.loadConversations().first?.conversation.title == payload)
        #expect(db.loadConversations().first?.conversation.systemPrompt == payload)
        try db.saveNotes("fixture/model", notes: payload)
        #expect(db.getNotes("fixture/model") == payload)
        try db.saveMemory(content: payload)
        #expect(db.searchMemories(query: "").first?.content == payload)
        try db.setFavorite(payload, true)
        #expect(db.getAllFavorites() == [payload])
        #expect(db.isFavorite(payload))
        db.insertUsageEvent(UsageEvent(feature: "Chat", modelID: payload, cost: 1))
        #expect(db.usageBuckets(.model).first?.key == payload)
        // The separate media extension must share the same text binder.
        var job = JobRecord(id: UUID(), remoteID: "fixture/job", kind: "video", submissionState: .submitted,
                            pollingState: .completed, lastRemoteStatus: "completed", conversationID: nil,
                            messageID: nil, modelID: "fixture/model", usageCost: nil, recoverableError: nil,
                            createdAt: Date(), updatedAt: Date())
        job.prompt = payload
        try db.saveJobRecordChecked(job)
        try db.saveJobMediaFieldsChecked(job)
        #expect(db.withMediaFields(db.findJobRecord(remoteID: "fixture/job"))?.prompt == payload)
        let content = try #require(db.loadMessages(for: conversation.id).first?.content)
        #expect(Data(content.utf8) == Data(payload.utf8))
    }

    @Test("B12: reading existing length-delimited SQLite data preserves NUL")
    func readsExistingNULText() throws {
        let db = DatabaseManager(path: ":memory:")
        try db.execChecked("INSERT INTO model_notes(model_id, notes) VALUES ('fixture/model', CAST(X'610062' AS TEXT));")
        #expect(db.getNotes("fixture/model") == "a\u{0}b")
        let stmt = try #require(db.prepare("SELECT NULL, '', CAST(X'610062' AS TEXT);"))
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(db.columnTextOrNil(stmt, 0) == nil)
        #expect(db.columnTextOrNil(stmt, 1) == "")
        #expect(db.columnTextOrNil(stmt, 2) == "a\u{0}b")
    }
}
