import Foundation
import SQLite3

// MARK: - Browser-owned database helpers
//
// DatabaseManager.swift belongs to the chat-core area; the model browser's
// favorites/notes writes live here so they can report failures (the legacy
// `addFavorite`/`setNotes` ignore `sqlite3_step`'s result).

extension DatabaseManager {
    /// Wait up to this long for a competing writer (another window, the
    /// Agent) instead of failing immediately with SQLITE_BUSY.
    static let busyTimeoutMilliseconds: Int32 = 5_000

    func applyBusyTimeout() {
        guard let db else { return }
        sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds)
    }

    /// Adds or removes a favorite; throws if SQLite did not finish the write.
    func setFavorite(_ modelId: String, _ favorite: Bool) throws {
        if favorite {
            try runChecked("INSERT OR IGNORE INTO favorites (model_id, added_at) VALUES (?, ?);") { stmt in
                Self.bind(stmt, 1, modelId)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            }
        } else {
            try runChecked("DELETE FROM favorites WHERE model_id = ?;") { stmt in
                Self.bind(stmt, 1, modelId)
            }
        }
    }

    /// Upserts notes for any model (favorite or not); throws on failure.
    func saveNotes(_ modelId: String, notes: String) throws {
        try runChecked("""
        INSERT INTO model_notes (model_id, notes) VALUES (?, ?)
        ON CONFLICT(model_id) DO UPDATE SET notes=excluded.notes;
        """) { stmt in
            Self.bind(stmt, 1, modelId)
            Self.bind(stmt, 2, notes)
        }
    }

    private static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func runChecked(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        guard let db else { throw DatabaseManagerError.notAvailable }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw DatabaseManagerError.operationFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseManagerError.operationFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
