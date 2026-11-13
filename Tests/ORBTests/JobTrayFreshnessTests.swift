import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Job tray snapshot freshness")
@MainActor
struct JobTrayFreshnessTests {
    @Test(
        "Resume rejects a queued tray snapshot after the controller learns the job is terminal",
        arguments: ["completed", "failed", "cancelled", "expired"], [false, true]
    )
    func staleQueuedSnapshotCannotRestartTerminalJob(
        terminalStatus: String,
        terminalWriteFails: Bool
    ) async throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let remoteID = "tray-freshness-\(UUID().uuidString)"
        // Any unexpected poll ends immediately with a non-retryable error.
        // Do not use a terminal-success fixture: that would touch accounting
        // and toasts, obscuring this preflight-only regression.
        let transport = MockMediaTransport(responses: [
            .status(400, #"{"error":{"message":"Unexpected stale-snapshot poll"}}"#)
        ])
        let service = VideoGenService(
            transport: transport,
            jobController: controller,
            retryPolicy: PollRetryPolicy(
                maxConsecutiveFailures: 0,
                baseDelay: .milliseconds(1),
                maxDelay: .milliseconds(1)
            )
        )
        defer { service.stopPolling() }

        controller.recordVideoSubmission(
            remoteID: remoteID, modelID: "test/tray-freshness",
            remoteStatus: "queued", prompt: "Offline snapshot regression"
        )
        // This is the actual service query passed into JobTrayButton.
        // Keeping the returned value models a popover left open across a
        // controller update, not a hand-built or mock JobRecord.
        let oldSnapshot = try #require(service.allJobRecords.first)
        #expect(oldSnapshot.lastRemoteStatus == "queued")
        #expect(oldSnapshot.isResumable)
        #expect(JobPresentation.make(oldSnapshot, hasLiveRun: false).actions == [.resume])
        let revisionBeforeTerminal = service.jobRecordsRevision

        if terminalWriteFails {
            try database.execChecked("""
                CREATE TRIGGER reject_tray_terminal_update BEFORE UPDATE ON jobs
                BEGIN SELECT RAISE(ABORT, 'injected terminal persistence failure'); END;
                """)
        }
        controller.recordTerminal(
            remoteID: remoteID, remoteStatus: terminalStatus, error: nil, cost: nil
        )
        let latest = try #require(controller.record(id: oldSnapshot.id))
        #expect(latest.pollingState == JobPollingState(remoteStatus: terminalStatus))
        #expect(!latest.isResumable)
        #expect(service.resumableRecords.isEmpty)
        #expect(service.allJobRecords == [latest])
        #expect(service.jobRecordsRevision > revisionBeforeTerminal)
        #expect(!JobPresentation.make(latest, hasLiveRun: false).actions.contains(.resume))
        #expect(service.activeJob == nil)
        if terminalWriteFails {
            // Lookup must prefer the pending terminal snapshot over both the
            // stale caller value AND the still-queued durable row.
            #expect(controller.unsavedRecordCount == 1)
            #expect(try database.findJobRecordChecked(id: oldSnapshot.id)?.pollingState == .polling)
        } else {
            #expect(controller.unsavedRecordCount == 0)
            #expect(try database.findJobRecordChecked(id: oldSnapshot.id)?.pollingState == latest.pollingState)
        }

        let updates = JobUpdateCollector()
        do {
            _ = try await service.resume(
                oldSnapshot, pollInterval: .milliseconds(1),
                onUpdate: { updates.append($0) }
            )
            Issue.record("A terminal job must reject Resume even when the caller retains its queued snapshot")
        } catch let error as MediaServiceError {
            if case .resumeUnavailable = error {
                // Expected: refusal before any callback, credential lookup,
                // active-job mutation, or transport request.
            } else {
                Issue.record("Expected resumeUnavailable before polling, received \(error)")
            }
        } catch {
            Issue.record("Expected resumeUnavailable, received \(error)")
        }

        #expect(transport.sentRequests().isEmpty)
        #expect(transport.submissions().isEmpty)
        #expect(transport.sentRawRequests().isEmpty)
        #expect(transport.keyCounter?.current == 0)
        #expect(updates.all.isEmpty)
        #expect(service.activeJob == nil)
        #expect(!service.isPolling)
        #expect(service.inFlightRemoteIDs.isEmpty)
        #expect(controller.record(id: oldSnapshot.id) == latest)
    }

