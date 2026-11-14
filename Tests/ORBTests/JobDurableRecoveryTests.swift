import Foundation
import SQLite3
import Testing
@testable import ORB

// The lead owns serial RED/GREEN execution; delegates do not compile or test.
// These contracts previously ran RED against the memory-only baseline shim.
// Public controller contract:
//   JobController.init(database: DatabaseManager, recoveryDirectory: URL?)
//   JobController.launched(database: DatabaseManager, recoveryDirectory: URL?)
//   JobController.memoryOnlyRecordIDs: Set<UUID>
// nil explicitly disables the journal (legacy/in-memory fixtures); the application
// shared controller must explicitly select its durable application-support directory.
//
// Journal contract: one versioned JSON full snapshot at <UUID>.json, atomically
// replaced BEFORE SQLite is attempted. Each envelope also stores the expected
// durable base (full canonical snapshot or fingerprint; explicit missing case).
// Constructor recovery reads/reconciles but does not submit, poll, download,
// account usage, or eagerly upsert pending rows. Identical DB/candidate snapshots
// need only acknowledgement. Replay may write only if DB still matches the base;
// a different durable snapshot is a visible conflict, regardless of timestamps.
// Failed reads/identity conflicts cannot acknowledge a file. Retry is local.
// Launch recovery reconciles first, then demotes interrupted polling snapshots.
//
// These are offline crash-window simulations, NOT executed process-kill/fsync tests.
// No claim of power-loss durability or recovery when BOTH independent stores fail.

