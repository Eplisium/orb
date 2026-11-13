import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Populated legacy job migration")
@MainActor
struct PopulatedJobMigrationTests {
    @Test("Opening populated legacy jobs preserves identities and supports updates", arguments: [false, true])
    func populatedLegacyJobs(hasMediaColumns: Bool) throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("orb-populated-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("legacy.sqlite3").path
        let jobID = UUID(), conversationID = UUID(), messageID = UUID(), savedID = UUID()
        var handle: OpaquePointer?
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        defer { if let handle { sqlite3_close(handle) } }
        let mediaColumns = hasMediaColumns ? ", prompt TEXT, saved_creation_id TEXT" : ""
        let sql = """
        CREATE TABLE jobs (
            id TEXT PRIMARY KEY, remote_id TEXT, kind TEXT NOT NULL,
            submission_state TEXT NOT NULL, polling_state TEXT NOT NULL,
            remote_status TEXT, conversation_id TEXT, message_id TEXT,
            model_id TEXT, usage_cost REAL, recoverable_error TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL\(mediaColumns)
        );
        INSERT INTO jobs (id, remote_id, kind, submission_state, polling_state,
            remote_status, conversation_id, message_id, model_id, usage_cost,
            recoverable_error, created_at, updated_at)
        VALUES ('\(jobID)', 'legacy-remote', 'video', 'submitted', 'completed',
            'completed', '\(conversationID)', '\(messageID)', 'legacy/model', 0.5,
            NULL, 1000, 1001);
        """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        if hasMediaColumns {
            #expect(sqlite3_exec(handle, "UPDATE jobs SET prompt = 'legacy prompt', saved_creation_id = '\(savedID)';", nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(handle)
        handle = nil

        do {
            let database = DatabaseManager(path: path)
            var loaded = try #require(try database.findJobRecordChecked(id: jobID))
            #expect(loaded.remoteID == "legacy-remote")
            #expect(loaded.conversationID == conversationID)
            #expect(loaded.messageID == messageID)
            #expect(loaded.modelID == "legacy/model")
            #expect(loaded.pollingState == .completed)
            #expect(loaded.usageCost == 0.5)
            #expect(loaded.createdAt.timeIntervalSince1970 == 1000)
            #expect(loaded.prompt == (hasMediaColumns ? "legacy prompt" : nil))
            #expect(loaded.savedCreationID == (hasMediaColumns ? savedID : nil))
            loaded.prompt = "updated\u{0}e\u{301}"
            loaded.savedCreationID = savedID
            loaded.updatedAt = Date(timeIntervalSince1970: 1002)
            try database.saveJobRecordChecked(loaded)
        }
        let reopened = DatabaseManager(path: path)
        let rows = try reopened.loadJobRecordsChecked()
        #expect(rows.count == 1)
        let restored = try #require(rows.first)
        #expect(restored.id == jobID)
        #expect(restored.prompt?.utf8.map { $0 } == Array("updated\u{0}e\u{301}".utf8))
        #expect(restored.savedCreationID == savedID)
        #expect(restored.createdAt.timeIntervalSince1970 == 1000)
        #expect(restored.updatedAt.timeIntervalSince1970 == 1002)
    }
}