    @Test("Missing or unreadable original UUID fails closed", arguments: [false, true])
    func missingOrUnreadableRecordCannotUseCallerSnapshot(readFails: Bool) async throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let remoteID = "tray-lookup-\(UUID().uuidString)"
        let oldSnapshot = try #require(controller.recordVideoSubmission(
            remoteID: remoteID, modelID: "test/tray", remoteStatus: "queued"
        ))
        let transport = MockMediaTransport(responses: [
            .status(400, #"{"error":{"message":"Unexpected poll"}}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        if readFails {
            sqlite3_set_authorizer(database.db, { _, operation, table, _, _, _ in
                if operation == SQLITE_READ, let table, String(cString: table) == "jobs" { return SQLITE_DENY }
                return SQLITE_OK
            }, nil)
        } else {
            try database.execChecked("DELETE FROM jobs")
            // A matching remote ID must not substitute for the original UUID.
            let replacement = try #require(controller.recordVideoSubmission(
                remoteID: remoteID, modelID: "test/replacement", remoteStatus: "queued"
            ))
            #expect(replacement.id != oldSnapshot.id)
        }
        defer { sqlite3_set_authorizer(database.db, nil, nil) }

        let updates = JobUpdateCollector()
        do {
            _ = try await service.resume(oldSnapshot, pollInterval: .milliseconds(1)) { updates.append($0) }
            Issue.record("An unavailable original record must reject resume")
        } catch let error as MediaServiceError {
            guard case .resumeUnavailable = error else {
                Issue.record("Expected resumeUnavailable, received \(error)")
                return
            }
        }
        #expect(transport.sentRequests().isEmpty)
        #expect(transport.keyCounter?.current == 0)
        #expect(updates.all.isEmpty)
        #expect(service.activeJob == nil)
        #expect(service.inFlightRemoteIDs.isEmpty)
        #expect((service.durablePersistenceError != nil) == readFails)
    }

    @Test("Resume seeds from the latest UUID snapshot, including pending updates", arguments: [false, true])
    func resumeUsesLatestNonterminalSnapshot(pendingUpdate: Bool) async throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let remoteID = "tray-latest-\(UUID().uuidString)"
        var snapshot = try #require(controller.recordVideoSubmission(
            remoteID: remoteID, modelID: "test/tray", remoteStatus: "queued", cost: 0.125
        ))
        if pendingUpdate {
            try database.execChecked("""
                CREATE TRIGGER reject_tray_latest_update BEFORE UPDATE ON jobs
                BEGIN SELECT RAISE(ABORT, 'injected latest update failure'); END;
                """)
        }
        controller.recordPollUpdate(remoteID: remoteID, remoteStatus: "running", error: nil, cost: 0.25)
        if pendingUpdate {
            // The controller already owns the newer snapshot; unreadable disk
            // must not prevent using it, or cause fallback to stale arguments.
            sqlite3_set_authorizer(database.db, { _, operation, table, _, _, _ in
                if operation == SQLITE_READ, let table, String(cString: table) == "jobs" { return SQLITE_DENY }
                return SQLITE_OK
            }, nil)
        }
        defer { sqlite3_set_authorizer(database.db, nil, nil) }
        snapshot.remoteID = "stale-caller-remote-id"
        let transport = MockMediaTransport(responses: [])
        let service = VideoGenService(transport: transport, jobController: controller)
        let updates = JobUpdateCollector()
        let run = Task {
            try await service.resume(snapshot, pollInterval: .seconds(3600)) { updates.append($0) }
        }
        defer { run.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.inFlightRemoteIDs.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(service.inFlightRemoteIDs == [remoteID])
        #expect(updates.all == [VideoJob(id: remoteID, status: "running", cost: 0.25)])
        #expect(transport.sentRequests().isEmpty)
        #expect(transport.keyCounter?.current == 0)
        run.cancel()
        _ = try? await run.value
        #expect(service.inFlightRemoteIDs.isEmpty)
    }

    @Test("Terminal preflight leaves the already-owned loop untouched")
    func terminalRefusalDoesNotCancelExistingLoop() async throws {
        let controller = JobController(database: DatabaseManager(path: ":memory:"))
        let snapshot = try #require(controller.recordVideoSubmission(
            remoteID: "tray-owned-loop", modelID: "test/tray", remoteStatus: "queued"
        ))
        let transport = MockMediaTransport(responses: [
            .status(400, #"{"error":{"message":"Unexpected poll"}}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        // The owned loop sleeps; this test never needs a transport response.
        let run = Task { try await service.resume(snapshot, pollInterval: .seconds(3600)) }
        defer { run.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !service.isRunInFlight(for: snapshot), ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(service.isRunInFlight(for: snapshot))
        let activeBefore = service.activeJob
        controller.recordTerminal(remoteID: "tray-owned-loop", remoteStatus: "completed", error: nil, cost: nil)
        let revisionBefore = service.jobRecordsRevision
        let updates = JobUpdateCollector()
        do {
            _ = try await service.resume(snapshot, pollInterval: .milliseconds(1)) { updates.append($0) }
            Issue.record("Expected terminal refusal")
        } catch let error as MediaServiceError {
            guard case .resumeUnavailable = error else {
                Issue.record("Expected resumeUnavailable, received \(error)")
                return
            }
        }
        #expect(service.isRunInFlight(for: snapshot))
        #expect(service.activeJob == activeBefore)
        #expect(service.jobRecordsRevision == revisionBefore)
        #expect(updates.all.isEmpty)
        #expect(transport.sentRequests().isEmpty)
        #expect(transport.keyCounter?.current == 0)
        run.cancel()
        _ = try? await run.value
        #expect(service.inFlightRemoteIDs.isEmpty)
    }

    @Test("Shared-controller tray inputs advance queued to terminal to saved", arguments: [false, true])
    func sharedControllerRevisionsRefreshTrayInputs(writesFail: Bool) throws {
        let database = DatabaseManager(path: ":memory:")
        let controller = JobController(database: database)
        let transport = MockMediaTransport(responses: [])
        let first = VideoGenService(transport: transport, jobController: controller)
        let second = VideoGenService(transport: transport, jobController: controller)
        let services = [first, second]
        let remoteID = "tray-stages-\(UUID().uuidString)"
        let initialRevision = first.jobRecordsRevision
        let submitted = try #require(controller.recordVideoSubmission(
            remoteID: remoteID, modelID: "test/tray", remoteStatus: "queued"
        ))
        // Compare against the canonical stored snapshot: Date -> Unix Double
        // round-trips can differ below a microsecond from the submission object.
        let snapshot = try #require(controller.record(id: submitted.id))
        for service in services {
            #expect(service.jobRecordsRevision > initialRevision)
            let tray = JobTrayButton(jobs: service.allJobRecords, onResume: { _ in }, onStop: { _ in })
            #expect(tray.jobs == [snapshot])
            #expect(JobTray.badgeText(tray.jobs) == "1")
            #expect(JobTray.summary(tray.jobs) == "1 active, 0 finished, 0 needs attention")
            #expect(JobPresentation.make(try #require(tray.jobs.first), hasLiveRun: false).actions == [.resume])
        }
        if writesFail {
            try database.execChecked("""
                CREATE TRIGGER reject_tray_stage_update BEFORE UPDATE ON jobs
                BEGIN SELECT RAISE(ABORT, 'injected tray stage failure'); END;
                """)
        }
        let queuedRevision = first.jobRecordsRevision
        controller.recordTerminal(remoteID: remoteID, remoteStatus: "completed", error: nil, cost: 0.125)
        for service in services {
            #expect(service.jobRecordsRevision > queuedRevision)
            let tray = JobTrayButton(jobs: service.allJobRecords, onResume: { _ in }, onStop: { _ in })
            let row = try #require(tray.jobs.first)
            #expect(row.id == snapshot.id)
            #expect(row.usageCost == 0.125)
            #expect(JobTray.badgeText(tray.jobs) == nil)
            #expect(JobTray.summary(tray.jobs) == "0 active, 1 finished, 0 needs attention")
            #expect(JobPresentation.make(row, hasLiveRun: false).actions == [.download])
            #expect(service.resumableRecords.isEmpty)
            #expect(service.downloadableRecords == [row])
        }
        let terminalRevision = first.jobRecordsRevision
        let creationID = UUID()
        controller.recordSavedCreation(remoteID: remoteID, creationID: creationID)
        for service in services {
            #expect(service.jobRecordsRevision > terminalRevision)
            let tray = JobTrayButton(jobs: service.allJobRecords, onResume: { _ in }, onStop: { _ in })
            let row = try #require(tray.jobs.first)
            #expect(row.id == snapshot.id)
            #expect(row.savedCreationID == creationID)
            #expect(JobPresentation.make(row, hasLiveRun: false).actions == [.open])
            #expect(service.downloadableRecords.isEmpty)
            #expect(service.activeJob == nil)
            #expect(service.unsavedJobRecordCount == (writesFail ? 1 : 0))
        }
        if writesFail {
            #expect(try database.findJobRecordChecked(id: snapshot.id)?.pollingState == .polling)
            let beforeRetry = second.jobRecordsRevision
            try database.execChecked("DROP TRIGGER reject_tray_stage_update")
            #expect(first.retryPendingJobPersistence(id: snapshot.id) == 1)
            #expect(second.jobRecordsRevision > beforeRetry)
            #expect(second.unsavedJobRecordCount == 0)
        }
        #expect(first.jobRecordsRevision == second.jobRecordsRevision)
        #expect(try database.findJobRecordChecked(id: snapshot.id)?.savedCreationID == creationID)
        #expect(transport.sentRequests().isEmpty)
        #expect(transport.keyCounter?.current == 0)
    }
}