@Suite("Job durable pending recovery", .serialized)
@MainActor
struct JobDurableRecoveryTests {
    @Test("Reopening restores the entire failed snapshot and retry performs only local writes", arguments: [false, true])
    func failedInsertOrUpdateSurvivesReopen(failUpdate: Bool) throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let expected: JobRecord
        do {
            let database = fixture.openDatabase()
            let controller = fixture.controller(database)
            if !failUpdate { try fixture.reject(database, event: "INSERT") }
            let initial = try #require(controller.recordVideoSubmission(
                remoteID: "recover-full", modelID: "fixture/video", conversationID: UUID(),
                messageID: UUID(), remoteStatus: "queued", error: "initial warning", cost: 0.25,
                prompt: "Keep before\u{0}e\u{301} 🧪 after"
            ))
            if failUpdate { try fixture.reject(database, event: "UPDATE") }
            controller.recordPollUpdate(remoteID: "recover-full", remoteStatus: "running", error: nil, cost: 0.75)
            controller.recordTerminal(remoteID: "recover-full", remoteStatus: "completed", error: "terminal detail", cost: nil)
            controller.recordSavedCreation(remoteID: "recover-full", creationID: UUID())
            expected = try #require(controller.record(id: initial.id))
            #expect(expected.usageCost == 0.75)
            #expect(expected.savedCreationID != nil)
            #expect(controller.unsavedRecordCount == 1)
            #expect(controller.memoryOnlyRecordIDs.isEmpty)
            #expect(FileManager.default.fileExists(atPath: fixture.entry(expected.id).path))
        } // No controller/database from the original session is retained.

        let database = fixture.openDatabase()
        let recovered = fixture.controller(database)
        let restored = try #require(recovered.record(id: expected.id))
        expectSameSnapshot(restored, expected)
        #expect(restored.prompt?.utf8.map { $0 } == expected.prompt?.utf8.map { $0 })
        #expect(recovered.pendingRecords.map(\.id) == [expected.id])
        #expect(recovered.downloadableJobs().isEmpty) // the creation link survived
        #expect(recovered.resumableJobs().isEmpty)
        // Repeated/late lifecycle events must use the recovered terminal UUID,
        // preserve its first creation link, and retry storage without mutation.
        let repeated = try #require(recovered.recordVideoSubmission(
            remoteID: "recover-full", modelID: "replacement", remoteStatus: "running", cost: 99, prompt: "replacement"
        ))
        expectSameSnapshot(repeated, expected)
        recovered.recordTerminal(remoteID: "recover-full", remoteStatus: "failed", error: "late", cost: 99)
        recovered.recordSavedCreation(remoteID: "recover-full", creationID: UUID())
        expectSameSnapshot(try #require(recovered.record(id: expected.id)), expected)
        #expect(recovered.retryPendingPersistence() == 0) // still rejected
        #expect(FileManager.default.fileExists(atPath: fixture.entry(expected.id).path))

        let transport = DurableJobNoNetworkTransport()
        let service = VideoGenService(transport: transport, jobController: recovered)
        let warning = try #require(service.jobPersistenceWarning)
        #expect(!warning.contains("only in memory"))
        #expect(!warning.contains("will be lost"))
        try database.execChecked("DROP TRIGGER reject_durable;")
        #expect(service.retryPendingJobPersistence(id: expected.id) == 1)
        #expect(service.retryPendingJobPersistence() == 0)
        #expect(transport.callCount == 0)
        #expect(service.unsavedJobRecordCount == 0)
        #expect(service.jobPersistenceWarning == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(expected.id).path))

        let reopened = fixture.controller(fixture.openDatabase())
        expectSameSnapshot(try #require(reopened.record(id: expected.id)), expected)
        #expect(reopened.allJobs().map(\.id) == [expected.id])
        #expect(reopened.pendingRecords.isEmpty)
    }

    @Test("Unknown outcomes retain separate UUIDs across restart and never become resubmission candidates")
    func unknownOutcomesRemainDistinct() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let expected: [JobRecord]
        do {
            let database = fixture.openDatabase()
            try fixture.reject(database, event: "INSERT")
            let controller = fixture.controller(database)
            _ = try #require(controller.recordUnknownSubmission(modelID: "fixture/video", error: "timeout A"))
            _ = try #require(controller.recordUnknownSubmission(modelID: "fixture/video", error: "timeout B"))
            expected = controller.pendingRecords
            #expect(Set(expected.map(\.id)).count == 2)
        }
        let database = fixture.openDatabase()
        let controller = fixture.controller(database)
        #expect(Set(controller.pendingRecords.map(\.id)) == Set(expected.map(\.id)))
        for snapshot in expected {
            expectSameSnapshot(try #require(controller.record(id: snapshot.id)), snapshot)
        }
        #expect(controller.resumableJobs().isEmpty)
        #expect(controller.downloadableJobs().isEmpty)
        let transport = DurableJobNoNetworkTransport()
        let service = VideoGenService(transport: transport, jobController: controller)
        try database.execChecked("DROP TRIGGER reject_durable;")
        #expect(service.retryPendingJobPersistence() == 2)
        #expect(transport.callCount == 0)
        #expect(try database.loadJobRecordsChecked().allSatisfy {
            $0.remoteID == nil && $0.submissionState == .outcomeUnknown
        })
        #expect(try database.loadJobRecordsChecked().count == 2)
    }

    @Test("Launch restores journal rows before demoting interrupted polls and never revives terminal rows")
    func launchOrdersRecoveryBeforeDemotion() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let running: JobRecord
        let terminal: JobRecord
        do {
            let database = fixture.openDatabase()
            try fixture.reject(database, event: "INSERT")
            let controller = fixture.controller(database)
            running = try #require(controller.recordVideoSubmission(
                remoteID: "running", modelID: "fixture/video", remoteStatus: "running", cost: 0, prompt: "keep"
            ))
            terminal = try #require(controller.recordVideoSubmission(
                remoteID: "terminal", modelID: "fixture/video", remoteStatus: "completed", cost: 0.5
            ))
        }
        let controller = JobController.launched(database: fixture.openDatabase(), recoveryDirectory: fixture.journal)
        let stopped = try #require(controller.record(id: running.id))
        #expect(stopped.pollingState == .stoppedLocally)
        #expect(stopped.lastRemoteStatus == "running")
        #expect(stopped.usageCost == 0)
        #expect(stopped.prompt == "keep")
        expectSameSnapshot(try #require(controller.record(id: terminal.id)), terminal)
        #expect(controller.resumableJobs().map(\.id) == [running.id])
        #expect(controller.downloadableJobs().map(\.id) == [terminal.id])
        // The demotion itself must replace the durable pending snapshot.
        let nextLaunch = fixture.controller(fixture.openDatabase())
        expectSameSnapshot(try #require(nextLaunch.record(id: running.id)), stopped)
    }

    @Test("Partial retry acknowledges only committed UUIDs and unrelated success cannot erase another failure")
    func partialRetryKeepsFailedSibling() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let first: JobRecord
        let second: JobRecord
        do {
            let database = fixture.openDatabase()
            try fixture.reject(database, event: "INSERT")
            let controller = fixture.controller(database)
            first = try #require(controller.recordVideoSubmission(remoteID: "first", modelID: "fixture/video", remoteStatus: "completed"))
            second = try #require(controller.recordVideoSubmission(remoteID: "second", modelID: "fixture/video", remoteStatus: "completed"))
        }
        let database = fixture.openDatabase()
        try database.execChecked("""
            DROP TRIGGER reject_durable;
            CREATE TRIGGER reject_second BEFORE INSERT ON jobs WHEN NEW.remote_id = 'second'
            BEGIN SELECT RAISE(ABORT, 'second still unavailable'); END;
            """)
        let controller = fixture.controller(database)
        #expect(controller.retryPendingPersistence() == 1)
        _ = try #require(controller.recordVideoSubmission(remoteID: "unrelated", modelID: "fixture/video", remoteStatus: "completed"))
        #expect(controller.pendingRecords.map(\.id) == [second.id])
        #expect(controller.persistenceErrors[first.id] == nil)
        #expect(controller.persistenceErrors[second.id] != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(first.id).path))
        #expect(FileManager.default.fileExists(atPath: fixture.entry(second.id).path))
        let reopened = fixture.controller(fixture.openDatabase())
        expectSameSnapshot(try #require(reopened.record(id: second.id)), second)
        #expect(reopened.pendingRecords.map(\.id) == [second.id])
        #expect(reopened.allJobs().count == 3)
        try database.execChecked("DROP TRIGGER reject_second;")
        #expect(reopened.retryPendingPersistence(id: second.id) == 1)
        #expect(reopened.retryPendingPersistence(id: first.id) == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(second.id).path))
    }

    @Test("Both stores failing explicitly means memory-only, not durable recovery")
    func journalWriteFailureIsHonest() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        // Start with a readable empty inventory, then break writes. A regular
        // file at the directory path is deterministic even for elevated users.
        try FileManager.default.createDirectory(at: fixture.journal, withIntermediateDirectories: true)
        let database = fixture.openDatabase()
        try fixture.reject(database, event: "INSERT")
        let controller = fixture.controller(database)
        try FileManager.default.removeItem(at: fixture.journal)
        try Data("not a directory".utf8).write(to: fixture.journal)
        let original = try #require(controller.recordVideoSubmission(
            remoteID: "memory-only", modelID: "fixture/video", remoteStatus: "completed", cost: 0.75
        ))
        #expect(controller.memoryOnlyRecordIDs == Set([original.id]))
        #expect(controller.lastPersistenceError != nil)
        let service = VideoGenService(transport: DurableJobNoNetworkTransport(), jobController: controller)
        let warning = try #require(service.jobPersistenceWarning)
        #expect(warning.contains("only in memory"))
        #expect(warning.contains("quit"))
        #expect(controller.retryPendingPersistence() == 0)
        // A new controller cannot magically reconstruct the lost snapshot.
        let fresh = fixture.controller(fixture.openDatabase())
        #expect(fresh.record(id: original.id) == nil)
        #expect(fresh.lastPersistenceError != nil)
        try database.execChecked("DROP TRIGGER reject_durable;")
        #expect(service.retryPendingJobPersistence() == 1) // SQLite can still save it
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        expectSameSnapshot(try #require(try database.findJobRecordChecked(id: original.id)), original)
    }

    @Test("An unavailable journal does not prevent a successful SQLite save or falsely label it memory-only")
    func sqliteSuccessDoesNotDependOnJournalSuccess() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        try Data("blocked".utf8).write(to: fixture.journal)
        let database = fixture.openDatabase()
        let controller = fixture.controller(database)
        let original = try #require(controller.recordUnknownSubmission(modelID: "fixture/video", error: "uncertain"))
        #expect(controller.unsavedRecordCount == 0)
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        expectSameSnapshot(try #require(try fixture.openDatabase().findJobRecordChecked(id: original.id)), original)
        let service = VideoGenService(transport: DurableJobNoNetworkTransport(), jobController: controller)
        #expect(service.jobPersistenceWarning?.contains("only in memory") != true)
    }

    @Test("A changed durable base is a visible conflict regardless of wall-clock ordering", arguments: [-60.0, 0.0, 60.0])
    func changedDatabaseBaseCannotBeOverwritten(clockDelta: Double) throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let candidate: JobRecord
        do {
            let database = fixture.openDatabase()
            let controller = fixture.controller(database)
            let original = try #require(controller.recordVideoSubmission(
                remoteID: "changed-base", modelID: "fixture/video", remoteStatus: "queued", cost: 0.25
            ))
            try fixture.reject(database, event: "UPDATE")
            controller.recordTerminal(remoteID: "changed-base", remoteStatus: "completed", error: nil, cost: 0.75)
            candidate = try #require(controller.record(id: original.id))
        }
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_durable;")
        var winner = candidate
        winner.savedCreationID = UUID()
        winner.usageCost = 1.25
        winner.updatedAt = Date(timeIntervalSince1970: candidate.updatedAt.timeIntervalSince1970 + clockDelta)
        try database.saveJobRecordChecked(winner)
        // Equal/newer/older timestamps are not proof that the journal supersedes
        // this independently committed state. Preserve both for explicit repair.
        let recovered = fixture.controller(fixture.openDatabase())
        #expect(recovered.retryPendingPersistence() == 0)
        #expect(recovered.lastPersistenceError != nil)
        #expect(recovered.pendingRecords.map(\.id) == [candidate.id])
        #expect(FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
        expectSameSnapshot(try #require(try database.findJobRecordChecked(id: candidate.id)), winner)
        let again = fixture.controller(fixture.openDatabase())
        #expect(again.retryPendingPersistence() == 0)
        #expect(again.lastPersistenceError != nil)
        expectSameSnapshot(try #require(try database.findJobRecordChecked(id: candidate.id)), winner)
    }

    @Test("An unchanged durable base permits recovery even when the pending timestamp went backwards")
    func matchingBaseSurvivesClockRollback() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let candidate: JobRecord
        do {
            let database = fixture.openDatabase()
            let controller = fixture.controller(database)
            var base = try #require(controller.recordVideoSubmission(
                remoteID: "clock-rollback", modelID: "fixture/video", remoteStatus: "queued", cost: 0.25
            ))
            base.updatedAt = Date(timeIntervalSince1970: 4_000_000_000)
            try database.saveJobRecordChecked(base)
            try fixture.reject(database, event: "UPDATE")
            controller.recordTerminal(remoteID: "clock-rollback", remoteStatus: "completed", error: nil, cost: 0.75)
            candidate = try #require(controller.record(id: base.id))
            #expect(candidate.updatedAt < base.updatedAt)
        }
        let database = fixture.openDatabase()
        let recovered = fixture.controller(database)
        expectSameSnapshot(try #require(recovered.record(id: candidate.id)), candidate)
        try database.execChecked("DROP TRIGGER reject_durable;")
        #expect(recovered.retryPendingPersistence() == 1)
        expectSameSnapshot(try #require(try database.findJobRecordChecked(id: candidate.id)), candidate)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
    }

    @Test("Crash after SQLite commit but before acknowledgement removes only the redundant journal without another write")
    func committedSnapshotNeedsOnlyAcknowledgement() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let snapshot = try fixture.makePending(remoteID: "ack-gap", status: "completed")
        let savedJournalBytes = try Data(contentsOf: fixture.entry(snapshot.id))
        do {
            let database = fixture.openDatabase()
            try database.execChecked("DROP TRIGGER reject_durable;")
            let controller = fixture.controller(database)
            #expect(controller.retryPendingPersistence() == 1)
        }
        // Restore the exact pre-ack bytes: equivalent durable state to the
        // process exiting after the DB commit but before journal deletion.
        try savedJournalBytes.write(to: fixture.entry(snapshot.id), options: .atomic)
        let database = fixture.openDatabase()
        try fixture.reject(database, event: "INSERT")
        let recovered = fixture.controller(database)
        #expect(recovered.retryPendingPersistence() == 0)
        #expect(recovered.pendingRecords.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(snapshot.id).path))
        expectSameSnapshot(try #require(recovered.record(id: snapshot.id)), snapshot)
        #expect(recovered.lastPersistenceError == nil)
    }

    @Test("Conflicting UUIDs for one remote job are preserved for resolution, never overwritten or duplicated by replay")
    func remoteIdentityConflictFailsClosed() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let journalRecord = try fixture.makePending(remoteID: "identity-conflict", status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_durable;")
        var canonical = journalRecord
        canonical.id = UUID()
        canonical.savedCreationID = UUID()
        try database.saveJobRecordChecked(canonical)
        let recovered = fixture.controller(database)
        #expect(recovered.retryPendingPersistence() == 0)
        #expect(recovered.lastPersistenceError != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.entry(journalRecord.id).path))
        let stored = try database.loadJobRecordsChecked()
        #expect(stored.count == 1)
        expectSameSnapshot(try #require(stored.first), canonical)
        #expect(try database.findJobRecordChecked(id: journalRecord.id) == nil)
    }

    @Test("Read faults preserve journal-owned UUIDs and cannot invent an identity or acknowledge unknown storage")
    func readFaultCannotInventUUID() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.makePending(remoteID: "owned", status: "completed")
        let journalBytes = try Data(contentsOf: fixture.entry(original.id))
        let database = fixture.openDatabase()
        sqlite3_set_authorizer(database.db, { _, operation, table, _, _, _ in
            if operation == SQLITE_READ, let table, String(cString: table) == "jobs" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(database.db, nil, nil) }
        let recovered = fixture.controller(database)
        expectSameSnapshot(try #require(recovered.record(id: original.id)), original)
        expectSameSnapshot(try #require(recovered.record(remoteID: "owned")), original)
        #expect(recovered.recordVideoSubmission(remoteID: "unreadable", modelID: "fixture/video", remoteStatus: "queued") == nil)
        #expect(recovered.pendingRecords.map(\.id) == [original.id])
        #expect(recovered.retryPendingPersistence() == 0)
        #expect(recovered.lastPersistenceError != nil)
        #expect(try Data(contentsOf: fixture.entry(original.id)) == journalBytes)
        sqlite3_set_authorizer(database.db, nil, nil)
        try database.execChecked("DROP TRIGGER reject_durable;")
        #expect(recovered.retryPendingPersistence() == 1)
        #expect(try database.loadJobRecordsChecked().map(\.id) == [original.id])
    }

    @Test("Malformed committed journal JSON remains diagnosable and cannot masquerade as an empty inventory")
    func corruptJournalIsNotAbsence() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.makePending(remoteID: "corrupt", status: "completed")
        let corruptBytes = Data("{\"version\":1,\"record\":".utf8)
        try corruptBytes.write(to: fixture.entry(original.id), options: .atomic)
        let database = fixture.openDatabase()
        let recovered = fixture.controller(database)
        #expect(recovered.lastPersistenceError != nil)
        #expect(recovered.recordVideoSubmission(remoteID: "corrupt", modelID: "fixture/video", remoteStatus: "queued") == nil)
        #expect(recovered.pendingRecords.isEmpty)
        #expect(recovered.retryPendingPersistence() == 0)
        #expect(recovered.allJobs().isEmpty)
        #expect(recovered.lastPersistenceError != nil) // a successful DB read must not clear this
        #expect(try Data(contentsOf: fixture.entry(original.id)) == corruptBytes)
        #expect(try database.loadJobRecordsChecked().isEmpty)
    }

    @Test("The complete journal is already visible at SQLite commit and survives a rejected commit")
    func journalPrecedesDatabaseCommit() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let controller = fixture.controller(database)
        let probe = DurableJobCommitProbe(directory: fixture.journal)
        let context = Unmanaged.passUnretained(probe).toOpaque()
        sqlite3_commit_hook(database.db, { context in
            guard let context else { return 1 }
            let probe = Unmanaged<DurableJobCommitProbe>.fromOpaque(context).takeUnretainedValue()
            probe.capture()
            return 1 // fail the DB commit after observing the independent journal
        }, context)
        defer { sqlite3_commit_hook(database.db, nil, nil) }
        let original = try #require(controller.recordVideoSubmission(
            remoteID: "commit-order", modelID: "fixture/video", remoteStatus: "completed",
            cost: 0.75, prompt: "write-ahead-snapshot"
        ))
        #expect(probe.calls == 1)
        let payload = try #require(probe.payloads.first)
        _ = try JSONSerialization.jsonObject(with: payload)
        let text = String(decoding: payload, as: UTF8.self)
        #expect(text.contains(original.id.uuidString))
        #expect(text.contains("write-ahead-snapshot"))
        #expect(try database.loadJobRecordsChecked().isEmpty)
        #expect(controller.unsavedRecordCount == 1)
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        sqlite3_commit_hook(database.db, nil, nil)
        let recovered = fixture.controller(fixture.openDatabase())
        expectSameSnapshot(try #require(recovered.record(id: original.id)), original)
        #expect(recovered.retryPendingPersistence() == 1)
    }

    @Test("Acknowledgement failure retains a diagnosable generation and restart only acknowledges")
    func failedAcknowledgementSurvivesRestart() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let controller = JobController(database: database, recoveryDirectory: fixture.journal, recoveryFault: { operation in
            if operation == .acknowledge { throw CocoaError(.fileWriteNoPermission) }
        })
        let record = try #require(controller.recordVideoSubmission(remoteID: "ack-failure", modelID: "fixture/video", remoteStatus: "completed", prompt: "complete snapshot"))
        #expect(controller.unsavedRecordCount == 0)
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        #expect(controller.persistenceErrors[record.id] != nil)
        #expect(controller.lastPersistenceError != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.entry(record.id).path))
        try fixture.reject(database, event: "INSERT")
        let recovered = fixture.controller(fixture.openDatabase())
        expectSameSnapshot(try #require(recovered.record(id: record.id)), record)
        #expect(recovered.lastPersistenceError == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(record.id).path))
    }

    @Test("Explicit conflict resolution stays local", arguments: [false, true])
    func deliberateConflictResolution(keepDurable: Bool) throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makePending(remoteID: "resolve", status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_durable;")
        var winner = candidate
        winner.usageCost = 88
        winner.savedCreationID = UUID()
        try database.saveJobRecordChecked(winner)
        let recovered = fixture.controller(database)
        #expect(recovered.persistenceConflicts[candidate.id] != nil)
        let transport = DurableJobNoNetworkTransport()
        let service = VideoGenService(transport: transport, jobController: recovered)
        #expect(service.resolveJobPersistenceConflict(id: candidate.id, resolution: keepDurable ? .keepDurable : .retryCandidate))
        #expect(transport.callCount == 0)
        expectSameSnapshot(try #require(try database.findJobRecordChecked(id: candidate.id)), keepDurable ? winner : candidate)
        #expect(recovered.pendingRecords.isEmpty)
        #expect(recovered.persistenceConflicts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
    }

    @Test("Conflict resolution cannot overwrite a durable snapshot changed since it was displayed", arguments: [JobPersistenceResolution.keepDurable, .retryCandidate, .useJournal])
    func conflictResolutionChecksReviewedBase(resolution: JobPersistenceResolution) throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makePending(remoteID: "resolve-race", status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_durable;")
        var winner = candidate
        winner.usageCost = 10
        try database.saveJobRecordChecked(winner)
        let recovered = fixture.controller(database)
        winner.usageCost = 20
        try database.saveJobRecordChecked(winner)
        #expect(!recovered.resolvePendingPersistence(id: candidate.id, resolution: resolution))
        expectSameSnapshot(try #require(try database.findJobRecordChecked(id: candidate.id)), winner)
        #expect(FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
    }

    @Test("Two controllers cannot overwrite an unobserved journal generation or invent another remote UUID")
    func multipleControllersUseGenerationCAS() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        try fixture.reject(database, event: "INSERT")
        let first = fixture.controller(database)
        let second = fixture.controller(fixture.openDatabase())
        let record = try #require(first.recordVideoSubmission(remoteID: "shared", modelID: "fixture/video", remoteStatus: "queued"))
        // The second controller was created before the first staged the row.
        let observed = try #require(second.recordVideoSubmission(remoteID: "shared", modelID: "fixture/video", remoteStatus: "running"))
        #expect(observed.id == record.id)
        let before = try Data(contentsOf: fixture.entry(record.id))
        first.recordTerminal(remoteID: "shared", remoteStatus: "completed", error: nil, cost: 9)
        #expect(first.lastPersistenceError != nil)
        #expect(first.memoryOnlyRecordIDs.contains(record.id))
        #expect(try Data(contentsOf: fixture.entry(record.id)) == before)
        let fresh = fixture.controller(fixture.openDatabase())
        #expect(fresh.allJobs().count == 1)
        #expect(fresh.record(id: record.id)?.pollingState != .completed)
    }

    @Test("Journal and entry modes are private and files contain no credential fields")
    func journalPermissionsAndSchema() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.makePending(remoteID: "permissions", status: "completed")
        let dir = try FileManager.default.attributesOfItem(atPath: fixture.journal.path)
        let entry = try FileManager.default.attributesOfItem(atPath: fixture.entry(record.id).path)
        #expect((dir[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((entry[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.entry(record.id))) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["generation"] != nil)
        #expect(json["expectedDurableBase"] != nil)
        #expect(json["candidate"] != nil)
        #expect(json["apiKey"] == nil)
        #expect(json["authorization"] == nil)
    }

    @Test("A scoped journal lock fails closed even when SQLite could accept a write")
    func heldDirectoryLockCannotBeBypassed() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let controller = fixture.controller(database)
        let owner = JobRecoveryJournal(directory: fixture.journal)
        try owner.withAccess { _ in
            let record = try #require(controller.recordUnknownSubmission(modelID: "fixture/video", error: "lock fixture"))
            #expect(controller.memoryOnlyRecordIDs.contains(record.id))
            #expect(controller.persistenceErrors[record.id]?.contains("Another process") == true)
            #expect(try database.loadJobRecordsChecked().isEmpty)
        }
        #expect(controller.retryPendingPersistence() == 1)
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        #expect(try database.loadJobRecordsChecked().count == 1)
    }

    @Test("Acknowledgement CAS cannot delete a newer generation")
    func staleAcknowledgementCannotRemoveNewerCandidate() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let record = try fixture.makePending(remoteID: "ack-generation", status: "completed")
        let journal = JobRecoveryJournal(directory: fixture.journal)
        let replacement = try journal.withAccess { access in
            let old = try #require(try access.read(record.id))
            var candidate = old.candidate
            candidate.savedCreationID = UUID()
            candidate.prompt = "newest full snapshot"
            let next = JobRecoveryEnvelope(candidate: candidate, expectedDurableBase: old.expectedDurableBase)
            try access.stage(next, replacing: old.generation)
            #expect(throws: Error.self) { try access.acknowledge(old) }
            #expect(try access.read(record.id)?.generation == next.generation)
            return candidate
        }
        let reopened = fixture.controller(fixture.openDatabase())
        expectSameSnapshot(try #require(reopened.record(id: record.id)), replacement)
    }

    @Test("Outer SQLite transactions cannot be mistaken for a committed job save")
    func outerTransactionRetainsRecoveryCandidate() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let controller = fixture.controller(database)
        try database.execChecked("BEGIN IMMEDIATE;")
        let record = try #require(controller.recordUnknownSubmission(modelID: "fixture/video", error: "outer fixture"))
        #expect(controller.unsavedRecordCount == 1)
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.entry(record.id).path))
        try database.execChecked("ROLLBACK;")
        #expect(controller.retryPendingPersistence() == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(record.id).path))
    }

    @Test("Keeping durable resolves remote UUID conflicts without deleting the remote owner's saved state")
    func keepDurableRemoteIdentityConflict() throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makePending(remoteID: "identity-resolution", status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_durable;")
        var owner = candidate
        owner.id = UUID()
        owner.savedCreationID = UUID()
        try database.saveJobRecordChecked(owner)
        let controller = fixture.controller(database)
        #expect(controller.persistenceConflicts[candidate.id]?.canRetryCandidate == false)
        #expect(!controller.resolvePendingPersistence(id: candidate.id, resolution: .retryCandidate))
        #expect(controller.resolvePendingPersistence(id: candidate.id, resolution: .keepDurable))
        #expect(controller.record(id: candidate.id) == nil)
        expectSameSnapshot(try #require(controller.record(id: owner.id)), owner)
        #expect(controller.allJobs().count == 1)
    }

    @Test("A recovered conflict cannot be resumed through a stale tray snapshot")
    func conflictedResumeStaysOffline() async throws {
        let fixture = try DurableJobFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makePending(remoteID: "conflicted-resume", status: "running")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_durable;")
        var winner = candidate
        winner.usageCost = 12
        try database.saveJobRecordChecked(winner)
        let controller = fixture.controller(database)
        let transport = DurableJobNoNetworkTransport()
        let service = VideoGenService(transport: transport, jobController: controller)
        #expect(service.resumableRecords.isEmpty)
        do {
            _ = try await service.resume(candidate)
            Issue.record("Expected a local conflict refusal")
        } catch MediaServiceError.resumeUnavailable(_) { }
        #expect(transport.callCount == 0)
    }

    @Test("Explicit nil journal fixtures retain sparse costs, terminal monotonicity and local retry")
    func nilJournalCompatibility() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database, recoveryDirectory: nil)
        let initial = try #require(controller.recordVideoSubmission(remoteID: "nil-journal", modelID: "fixture/video", remoteStatus: "running", cost: 0, prompt: "sparse fixture"))
        try database.execChecked("CREATE TRIGGER reject_nil_update BEFORE UPDATE ON jobs BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
        controller.recordTerminal(remoteID: "nil-journal", remoteStatus: "completed", error: nil, cost: nil)
        let creation = UUID()
        controller.recordSavedCreation(remoteID: "nil-journal", creationID: creation)
        let expected = try #require(controller.record(id: initial.id))
        #expect(expected.usageCost == 0)
        #expect(expected.savedCreationID == creation)
        #expect(controller.memoryOnlyRecordIDs.contains(initial.id))
        controller.recordPollUpdate(remoteID: "nil-journal", remoteStatus: "running", error: "late", cost: 99)
        expectSameSnapshot(try #require(controller.record(id: initial.id)), expected)
        try database.execChecked("DROP TRIGGER reject_nil_update;")
        #expect(controller.retryPendingPersistence(id: initial.id) == 1)
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        #expect(controller.lastPersistenceError == nil)
        expectSameSnapshot(try #require(try database.findJobRecordChecked(id: initial.id)), expected)
    }

    private func expectSameSnapshot(_ actual: JobRecord, _ expected: JobRecord) {
        // SQLite stores Unix doubles; compare at that precision rather than
        // letting Date's reference-epoch conversion create unrelated failures.
        #expect(actual.createdAt.timeIntervalSince1970 == expected.createdAt.timeIntervalSince1970)
        #expect(actual.updatedAt.timeIntervalSince1970 == expected.updatedAt.timeIntervalSince1970)
        var normalized = expected
        normalized.createdAt = actual.createdAt
        normalized.updatedAt = actual.updatedAt
        #expect(actual == normalized)
    }
}

@MainActor
private struct DurableJobFixture {
    let root: URL
    var journal: URL { root.appendingPathComponent("pending-jobs", isDirectory: true) }

    init() throws {
        root = ORBTestScratch.root
            .appendingPathComponent("ORB-job-durable-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func openDatabase() -> DatabaseManager {
        DatabaseManager(path: root.appendingPathComponent("jobs.sqlite3").path)
    }

    func controller(_ database: DatabaseManager) -> JobController {
        JobController(database: database, recoveryDirectory: journal)
    }

    func entry(_ id: UUID) -> URL { journal.appendingPathComponent("\(id.uuidString).json") }

    func reject(_ database: DatabaseManager, event: String) throws {
        // event is one of the fixed INSERT/UPDATE test arguments, never user input.
        try database.execChecked("""
            CREATE TRIGGER reject_durable BEFORE \(event) ON jobs
            BEGIN SELECT RAISE(ABORT, 'injected durable job write failure'); END;
            """)
    }

    func makePending(remoteID: String, status: String) throws -> JobRecord {
        let database = openDatabase()
        try reject(database, event: "INSERT")
        let controller = controller(database)
        let record = try #require(controller.recordVideoSubmission(
            remoteID: remoteID, modelID: "fixture/video", conversationID: UUID(), messageID: UUID(),
            remoteStatus: status, cost: 0.25, prompt: "durable fixture"
        ))
        #expect(controller.unsavedRecordCount == 1)
        #expect(controller.memoryOnlyRecordIDs.isEmpty)
        return record
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

// SQLite invokes this synchronously on the fixture's calling thread. It does
// not call the controller/SQLite recursively and cannot touch application data.
private final class DurableJobCommitProbe {
    let directory: URL
    var calls = 0
    var payloads: [Data] = []

    init(directory: URL) { self.directory = directory }

    func capture() {
        calls += 1
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        payloads = files.filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }
    }
}

private final class DurableJobNoNetworkTransport: MediaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    init() { super.init(apiKeyProvider: { "offline-fixture-key" }) }

    private func unexpected() {
        lock.lock()
        calls += 1
        lock.unlock()
        Issue.record("Local job recovery must not call any transport")
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        unexpected()
        throw URLError(.notConnectedToInternet)
    }

    override func sendRaw(_ request: URLRequest) async throws -> (Data, String?) {
        unexpected()
        throw URLError(.notConnectedToInternet)
    }

    override func downloadToFile(_ request: URLRequest) async throws -> (URL, String?) {
        unexpected()
        throw URLError(.notConnectedToInternet)
    }
}
