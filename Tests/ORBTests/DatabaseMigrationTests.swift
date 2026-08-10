import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Database migrations")
struct DatabaseMigrationTests {
    @Test("implicit test databases are isolated per manager")
    func implicitTestDatabasesAreIsolated() {
        let first = DatabaseManager()
        let second = DatabaseManager()
        let modelID = "test/isolation-\(UUID().uuidString)"

        first.addFavorite(modelID)

        #expect(first.isFavorite(modelID))
        #expect(second.isFavorite(modelID) == false)
    }

    @Test("registered test databases are removed by process cleanup")
    func processCleanupRemovesTestDatabaseFiles() throws {
        let manager = DatabaseManager()
        let path = try #require(manager.testDatabasePath)
        manager.addFavorite("test/cleanup")
        #expect(FileManager.default.fileExists(atPath: path))

        DatabaseManager.cleanupTestDatabaseForTesting(at: path)

        #expect(FileManager.default.fileExists(atPath: path) == false)
        #expect(FileManager.default.fileExists(atPath: path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: path + "-shm") == false)
        _ = manager
    }

    @Test("legacy favorite notes migrate into durable model notes")
    func migratesLegacyFavoriteNotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-notes-migration-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let sql = """
        CREATE TABLE favorites (
            model_id TEXT PRIMARY KEY,
            added_at REAL NOT NULL,
            notes TEXT DEFAULT ''
        );
        INSERT INTO favorites (model_id, added_at, notes)
        VALUES ('legacy/model', 0, 'legacy note');
        """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let migrated = DatabaseManager(path: url.path)
        #expect(migrated.getNotes("legacy/model") == "legacy note")
        migrated.removeFavorite("legacy/model")
        migrated.addFavorite("legacy/model")
        #expect(migrated.getNotes("legacy/model") == "legacy note")
    }

    @Test("pre-stream schema migrates once and remains readable after a second launch")
    func migratesLegacyMessagesIdempotently() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-migration-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let legacySQL = """
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY, mode TEXT NOT NULL, model_id TEXT NOT NULL,
            title TEXT NOT NULL, system_prompt TEXT DEFAULT '', total_cost REAL DEFAULT 0,
            total_tokens INTEGER DEFAULT 0, agent_history_json TEXT DEFAULT '[]', created_at REAL NOT NULL
        );
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
            content TEXT NOT NULL, tool_calls_json TEXT, tool_call_id TEXT, tool_name TEXT,
            sort_order INTEGER NOT NULL, created_at REAL NOT NULL,
            FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        );
        """
        #expect(sqlite3_exec(handle, legacySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        handle = nil

        let first = DatabaseManager(path: url.path)
        var conversation = ChatConversation(modelId: "test/model", mode: .chat)
        conversation.messages = [ChatMessage(role: "assistant", content: "partial", status: .interrupted, finishReason: "cancelled")]
        try first.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")
        #expect(first.loadMessages(for: conversation.id).first?.status == .interrupted)

        let second = DatabaseManager(path: url.path)
        #expect(second.loadMessages(for: conversation.id).first?.finishReason == "cancelled")
    }
}
