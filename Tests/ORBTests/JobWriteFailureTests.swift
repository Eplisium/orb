import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Job write failures", .serialized)
@MainActor
struct JobWriteFailureTests {
    @Test("Rejected text binding cannot silently clear a job field", arguments: ["remote", "model", "status", "error", "prompt"])
    func failedBindingPreservesRecord(field: String) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        controller.recordVideoSubmission(remoteID: "binding-job", modelID: "test/model", remoteStatus: "queued", prompt: "original")
        let original = try #require(try database.findJobRecordChecked(remoteID: "binding-job"))
        var changed = original
        let oversized = String(repeating: "x", count: 2048)
        switch field {
        case "remote": changed.remoteID = oversized
        case "model": changed.modelID = oversized
        case "status": changed.lastRemoteStatus = oversized
        case "error": changed.recoverableError = oversized
        default: changed.prompt = oversized
        }
        let previousLimit = sqlite3_limit(database.db, SQLITE_LIMIT_LENGTH, 1024)
        #expect(throws: Error.self) { try database.saveJobRecordChecked(changed) }
        sqlite3_limit(database.db, SQLITE_LIMIT_LENGTH, previousLimit)
        #expect(try database.findJobRecordChecked(id: original.id) == original)
    }

    @Test("Legacy media field writes reject failed bindings without clearing the prompt")
    func legacyMediaBindingPreservesRecord() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        controller.recordVideoSubmission(remoteID: "legacy-binding", modelID: "test/model", remoteStatus: "queued", prompt: "original")
        let original = try #require(try database.findJobRecordChecked(remoteID: "legacy-binding"))
        var changed = original
        changed.prompt = String(repeating: "x", count: 2048)
        let previousLimit = sqlite3_limit(database.db, SQLITE_LIMIT_LENGTH, 1024)
        #expect(throws: Error.self) { try database.saveJobMediaFieldsChecked(changed) }
        sqlite3_limit(database.db, SQLITE_LIMIT_LENGTH, previousLimit)
        #expect(try database.findJobRecordChecked(id: original.id) == original)
    }

    @Test("Core and recovery fields commit together", arguments: [false, true])
    func mediaWriteFailureIsAtomic(existing: Bool) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        if existing {
            controller.recordVideoSubmission(remoteID: "atomic-job", modelID: "test/model", remoteStatus: "queued", prompt: "keep me")
        }
        let original = try database.findJobRecordChecked(remoteID: "atomic-job")
        // The existing-row case reaches the upsert's UPDATE branch. Reject
        // inserts separately for the new-row case, plus the legacy extras write.
        if !existing {
            try database.execChecked("""
                CREATE TRIGGER reject_job_insert BEFORE INSERT ON jobs WHEN NEW.prompt IS NOT NULL
                BEGIN SELECT RAISE(ABORT, 'injected recovery field failure'); END;
                """)
        }
        try database.execChecked("""
            CREATE TRIGGER reject_job_media BEFORE UPDATE OF prompt ON jobs
            BEGIN SELECT RAISE(ABORT, 'injected recovery field failure'); END;
            """)
        if existing {
            controller.recordTerminal(remoteID: "atomic-job", remoteStatus: "completed", error: nil, cost: 0.5)
        } else {
            controller.recordVideoSubmission(remoteID: "atomic-job", modelID: "test/model", remoteStatus: "queued", prompt: "keep me")
        }
        #expect(controller.lastPersistenceError != nil)
        #expect(try database.findJobRecordChecked(remoteID: "atomic-job") == original)
        try database.execChecked("DROP TRIGGER IF EXISTS reject_job_insert; DROP TRIGGER reject_job_media;")
        if existing {
            controller.recordTerminal(remoteID: "atomic-job", remoteStatus: "completed", error: nil, cost: 0.5)
        } else {
            controller.recordVideoSubmission(remoteID: "atomic-job", modelID: "test/model", remoteStatus: "queued", prompt: "keep me")
        }
        let recovered = try #require(try database.findJobRecordChecked(remoteID: "atomic-job"))
        #expect(recovered.prompt == "keep me")
        #expect(recovered.pollingState == (existing ? .completed : .polling))
        #expect(recovered.usageCost == (existing ? 0.5 : nil))
        #expect(controller.lastPersistenceError == nil)
        #expect(try database.loadJobRecordsChecked().count == 1)
    }
}
