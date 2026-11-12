import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Job read failures", .serialized)
@MainActor
struct JobReadFailureTests {
    private func denyRead(_ column: String, database: DatabaseManager, action: () -> Void) {
        var requestedColumn = column
        withUnsafeMutablePointer(to: &requestedColumn) { context in
            sqlite3_set_authorizer(database.db, { context, operation, table, column, _, _ in
                guard operation == SQLITE_READ, let context, let table, let column,
                      String(cString: table) == "jobs",
                      String(cString: column) == context.assumingMemoryBound(to: String.self).pointee
                else { return SQLITE_OK }
                return SQLITE_DENY
            }, context)
            defer { sqlite3_set_authorizer(database.db, nil, nil) }
            action()
        }
    }

    @Test("Failed job reads never erase recovery metadata or overwrite state", arguments: ["prompt", "polling_state"])
    func readFailurePreservesRecord(column: String) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let original = try #require(controller.recordVideoSubmission(
            remoteID: "job-read-failure", modelID: "test/model", remoteStatus: "queued", prompt: "original prompt"
        ))
        let creationID = UUID()
        controller.recordSavedCreation(remoteID: "job-read-failure", creationID: creationID)
        denyRead(column, database: database) {
            controller.recordStoppedLocally(remoteID: "job-read-failure")
            #expect(controller.lastPersistenceError != nil)
        }
        let restored = try #require(JobController(database: database).record(id: original.id))
        #expect(restored.prompt == "original prompt")
        #expect(restored.savedCreationID == creationID)
        #expect(restored.pollingState == .polling)
        controller.recordStoppedLocally(remoteID: "job-read-failure")
        #expect(controller.record(id: original.id)?.pollingState == .stoppedLocally)
        #expect(controller.lastPersistenceError == nil)
    }

    @Test("Checked job reads preserve legacy NULL, empty and Unicode prompts")
    func promptCompatibility() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        for prompt: String? in [nil, "", "before\u{0}e\u{301} 🧪 after"] {
            let remoteID = UUID().uuidString
            let original = try #require(controller.recordVideoSubmission(
                remoteID: remoteID, modelID: "test/model", remoteStatus: "queued", prompt: prompt
            ))
            let loaded = try #require(try database.findJobRecordChecked(id: original.id))
            #expect(loaded.prompt?.utf8.map { $0 } == prompt?.utf8.map { $0 })
            #expect(loaded.savedCreationID == nil)
            #expect(loaded.conversationID == nil)
            #expect(loaded.messageID == nil)
        }
        #expect(try database.loadJobRecordsChecked().count == 3)
    }

    @Test("Link mutations stop after failed job reads", arguments: [false, true])
    func readFailurePreservesLinks(clearExisting: Bool) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(remoteID: "job-link", modelID: "test/model", remoteStatus: "completed")
        let savedID = UUID()
        if clearExisting { controller.recordSavedCreation(remoteID: "job-link", creationID: savedID) }
        denyRead("saved_creation_id", database: database) {
            if clearExisting { controller.clearSavedCreation(remoteID: "job-link") }
            else { controller.recordSavedCreation(remoteID: "job-link", creationID: savedID) }
            #expect(controller.lastPersistenceError != nil)
        }
        let loaded = try #require(controller.record(remoteID: "job-link"))
        #expect(loaded.savedCreationID == (clearExisting ? savedID : nil))
        #expect(loaded.pollingState == .completed)
    }

    @Test("Malformed required fields prevent partial launch recovery", arguments: ["id", "submission_state", "polling_state"])
    func malformedRequiredFieldsStopRecovery(column: String) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(remoteID: "job-valid", modelID: "test/model", remoteStatus: "queued")
        _ = controller.recordVideoSubmission(remoteID: "job-invalid", modelID: "test/model", remoteStatus: "queued")
        try database.execChecked("UPDATE jobs SET created_at = CASE WHEN remote_id = 'job-valid' THEN 2 ELSE 1 END;")
        try database.execChecked("UPDATE jobs SET \(column) = 'broken' WHERE remote_id = 'job-invalid';")
        #expect(throws: Error.self) { try database.loadJobRecordsChecked() }
        #expect(controller.demoteInterruptedPolls() == 0)
        #expect(controller.lastPersistenceError != nil)
        #expect(try database.findJobRecordChecked(remoteID: "job-valid")?.pollingState == .polling)
    }

    @Test("Failed lookup parameter binding cannot be treated as an absent job")
    func failedParameterBindingStopsSubmission() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let previousLimit = sqlite3_limit(database.db, SQLITE_LIMIT_LENGTH, 1024)
        defer { sqlite3_limit(database.db, SQLITE_LIMIT_LENGTH, previousLimit) }
        let remoteID = String(repeating: "x", count: 2048)
        #expect(throws: Error.self) { try database.findJobRecordChecked(remoteID: remoteID) }
        #expect(controller.recordVideoSubmission(remoteID: remoteID, modelID: "test/model", remoteStatus: "queued") == nil)
        #expect(controller.lastPersistenceError != nil)
        let count = try #require(database.prepare("SELECT COUNT(*) FROM jobs;"))
        defer { sqlite3_finalize(count) }
        #expect(sqlite3_step(count) == SQLITE_ROW)
        #expect(sqlite3_column_int(count, 0) == 0)
    }

    @Test("Malformed optional job identities cannot be rewritten as absent", arguments: ["saved_creation_id", "conversation_id", "message_id"])
    func malformedIdentityStopsMutation(column: String) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(remoteID: "job-malformed", modelID: "test/model", remoteStatus: "queued")
        // Column is one of the fixed test cases above, not external input.
        try database.execChecked("UPDATE jobs SET \(column) = 'invalid-id';")
        controller.recordStoppedLocally(remoteID: "job-malformed")
        #expect(controller.lastPersistenceError != nil)
        let statement = try #require(database.prepare("SELECT \(column), polling_state FROM jobs;"))
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(database.columnTextOrNil(statement, 0) == "invalid-id")
        #expect(database.columnTextOrNil(statement, 1) == "polling")
    }

    @Test("A mid-iteration job read error cannot return a partial recovery inventory")
    func partialInventoryStopsRecovery() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(remoteID: "job-first", modelID: "test/model", remoteStatus: "queued", prompt: "safe")
        _ = controller.recordVideoSubmission(remoteID: "job-fault", modelID: "test/model", remoteStatus: "queued", prompt: "fault")
        try database.execChecked("UPDATE jobs SET created_at = CASE WHEN remote_id = 'job-first' THEN 2 ELSE 1 END;")
        try database.execChecked("ALTER TABLE jobs RENAME TO stored_jobs;")
        try database.execChecked("""
            CREATE VIEW jobs AS SELECT id, remote_id, kind, submission_state, polling_state, remote_status,
            conversation_id, message_id, model_id, usage_cost, recoverable_error, created_at, updated_at,
            CASE WHEN prompt = 'fault' THEN abs(-9223372036854775808) ELSE prompt END AS prompt,
            saved_creation_id FROM stored_jobs;
            """)
        // Force index-order delivery so the first row is observable before the fault.
        try database.execChecked("CREATE INDEX stored_jobs_created ON stored_jobs(created_at DESC);")
        let probe = try #require(database.prepare("SELECT prompt FROM jobs ORDER BY created_at DESC;"))
        #expect(sqlite3_step(probe) == SQLITE_ROW)
        #expect(sqlite3_step(probe) == SQLITE_ERROR)
        sqlite3_finalize(probe)
        #expect(controller.allJobs().isEmpty)
        #expect(controller.lastPersistenceError != nil)
        #expect(controller.demoteInterruptedPolls() == 0)
        let count = try #require(database.prepare("SELECT COUNT(*) FROM stored_jobs WHERE polling_state = 'polling';"))
        defer { sqlite3_finalize(count) }
        #expect(sqlite3_step(count) == SQLITE_ROW)
        #expect(sqlite3_column_int(count, 0) == 2)
    }

    @Test("Failed submission lookups cannot masquerade as a new remote job", arguments: ["prompt", "polling_state"])
    func failedLookupCannotDuplicateSubmission(column: String) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let original = try #require(controller.recordVideoSubmission(
            remoteID: "job-repeat", modelID: "test/model", remoteStatus: "queued", prompt: "keep prompt"
        ))
        denyRead(column, database: database) {
            let result = controller.recordVideoSubmission(
                remoteID: "job-repeat", modelID: "test/model", remoteStatus: "completed", prompt: "replacement"
            )
            #expect(result == nil)
            #expect(controller.lastPersistenceError != nil)
        }
        let records = controller.allJobs()
        #expect(records.count == 1)
        #expect(records.first?.id == original.id)
        #expect(records.first?.prompt == "keep prompt")
        #expect(records.first?.pollingState == .polling)
    }
}
