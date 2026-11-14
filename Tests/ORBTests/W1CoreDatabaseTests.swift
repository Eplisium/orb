import Foundation
import SQLite3
import Testing
@testable import ORB

// MARK: - Fixtures

private struct W1CoreProbeError: Error {}

/// A temporary file-backed database path plus its sidecars, removed on deinit.
private final class W1CoreTempDatabase {
    let path: String

    init(_ label: String) {
        path = ORBTestScratch.root
            .appendingPathComponent("ORB-w1core-\(label)-\(UUID().uuidString).sqlite3").path
    }

    deinit {
        for suffix in ["", "-wal", "-shm", "-journal", ".orb-initializing"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Opens the file with raw SQLite (not DatabaseManager) and runs `sql`.
    func rawExec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw W1CoreProbeError()
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw W1CoreProbeError() }
    }

    func rawScalar(_ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw W1CoreProbeError()
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw W1CoreProbeError() }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}

private func w1coreQueryPlan(_ db: DatabaseManager, _ sql: String) throws -> String {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db.db, "EXPLAIN QUERY PLAN " + sql, -1, &stmt, nil) == SQLITE_OK else {
        throw DatabaseManagerError.operationFailed(db.currentError())
    }
    defer { sqlite3_finalize(stmt) }
    var lines: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let detail = sqlite3_column_text(stmt, 3) { lines.append(String(cString: detail)) }
    }
    return lines.joined(separator: "\n")
}

private func w1coreIndexNames(_ db: DatabaseManager, table: String) throws -> [String] {
    try db.libraryRows("PRAGMA index_list(\(table));").map { $0[1] }
}

// MARK: - CORE-1: hot-path indexes

@Suite("W1 core: hot-path indexes")
struct W1CoreIndexTests {
    @Test("messages(conversation_id, sort_order) index exists and serves the transcript load")
    func messagesLoadUsesIndex() throws {
        let db = DatabaseManager()
        #expect(try w1coreIndexNames(db, table: "messages").contains("idx_messages_conversation"))
        let plan = try w1coreQueryPlan(db, "SELECT * FROM messages WHERE conversation_id = ? ORDER BY sort_order ASC;")
        #expect(plan.contains("USING INDEX idx_messages_conversation"), "plan: \(plan)")
        #expect(!plan.contains("TEMP B-TREE"), "plan: \(plan)")
        #expect(!plan.contains("SCAN messages"), "plan: \(plan)")
    }

    @Test("deleting a conversation's messages searches the index instead of scanning")
    func messageDeleteUsesIndex() throws {
        let db = DatabaseManager()
        let plan = try w1coreQueryPlan(db, "DELETE FROM messages WHERE conversation_id = ?;")
        #expect(plan.contains("INDEX idx_messages_conversation"), "plan: \(plan)")
        #expect(!plan.contains("SCAN messages"), "plan: \(plan)")
    }

    @Test("per-mode session list uses the mode/created_at index without a sort")
    func conversationListUsesIndex() throws {
        let db = DatabaseManager()
        let plan = try w1coreQueryPlan(db, "SELECT * FROM conversations WHERE mode = ? ORDER BY created_at DESC;")
        #expect(plan.contains("USING INDEX idx_conversations_mode_created"), "plan: \(plan)")
        #expect(!plan.contains("TEMP B-TREE"), "plan: \(plan)")
    }

    @Test("launch recovery of streaming rows uses the partial index")
    func streamingRecoveryUsesPartialIndex() throws {
        let db = DatabaseManager()
        let plan = try w1coreQueryPlan(db, "UPDATE messages SET status='interrupted' WHERE status='streaming';")
        #expect(plan.contains("idx_messages_streaming"), "plan: \(plan)")
        #expect(!plan.contains("SCAN messages"), "plan: \(plan)")
    }

    @Test("index migration is idempotent and upgrades a database created without the indexes")
    func indexMigrationIsIdempotent() throws {
        let file = W1CoreTempDatabase("legacy-index")
        // A pre-index database: the messages table exists, the index does not.
        try file.rawExec("""
            CREATE TABLE conversations (id TEXT PRIMARY KEY, mode TEXT NOT NULL, model_id TEXT NOT NULL, title TEXT NOT NULL,
              system_prompt TEXT DEFAULT '', total_cost REAL DEFAULT 0, total_tokens INTEGER DEFAULT 0,
              agent_history_json TEXT DEFAULT '[]', created_at REAL NOT NULL);
            CREATE TABLE messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
              tool_calls_json TEXT, tool_call_id TEXT, tool_name TEXT, sort_order INTEGER NOT NULL, created_at REAL NOT NULL,
              FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE);
            PRAGMA user_version=6;
            """)
        do {
            let first = DatabaseManager(path: file.path)
            #expect(first.launchFailure == nil)
            #expect(try w1coreIndexNames(first, table: "messages").contains("idx_messages_conversation"))
        }
        let second = DatabaseManager(path: file.path)
        #expect(second.launchFailure == nil)
        let names = try w1coreIndexNames(second, table: "messages")
        #expect(names.filter { $0 == "idx_messages_conversation" }.count == 1)
        #expect(names.contains("idx_messages_streaming"))
        #expect(try w1coreIndexNames(second, table: "conversations").contains("idx_conversations_mode_created"))
    }

