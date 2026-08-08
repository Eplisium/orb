import Foundation
import SQLite3

final class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("OpenRouterBrowser", isDirectory: true)
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
}
