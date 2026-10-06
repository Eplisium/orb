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
            parts_json TEXT,
            images_json TEXT,
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
            // Phase D: durable agent memories for remember/recall.
            try execChecked("""
            CREATE TABLE IF NOT EXISTS agent_memories (
                id TEXT PRIMARY KEY,
                content TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """)
            try addColumnIfMissing(table: "messages", column: "status", definition: "TEXT NOT NULL DEFAULT 'complete'")
            try addColumnIfMissing(table: "messages", column: "finish_reason", definition: "TEXT")
            try addColumnIfMissing(table: "messages", column: "error_message", definition: "TEXT")
            // A1: multimodal persistence — attachment wire parts + generated images.
            try addColumnIfMissing(table: "messages", column: "parts_json", definition: "TEXT")
            try addColumnIfMissing(table: "messages", column: "images_json", definition: "TEXT")
            // W05/F07: structured reasoning blocks (`reasoning_details`), kept
            // separately from the display `reasoning` summary so opaque
            // signature/encrypted payloads survive restarts byte-exact.
            try addColumnIfMissing(table: "messages", column: "reasoning_details_json", definition: "TEXT")
            // Displayable reasoning is independent of opaque wire details. Keep
            // it when reopening a conversation instead of losing the disclosure.
            try addColumnIfMissing(table: "messages", column: "reasoning", definition: "TEXT")
            try addColumnIfMissing(table: "messages", column: "reasoning_started_at", definition: "REAL")
            try addColumnIfMissing(table: "messages", column: "reasoning_duration_seconds", definition: "REAL")
            try addColumnIfMissing(table: "messages", column: "transcript_json", definition: "TEXT")
            // W06: durable media jobs and assets. Additive migrations only —
            // existing tables are never altered or dropped and legacy rows
            // keep loading.
            try execChecked("""
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                remote_id TEXT,
                kind TEXT NOT NULL,
                submission_state TEXT NOT NULL,
                polling_state TEXT NOT NULL,
                remote_status TEXT,
                conversation_id TEXT,
                message_id TEXT,
                model_id TEXT,
                usage_cost REAL,
                recoverable_error TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
            try execChecked("CREATE INDEX IF NOT EXISTS idx_jobs_remote_id ON jobs(remote_id);")
            try execChecked("""
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                relative_path TEXT NOT NULL,
                remote_reference TEXT,
                mime_type TEXT,
                size_bytes INTEGER NOT NULL,
                checksum TEXT NOT NULL,
                job_id TEXT,
                message_id TEXT,
                retention TEXT NOT NULL DEFAULT 'keep',
                created_at REAL NOT NULL
            );
            """)
            try execChecked("CREATE INDEX IF NOT EXISTS idx_assets_checksum ON assets(checksum);")
            // W12/F10: durable experiment run records. The full Codable
            // record is stored as JSON (record_json) so nested artifact
            // checks, assertions, and spend round-trip losslessly; scalar
            // columns exist for ordering and future filtering. Additive
            // migration only — existing tables are never altered.
            try execChecked("""
            CREATE TABLE IF NOT EXISTS experiment_runs (
                id TEXT PRIMARY KEY,
                scenario_id TEXT NOT NULL,
                scenario_title TEXT NOT NULL,
                scenario_version INTEGER NOT NULL DEFAULT 1,
                category TEXT NOT NULL,
                model_id TEXT NOT NULL,
                completion_status TEXT NOT NULL,
                verdict TEXT NOT NULL,
                prompt_tokens INTEGER,
                completion_tokens INTEGER,
                total_tokens INTEGER,
                known_cost REAL,
                started_at REAL NOT NULL,
                finished_at REAL NOT NULL,
                record_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """)
            try execChecked("CREATE INDEX IF NOT EXISTS idx_experiment_runs_started ON experiment_runs(started_at);")
            // Permanent, append-only usage/cost ledger. Rows are never deleted
            // or rewritten (INSERT OR IGNORE on a stable event id), so lifetime
            // totals survive conversation/creation deletion. cost is NULL when
            // the provider did not report one — unknown is never stored as $0.
            try execChecked("""
            CREATE TABLE IF NOT EXISTS usage_events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                feature TEXT NOT NULL,
                model_id TEXT NOT NULL,
                cost REAL,
                prompt_tokens INTEGER,
                completion_tokens INTEGER,
                total_tokens INTEGER,
                requests INTEGER NOT NULL DEFAULT 1
            );
            """)
            try execChecked("CREATE INDEX IF NOT EXISTS idx_usage_events_ts ON usage_events(timestamp);")
            try execChecked("PRAGMA user_version=6;")
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

    // MARK: - Usage ledger

    /// Appends one usage event. Duplicate ids are ignored, so a retried or
    /// re-delivered completion can never double count.
    @discardableResult
    func insertUsageEvent(_ event: UsageEvent) -> Bool {
        let sql = """
        INSERT OR IGNORE INTO usage_events
        (id, timestamp, feature, model_id, cost, prompt_tokens, completion_tokens, total_tokens, requests)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, event.id, -1, transient)
        sqlite3_bind_double(stmt, 2, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, event.feature, -1, transient)
        sqlite3_bind_text(stmt, 4, event.modelID, -1, transient)
        if let cost = event.cost { sqlite3_bind_double(stmt, 5, cost) } else { sqlite3_bind_null(stmt, 5) }
        for (index, value) in [event.promptTokens, event.completionTokens, event.totalTokens].enumerated() {
            if let value { sqlite3_bind_int64(stmt, Int32(6 + index), Int64(value)) } else { sqlite3_bind_null(stmt, Int32(6 + index)) }
        }
        sqlite3_bind_int64(stmt, 9, Int64(event.requests))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Aggregates the ledger. `grouping` is a closed enum, never caller SQL.
    func usageBuckets(_ grouping: UsageGrouping, since: Date? = nil) -> [UsageBucket] {
        let sql = """
        SELECT \(grouping.expression) AS k,
               COALESCE(SUM(cost), 0), SUM(requests),
               COALESCE(SUM(total_tokens), 0),
               COALESCE(SUM(CASE WHEN cost IS NULL THEN requests ELSE 0 END), 0)
        FROM usage_events
        WHERE timestamp >= ?
        GROUP BY k ORDER BY \(grouping.order);
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since?.timeIntervalSince1970 ?? 0)
        var rows: [UsageBucket] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "Unknown"
            rows.append(UsageBucket(key: key, cost: sqlite3_column_double(stmt, 1),
                                    requests: Int(sqlite3_column_int64(stmt, 2)),
                                    tokens: Int(sqlite3_column_int64(stmt, 3)),
                                    unpricedRequests: Int(sqlite3_column_int64(stmt, 4))))
        }
        return rows
    }

    func usageFirstEventDate() -> Date? {
        guard let stmt = prepare("SELECT MIN(timestamp) FROM usage_events;") else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
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

    // MARK: - Agent memories (remember/recall)

    func saveMemory(content: String) throws {
        let sql = "INSERT INTO agent_memories (id, content, created_at) VALUES (?, ?, ?);"
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, t)
        sqlite3_bind_text(stmt, 2, content, -1, t)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        try requireDone(stmt)
    }

    /// Case-insensitive substring search, newest first. LIKE wildcards in
    /// the query are escaped so they match literally.
    func searchMemories(query: String, limit: Int = 8) -> [AgentMemory] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let sql = "SELECT id, content, created_at FROM agent_memories WHERE content LIKE ? ESCAPE '\\' ORDER BY created_at DESC LIMIT ?;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%\(escaped)%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(max(limit, 1)))
        var hits: [AgentMemory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let content = columnTextOrNil(stmt, 1) ?? ""
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            hits.append(AgentMemory(id: id, content: content, createdAt: createdAt))
        }
        return hits
    }

    func deleteMemory(id: String) throws {
        let sql = "DELETE FROM agent_memories WHERE id = ?;"
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        try requireDone(stmt)
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

    /// Incremental save: conversation row + the given message rows only, in
    /// one transaction. Other message rows are left untouched.
    func saveConversationMessagesChecked(
        _ conv: ChatConversation, agentHistoryJSON: String,
        messages: [(message: ChatMessage, sortOrder: Int)]
    ) throws {
        try execChecked("BEGIN IMMEDIATE;")
        do {
            try saveConversationChecked(conv, agentHistoryJSON: agentHistoryJSON)
            for row in messages {
                try saveMessageChecked(row.message, conversationId: conv.id, sortOrder: row.sortOrder)
            }
            try execChecked("COMMIT;")
        } catch {
            try? execChecked("ROLLBACK;")
            throw error
        }
    }

    /// All conversations, or only one mode's (each playground service loads
    /// just its own sessions and their messages).
    func loadConversations(mode: PlaygroundMode? = nil) -> [(conversation: ChatConversation, agentHistoryJSON: String)] {
        let sql = mode == nil
            ? "SELECT * FROM conversations ORDER BY created_at DESC;"
            : "SELECT * FROM conversations WHERE mode = ? ORDER BY created_at DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let mode {
            sqlite3_bind_text(stmt, 1, mode.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
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
        (id, conversation_id, role, content, tool_calls_json, tool_call_id, tool_name, sort_order, created_at, status, finish_reason, error_message, parts_json, images_json, reasoning_details_json, reasoning, reasoning_started_at, reasoning_duration_seconds, transcript_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        if let parts = message.parts, !parts.isEmpty,
           let data = try? JSONEncoder().encode(parts),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 13, json, -1, t)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        if let images = message.images, !images.isEmpty,
           let data = try? JSONEncoder().encode(images),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 14, json, -1, t)
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        if let details = message.reasoningDetails, !details.isEmpty,
           let data = try? JSONEncoder().encode(details),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 15, json, -1, t)
        } else {
            sqlite3_bind_null(stmt, 15)
        }
        if let reasoning = message.reasoning {
            sqlite3_bind_text(stmt, 16, reasoning, -1, t)
        } else {
            sqlite3_bind_null(stmt, 16)
        }
        if let startedAt = message.reasoningStartedAt {
            sqlite3_bind_double(stmt, 17, startedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 17)
        }
        if let duration = message.reasoningDuration {
            sqlite3_bind_double(stmt, 18, duration)
        } else {
            sqlite3_bind_null(stmt, 18)
        }
        if let transcript = message.transcript {
            let data = try JSONEncoder().encode(transcript)
            sqlite3_bind_text(stmt, 19, String(decoding: data, as: UTF8.self), -1, t)
        } else {
            sqlite3_bind_null(stmt, 19)
        }
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
            let partsJSON = columnTextOrNil(stmt, 12)
            let imagesJSON = columnTextOrNil(stmt, 13)
            // Resolved by name: legacy databases gain the column via ALTER
            // TABLE, so its position depends on the schema vintage.
            let reasoningDetailsJSON = columnTextOrNil(stmt, columnIndex(stmt, "reasoning_details_json"))
            let reasoning = columnTextOrNil(stmt, columnIndex(stmt, "reasoning"))
            let startedAtValue = columnDoubleOrNil(stmt, columnIndex(stmt, "reasoning_started_at"))
            let reasoningDuration = columnDoubleOrNil(stmt, columnIndex(stmt, "reasoning_duration_seconds"))

            var toolCalls: [ToolCallDisplay]? = nil
            if let json = toolCallsJSON, let data = json.data(using: .utf8) {
                toolCalls = try? JSONDecoder().decode([ToolCallDisplay].self, from: data)
            }
            var parts: [MessageContentPart]? = nil
            if let json = partsJSON, let data = json.data(using: .utf8) {
                parts = try? JSONDecoder().decode([MessageContentPart].self, from: data)
            }
            var images: [ChatImageAttachment]? = nil
            if let json = imagesJSON, let data = json.data(using: .utf8) {
                images = try? JSONDecoder().decode([ChatImageAttachment].self, from: data)
            }
            var reasoningDetails: [ReasoningDetail]? = nil
            if let json = reasoningDetailsJSON, let data = json.data(using: .utf8) {
                reasoningDetails = try? JSONDecoder().decode([ReasoningDetail].self, from: data)
            }

            guard let id = UUID(uuidString: idStr) else { continue }
            let msg = ChatMessage(
                id: id, role: role, content: content, parts: parts, images: images,
                toolCalls: toolCalls,
                toolCallId: toolCallId, toolName: toolName, status: status,
                finishReason: finishReason, errorMessage: errorMessage,
                reasoning: reasoning,
                reasoningStartedAt: startedAtValue.map(Date.init(timeIntervalSince1970:)),
                reasoningDuration: reasoningDuration,
                reasoningDetails: reasoningDetails,
                transcript: columnTextOrNil(stmt, columnIndex(stmt, "transcript_json"))
                    .flatMap { try? JSONDecoder().decode([MessageTranscriptSegment].self, from: Data($0.utf8)) }
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

    // MARK: - Jobs (durable media job records)

    func saveJobRecordChecked(_ record: JobRecord) throws {
        let sql = """
        INSERT INTO jobs
        (id, remote_id, kind, submission_state, polling_state, remote_status,
         conversation_id, message_id, model_id, usage_cost, recoverable_error,
         created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            remote_id=excluded.remote_id, kind=excluded.kind,
            submission_state=excluded.submission_state,
            polling_state=excluded.polling_state, remote_status=excluded.remote_status,
            conversation_id=excluded.conversation_id, message_id=excluded.message_id,
            model_id=excluded.model_id, usage_cost=excluded.usage_cost,
            recoverable_error=excluded.recoverable_error, updated_at=excluded.updated_at;
        """
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, t)
        if let remoteID = record.remoteID { sqlite3_bind_text(stmt, 2, remoteID, -1, t) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_text(stmt, 3, record.kind, -1, t)
        sqlite3_bind_text(stmt, 4, record.submissionState.rawValue, -1, t)
        sqlite3_bind_text(stmt, 5, record.pollingState.rawValue, -1, t)
        if let status = record.lastRemoteStatus { sqlite3_bind_text(stmt, 6, status, -1, t) } else { sqlite3_bind_null(stmt, 6) }
        if let conversationID = record.conversationID { sqlite3_bind_text(stmt, 7, conversationID.uuidString, -1, t) } else { sqlite3_bind_null(stmt, 7) }
        if let messageID = record.messageID { sqlite3_bind_text(stmt, 8, messageID.uuidString, -1, t) } else { sqlite3_bind_null(stmt, 8) }
        if let modelID = record.modelID { sqlite3_bind_text(stmt, 9, modelID, -1, t) } else { sqlite3_bind_null(stmt, 9) }
        if let cost = record.usageCost { sqlite3_bind_double(stmt, 10, cost) } else { sqlite3_bind_null(stmt, 10) }
        if let error = record.recoverableError { sqlite3_bind_text(stmt, 11, error, -1, t) } else { sqlite3_bind_null(stmt, 11) }
        sqlite3_bind_double(stmt, 12, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 13, record.updatedAt.timeIntervalSince1970)
        try requireDone(stmt)
    }

    func loadJobRecords() -> [JobRecord] {
        let sql = """
        SELECT id, remote_id, kind, submission_state, polling_state, remote_status,
               conversation_id, message_id, model_id, usage_cost, recoverable_error,
               created_at, updated_at
        FROM jobs ORDER BY created_at DESC;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var records: [JobRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = jobRecord(from: stmt) { records.append(record) }
        }
        return records
    }

    func findJobRecord(id: UUID) -> JobRecord? {
        let sql = """
        SELECT id, remote_id, kind, submission_state, polling_state, remote_status,
               conversation_id, message_id, model_id, usage_cost, recoverable_error,
               created_at, updated_at
        FROM jobs WHERE id = ?;
        """
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return jobRecord(from: stmt)
    }

    func findJobRecord(remoteID: String) -> JobRecord? {
        let sql = """
        SELECT id, remote_id, kind, submission_state, polling_state, remote_status,
               conversation_id, message_id, model_id, usage_cost, recoverable_error,
               created_at, updated_at
        FROM jobs WHERE remote_id = ? ORDER BY created_at DESC LIMIT 1;
        """
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, remoteID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return jobRecord(from: stmt)
    }

    private func jobRecord(from stmt: OpaquePointer) -> JobRecord? {
        guard let idStr = columnTextOrNil(stmt, 0), let id = UUID(uuidString: idStr),
              let kind = columnTextOrNil(stmt, 2),
              let submissionRaw = columnTextOrNil(stmt, 3),
              let submissionState = JobSubmissionState(rawValue: submissionRaw),
              let pollingRaw = columnTextOrNil(stmt, 4),
              let pollingState = JobPollingState(rawValue: pollingRaw)
        else { return nil }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        return JobRecord(
            id: id,
            remoteID: columnTextOrNil(stmt, 1),
            kind: kind,
            submissionState: submissionState,
            pollingState: pollingState,
            lastRemoteStatus: columnTextOrNil(stmt, 5),
            conversationID: columnTextOrNil(stmt, 6).flatMap(UUID.init(uuidString:)),
            messageID: columnTextOrNil(stmt, 7).flatMap(UUID.init(uuidString:)),
            modelID: columnTextOrNil(stmt, 8),
            usageCost: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9),
            recoverableError: columnTextOrNil(stmt, 10),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Assets (durable asset metadata)

    func saveAssetRecordChecked(_ record: AssetRecord) throws {
        let sql = """
        INSERT INTO assets
        (id, relative_path, remote_reference, mime_type, size_bytes, checksum,
         job_id, message_id, retention, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            relative_path=excluded.relative_path, remote_reference=excluded.remote_reference,
            mime_type=excluded.mime_type, size_bytes=excluded.size_bytes,
            checksum=excluded.checksum, job_id=excluded.job_id,
            message_id=excluded.message_id, retention=excluded.retention;
        """
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, t)
        sqlite3_bind_text(stmt, 2, record.relativePath, -1, t)
        if let remote = record.remoteReference { sqlite3_bind_text(stmt, 3, remote, -1, t) } else { sqlite3_bind_null(stmt, 3) }
        if let mime = record.mimeType { sqlite3_bind_text(stmt, 4, mime, -1, t) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_int64(stmt, 5, Int64(record.sizeBytes))
        sqlite3_bind_text(stmt, 6, record.checksum, -1, t)
        if let jobID = record.jobID { sqlite3_bind_text(stmt, 7, jobID.uuidString, -1, t) } else { sqlite3_bind_null(stmt, 7) }
        if let messageID = record.messageID { sqlite3_bind_text(stmt, 8, messageID.uuidString, -1, t) } else { sqlite3_bind_null(stmt, 8) }
        sqlite3_bind_text(stmt, 9, record.retention.rawValue, -1, t)
        sqlite3_bind_double(stmt, 10, record.createdAt.timeIntervalSince1970)
        try requireDone(stmt)
    }

    /// Removes metadata rows for a checksum. Rows tied to a job or message are left alone.
    func deleteUnattachedAssetRecords(checksum: String) throws {
        let sql = "DELETE FROM assets WHERE checksum = ? AND job_id IS NULL AND message_id IS NULL;"
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, checksum, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        try requireDone(stmt)
    }

    func hasAttachedAssetRecord(checksum: String) -> Bool {
        let sql = "SELECT 1 FROM assets WHERE checksum = ? AND (job_id IS NOT NULL OR message_id IS NOT NULL) LIMIT 1;"
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, checksum, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func loadAssetRecords() -> [AssetRecord] {
        let sql = """
        SELECT id, relative_path, remote_reference, mime_type, size_bytes, checksum,
               job_id, message_id, retention, created_at
        FROM assets ORDER BY created_at DESC;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var records: [AssetRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = assetRecord(from: stmt) { records.append(record) }
        }
        return records
    }

    func findAssetRecord(checksum: String) -> AssetRecord? {
        let sql = """
        SELECT id, relative_path, remote_reference, mime_type, size_bytes, checksum,
               job_id, message_id, retention, created_at
        FROM assets WHERE checksum = ? ORDER BY created_at ASC LIMIT 1;
        """
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, checksum, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return assetRecord(from: stmt)
    }

    private func assetRecord(from stmt: OpaquePointer) -> AssetRecord? {
        guard let idStr = columnTextOrNil(stmt, 0), let id = UUID(uuidString: idStr),
              let relativePath = columnTextOrNil(stmt, 1),
              let checksum = columnTextOrNil(stmt, 5),
              let retentionRaw = columnTextOrNil(stmt, 8),
              let retention = AssetRetention(rawValue: retentionRaw)
        else { return nil }
        return AssetRecord(
            id: id,
            relativePath: relativePath,
            remoteReference: columnTextOrNil(stmt, 2),
            mimeType: columnTextOrNil(stmt, 3),
            sizeBytes: Int(sqlite3_column_int64(stmt, 4)),
            checksum: checksum,
            jobID: columnTextOrNil(stmt, 6).flatMap(UUID.init(uuidString:)),
            messageID: columnTextOrNil(stmt, 7).flatMap(UUID.init(uuidString:)),
            retention: retention,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        )
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
            md += "\(label):\n\n\(msg.content)\n"
            if let parts = msg.parts, !parts.isEmpty {
                md += "\n*Attachments: \(parts.count) file(s) — see app to view.*\n"
            }
            if let images = msg.images, !images.isEmpty {
                for (index, image) in images.enumerated() {
                    // Remote URLs embed directly; data URLs would bloat the
                    // file, so reference them by position instead.
                    if image.isRemoteURL {
                        md += "\n![generated image \(index + 1)](\(image.dataURL))\n"
                    } else {
                        md += "\n*[generated image \(index + 1): embedded \(image.mimeType), see app to view]*\n"
                    }
                }
            }
            md += "\n---\n\n"
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

    // MARK: - Experiment Run Records (W12)

    func saveExperimentRunRecord(_ record: ExperimentRunRecord) {
        do {
            try saveExperimentRunRecordChecked(record)
        } catch {
            // A failed experiment-record write must never break a run that
            // just finished; the in-memory result still reaches the UI.
        }
    }

    func saveExperimentRunRecordChecked(_ record: ExperimentRunRecord) throws {
        let json: String
        do {
            let data = try JSONEncoder().encode(record)
            json = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw DatabaseManagerError.operationFailed("Could not encode experiment record: \(error.localizedDescription)")
        }
        let sql = """
        INSERT OR REPLACE INTO experiment_runs
        (id, scenario_id, scenario_title, scenario_version, category, model_id,
         completion_status, verdict, prompt_tokens, completion_tokens, total_tokens,
         known_cost, started_at, finished_at, record_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        defer { sqlite3_finalize(stmt) }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, t)
        sqlite3_bind_text(stmt, 2, record.scenarioID, -1, t)
        sqlite3_bind_text(stmt, 3, record.scenarioTitle, -1, t)
        sqlite3_bind_int(stmt, 4, Int32(record.scenarioVersion))
        sqlite3_bind_text(stmt, 5, record.categoryRawValue, -1, t)
        sqlite3_bind_text(stmt, 6, record.modelID, -1, t)
        sqlite3_bind_text(stmt, 7, record.completionStatus.rawValue, -1, t)
        sqlite3_bind_text(stmt, 8, record.verdict.rawValue, -1, t)
        if let v = record.spend.promptTokens { sqlite3_bind_int(stmt, 9, Int32(v)) } else { sqlite3_bind_null(stmt, 9) }
        if let v = record.spend.completionTokens { sqlite3_bind_int(stmt, 10, Int32(v)) } else { sqlite3_bind_null(stmt, 10) }
        if let v = record.spend.totalTokens { sqlite3_bind_int(stmt, 11, Int32(v)) } else { sqlite3_bind_null(stmt, 11) }
        if let v = record.spend.knownCostUSD { sqlite3_bind_double(stmt, 12, v) } else { sqlite3_bind_null(stmt, 12) }
        sqlite3_bind_double(stmt, 13, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 14, record.finishedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 15, json, -1, t)
        sqlite3_bind_double(stmt, 16, Date().timeIntervalSince1970)
        try requireDone(stmt)
    }

    func loadExperimentRunRecords() -> [ExperimentRunRecord] {
        let sql = "SELECT record_json FROM experiment_runs ORDER BY started_at DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var records: [ExperimentRunRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let json = columnTextOrNil(stmt, 0),
                  let data = json.data(using: .utf8)
            else { continue }
            if let record = try? JSONDecoder().decode(ExperimentRunRecord.self, from: data) {
                records.append(record)
            }
        }
        return records
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
        if index < 0 { return nil }
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func columnDoubleOrNil(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        guard index >= 0, sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    /// Zero-based position of a result column by name, or -1 when absent.
    private func columnIndex(_ stmt: OpaquePointer, _ name: String) -> Int32 {
        let count = sqlite3_column_count(stmt)
        for index in 0..<count {
            if let cName = sqlite3_column_name(stmt, index), String(cString: cName) == name {
                return index
            }
        }
        return -1
    }
}