    @Test("bulk grouped loader returns each mode's transcripts in order, matching per-conversation loads")
    func groupedLoaderMatchesPerConversationLoads() throws {
        let db = DatabaseManager()
        var chatA = ChatConversation(modelId: "w1core/a", mode: .chat)
        chatA.messages = (0..<5).map { ChatMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "a\($0)") }
        var chatB = ChatConversation(modelId: "w1core/b", mode: .chat)
        chatB.messages = [ChatMessage(role: "user", content: "b0")]
        var agent = ChatConversation(modelId: "w1core/c", mode: .agent)
        agent.messages = [ChatMessage(role: "user", content: "c0"), ChatMessage(role: "assistant", content: "c1")]
        let empty = ChatConversation(modelId: "w1core/empty", mode: .chat)
        for conversation in [chatA, chatB, agent, empty] {
            try db.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")
        }

        let chat = try db.loadMessagesGroupedChecked(mode: .chat)
        #expect(Set(chat.keys) == [chatA.id, chatB.id])
        #expect(chat[chatA.id]?.map(\.content) == ["a0", "a1", "a2", "a3", "a4"])
        #expect(chat[chatA.id] == (try db.loadMessagesChecked(for: chatA.id)))
        #expect(chat[chatB.id]?.map(\.content) == ["b0"])

        let all = try db.loadMessagesGroupedChecked()
        #expect(Set(all.keys) == [chatA.id, chatB.id, agent.id])
        #expect(all[agent.id]?.map(\.content) == ["c0", "c1"])
    }
}

// MARK: - CORE-10: forward-schema guard

@Suite("W1 core: schema version guard")
@MainActor
struct W1CoreSchemaVersionTests {
    @Test("a database from a newer ORB is refused, left untouched, and the session falls back to memory")
    func newerDatabaseIsRefused() throws {
        let file = W1CoreTempDatabase("newer")
        try file.rawExec("CREATE TABLE future_only (x TEXT); INSERT INTO future_only VALUES ('keep'); PRAGMA user_version=99;")
        let before = try Data(contentsOf: URL(fileURLWithPath: file.path))

        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }
        do {
            let manager = DatabaseManager(path: file.path)
            let failure = try #require(manager.launchFailure)
            #expect(failure.title == "Database From a Newer ORB")
            #expect(failure.detail.contains("newer version of ORB"))
            #expect(failure.detail.contains("99"))
            #expect(failure.backupPath == nil)
            // Still usable for this session, without persistence and without crashing.
            let modelID = "w1core/\(UUID().uuidString)"
            manager.addFavorite(modelID)
            #expect(manager.isFavorite(modelID))
            #expect(manager.schemaVersionOnDisk == DatabaseManager.schemaVersion) // the memory fallback
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == before)
        #expect(try file.rawScalar("PRAGMA user_version;") == "99")
        #expect(try file.rawScalar("SELECT x FROM future_only;") == "keep")
        #expect(try file.rawScalar("SELECT name FROM sqlite_master WHERE name='favorites';") == nil)
    }

    @Test("older databases are upgraded to the current stamp; the current stamp is kept")
    func olderDatabaseIsStamped() throws {
        let older = W1CoreTempDatabase("older")
        try older.rawExec("PRAGMA user_version=5;")
        do {
            let manager = DatabaseManager(path: older.path)
            #expect(manager.launchFailure == nil)
        }
        #expect(try older.rawScalar("PRAGMA user_version;") == String(DatabaseManager.schemaVersion))

        let current = W1CoreTempDatabase("current")
        do { _ = DatabaseManager(path: current.path) }
        do {
            let reopened = DatabaseManager(path: current.path)
            #expect(reopened.launchFailure == nil)
            #expect(reopened.schemaVersionOnDisk == DatabaseManager.schemaVersion)
        }
        #expect(try current.rawScalar("PRAGMA user_version;") == String(DatabaseManager.schemaVersion))
    }
}

// MARK: - CORE-7: writers never join another thread's transaction

/// Runs `body` on a dedicated Foundation thread (not the cooperative pool, which
/// a blocked semaphore wait could starve).
private func w1coreRunOnThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.start()
}

struct W1CoreWriter: Sendable, CustomTestStringConvertible {
    let name: String
    let write: @Sendable (DatabaseManager, String) -> Void
    let persisted: @Sendable (DatabaseManager, String) -> Bool
    var testDescription: String { name }

