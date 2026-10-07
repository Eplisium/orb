import Foundation
import SQLite3

// MARK: - Media-owned persistence (jobs extras, test-result paging, leaderboard)
//
// Kept out of DatabaseManager.swift (owned by chat core). Schema changes here
// are additive `addColumnIfMissing` calls only and never bump user_version.

extension DatabaseManager {
    private static let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Additive media columns. Called from `createTablesCore` before the
    /// version pragma; idempotent.
    func migrateMediaColumns() throws {
        // The prompt that started a job, so a resumed video keeps it.
        try addColumnIfMissing(table: "jobs", column: "prompt", definition: "TEXT")
        // The saved creation produced from a finished job: set exactly once.
        try addColumnIfMissing(table: "jobs", column: "saved_creation_id", definition: "TEXT")
    }

    // MARK: Job media fields

    /// Writes the media-only fields of a job record. Run after
    /// `saveJobRecordChecked`, which persists the core columns.
    func saveJobMediaFieldsChecked(_ record: JobRecord) throws {
        guard let stmt = prepare("UPDATE jobs SET prompt = ?, saved_creation_id = ? WHERE id = ?;") else {
            throw DatabaseManagerError.operationFailed(currentError())
        }
        defer { sqlite3_finalize(stmt) }
        let t = Self.transientText
        if let prompt = record.prompt { sqlite3_bind_text(stmt, 1, prompt, -1, t) } else { sqlite3_bind_null(stmt, 1) }
        if let saved = record.savedCreationID { sqlite3_bind_text(stmt, 2, saved.uuidString, -1, t) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_text(stmt, 3, record.id.uuidString, -1, t)
        try requireDone(stmt)
    }

    /// Fills `prompt` / `savedCreationID` on records loaded through the core
    /// loaders (which don't know about the media columns).
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
