import Foundation
import SQLite3

// MARK: - Media-owned persistence (jobs extras, test-result paging, leaderboard)
//
// Kept out of DatabaseManager.swift (owned by chat core). Schema changes here
// are additive columns/tables and never bump user_version.

extension DatabaseManager {
    /// Additive media columns. Called from `createTablesCore` before the
    /// version pragma; idempotent.
    func migrateMediaColumns() throws {
        // The prompt that started a job, so a resumed video keeps it.
        try addColumnIfMissing(table: "jobs", column: "prompt", definition: "TEXT")
        // The saved creation produced from a finished job: set exactly once.
        try addColumnIfMissing(table: "jobs", column: "saved_creation_id", definition: "TEXT")
        // Durable deletion intent commits together with metadata removal, before
        // any unlink. A failed cleanup/acknowledgement leaves this inventory intact.
        try execChecked("""
            CREATE TABLE IF NOT EXISTS asset_deletions (
                checksum TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                PRIMARY KEY(checksum, relative_path)
            );
            CREATE TABLE IF NOT EXISTS asset_library_pins (
                checksum TEXT PRIMARY KEY
            );
            CREATE TABLE IF NOT EXISTS asset_catalog (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                identity TEXT NOT NULL,
                root TEXT
            );
            CREATE TABLE IF NOT EXISTS asset_catalog_origin (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                identity TEXT NOT NULL, version INTEGER NOT NULL, database_path TEXT NOT NULL
            );
            """)
        let origin = try libraryRows("SELECT identity,version,database_path FROM asset_catalog_origin WHERE singleton=1;").first
        let identity: String
        if let origin, UUID(uuidString: origin[0]) != nil, origin[1] == "1", origin[2] == catalogStorageIdentity {
            identity = origin[0]
        } else { identity = UUID().uuidString }
        try libraryExecute("INSERT OR IGNORE INTO asset_catalog(singleton,identity) VALUES (1,?);", [identity])
        try migrateLibraryOwnership()
    }

    // MARK: Asset deletion coordination

    /// Caller holds withAssetReservation across binding and filesystem mutation.
    func bindAssetRoot(_ root: URL) throws -> String {
        let stmt = try checkedAssetStatement("SELECT identity, root FROM asset_catalog WHERE singleton = 1;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let identity = columnTextOrNil(stmt, 0), UUID(uuidString: identity) != nil else {
            throw DatabaseManagerError.operationFailed("Invalid asset catalog identity")
        }
        if let existing = columnTextOrNil(stmt, 1) {
            guard existing == root.path else {
                throw DatabaseManagerError.operationFailed("This asset catalog is already bound to another root")
            }
        } else {
            try assetStatement("UPDATE asset_catalog SET root = ? WHERE singleton = 1;", [root.path])
        }
        let databasePath = storageFileURLs.first?.resolvingSymlinksInPath().standardizedFileURL.path ?? ":memory:"
        return identity + "\n" + databasePath
    }

    func validateAssetAttachment(_ record: AssetRecord) throws {
        guard record.jobID != nil || record.messageID != nil else { return }
        let stmt = try checkedAssetStatement("SELECT root FROM asset_catalog WHERE singleton = 1;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let root = columnTextOrNil(stmt, 0) else {
            throw DatabaseManagerError.operationFailed("Store bytes through AssetStore before attaching metadata")
        }
        try AssetStore(baseDirectory: URL(fileURLWithPath: root), database: self).validateAttachment(record)
    }

