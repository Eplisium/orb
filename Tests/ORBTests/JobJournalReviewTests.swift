import Darwin
import Foundation
import SQLite3
import Testing
@testable import ORB

// Lead-owned RED/GREEN execution only; this file was authored without compilation.
// All databases and journals are disposable scratch fixtures. No shared service,
// Keychain, provider request, or usage-ledger access is required.
//
// The lead reproduced the six original behavioral regressions before these
// repairs. afterRename / afterUnlink fire after the syscall and before directory
// fsync; injected throws model sync failure, not process kill or power loss.
// Additional resolution/race variants below are authored but not executed by
// this delegate. The lead owns compilation and RED/GREEN verification.

@Suite("Job journal blocking review regressions", .serialized)
@MainActor
struct JobJournalReviewTests {
    @Test("Launch fallback SQLite must retain journal snapshots rather than acknowledge volatile writes")
    func fallbackDatabaseLaunchPreservesJournal() throws {
        let previousLaunchFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = previousLaunchFailure }
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makePending(status: "completed")
        let before = try Data(contentsOf: fixture.entry(candidate.id))
        // A regular file as the parent guarantees SQLITE_CANTOPEN even as root.
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocker)
        let fallback = DatabaseManager(path: blocker.appendingPathComponent("jobs.sqlite3").path)
        _ = try #require(fallback.launchFailure)
        _ = try #require(fallback.db) // Exercise a functioning, but volatile, fallback.

        let recovered = JobController.launched(database: fallback, recoveryDirectory: fixture.journal)
        #expect(recovered.unsavedRecordCount == 1)
        #expect(recovered.pendingRecords.map(\.id) == [candidate.id])
        #expect(recovered.lastPersistenceError != nil)
        #expect(recovered.retryPendingPersistence(id: candidate.id) == 0)
        // Use #require before Data(contentsOf:) to report loss rather than an
        // incidental Cocoa file-not-found exception masking the regression.
        try #require(FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
        #expect(try Data(contentsOf: fixture.entry(candidate.id)) == before)

        let disk = fixture.openDatabase()
        try disk.execChecked("DROP TRIGGER reject_review_insert;")
        let nextLaunch = JobController.launched(database: disk, recoveryDirectory: fixture.journal)
        #expect(try JobRecoveryEnvelope.same(try #require(nextLaunch.record(id: candidate.id)), candidate))
        #expect(nextLaunch.unsavedRecordCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
    }

    @Test("A stale controller can explicitly save its newer terminal cost and creation link without reopening")
    func competingGenerationAllowsExplicitLocalResolution() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        try fixture.rejectInserts(database)
        let first = fixture.controller(database)
        let second = fixture.controller(fixture.openDatabase())
        let initial = try #require(first.recordVideoSubmission(
            remoteID: "review-shared", modelID: "fixture/video", remoteStatus: "queued", cost: 0.25,
            prompt: "retain the original identity"
        ))
        let g1 = try fixture.envelope(initial.id)
        _ = try #require(second.recordVideoSubmission(
            remoteID: "review-shared", modelID: "fixture/video", remoteStatus: "running", cost: 0.5
        ))
        let g2 = try fixture.envelope(initial.id)
        try #require(g1.generation != g2.generation)
        let diskBytes = try Data(contentsOf: fixture.entry(initial.id))
        first.recordTerminal(remoteID: "review-shared", remoteStatus: "completed", error: nil, cost: 9)
        let creationID = UUID()
        first.recordSavedCreation(remoteID: "review-shared", creationID: creationID)
        let local = try #require(first.record(id: initial.id))
        #expect(local.pollingState == .completed)
        #expect(local.usageCost == 9)
        #expect(local.savedCreationID == creationID)
        #expect(first.memoryOnlyRecordIDs.contains(initial.id))
        #expect(try Data(contentsOf: fixture.entry(initial.id)) == diskBytes)

        try database.execChecked("DROP TRIGGER reject_review_insert;")
        // Ordinary retry must not silently take over the competing generation.
        #expect(first.retryPendingPersistence(id: initial.id) == 0)
        #expect(try Data(contentsOf: fixture.entry(initial.id)) == diskBytes)
        #expect(first.persistenceConflicts[initial.id] != nil)
        let transport = JobJournalReviewOfflineTransport()
        let service = VideoGenService(transport: transport, jobController: first)
        #expect(service.resolveJobPersistenceConflict(id: initial.id, resolution: .retryCandidate))
        #expect(transport.callCount == 0)
        #expect(first.pendingRecords.isEmpty)
        #expect(first.memoryOnlyRecordIDs.isEmpty)
        #expect(first.persistenceConflicts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(initial.id).path))
        let saved = try #require(try database.findJobRecordChecked(id: initial.id))
        #expect(try JobRecoveryEnvelope.same(saved, local))
        let reopened = fixture.controller(fixture.openDatabase())
        #expect(try JobRecoveryEnvelope.same(try #require(reopened.record(id: initial.id)), local))
        #expect(reopened.allJobs().count == 1)
    }

    @Test("Post-rename directory sync failure cannot strand the installed generation")
    func postRenameSyncFailureCanRetryInSameController() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        try fixture.rejectInserts(database)
        let fault = JobJournalReviewOneShotFault(point: "afterRename")
        let controller = JobController(database: database, recoveryDirectory: fixture.journal,
                                       recoveryFault: { try fault.inject($0) })
        let record = try #require(controller.recordVideoSubmission(
            remoteID: "rename-sync", modelID: "fixture/video", remoteStatus: "completed", cost: 1
        ))
        try #require(fault.hitCount == 1, "Requires approved afterRename hook before directory fsync; not yet a behavioral RED")
        #expect(controller.unsavedRecordCount == 1)
        #expect(controller.lastPersistenceError != nil)
        #expect(try database.loadJobRecordsChecked().isEmpty)
        let installed = try fixture.envelope(record.id)
        #expect(try JobRecoveryEnvelope.same(installed.candidate, record))

        // No restart: this is specifically the stale in-process generation bug.
        // SQLite still fails here, so the replacement must reach the journal.
        let creationID = UUID()
        controller.recordSavedCreation(remoteID: "rename-sync", creationID: creationID)
        #expect(try fixture.envelope(record.id).candidate.savedCreationID == creationID)
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        #expect(controller.retryPendingPersistence(id: record.id) == 1)
        #expect(controller.unsavedRecordCount == 0)
        #expect(controller.lastPersistenceError == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(record.id).path))
        let saved = try #require(try fixture.openDatabase().findJobRecordChecked(id: record.id))
        #expect(saved.savedCreationID == creationID)
        #expect(saved.pollingState == .completed)
        #expect(saved.usageCost == 1)
    }

    @Test("Post-unlink directory sync failure permits cleanup retry and later lifecycle writes")
    func postUnlinkSyncFailureCanRetryInSameController() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let fault = JobJournalReviewOneShotFault(point: "afterUnlink")
        let controller = JobController(database: database, recoveryDirectory: fixture.journal,
                                       recoveryFault: { try fault.inject($0) })
        let record = try #require(controller.recordVideoSubmission(
            remoteID: "unlink-sync", modelID: "fixture/video", remoteStatus: "completed", cost: 2
        ))
        try #require(fault.hitCount == 1, "Requires approved afterUnlink hook before directory fsync; not yet a behavioral RED")
        #expect(controller.unsavedRecordCount == 0) // SQLite really committed.
        #expect(controller.lastPersistenceError != nil) // fsync failure is not success.
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(record.id).path))
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: record.id)), record))
        #expect(controller.retryPendingPersistence(id: record.id) == 0) // cleanup, not another save
        #expect(controller.lastPersistenceError == nil)
        let creationID = UUID()
        controller.recordSavedCreation(remoteID: "unlink-sync", creationID: creationID)
        #expect(controller.unsavedRecordCount == 0)
        #expect(controller.lastPersistenceError == nil)
        #expect(try fixture.openDatabase().findJobRecordChecked(id: record.id)?.savedCreationID == creationID)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(record.id).path))
    }

    @Test("A partial filesystem mutation followed immediately by a newer write preserves that write", arguments: ["afterRename", "afterUnlink"])
    func partialMutationAllowsImmediateLifecycleWrite(point: String) throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let fault = JobJournalReviewOneShotFault(point: point)
        let controller = JobController(database: database, recoveryDirectory: fixture.journal, recoveryFault: { try fault.inject($0) })
        let original = try #require(controller.recordVideoSubmission(remoteID: "partial-then-write", modelID: "fixture/video", remoteStatus: "completed", cost: 4))
        #expect(fault.hitCount == 1)
        #expect(controller.unsavedRecordCount == 0) // SQLite succeeded in either case.
        let creation = UUID()
        // No retry/cleanup between the partial filesystem outcome and mutation.
        controller.recordSavedCreation(remoteID: "partial-then-write", creationID: creation)
        #expect(controller.unsavedRecordCount == 0)
        #expect(controller.lastPersistenceError == nil)
        #expect(try fixture.openDatabase().findJobRecordChecked(id: original.id)?.savedCreationID == creation)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(original.id).path))
    }

    @Test("Keep durable must exclude another SQLite writer until the reviewed candidate is discarded")
    func keepDurableRejectsChangeBetweenValidationAndDiscard() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makePending(status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        var reviewed = candidate
        reviewed.usageCost = 10
        try database.saveJobRecordChecked(reviewed)
        let otherConnection = fixture.openDatabase()
        // Never wait on a writer reservation held by the resolver itself.
        sqlite3_busy_timeout(otherConnection.db, 0)
        var later = reviewed
        later.usageCost = 20
        later.savedCreationID = UUID()
        var reachedDiscard = false
        var racedWriteCommitted = false
        var writerWasExcluded = false
        let controller = JobController(database: database, recoveryDirectory: fixture.journal, recoveryFault: { operation in
            guard operation == .acknowledge else { return }
            reachedDiscard = true
            do {
                try otherConnection.saveJobRecordChecked(later)
                racedWriteCommitted = true
            } catch {
                let code = sqlite3_errcode(otherConnection.db)
                guard code == SQLITE_BUSY || code == SQLITE_LOCKED else { throw error }
                writerWasExcluded = true
            }
        })
        try #require(controller.persistenceConflicts[candidate.id] != nil)
        let journalBefore = try Data(contentsOf: fixture.entry(candidate.id))
        let resolved = controller.resolvePendingPersistence(id: candidate.id, resolution: .keepDurable)
        try #require(reachedDiscard)
        #expect(racedWriteCommitted != writerWasExcluded)
        if racedWriteCommitted {
            // If a fix allows the writer, it must detect the changed review and
            // preserve the candidate. It cannot report successful discarding.
            #expect(!resolved)
            #expect(controller.pendingRecords.map(\.id) == [candidate.id])
            try #require(FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
            #expect(try Data(contentsOf: fixture.entry(candidate.id)) == journalBefore)
            #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: candidate.id)), later))
        } else {
            #expect(writerWasExcluded)
            #expect(resolved)
            #expect(controller.pendingRecords.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.entry(candidate.id).path))
            #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: candidate.id)), reviewed))
        }
    }

    @Test("All three reviewed snapshot choices preserve exactly the selected data", arguments: [JobPersistenceResolution.keepDurable, .retryCandidate, .useJournal])
    func threeWayResolution(resolution: JobPersistenceResolution) throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let first = fixture.controller(database)
        let base = try #require(first.recordVideoSubmission(remoteID: "three-way", modelID: "fixture/video", remoteStatus: "queued", cost: 0, prompt: "base prompt"))
        try database.execChecked("CREATE TRIGGER reject_review_update BEFORE UPDATE ON jobs BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
        first.recordPollUpdate(remoteID: "three-way", remoteStatus: "running", error: nil, cost: 1)
        let second = fixture.controller(fixture.openDatabase())
        second.recordPollUpdate(remoteID: "three-way", remoteStatus: "running", error: "journal detail", cost: 2)
        let disk = try fixture.envelope(base.id)
        first.recordTerminal(remoteID: "three-way", remoteStatus: "completed", error: nil, cost: 9)
        first.recordSavedCreation(remoteID: "three-way", creationID: UUID())
        let local = try #require(first.record(id: base.id))
        let review = try #require(first.persistenceConflicts[base.id])
        #expect(review.competingJournal)
        #expect(try JobRecoveryEnvelope.same(try #require(review.candidate), local))
        #expect(try JobRecoveryEnvelope.same(try #require(review.journal).candidate, disk.candidate))
        #expect(try JobRecoveryEnvelope.same(try #require(review.durable), base))
        try database.execChecked("DROP TRIGGER reject_review_update;")
        #expect(first.resolvePendingPersistence(id: base.id, resolution: resolution, reviewToken: review.reviewToken))
        let expected = resolution == .keepDurable ? base : (resolution == .useJournal ? disk.candidate : local)
        let reopened = fixture.openDatabase()
        #expect(try JobRecoveryEnvelope.same(try #require(try reopened.findJobRecordChecked(id: base.id)), expected))
        #expect(try reopened.loadJobRecordsChecked().count == 1)
        #expect(first.pendingRecords.isEmpty)
        #expect(first.persistenceConflicts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(base.id).path))
    }

    @Test("Every resolution rejects an unreviewed journal replacement", arguments: [JobPersistenceResolution.keepDurable, .retryCandidate, .useJournal])
    func resolutionChecksDiskGeneration(resolution: JobPersistenceResolution) throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let local = try fixture.makePending(status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        var durable = local
        durable.usageCost = 55
        try database.saveJobRecordChecked(durable)
        let controller = fixture.controller(database)
        let review = try #require(controller.persistenceConflicts[local.id])
        let journal = JobRecoveryJournal(directory: fixture.journal)
        let replacement = try journal.withAccess { access in
            let old = try #require(try access.read(local.id))
            var next = old.candidate
            next.savedCreationID = UUID()
            next.usageCost = 88
            next.prompt = "journal replaced after review"
            let entry = JobRecoveryEnvelope(candidate: next, expectedDurableBase: old.expectedDurableBase)
            try access.stage(entry, replacing: old.generation)
            return entry
        }
        let bytes = try Data(contentsOf: fixture.entry(local.id))
        #expect(!controller.resolvePendingPersistence(id: local.id, resolution: resolution, reviewToken: review.reviewToken))
        #expect(try Data(contentsOf: fixture.entry(local.id)) == bytes)
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: local.id)), durable))
        #expect(controller.retryPendingPersistence(id: local.id) == 0)
        let refreshed = try #require(controller.persistenceConflicts[local.id])
        #expect(refreshed.journal?.generation == replacement.generation)
        #expect(refreshed.reviewToken != review.reviewToken)
        #expect(controller.resolvePendingPersistence(id: local.id, resolution: resolution, reviewToken: refreshed.reviewToken))
        let expected = resolution == .keepDurable ? durable : (resolution == .useJournal ? replacement.candidate : local)
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: local.id)), expected))
    }

    @Test("A peer committing and removing its journal still leaves the newer local candidate reviewable")
    func peerAcknowledgementDoesNotEraseLocalCandidate() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        try fixture.rejectInserts(database)
        let first = fixture.controller(database)
        let initial = try #require(first.recordVideoSubmission(remoteID: "peer-ack", modelID: "fixture/video", remoteStatus: "queued", cost: 1))
        let peer = fixture.controller(fixture.openDatabase())
        peer.recordPollUpdate(remoteID: "peer-ack", remoteStatus: "running", error: nil, cost: 2)
        first.recordTerminal(remoteID: "peer-ack", remoteStatus: "completed", error: nil, cost: 9)
        first.recordSavedCreation(remoteID: "peer-ack", creationID: UUID())
        let local = try #require(first.record(id: initial.id))
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        #expect(peer.retryPendingPersistence(id: initial.id) == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(initial.id).path))
        #expect(try JobRecoveryEnvelope.same(try #require(first.record(id: initial.id)), local))
        let review = try #require(first.persistenceConflicts[initial.id])
        #expect(review.journal == nil)
        #expect(review.durable?.usageCost == 2)
        #expect(!first.resolvePendingPersistence(id: initial.id, resolution: .useJournal, reviewToken: review.reviewToken))
        #expect(first.resolvePendingPersistence(id: initial.id, resolution: .retryCandidate, reviewToken: review.reviewToken))
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: initial.id)), local))
    }

    @Test("A displayed review cannot discard a later local saved-creation link")
    func reviewTokenProtectsNewLocalSnapshot() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let local = try fixture.makePending(status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        var durable = local
        durable.usageCost = 77
        try database.saveJobRecordChecked(durable)
        let controller = fixture.controller(database)
        let old = try #require(controller.persistenceConflicts[local.id])
        let creation = UUID()
        controller.recordSavedCreation(remoteID: "review-pending", creationID: creation)
        let latest = try #require(controller.record(id: local.id))
        #expect(latest.savedCreationID == creation)
        #expect(!controller.resolvePendingPersistence(id: local.id, resolution: .keepDurable, reviewToken: old.reviewToken))
        #expect(controller.pendingRecords.first?.savedCreationID == creation)
        let fresh = try #require(controller.persistenceConflicts[local.id])
        #expect(fresh.reviewToken != old.reviewToken)
        #expect(controller.resolvePendingPersistence(id: local.id, resolution: .retryCandidate, reviewToken: fresh.reviewToken))
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: local.id)), latest))
    }

    @Test("Keep SQLite can finish a post-unlink sync failure without restarting")
    func keepDurableRetriesPartialDiscard() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let local = try fixture.makePending(status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        var durable = local
        durable.usageCost = 33
        try database.saveJobRecordChecked(durable)
        let fault = JobJournalReviewOneShotFault(point: "afterUnlink")
        let controller = JobController(database: database, recoveryDirectory: fixture.journal, recoveryFault: { try fault.inject($0) })
        let review = try #require(controller.persistenceConflicts[local.id])
        #expect(!controller.resolvePendingPersistence(id: local.id, resolution: .keepDurable, reviewToken: review.reviewToken))
        #expect(controller.unsavedRecordCount == 1)
        #expect(fault.hitCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(local.id).path))
        #expect(controller.resolvePendingPersistence(id: local.id, resolution: .keepDurable, reviewToken: review.reviewToken))
        #expect(controller.pendingRecords.isEmpty)
        #expect(controller.lastPersistenceError == nil)
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: local.id)), durable))
    }

    @Test("A partial acknowledgement cannot later delete a replacement generation")
    func partialAckRejectsReplacement() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let fault = JobJournalReviewOneShotFault(point: "afterUnlink")
        let controller = JobController(database: database, recoveryDirectory: fixture.journal, recoveryFault: { try fault.inject($0) })
        let original = try #require(controller.recordVideoSubmission(remoteID: "partial-ack", modelID: "fixture/video", remoteStatus: "completed", cost: 1))
        var next = original
        next.savedCreationID = UUID()
        next.prompt = "new independent generation"
        let replacement = JobRecoveryEnvelope(candidate: next, expectedDurableBase: .snapshot(original))
        try JobRecoveryJournal(directory: fixture.journal).withAccess { try $0.stage(replacement, replacing: nil) }
        let before = try Data(contentsOf: fixture.entry(original.id))
        #expect(controller.retryPendingPersistence(id: original.id) == 0)
        #expect(try Data(contentsOf: fixture.entry(original.id)) == before)
        let review = try #require(controller.persistenceConflicts[original.id])
        #expect(review.journal?.generation == replacement.generation)
        #expect(controller.resolvePendingPersistence(id: original.id, resolution: .useJournal, reviewToken: review.reviewToken))
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: original.id)), next))
    }

    @Test("Keep SQLite holds its connection mutex against raw same-connection writes during discard")
    func keepDurableExcludesRawConnectionWriter() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let local = try fixture.makePending(status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        var durable = local
        durable.usageCost = 10
        try database.saveJobRecordChecked(durable)
        let probe = JobJournalReviewRawWriter(db: try #require(database.db), id: local.id)
        var reachedDiscard = false
        var finishedInsideReservation = false
        let controller = JobController(database: database, recoveryDirectory: fixture.journal, recoveryFault: { operation in
            guard operation == .acknowledge else { return }
            reachedDiscard = true
            DispatchQueue.global().async { probe.write() }
            guard probe.started.wait(timeout: .now() + .seconds(2)) == .success else {
                throw JobRecoveryJournalError.unavailable
            }
            finishedInsideReservation = probe.done.wait(timeout: .now() + .milliseconds(150)) == .success
        })
        let resolved = controller.resolvePendingPersistence(id: local.id, resolution: .keepDurable)
        #expect(reachedDiscard)
        #expect(!finishedInsideReservation)
        #expect(resolved)
        if !finishedInsideReservation {
            try #require(probe.done.wait(timeout: .now() + .seconds(2)) == .success)
        }
        #expect(probe.result == SQLITE_OK)
        #expect(try database.findJobRecordChecked(id: local.id)?.usageCost == 999)
        #expect(controller.pendingRecords.isEmpty)
    }

    @Test("Oversized regular journal entries are rejected without unbounded allocation")
    func boundedRegularEntryRead() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.journal, withIntermediateDirectories: true)
        let id = UUID()
        let fd = open(fixture.entry(id).path, O_CREAT | O_WRONLY | O_EXCL, mode_t(0o600))
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(ftruncate(fd, off_t(JobRecoveryJournal.maximumEntryBytes + 1)) == 0)
        #expect(throws: JobRecoveryJournalError.self) {
            try JobRecoveryJournal(directory: fixture.journal).withAccess { try $0.read(id) }
        }
        var info = stat()
        #expect(fstat(fd, &info) == 0)
        #expect(info.st_size == off_t(JobRecoveryJournal.maximumEntryBytes + 1))
    }

    @Test("Explicit resolution retains the chosen creation timestamp as well as updated timestamp")
    func resolutionRetainsBothTimestamps() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let candidate = try fixture.makePending(status: "completed")
        let database = fixture.openDatabase()
        try database.execChecked("DROP TRIGGER reject_review_insert;")
        var durable = candidate
        durable.createdAt = Date(timeIntervalSince1970: 1234)
        durable.updatedAt = Date(timeIntervalSince1970: 5678)
        try database.saveJobRecordChecked(durable)
        let controller = fixture.controller(database)
        let review = try #require(controller.persistenceConflicts[candidate.id])
        #expect(controller.resolvePendingPersistence(id: candidate.id, resolution: .retryCandidate, reviewToken: review.reviewToken))
        #expect(try JobRecoveryEnvelope.same(try #require(try database.findJobRecordChecked(id: candidate.id)), candidate))
    }

    @Test("An older failed acknowledgement cannot replace a newer memory-only creation link")
    func oldAckDoesNotOverwriteNewPending() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        let database = fixture.openDatabase()
        let controller = JobController(database: database, recoveryDirectory: fixture.journal, recoveryFault: { operation in
            if operation == .acknowledge { throw JobRecoveryJournalError.unavailable }
        })
        let original = try #require(controller.recordVideoSubmission(remoteID: "old-ack-new-local", modelID: "fixture/video", remoteStatus: "completed", cost: 3))
        let creation = UUID()
        try JobRecoveryJournal(directory: fixture.journal).withAccess { _ in
            controller.recordSavedCreation(remoteID: "old-ack-new-local", creationID: creation)
            #expect(controller.unsavedRecordCount == 1)
            #expect(controller.memoryOnlyRecordIDs.contains(original.id))
        }
        #expect(controller.retryPendingPersistence(id: original.id) == 1)
        #expect(try database.findJobRecordChecked(id: original.id)?.savedCreationID == creation)
        #expect(try fixture.envelope(original.id).candidate.savedCreationID == creation)
        #expect(controller.pendingRecords.isEmpty)
        // The injected acknowledgement failure remains honest; a fresh owner
        // can remove only the now-identical new generation.
        let fresh = fixture.controller(fixture.openDatabase())
        #expect(fresh.record(id: original.id)?.savedCreationID == creation)
        #expect(!FileManager.default.fileExists(atPath: fixture.entry(original.id).path))
    }

    @Test("Conflict presentation exposes full values rather than only state names")
    func fullConflictPresentation() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        var record = try fixture.makePending(status: "completed")
        record.savedCreationID = UUID()
        record.prompt = "visible prompt\u{0}suffix\nnew line"
        let text = JobPersistenceConflict.describe(record)
        #expect(text.contains(record.savedCreationID!.uuidString))
        #expect(text.contains(String(reflecting: record.prompt!)))
        #expect(text.contains("Cost (USD): 0.25"))
        #expect(text.contains(String(record.createdAt.timeIntervalSince1970)))
        #expect(text.contains(String(record.updatedAt.timeIntervalSince1970)))
        record.usageCost = nil
        #expect(JobPersistenceConflict.describe(record).contains("Cost (USD): unknown"))
        record.usageCost = 0
        #expect(JobPersistenceConflict.describe(record).contains("Cost (USD): 0.0"))
    }

    @Test("FIFO journal entries are rejected without needing a writer to unblock open")
    func fifoEntryRejectsWithoutBlockingOpen() throws {
        let fixture = try JobJournalReviewFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.journal, withIntermediateDirectories: true)
        let id = UUID()
        let path = fixture.entry(id).path
        try #require(mkfifo(path, mode_t(0o600)) == 0)
        let probe = JobJournalReviewFIFOProbe(directory: fixture.journal, id: id)
        // Never invoke the reviewed potentially-blocking open on the test actor.
        DispatchQueue.global(qos: .userInitiated).async { probe.read() }
        let finishedWithoutWriter = probe.done.wait(timeout: .now() + .seconds(1)) == .success
        if !finishedWithoutWriter {
            // O_RDWR|O_NONBLOCK cannot wait for a peer and keeps a writer present
            // even if the reader worker has not yet been scheduled. The probe
            // owns this rescue descriptor until read finishes (including a
            // timeout), so no blocked worker escapes after the test closes it.
            let rescueFD = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            try #require(rescueFD >= 0, "Could not establish nonblocking FIFO watchdog rescue")
            probe.installRescue(rescueFD)
            #expect(probe.done.wait(timeout: .now() + .seconds(2)) == .success,
                    "FIFO read worker did not finish after a nonblocking writer was attached")
        }
        #expect(finishedWithoutWriter, "A FIFO blocked open until watchdog attached a writer; openat needs O_NONBLOCK before fstat")
        #expect(probe.rejectedAsCorrupt)
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFIFO) // reject, do not consume/delete
    }
}

