import Foundation
import SQLite3

private final class TestDatabaseCleanupRegistry: @unchecked Sendable {
    static let shared = TestDatabaseCleanupRegistry()

    private let lock = NSLock()
    private var paths: Set<String> = []
    private var registeredExitHandler = false

    func register(_ path: String) {
        lock.lock()
        paths.insert(path)
        if !registeredExitHandler {
            registeredExitHandler = true
            atexit(cleanupORBTestDatabasesAtExit)
        }
        lock.unlock()
    }

    func unregister(_ path: String) {
        lock.lock()
        paths.remove(path)
        lock.unlock()
    }

    func cleanup(_ path: String) {
        unregister(path)
        removeFiles(at: path)
    }

    func cleanup() {
        lock.lock()
        let registeredPaths = paths
        paths.removeAll()
        lock.unlock()
        for path in registeredPaths { removeFiles(at: path) }
    }

    private func removeFiles(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}

private func cleanupORBTestDatabasesAtExit() {
    TestDatabaseCleanupRegistry.shared.cleanup()
}

enum DatabaseManagerError: Error, LocalizedError {
    case operationFailed(String)
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .operationFailed(let message): return "Database operation failed: \(message)"
        case .notAvailable: return "The local database is unavailable for this session."
        }
    }
}

/// Describes why ORB fell back to a non-persistent database at launch.
struct DatabaseLaunchFailure: Equatable {
    let title: String
    let detail: String
    /// Set when the previously-failing database file was moved aside to a backup.
    let backupPath: String?
}