    func loadAssetDeletionInventory() throws -> [AssetDeletionEntry] {
        dbLock.lock()
        defer { dbLock.unlock() }
        let stmt = try checkedAssetStatement("SELECT checksum, relative_path FROM asset_deletions ORDER BY checksum, relative_path;")
        defer { sqlite3_finalize(stmt) }
        var result: [AssetDeletionEntry] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                guard let checksum = columnTextOrNil(stmt, 0), let path = columnTextOrNil(stmt, 1) else {
                    throw DatabaseManagerError.operationFailed("Invalid asset deletion inventory")
                }
                result.append(AssetDeletionEntry(checksum: checksum, relativePath: path))
            case SQLITE_DONE: return result
            default: throw DatabaseManagerError.operationFailed(currentError())
            }
        }
    }

    func pinLibraryAsset(checksum: String) throws {
        try assetStatement("INSERT OR IGNORE INTO asset_library_pins(checksum) VALUES (?);", [checksum])
    }

    func journalAssetDeletion(_ entry: AssetDeletionEntry) throws {
        try assetStatement("INSERT INTO asset_deletions(checksum, relative_path) VALUES (?, ?);", [entry.checksum, entry.relativePath])
    }

    func acknowledgeAssetDeletion(_ entry: AssetDeletionEntry) throws {
        try assetStatement("DELETE FROM asset_deletions WHERE checksum = ? AND relative_path = ?;", [entry.checksum, entry.relativePath])
    }

    /// Also check path aliases, not only checksums, before unlinking anything.
    func hasAssetRecord(checksum: String, relativePath: String) throws -> Bool {
        let stmt = try checkedAssetStatement("SELECT 1 FROM assets WHERE checksum = ? OR relative_path = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        Self.bindText(stmt, 1, checksum)
        Self.bindText(stmt, 2, relativePath)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseManagerError.operationFailed(currentError())
        }
    }

    private func checkedAssetStatement(_ sql: String) throws -> OpaquePointer {
        guard let stmt = prepare(sql) else { throw DatabaseManagerError.operationFailed(currentError()) }
        return stmt
    }

    private func assetStatement(_ sql: String, _ values: [String]) throws {
        let stmt = try checkedAssetStatement(sql)
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in values.enumerated() {
            guard Self.bindText(stmt, Int32(offset + 1), value) == SQLITE_OK else {
                throw DatabaseManagerError.operationFailed(currentError())
            }
        }
        try requireDone(stmt)
    }

    // MARK: Job media fields

    /// Compatibility helper for media-only updates. Full lifecycle writes use
    /// `saveJobRecordChecked`, which commits core and media fields together.
    func saveJobMediaFieldsChecked(_ record: JobRecord) throws {
        guard let stmt = prepare("UPDATE jobs SET prompt = ?, saved_creation_id = ? WHERE id = ?;") else {
            throw DatabaseManagerError.operationFailed(currentError())
        }
        defer { sqlite3_finalize(stmt) }
        let textFields: [(Int32, String?)] = [
            (1, record.prompt), (2, record.savedCreationID?.uuidString), (3, record.id.uuidString)
        ]
        for (index, value) in textFields {
            let result = value.map { Self.bindText(stmt, index, $0) } ?? sqlite3_bind_null(stmt, index)
            guard result == SQLITE_OK else { throw DatabaseManagerError.operationFailed(currentError()) }
        }
        try requireDone(stmt)
    }

    /// Legacy enrichment helper. Core job loaders now include these fields;
    /// lifecycle mutations use the checked single-statement loaders instead.
    func withMediaFields(_ records: [JobRecord]) -> [JobRecord] {
        guard !records.isEmpty,
              let stmt = prepare("SELECT id, prompt, saved_creation_id FROM jobs;") else { return records }
        defer { sqlite3_finalize(stmt) }
        var extras: [String: (String?, UUID?)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnTextOrNil(stmt, 0) else { continue }
            extras[id] = (columnTextOrNil(stmt, 1), columnTextOrNil(stmt, 2).flatMap(UUID.init(uuidString:)))
        }
        return records.map { record in
            var copy = record
            if let extra = extras[record.id.uuidString] {
                copy.prompt = extra.0
                copy.savedCreationID = extra.1
            }
            return copy
        }
    }

    func withMediaFields(_ record: JobRecord?) -> JobRecord? {
        record.flatMap { withMediaFields([$0]).first }
    }

    // MARK: Test results paging

    /// Total number of stored test results (the loader shows at most 200).
    func countTestResults() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM test_results;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Every stored test result, newest first (no LIMIT). Rows are read with
    /// the same decoding as `loadTestResults`.
    func loadAllTestResults() -> [TestRunResult] {
        let sql = """
        SELECT id, scenario_id, scenario_title, category, model_id, response,
               prompt_tokens, completion_tokens, total_tokens, cost, latency_ms,
               success, error_message, output_path, timestamp
        FROM test_results ORDER BY timestamp DESC;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [TestRunResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let category = TestCategory(rawValue: columnTextOrNil(stmt, 3) ?? "") ?? .webDevelopment
            results.append(TestRunResult(
                id: UUID(uuidString: columnTextOrNil(stmt, 0) ?? "") ?? UUID(),
                scenarioId: columnTextOrNil(stmt, 1) ?? "",
                scenarioTitle: columnTextOrNil(stmt, 2) ?? "",
                category: category,
                modelId: columnTextOrNil(stmt, 4) ?? "",
                response: columnTextOrNil(stmt, 5) ?? "",
                promptTokens: Int(sqlite3_column_int(stmt, 6)),
                completionTokens: Int(sqlite3_column_int(stmt, 7)),
                totalTokens: Int(sqlite3_column_int(stmt, 8)),
                cost: sqlite3_column_double(stmt, 9),
                latencyMs: Int(sqlite3_column_int(stmt, 10)),
                success: sqlite3_column_int(stmt, 11) == 1,
                errorMessage: columnTextOrNil(stmt, 12),
                outputPath: columnTextOrNil(stmt, 13),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
            ))
        }
        return results
    }

    // MARK: Leaderboard source rows

    /// Lightweight scalar rows from `experiment_runs` (no JSON decoding) for
    /// the per-model leaderboard.
    func loadExperimentRunSummaries() -> [ExperimentRunSummary] {
        let sql = """
        SELECT model_id, verdict, started_at, finished_at, known_cost
        FROM experiment_runs ORDER BY started_at DESC;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ExperimentRunSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let started = sqlite3_column_double(stmt, 2)
            let finished = sqlite3_column_double(stmt, 3)
            rows.append(ExperimentRunSummary(
                modelID: columnTextOrNil(stmt, 0) ?? "",
                verdict: columnTextOrNil(stmt, 1) ?? "",
                latencySeconds: max(0, finished - started),
                knownCost: columnDoubleOrNil(stmt, 4)
            ))
        }
        return rows
    }
}

/// Scalar projection of one `experiment_runs` row.
struct ExperimentRunSummary: Equatable, Sendable {
    var modelID: String
    var verdict: String
    var latencySeconds: Double
    var knownCost: Double?
}