@MainActor
private struct JobJournalReviewFixture {
    let root: URL
    var journal: URL { root.appendingPathComponent("pending-jobs", isDirectory: true) }

    init() throws {
        root = ORBTestScratch.root
            .appendingPathComponent("ORB-job-journal-review-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func openDatabase() -> DatabaseManager {
        DatabaseManager(path: root.appendingPathComponent("jobs.sqlite3").path)
    }

    func controller(_ database: DatabaseManager) -> JobController {
        JobController(database: database, recoveryDirectory: journal)
    }

    func entry(_ id: UUID) -> URL { journal.appendingPathComponent("\(id.uuidString).json") }

    func envelope(_ id: UUID) throws -> JobRecoveryEnvelope {
        try JobRecoveryJournal(directory: journal).withAccess { access in
            try #require(try access.read(id))
        }
    }

    func rejectInserts(_ database: DatabaseManager) throws {
        try database.execChecked("""
            CREATE TRIGGER reject_review_insert BEFORE INSERT ON jobs
            BEGIN SELECT RAISE(ABORT, 'injected review insert failure'); END;
            """)
    }

    func makePending(status: String) throws -> JobRecord {
        let database = openDatabase()
        try rejectInserts(database)
        let owner = controller(database)
        let record = try #require(owner.recordVideoSubmission(
            remoteID: "review-pending", modelID: "fixture/video", remoteStatus: status, cost: 0.25,
            prompt: "full snapshot survives"
        ))
        try #require(owner.unsavedRecordCount == 1)
        return record
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private final class JobJournalReviewRawWriter: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    private let db: OpaquePointer
    private let id: UUID
    private let lock = NSLock()
    private var code: Int32 = SQLITE_ERROR
    var result: Int32 { lock.lock(); defer { lock.unlock() }; return code }