    static let all: [W1CoreWriter] = [
        // Browser-owned helper that does not take dbLock itself; it is
        // excluded by the connection mutex the transactions hold.
        W1CoreWriter(name: "setFavorite (unlocked caller)",
                     write: { db, key in try? db.setFavorite(key, true) },
                     persisted: { db, key in db.getAllFavorites().contains(key) }),
        W1CoreWriter(name: "addFavorite",
                     write: { db, key in db.addFavorite(key) },
                     persisted: { db, key in db.isFavorite(key) }),
        W1CoreWriter(name: "saveConversationChecked",
                     write: { db, key in
                         var conversation = ChatConversation(modelId: key, mode: .chat)
                         conversation.title = key
                         try? db.saveConversationChecked(conversation)
                     },
                     persisted: { db, key in
                         ((try? db.loadConversationsChecked()) ?? []).contains { $0.conversation.modelId == key }
                     }),
    ]
}

enum W1CoreTransactionKind: String, CaseIterable, Sendable {
    case assetReservation, immediateTransaction

    func run(_ db: DatabaseManager, _ work: () throws -> Void) throws {
        switch self {
        case .assetReservation: try db.withAssetReservation(work)
        case .immediateTransaction: try db.withImmediateTransaction(work)
        }
    }
}

@Suite("W1 core: transaction isolation across threads")
struct W1CoreTransactionIsolationTests {
    @Test("a write from another thread waits for a failing transaction and is not rolled back with it",
          arguments: W1CoreTransactionKind.allCases, W1CoreWriter.all)
    func concurrentWriteSurvivesRollback(kind: W1CoreTransactionKind, writer: W1CoreWriter) throws {
        let file = W1CoreTempDatabase("isolation")
        let db = DatabaseManager(path: file.path)
        try #require(db.launchFailure == nil)
        let key = "w1core/\(UUID().uuidString)"

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let transactionDone = DispatchSemaphore(value: 0)
        let writerStarted = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)

        w1coreRunOnThread {
            _ = try? kind.run(db) {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
                throw W1CoreProbeError() // ROLLBACK
            }
            transactionDone.signal()
        }
        try #require(entered.wait(timeout: .now() + 5) == .success)

        w1coreRunOnThread {
            writerStarted.signal()
            writer.write(db, key)
            writerDone.signal()
        }
        try #require(writerStarted.wait(timeout: .now() + 5) == .success)
        // The writer must be parked until the transaction ends. Before the fix
        // it ran inside the open transaction and returned at once.
        let finishedEarly = writerDone.wait(timeout: .now() + 0.15) == .success
        #expect(!finishedEarly, "\(writer.name) executed inside another thread's transaction")

        release.signal()
        #expect(transactionDone.wait(timeout: .now() + 10) == .success)
        if !finishedEarly {
            #expect(writerDone.wait(timeout: .now() + 10) == .success)
        }
        #expect(writer.persisted(db, key), "\(writer.name)'s committed write was rolled back")
    }

    @Test("nested transactions are refused instead of silently joining")
    func nestedTransactionIsRefused() throws {
        let db = DatabaseManager()
        #expect(throws: DatabaseManagerError.self) {
            try db.withImmediateTransaction {
                try db.withImmediateTransaction {}
            }
        }
        // The outer failure rolled back cleanly; the connection is usable.
        try db.withImmediateTransaction { db.addFavorite("w1core/after-nested") }
        #expect(db.isFavorite("w1core/after-nested"))
    }
}

// MARK: - compact()

@Suite("W1 core: database compaction")
struct W1CoreCompactionTests {
    @Test("compact() off the main thread checkpoints the WAL and shrinks the file after deletes")
    func compactShrinksDatabase() throws {
        let file = W1CoreTempDatabase("compact")
        let db = DatabaseManager(path: file.path)
        try #require(db.launchFailure == nil)
        let blob = String(repeating: "x", count: 64 * 1024)
        for index in 0..<80 { try db.saveMemory(content: "\(index) \(blob)") }
        try db.execChecked("DELETE FROM agent_memories;")
        try db.execChecked("PRAGMA wal_checkpoint(TRUNCATE);")
        let before = db.storageByteCount
        #expect(before > 4 * 1024 * 1024)

        final class Outcome: @unchecked Sendable { var error: Error?; var onMain = true }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        w1coreRunOnThread {
            outcome.onMain = Thread.isMainThread
            do { try db.compact() } catch { outcome.error = error }
            done.signal()
        }
        try #require(done.wait(timeout: .now() + 30) == .success)
        #expect(outcome.error == nil)
        #expect(!outcome.onMain)

        let after = db.storageByteCount
        #expect(after < before / 4, "before \(before) bytes, after \(after) bytes")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: file.path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        #expect(walSize == 0)
        // Still fully usable afterwards.
        try db.saveMemory(content: "after compaction")
        #expect(db.searchMemories(query: "after compaction").count == 1)
    }

    @Test("compact() refuses to run inside an open transaction")
    func compactRefusesInsideTransaction() throws {
        let file = W1CoreTempDatabase("compact-txn")
        let db = DatabaseManager(path: file.path)
        #expect(throws: DatabaseManagerError.self) {
            try db.withImmediateTransaction { try db.compact() }
        }
        try db.compact()
    }
}
