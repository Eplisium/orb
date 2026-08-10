import Foundation
import SQLite3

final class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ORB", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("favorites.sqlite3").path

        openDatabase()
        createTables()
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            fatalError("Failed to open database: \(msg)")
        }
        exec("PRAGMA journal_mode=WAL;")
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let e = err { sqlite3_free(e) }
        }
    }

    private func createTables() {
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
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
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
        let sql = "SELECT notes FROM favorites WHERE model_id = ?;"
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
        let sql = "UPDATE favorites SET notes = ? WHERE model_id = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, notes, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, modelId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
    }

    deinit {
        sqlite3_close(db)
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
