import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Job initial persistence recovery")
@MainActor
struct JobInitialPersistenceTests {
    @Test("A later lifecycle update recovers a failed initial insert with its original identity and metadata")
    func laterUpdateRecoversInitialInsert() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        try database.execChecked("""
            CREATE TRIGGER reject_initial_job BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'injected initial job persistence failure'); END;
            """)

        let original = try #require(controller.recordVideoSubmission(
            remoteID: "initial-insert-job", modelID: "test/video",
            conversationID: UUID(), messageID: UUID(), remoteStatus: "queued",
            cost: 0.25, prompt: "Keep this original prompt 🧪"
        ))
        #expect(controller.lastPersistenceError != nil)
        #expect(try database.loadJobRecordsChecked().isEmpty)

        // Polling continues while storage is unavailable. Its latest known
        // cost must survive a later sparse response, not just the initial row.
        controller.recordPollUpdate(
            remoteID: "initial-insert-job", remoteStatus: "running", error: nil, cost: 0.75
        )
        #expect(controller.lastPersistenceError != nil)
        #expect(try database.loadJobRecordsChecked().isEmpty)
        try database.execChecked("DROP TRIGGER reject_initial_job;")

        // A normal lifecycle event must heal storage; recording another
        // submission would hide the bug by allocating a replacement UUID.
        controller.recordTerminal(
            remoteID: "initial-insert-job", remoteStatus: "completed", error: nil, cost: nil
        )
        let recovered = try #require(try database.findJobRecordChecked(id: original.id))
        var expected = original
        expected.pollingState = .completed
        expected.lastRemoteStatus = "completed"
        expected.usageCost = 0.75
        // SQLite stores Unix-epoch doubles; compare creation time in that
        // representation rather than Date's reference-epoch precision.
        #expect(recovered.createdAt.timeIntervalSince1970 == original.createdAt.timeIntervalSince1970)
        expected.createdAt = recovered.createdAt
        expected.updatedAt = recovered.updatedAt
        #expect(recovered == expected)
        #expect(recovered.updatedAt.timeIntervalSince1970 >= original.updatedAt.timeIntervalSince1970)
        #expect(controller.lastPersistenceError == nil)
        #expect(try database.loadJobRecordsChecked().count == 1)
        #expect(JobController(database: database).downloadableJobs() == [recovered])
    }

    @Test("Pending updates override persisted rows, preserve sparse metadata and retry terminal snapshots")
    func failedUpdateKeepsLatestSnapshot() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let original = try #require(controller.recordVideoSubmission(
            remoteID: "update-job", modelID: "test/video", conversationID: UUID(),
            messageID: UUID(), remoteStatus: "queued", cost: 0.25, prompt: "original"
        ))
        try database.execChecked("""
            CREATE TRIGGER reject_job_update BEFORE UPDATE ON jobs
            BEGIN SELECT RAISE(ABORT, 'injected update failure'); END;
            """)
        controller.recordPollUpdate(remoteID: "update-job", remoteStatus: "running", error: nil, cost: 0.75)
        controller.recordPollFailure(remoteID: "update-job", error: "poll unavailable")
        #expect(controller.record(id: original.id)?.pollingState == .stoppedLocally)
        #expect(controller.resumableJobs().map(\.id) == [original.id])
        #expect(controller.allJobs().count == 1)
        #expect(try database.findJobRecordChecked(id: original.id)?.usageCost == 0.25)
        controller.recordTerminal(remoteID: "update-job", remoteStatus: "completed", error: nil, cost: nil)
        let creationID = UUID()
        controller.recordSavedCreation(remoteID: "update-job", creationID: creationID)
        let pending = try #require(controller.record(id: original.id))
        #expect(controller.pendingRecords == [pending])
        #expect(pending.id == original.id)
        #expect(pending.createdAt.timeIntervalSince1970 == original.createdAt.timeIntervalSince1970)
        #expect(pending.conversationID == original.conversationID)
        #expect(pending.messageID == original.messageID)
        #expect(pending.prompt == original.prompt)
        #expect(pending.usageCost == 0.75)
        #expect(pending.savedCreationID == creationID)
        #expect(controller.resumableJobs().isEmpty)
        #expect(controller.downloadableJobs().isEmpty)
        #expect(controller.unsavedRecordCount == 1)

        // Lifecycle no-ops cannot regress a terminal snapshot, even while unsaved.
        controller.recordStoppedLocally(remoteID: "update-job")
        controller.recordPollingStarted(remoteID: "update-job")
        controller.recordPollUpdate(remoteID: "update-job", remoteStatus: "running", error: "late", cost: 99)
        controller.recordTerminal(remoteID: "update-job", remoteStatus: "failed", error: "late", cost: 99)
        let repeated = controller.recordVideoSubmission(remoteID: "update-job", modelID: "replacement", remoteStatus: "queued")
        #expect(repeated == pending)
        #expect(controller.retryPendingPersistence(id: original.id) == 0)
        #expect(controller.record(id: original.id) == pending)
        try database.execChecked("DROP TRIGGER reject_job_update;")
        #expect(controller.retryPendingPersistence(id: original.id) == 1)
        #expect(controller.unsavedRecordCount == 0)
        #expect(controller.persistenceErrors.isEmpty)
        #expect(controller.lastPersistenceError == nil)
        let stored = try #require(try database.findJobRecordChecked(id: original.id))
        var expected = pending
        expected.createdAt = stored.createdAt
        expected.updatedAt = stored.updatedAt
        #expect(stored == expected)
        #expect(stored.updatedAt.timeIntervalSince1970 == pending.updatedAt.timeIntervalSince1970)
        // An empty retry makes no write, not even a harmless upsert.
        try database.execChecked("""
            CREATE TRIGGER reject_noop BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'must not write'); END;
            """)
        #expect(controller.retryPendingPersistence() == 0)
        #expect(controller.lastPersistenceError == nil)
    }

    @Test("Independent pending failures survive unrelated success and selective retry")
    func multiplePendingErrors() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        try database.execChecked("""
            CREATE TRIGGER reject_first BEFORE INSERT ON jobs WHEN NEW.remote_id = 'first'
            BEGIN SELECT RAISE(ABORT, 'first failure'); END;
            CREATE TRIGGER reject_second BEFORE INSERT ON jobs WHEN NEW.remote_id = 'second'
            BEGIN SELECT RAISE(ABORT, 'second failure'); END;
            """)
        let first = try #require(controller.recordVideoSubmission(remoteID: "first", modelID: "test/video", remoteStatus: "queued"))
        let second = try #require(controller.recordVideoSubmission(remoteID: "second", modelID: "test/video", remoteStatus: "completed"))
        _ = controller.recordVideoSubmission(remoteID: "saved", modelID: "test/video", remoteStatus: "queued")
        #expect(controller.unsavedRecordCount == 2)
        #expect(controller.persistenceErrors[first.id]?.contains("first failure") == true)
        #expect(controller.persistenceErrors[second.id]?.contains("second failure") == true)
        #expect(controller.lastPersistenceError != nil)
        #expect(controller.allJobs().count == 3)
        #expect(controller.downloadableJobs().map(\.id) == [second.id])
        try database.execChecked("DROP TRIGGER reject_first;")
        #expect(controller.retryPendingPersistence() == 1)
        #expect(controller.unsavedRecordCount == 1)
        #expect(controller.persistenceErrors[first.id] == nil)
        #expect(controller.persistenceErrors[second.id]?.contains("second failure") == true)
        #expect(controller.lastPersistenceError?.contains("second failure") == true)
        #expect(controller.retryPendingPersistence(id: first.id) == 0)
        try database.execChecked("DROP TRIGGER reject_second;")
        #expect(controller.retryPendingPersistence(id: second.id) == 1)
        #expect(controller.lastPersistenceError == nil)
        #expect(try database.loadJobRecordsChecked().count == 3)
    }

    @Test("Unknown submissions without remote IDs retain distinct identities and retry only local storage")
    func unknownSubmissionsRetryLocally() async throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let transport = InitialPersistenceTransport()
        let service = VideoGenService(transport: transport, jobController: controller)
        try database.execChecked("""
            CREATE TRIGGER reject_unknown BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'unknown write failure'); END;
            """)
        let model = "pending-unknown-\(UUID().uuidString)"
        for _ in 0..<2 {
            do {
                _ = try await service.submitAndPoll(VideoGenRequest(model: model, prompt: "unknown"))
                Issue.record("Expected an unknown submission outcome")
            } catch is URLError { }
        }
        let pending = controller.pendingRecords
        #expect(Set(pending.map(\.id)).count == 2)
        #expect(pending.allSatisfy { $0.remoteID == nil && $0.submissionState == .outcomeUnknown })
        #expect(service.unsavedJobRecordCount == 2)
        #expect(service.unsavedJobRecords == pending)
        #expect(service.jobPersistenceWarning?.contains("quit") == true)
        #expect(service.resumableRecords.isEmpty)
        #expect(service.downloadableRecords.isEmpty)
        try database.execChecked("DROP TRIGGER reject_unknown;")
        #expect(service.retryPendingJobPersistence() == 2)
        #expect(service.retryPendingJobPersistence() == 0)
        #expect(service.unsavedJobRecordCount == 0)
        #expect(service.jobPersistenceWarning == nil)
        #expect(transport.methods == ["POST", "POST"])
        let stored = try database.loadJobRecordsChecked()
        #expect(Set(stored.map(\.id)) == Set(pending.map(\.id)))
        for record in stored {
            let original = try #require(pending.first { $0.id == record.id })
            #expect(record.createdAt.timeIntervalSince1970 == original.createdAt.timeIntervalSince1970)
            #expect(record.updatedAt.timeIntervalSince1970 == original.updatedAt.timeIntervalSince1970)
            #expect(record.recoverableError == original.recoverableError)
        }
    }

    @Test("Saving a pending paid terminal job never resubmits, polls or adds another charge")
    func terminalRetryDoesNotRepeatPaidWork() async throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let remoteID = UUID().uuidString
        let model = "pending-paid-\(UUID().uuidString)"
        let transport = InitialPersistenceTransport(response: Data("""
            {"id":"\(remoteID)","status":"completed","usage":{"cost":0.75}}
            """.utf8))
        let service = VideoGenService(transport: transport, jobController: controller)
        let secondService = VideoGenService(transport: transport, jobController: controller)
        try database.execChecked("""
            CREATE TRIGGER reject_paid BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'paid record write failure'); END;
            """)
        _ = try await service.submitAndPoll(VideoGenRequest(model: model, prompt: "paid fixture"))
        let original = try #require(controller.pendingRecords.first)
        let revisionBeforeRetry = service.jobRecordsRevision
        #expect(secondService.jobRecordsRevision == revisionBeforeRetry)
        #expect(original.pollingState == .completed)
        #expect(service.downloadableRecords == [original])
        #expect(service.resumableRecords.isEmpty)
        #expect(service.unsavedJobRecordCount == 1)
        // A separate controller/process has no access to this memory queue.
        #expect(JobController(database: database).allJobs().isEmpty)
        let charged = try #require(UsageLedger.shared.buckets(.model).first { $0.key == model })
        #expect(charged.requests == 1)
        #expect(charged.cost == 0.75)
        try database.execChecked("DROP TRIGGER reject_paid;")
        #expect(service.retryPendingJobPersistence(id: original.id) == 1)
        #expect(service.retryPendingJobPersistence() == 0)
        #expect(service.jobRecordsRevision > revisionBeforeRetry)
        #expect(secondService.jobRecordsRevision == service.jobRecordsRevision)
        #expect(transport.methods == ["POST"])
        #expect(UsageLedger.shared.buckets(.model).first { $0.key == model } == charged)
        #expect(try database.loadJobRecordsChecked().count == 1)
        #expect(try database.findJobRecordChecked(id: original.id)?.prompt == "paid fixture")
    }

    @Test("Repeated submissions merge into the pending original instead of allocating another UUID")
    func repeatedPendingSubmission() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        try database.execChecked("""
            CREATE TRIGGER reject_repeat BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'repeat write failure'); END;
            """)
        let original = try #require(controller.recordVideoSubmission(
            remoteID: "repeat-pending", modelID: "original-model", conversationID: UUID(),
            messageID: UUID(), remoteStatus: "queued", cost: 0.5, prompt: "original prompt"
        ))
        let repeated = try #require(controller.recordVideoSubmission(
            remoteID: "repeat-pending", modelID: "replacement", remoteStatus: "running"
        ))
        #expect(repeated.id == original.id)
        #expect(repeated.createdAt == original.createdAt)
        #expect(repeated.modelID == original.modelID)
        #expect(repeated.conversationID == original.conversationID)
        #expect(repeated.messageID == original.messageID)
        #expect(repeated.prompt == original.prompt)
        #expect(repeated.usageCost == 0.5)
        #expect(repeated.lastRemoteStatus == "running")
        #expect(controller.pendingRecords == [repeated])
        #expect(controller.allJobs() == [repeated])
    }

    @Test("Pending-first lookups survive read faults without inventing absent records")
    func pendingLookupDuringReadFailure() throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        try database.execChecked("""
            CREATE TRIGGER reject_pending BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'pending write failure'); END;
            """)
        let original = try #require(controller.recordVideoSubmission(remoteID: "owned", modelID: "test/video", remoteStatus: "queued"))
        sqlite3_set_authorizer(database.db, { _, operation, table, _, _, _ in
            if operation == SQLITE_READ, let table, String(cString: table) == "jobs" { return SQLITE_DENY }
            return SQLITE_OK
        }, nil)
        defer { sqlite3_set_authorizer(database.db, nil, nil) }
        #expect(controller.record(id: original.id) == original)
        #expect(controller.record(remoteID: "owned") == original)
        #expect(controller.allJobs() == [original])
        #expect(controller.lastPersistenceError != nil)
        #expect(controller.recordVideoSubmission(remoteID: "unreadable", modelID: "test/video", remoteStatus: "queued") == nil)
        #expect(controller.unsavedRecordCount == 1)
        controller.recordPollUpdate(remoteID: "owned", remoteStatus: "running", error: nil, cost: 0)
        #expect(controller.record(id: original.id)?.usageCost == 0)
        #expect(controller.record(id: original.id)?.lastRemoteStatus == "running")
        #expect(controller.unsavedRecordCount == 1)
    }
}

private final class InitialPersistenceTransport: MediaTransport, @unchecked Sendable {
    private(set) var methods: [String] = []
    private let response: Data?

    init(response: Data? = nil) {
        self.response = response
        super.init(apiKeyProvider: { "fixture-key" })
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        methods.append(request.httpMethod ?? "GET")
        if let response { return try JSONDecoder().decode(T.self, from: response) }
        throw URLError(.timedOut)
    }
}