final class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let dbPath: String
    private let deletesDatabaseOnDeinit: Bool
    /// Set when the on-disk database could not be opened or migrated; ORB then
    /// degrades to a non-persistent in-memory database instead of crashing.
    private(set) var launchFailure: DatabaseLaunchFailure?
    /// The launch failure from the most recently constructed manager, for UI
    /// presentation. (The shared manager is constructed before SwiftUI exists.)
    static var lastLaunchFailure: DatabaseLaunchFailure?

    init(path: String? = nil) {
        if let path {
            dbPath = path
            deletesDatabaseOnDeinit = false
        } else if Self.isRunningTests {
            dbPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("ORB-tests-\(UUID().uuidString).sqlite3").path
            deletesDatabaseOnDeinit = true
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("ORB", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            dbPath = appDir.appendingPathComponent("favorites.sqlite3").path
            deletesDatabaseOnDeinit = false
        }

        if deletesDatabaseOnDeinit {
            TestDatabaseCleanupRegistry.shared.register(dbPath)
        }
        openDatabase()
        createTables()
        if let launchFailure {
            Self.lastLaunchFailure = launchFailure
        }
    }

    var testDatabasePath: String? {
        deletesDatabaseOnDeinit ? dbPath : nil
    }

    static func cleanupTestDatabaseForTesting(at path: String) {
        TestDatabaseCleanupRegistry.shared.cleanup(path)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.processName.contains("ORBPackageTests")
            || ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || CommandLine.arguments.first?.contains("ORBPackageTests") == true
            || CommandLine.arguments.first?.contains(".xctest") == true
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundleURL.pathExtension == "xctest"
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let failed = db
            let msg = failed.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(failed)
            db = nil
            // A failed open must never take the app down. Degrade to an
            // in-memory database so ORB still works (without persistence).
            if sqlite3_open(":memory:", &db) == SQLITE_OK {
                launchFailure = DatabaseLaunchFailure(
                    title: "Database Unavailable",
                    detail: "ORB could not open its local database at \(dbPath) (\(msg)). ORB is running with a temporary in-memory database, so data will not persist for this session.",
                    backupPath: nil
                )
            } else {
                db = nil
                launchFailure = DatabaseLaunchFailure(
                    title: "Database Unavailable",
                    detail: "ORB could not open its local database at \(dbPath) (\(msg)). Data features are disabled for this session.",
                    backupPath: nil
                )
            }
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
    }

    /// Moves a database file that failed to open or migrate aside to a
    /// timestamped backup so the next launch starts fresh. Returns the backup
    /// path, or nil when there was nothing to move (or the move failed — the
    /// failure will resurface next launch, which is preferable to data loss).
    private static func backupDatabase(at path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = path + ".corrupt-" + stamp
        do {
            try fm.moveItem(atPath: path, toPath: backup)
            try? fm.removeItem(atPath: path + "-wal")
            try? fm.removeItem(atPath: path + "-shm")
            return backup
        } catch {
            return nil
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let e = err { sqlite3_free(e) }
        }
    }

    private func execChecked(_ sql: String) throws {
        guard let db else { throw DatabaseManagerError.notAvailable }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? currentError()
            if let error { sqlite3_free(error) }
            throw DatabaseManagerError.operationFailed(message)
        }
    }

    private func currentError() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is unavailable"
    }

    private func requireDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseManagerError.operationFailed(currentError())
        }
    }

    private func createTables() {
        createTablesCore(retryingAfterFailure: false)
    }

    private func createTablesCore(retryingAfterFailure: Bool) {
        exec("""
        CREATE TABLE IF NOT EXISTS favorites (
            model_id TEXT PRIMARY KEY,
            added_at REAL NOT NULL,
            notes TEXT DEFAULT ''
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS test_results (
            id TEXT PRIMARY KEY,
            scenario_id TEXT NOT NULL,
            scenario_title TEXT NOT NULL,
            category TEXT NOT NULL,
            model_id TEXT NOT NULL,
            response TEXT NOT NULL,
            prompt_tokens INTEGER DEFAULT 0,
            completion_tokens INTEGER DEFAULT 0,
            total_tokens INTEGER DEFAULT 0,
            cost REAL DEFAULT 0,
            latency_ms INTEGER DEFAULT 0,
            success INTEGER DEFAULT 0,
            error_message TEXT,
            output_path TEXT,
            timestamp REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS custom_tests (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            icon TEXT NOT NULL,
            category TEXT NOT NULL,
            system_prompt TEXT NOT NULL,
            user_prompt TEXT NOT NULL,
            notes TEXT DEFAULT '',
            created_at REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            model_id TEXT NOT NULL,
            title TEXT NOT NULL,
            system_prompt TEXT DEFAULT '',
            total_cost REAL DEFAULT 0,
            total_tokens INTEGER DEFAULT 0,
            agent_history_json TEXT DEFAULT '[]',
            created_at REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            tool_calls_json TEXT,
            tool_call_id TEXT,
            tool_name TEXT,
            sort_order INTEGER NOT NULL,
            created_at REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'complete',
            finish_reason TEXT,
            error_message TEXT,
            FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        );
        """)
        do {
            try execChecked("""
            CREATE TABLE IF NOT EXISTS model_notes (
                model_id TEXT PRIMARY KEY,
                notes TEXT NOT NULL DEFAULT ''
            );
            """)
            try execChecked("""
            INSERT OR IGNORE INTO model_notes (model_id, notes)
            SELECT model_id, notes FROM favorites WHERE notes != '';
            """)
            try addColumnIfMissing(table: "messages", column: "status", definition: "TEXT NOT NULL DEFAULT 'complete'")
            try addColumnIfMissing(table: "messages", column: "finish_reason", definition: "TEXT")
            try addColumnIfMissing(table: "messages", column: "error_message", definition: "TEXT")
            try execChecked("PRAGMA user_version=2;")
        } catch {
            // A failed migration must never take the app down. Back up the
            // failing file, swap in a fresh in-memory database, and surface
            // the problem to the user instead of crashing at launch.
            sqlite3_close(db)
            db = nil
            let backupPath = Self.backupDatabase(at: dbPath)
            let openedFallback = sqlite3_open(":memory:", &db) == SQLITE_OK
            if openedFallback {
                exec("PRAGMA journal_mode=WAL;")
                exec("PRAGMA foreign_keys=ON;")
            } else {
                db = nil
            }
            launchFailure = DatabaseLaunchFailure(
                title: "Database Migration Failed",
                detail: backupPath != nil
                    ? "ORB could not upgrade its local database (\(error.localizedDescription)). The previous database was moved to \(backupPath!) and ORB is starting with a fresh, empty one."
                    : "ORB could not upgrade its local database (\(error.localizedDescription)). ORB is running with a temporary in-memory database; data will not persist for this session.",
                backupPath: backupPath
            )
            if openedFallback && !retryingAfterFailure {
                createTablesCore(retryingAfterFailure: true)
            }
        }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        guard !columnExists(table: table, column: column) else { return }
        try execChecked("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let statement = prepare("PRAGMA table_info(\(table));") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return nil
        }
        return stmt
    }

    // MARK: - Favorites

    func isFavorite(_ modelId: String) -> Bool {
        let sql = "SELECT 1 FROM favorites WHERE model_id = ?;"
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, modelId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func addFavorite(_ modelId: String) {
        let sql = "INSERT OR IGNORE INTO favorites (model_id, added_at) VALUES (?, ?);"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, modelId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func removeFavorite(_ modelId: String) {
        let sql = "DELETE FROM favorites WHERE model_id = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, modelId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    func toggleFavorite(_ modelId: String) {
        if isFavorite(modelId) {
            removeFavorite(modelId)
        } else {
            addFavorite(modelId)
        }
    }

    func getAllFavorites() -> [String] {
        let sql = "SELECT model_id FROM favorites ORDER BY added_at DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return ids
    }

    // MARK: - Notes

    func getNotes(_ modelId: String) -> String {
        let sql = "SELECT notes FROM model_notes WHERE model_id = ?;"
        guard let stmt = prepare(sql) else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, modelId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                return String(cString: cStr)
            }
        }
        return ""
    }

    func setNotes(_ modelId: String, notes: String) {
        let sql = """
        INSERT INTO model_notes (model_id, notes) VALUES (?, ?)
        ON CONFLICT(model_id) DO UPDATE SET notes=excluded.notes;
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, modelId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, notes, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    // MARK: - Conversations

    func saveConversation(_ conv: ChatConversation, agentHistoryJSON: String = "[]") {
        try? saveConversationChecked(conv, agentHistoryJSON: agentHistoryJSON)
    }

    func saveConversationChecked(_ conv: ChatConversation, agentHistoryJSON: String = "[]") throws {
        let sql = """
        INSERT INTO conversations
        (id, mode, model_id, title, system_prompt, total_cost, total_tokens, agent_history_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            mode=excluded.mode, model_id=excluded.model_id, title=excluded.title,
            system_prompt=excluded.system_prompt, total_cost=excluded.total_cost,
            total_tokens=excluded.total_tokens, agent_history_json=excluded.agent_history_json;
        """
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, conv.id.uuidString, -1, t)
        sqlite3_bind_text(stmt, 2, conv.mode.rawValue, -1, t)
        sqlite3_bind_text(stmt, 3, conv.modelId, -1, t)
        sqlite3_bind_text(stmt, 4, conv.title, -1, t)
        sqlite3_bind_text(stmt, 5, conv.systemPrompt, -1, t)
        sqlite3_bind_double(stmt, 6, conv.totalCost)
        sqlite3_bind_int(stmt, 7, Int32(conv.totalTokens))
        sqlite3_bind_text(stmt, 8, agentHistoryJSON, -1, t)
        sqlite3_bind_double(stmt, 9, conv.createdAt.timeIntervalSince1970)
        try requireDone(stmt)
    }

    func saveConversationRecordChecked(_ conv: ChatConversation, agentHistoryJSON: String) throws {
        try execChecked("BEGIN IMMEDIATE;")
        do {
            try saveConversationChecked(conv, agentHistoryJSON: agentHistoryJSON)
            try deleteMessagesChecked(for: conv.id)
            for (index, message) in conv.messages.enumerated() {
                try saveMessageChecked(message, conversationId: conv.id, sortOrder: index)
            }
            try execChecked("COMMIT;")
        } catch {
            try? execChecked("ROLLBACK;")
            throw error
        }
    }

    func loadConversations() -> [(conversation: ChatConversation, agentHistoryJSON: String)] {
        let sql = "SELECT * FROM conversations ORDER BY created_at DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [(ChatConversation, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let modeStr = String(cString: sqlite3_column_text(stmt, 1))
            let modelId = String(cString: sqlite3_column_text(stmt, 2))
            let title = String(cString: sqlite3_column_text(stmt, 3))
            let systemPrompt = columnTextOrNil(stmt, 4) ?? ""
            let totalCost = sqlite3_column_double(stmt, 5)
            let totalTokens = Int(sqlite3_column_int(stmt, 6))
            let agentJSON = columnTextOrNil(stmt, 7) ?? "[]"
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))

            let mode = PlaygroundMode(rawValue: modeStr) ?? .chat
            guard let id = UUID(uuidString: idStr) else { continue }
            var conv = ChatConversation(id: id, modelId: modelId, mode: mode, systemPrompt: systemPrompt, createdAt: createdAt)
            conv.title = title
            conv.totalCost = totalCost
            conv.totalTokens = totalTokens
            results.append((conv, agentJSON))
        }
        return results
    }

    func deleteConversation(_ id: UUID) {
        try? deleteConversationChecked(id)
    }

    func deleteConversationChecked(_ id: UUID) throws {
        let sql = "DELETE FROM conversations WHERE id = ?;"
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        try requireDone(stmt)
    }

    // MARK: - Messages

    func saveMessage(_ message: ChatMessage, conversationId: UUID, sortOrder: Int) {
        try? saveMessageChecked(message, conversationId: conversationId, sortOrder: sortOrder)
    }

    func saveMessageChecked(_ message: ChatMessage, conversationId: UUID, sortOrder: Int) throws {
        let sql = """
        INSERT OR REPLACE INTO messages
        (id, conversation_id, role, content, tool_calls_json, tool_call_id, tool_name, sort_order, created_at, status, finish_reason, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, message.id.uuidString, -1, t)
        sqlite3_bind_text(stmt, 2, conversationId.uuidString, -1, t)
        sqlite3_bind_text(stmt, 3, message.role, -1, t)
        sqlite3_bind_text(stmt, 4, message.content, -1, t)

        if let toolCalls = message.toolCalls, !toolCalls.isEmpty,
           let data = try? JSONEncoder().encode(toolCalls),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 5, json, -1, t)
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        if let tcid = message.toolCallId {
            sqlite3_bind_text(stmt, 6, tcid, -1, t)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        if let tn = message.toolName {
            sqlite3_bind_text(stmt, 7, tn, -1, t)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        sqlite3_bind_int(stmt, 8, Int32(sortOrder))
        sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 10, message.status.rawValue, -1, t)
        if let reason = message.finishReason { sqlite3_bind_text(stmt, 11, reason, -1, t) } else { sqlite3_bind_null(stmt, 11) }
        if let error = message.errorMessage { sqlite3_bind_text(stmt, 12, error, -1, t) } else { sqlite3_bind_null(stmt, 12) }
        try requireDone(stmt)
    }

    func loadMessages(for conversationId: UUID) -> [ChatMessage] {
        let sql = "SELECT * FROM messages WHERE conversation_id = ? ORDER BY sort_order ASC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, conversationId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var messages: [ChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let role = String(cString: sqlite3_column_text(stmt, 2))
            let content = columnTextOrNil(stmt, 3) ?? ""
            let toolCallsJSON = columnTextOrNil(stmt, 4)
            let toolCallId = columnTextOrNil(stmt, 5)
            let toolName = columnTextOrNil(stmt, 6)
            let status = columnTextOrNil(stmt, 9).flatMap(ChatMessageStatus.init(rawValue:)) ?? .complete
            let finishReason = columnTextOrNil(stmt, 10)
            let errorMessage = columnTextOrNil(stmt, 11)

            var toolCalls: [ToolCallDisplay]? = nil
            if let json = toolCallsJSON, let data = json.data(using: .utf8) {
                toolCalls = try? JSONDecoder().decode([ToolCallDisplay].self, from: data)
            }

            guard let id = UUID(uuidString: idStr) else { continue }
            let msg = ChatMessage(
                id: id, role: role, content: content, toolCalls: toolCalls,
                toolCallId: toolCallId, toolName: toolName, status: status,
                finishReason: finishReason, errorMessage: errorMessage
            )
            messages.append(msg)
        }
        return messages
    }

    func deleteMessages(for conversationId: UUID) {
        try? deleteMessagesChecked(for: conversationId)
    }

    func deleteMessagesChecked(for conversationId: UUID) throws {
        let sql = "DELETE FROM messages WHERE conversation_id = ?;"
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, conversationId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        try requireDone(stmt)
    }

    func deleteMessage(_ messageId: UUID) {
        try? deleteMessageChecked(messageId)
    }

    func deleteMessageChecked(_ messageId: UUID) throws {
        let sql = "DELETE FROM messages WHERE id = ?;"
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, messageId.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        try requireDone(stmt)
    }

    func markStreamingMessagesInterrupted() {
        try? markStreamingMessagesInterruptedChecked()
    }

    func markStreamingMessagesInterruptedChecked() throws {
        try execChecked("UPDATE messages SET status='interrupted', finish_reason='app_terminated', error_message=COALESCE(error_message, 'Interrupted when ORB closed.') WHERE status='streaming';")
    }

    // MARK: - Export

    func exportConversationMarkdown(_ conv: ChatConversation) -> String {
        var md = "# \(conv.title)\n\n"
        md += "**Model:** \(conv.modelId)  \n"
        md += "**Mode:** \(conv.mode.rawValue)  \n"
        md += "**Date:** \(conv.createdAt.formatted())  \n"
        if conv.totalTokens > 0 {
            md += "**Tokens:** \(conv.totalTokens)  \n"
        }
        if conv.totalCost > 0 {
            md += "**Cost:** $\(String(format: "%.4f", conv.totalCost))  \n"
        }
        md += "\n---\n\n"
        for msg in conv.messages {
            let label: String
            switch msg.role {
            case "user": label = "**You**"
            case "assistant": label = "**Assistant**"
            case "tool": label = "**Tool** (\(msg.toolName ?? "unknown"))"
            case "system": label = "**System**"
            default: label = "**\(msg.role)**"
            }
            md += "\(label):\n\n\(msg.content)\n\n---\n\n"
        }
        return md
    }

    deinit {
        sqlite3_close(db)
        guard deletesDatabaseOnDeinit else { return }
        TestDatabaseCleanupRegistry.shared.unregister(dbPath)
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
    }

    // MARK: - Test Results

    func saveTestResult(_ result: TestRunResult) {
        let sql = """
        INSERT OR REPLACE INTO test_results
        (id, scenario_id, scenario_title, category, model_id, response,
         prompt_tokens, completion_tokens, total_tokens, cost, latency_ms,
         success, error_message, output_path, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, result.id.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, result.scenarioId, -1, transient)
        sqlite3_bind_text(stmt, 3, result.scenarioTitle, -1, transient)
        sqlite3_bind_text(stmt, 4, result.category.rawValue, -1, transient)
        sqlite3_bind_text(stmt, 5, result.modelId, -1, transient)
        sqlite3_bind_text(stmt, 6, result.response, -1, transient)
        sqlite3_bind_int(stmt, 7, Int32(result.promptTokens))
        sqlite3_bind_int(stmt, 8, Int32(result.completionTokens))
        sqlite3_bind_int(stmt, 9, Int32(result.totalTokens))
        sqlite3_bind_double(stmt, 10, result.cost)
        sqlite3_bind_int(stmt, 11, Int32(result.latencyMs))
        sqlite3_bind_int(stmt, 12, result.success ? 1 : 0)
        if let err = result.errorMessage {
            sqlite3_bind_text(stmt, 13, err, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        if let path = result.outputPath {
            sqlite3_bind_text(stmt, 14, path, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        sqlite3_bind_double(stmt, 15, result.timestamp.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func loadTestResults() -> [TestRunResult] {
        let sql = "SELECT * FROM test_results ORDER BY timestamp DESC LIMIT 200;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [TestRunResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let scenarioId = String(cString: sqlite3_column_text(stmt, 1))
            let scenarioTitle = String(cString: sqlite3_column_text(stmt, 2))
            let categoryStr = String(cString: sqlite3_column_text(stmt, 3))
            let modelId = String(cString: sqlite3_column_text(stmt, 4))
            let response = String(cString: sqlite3_column_text(stmt, 5))
            let promptTokens = Int(sqlite3_column_int(stmt, 6))
            let completionTokens = Int(sqlite3_column_int(stmt, 7))
            let totalTokens = Int(sqlite3_column_int(stmt, 8))
            let cost = sqlite3_column_double(stmt, 9)
            let latencyMs = Int(sqlite3_column_int(stmt, 10))
            let success = sqlite3_column_int(stmt, 11) == 1
            let errorMessage = columnTextOrNil(stmt, 12)
            let outputPath = columnTextOrNil(stmt, 13)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))

            let category = TestCategory(rawValue: categoryStr) ?? .webDevelopment
            let id = UUID(uuidString: idStr) ?? UUID()

            results.append(TestRunResult(
                id: id,
                scenarioId: scenarioId,
                scenarioTitle: scenarioTitle,
                category: category,
                modelId: modelId,
                response: response,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens,
                cost: cost,
                latencyMs: latencyMs,
                success: success,
                errorMessage: errorMessage,
                outputPath: outputPath,
                timestamp: timestamp
            ))
        }
        return results
    }

    func clearTestResults() {
        exec("DELETE FROM test_results;")
    }

    func deleteTestResult(_ id: UUID) {
        let sql = "DELETE FROM test_results WHERE id = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    // MARK: - Custom Tests

    func saveCustomTest(_ test: CustomTest) {
        let sql = """
        INSERT OR REPLACE INTO custom_tests
        (id, title, subtitle, icon, category, system_prompt, user_prompt, notes, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, test.id, -1, transient)
        sqlite3_bind_text(stmt, 2, test.title, -1, transient)
        sqlite3_bind_text(stmt, 3, test.subtitle, -1, transient)
        sqlite3_bind_text(stmt, 4, test.icon, -1, transient)
        sqlite3_bind_text(stmt, 5, test.category.rawValue, -1, transient)
        sqlite3_bind_text(stmt, 6, test.systemPrompt, -1, transient)
        sqlite3_bind_text(stmt, 7, test.userPrompt, -1, transient)
        sqlite3_bind_text(stmt, 8, test.notes, -1, transient)
        sqlite3_bind_double(stmt, 9, test.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func loadCustomTests() -> [CustomTest] {
        let sql = "SELECT * FROM custom_tests ORDER BY created_at DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var tests: [CustomTest] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let subtitle = String(cString: sqlite3_column_text(stmt, 2))
            let icon = String(cString: sqlite3_column_text(stmt, 3))
            let categoryStr = String(cString: sqlite3_column_text(stmt, 4))
            let systemPrompt = String(cString: sqlite3_column_text(stmt, 5))
            let userPrompt = String(cString: sqlite3_column_text(stmt, 6))
            let notes = columnTextOrNil(stmt, 7) ?? ""
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            let category = TestCategory(rawValue: categoryStr) ?? .webDevelopment

            tests.append(CustomTest(
                id: id,
                title: title,
                subtitle: subtitle,
                icon: icon,
                category: category,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                notes: notes,
                createdAt: createdAt
            ))
        }
        return tests
    }

    func deleteCustomTest(_ id: String) {
        let sql = "DELETE FROM custom_tests WHERE id = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    // MARK: - Helpers

    private func columnTextOrNil(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }
}