    init(db: OpaquePointer, id: UUID) { self.db = db; self.id = id }

    func write() {
        started.signal()
        // Deliberately bypass dbLock: the connection mutex must serialize this
        // legacy/raw API path across the resolver's complete reservation.
        let result = sqlite3_exec(db, "UPDATE jobs SET usage_cost = 999 WHERE id = '\(id.uuidString)';", nil, nil, nil)
        lock.lock(); code = result; lock.unlock()
        done.signal()
    }
}

private final class JobJournalReviewOneShotFault {
    let point: String
    private(set) var hitCount = 0

    init(point: String) { self.point = point }

    func inject(_ operation: JobRecoveryJournal.Operation) throws {
        guard String(describing: operation) == point, hitCount == 0 else { return }
        hitCount += 1
        throw JobRecoveryJournalError.unavailable
    }
}

// State is protected independently of the test actor. Semaphore waits are bounded;
// even the buggy reader is rescued rather than leaking a permanently blocked task.
private final class JobJournalReviewFIFOProbe: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let directory: URL
    private let id: UUID
    private let lock = NSLock()
    private var finished = false
    private var corrupt = false
    private var rescueFD: Int32 = -1

    init(directory: URL, id: UUID) { self.directory = directory; self.id = id }

    var rejectedAsCorrupt: Bool {
        lock.lock(); defer { lock.unlock() }
        return corrupt
    }

    func installRescue(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        if finished { close(fd) } else { rescueFD = fd }
    }

    func read() {
        var rejected = false
        do {
            _ = try JobRecoveryJournal(directory: directory).withAccess { try $0.read(id) }
        } catch JobRecoveryJournalError.corrupt {
            rejected = true
        } catch { /* Report unexpected errors via rejectedAsCorrupt, not off-task issues. */ }
        lock.lock()
        corrupt = rejected
        finished = true
        if rescueFD >= 0 { close(rescueFD); rescueFD = -1 }
        lock.unlock()
        done.signal()
    }
}

private final class JobJournalReviewOfflineTransport: MediaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    init() { super.init(apiKeyProvider: { "offline-fixture-key" }) }

    private func unexpected() {
        lock.lock(); calls += 1; lock.unlock()
        Issue.record("Journal conflict resolution must not call a transport")
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        unexpected(); throw URLError(.notConnectedToInternet)
    }

    override func sendRaw(_ request: URLRequest) async throws -> (Data, String?) {
        unexpected(); throw URLError(.notConnectedToInternet)
    }

    override func downloadToFile(_ request: URLRequest) async throws -> (URL, String?) {
        unexpected(); throw URLError(.notConnectedToInternet)
    }
}
