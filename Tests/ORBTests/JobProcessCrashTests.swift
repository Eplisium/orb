import Foundation
import Darwin
import SQLite3
import Testing
@testable import ORB

/// Opt-in subprocess fixture. The external watchdog kills only its owned process
/// helper PID at a signalled boundary, then runs a fresh verifier. No app singleton,
/// transport, credentials or paid request is constructed. Not a power-loss test.
@Suite("Job process-crash recovery", .serialized)
@MainActor
struct JobProcessCrashTests {
    @Test("Recover exact snapshots after an externally killed journal writer",
          .enabled(if: ProcessInfo.processInfo.environment["ORB_JOB_CRASH_ROOT"] != nil,
                   "Requires the disposable external process-kill harness"))
    func subprocessFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["ORB_JOB_CRASH_ROOT"])
        let phase = try #require(environment["ORB_JOB_CRASH_PHASE"])
        let mode = try #require(environment["ORB_JOB_CRASH_MODE"])
        let root = URL(fileURLWithPath: path).standardizedFileURL
        try #require(root.lastPathComponent.hasPrefix("ORB-job-crash-"))
        try #require(try String(contentsOf: root.appendingPathComponent("probe-permitted"), encoding: .utf8) == root.lastPathComponent)
        let database = DatabaseManager(path: root.appendingPathComponent("fixture.sqlite3").path)
        try #require(database.launchFailure == nil)
        let journal = root.appendingPathComponent("Journal")
        let expectedURL = root.appendingPathComponent("expected.json")
        if mode == "writer" {
            var armed = false
            let controller = JobController(database: database, recoveryDirectory: journal, recoveryFault: { operation in
                guard armed, String(describing: operation) == phase else { return }
                let files = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                let expected: JobRecord
                if let file = files.first {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .secondsSince1970
                    expected = try decoder.decode(JobRecoveryEnvelope.self, from: Data(contentsOf: file)).candidate
                } else {
                    guard let stored = try database.loadJobRecordsChecked().first else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    expected = stored
                }
                try JSONEncoder().encode(expected).write(to: expectedURL, options: .atomic)
                try JSONSerialization.data(withJSONObject: ["phase": phase, "pid": Int(getpid())])
                    .write(to: root.appendingPathComponent("reached"), options: .atomic)
                // Bounded even if the external harness dies: never an orphaned
                // indefinitely sleeping fixture. A normal return is a failure.
                for _ in 0..<300 { usleep(100_000) }
                throw CocoaError(.userCancelled)
            })
            let first = try #require(controller.recordVideoSubmission(remoteID: "offline-crash-job", modelID: "offline/model",
                conversationID: UUID(), messageID: UUID(), remoteStatus: "completed", cost: 0.125,
                prompt: "crash fixture \u{0} e\u{301} 完整"))
            armed = true
            controller.recordSavedCreation(remoteID: try #require(first.remoteID), creationID: UUID())
            Issue.record("Writer returned without being killed at the requested boundary")
        } else {
            try #require(mode == "verify")
            let expected = try JSONDecoder().decode(JobRecord.self, from: Data(contentsOf: expectedURL))
            let counter = JobCrashWriteCounter()
            sqlite3_update_hook(database.db, { context, _, _, table, _ in
                guard let context, let table, String(cString: table) == "jobs" else { return }
                Unmanaged<JobCrashWriteCounter>.fromOpaque(context).takeUnretainedValue().count += 1
            }, Unmanaged.passUnretained(counter).toOpaque())
            defer { sqlite3_update_hook(database.db, nil, nil) }
            let recovered = JobController.launched(database: database, recoveryDirectory: journal)
            let records = try database.loadJobRecordsChecked()
            try #require(records.count == 1)
            #expect(try JobRecoveryEnvelope.same(records[0], expected))
            #expect(records[0].savedCreationID != nil)
            #expect(recovered.pendingRecords.isEmpty)
            #expect(recovered.memoryOnlyRecordIDs.isEmpty)
            #expect(recovered.lastPersistenceError == nil)
            let entries = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            #expect(entries.isEmpty)
            #expect(counter.count == (phase == "afterRename" ? 1 : 0), "Committed records must be acknowledged without another write")
            let savedCreationID = try #require(records[0].savedCreationID)
            let result: [String: String] = ["phase": phase, "jobID": records[0].id.uuidString,
                "savedCreationID": savedCreationID.uuidString, "jobWrites": String(counter.count)]
            try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                .write(to: root.appendingPathComponent("verified.json"), options: .atomic)
        }
    }
}

private final class JobCrashWriteCounter { var count = 0 }
