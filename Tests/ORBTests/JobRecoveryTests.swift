import Foundation
import SQLite3
import Testing
@testable import ORB

// W06 — durable jobs: migration, restart recovery, terminal monotonicity,
// and local-stop semantics. No network: every media flow uses the shared
// MockMediaTransport from MediaTransportTests.swift.

@Suite("Durable job migrations")
struct DurableJobMigrationTests {
    @Test("W06 migration creates job/asset tables without breaking legacy reads")
    func migrationCreatesNewTablesAndKeepsLegacyReads() throws {
        // A pre-W06 database: favorites + conversations + messages, but no
        // jobs/assets tables.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-w06-migration-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let legacySQL = """
        CREATE TABLE favorites (
            model_id TEXT PRIMARY KEY,
            added_at REAL NOT NULL,
            notes TEXT DEFAULT ''
        );
        INSERT INTO favorites (model_id, added_at, notes)
        VALUES ('legacy/model', 0, 'legacy note');
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY, mode TEXT NOT NULL, model_id TEXT NOT NULL,
            title TEXT NOT NULL, system_prompt TEXT DEFAULT '', total_cost REAL DEFAULT 0,
            total_tokens INTEGER DEFAULT 0, agent_history_json TEXT DEFAULT '[]', created_at REAL NOT NULL
        );
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
            content TEXT NOT NULL, tool_calls_json TEXT, tool_call_id TEXT, tool_name TEXT,
            sort_order INTEGER NOT NULL, created_at REAL NOT NULL,
            FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        );
        """
        #expect(sqlite3_exec(handle, legacySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        handle = nil

        // Opening through DatabaseManager runs the additive migration.
        let migrated = DatabaseManager(path: url.path)

        // Legacy data still loads.
        #expect(migrated.isFavorite("legacy/model"))
        #expect(migrated.getNotes("legacy/model") == "legacy note")

        // Existing write/read APIs still work on the migrated store.
        migrated.addFavorite("new/model")
        #expect(migrated.isFavorite("new/model"))
        var conversation = ChatConversation(modelId: "test/model", mode: .chat)
        conversation.messages = [ChatMessage(role: "user", content: "hello")]
        try migrated.saveConversationRecordChecked(conversation, agentHistoryJSON: "[]")
        #expect(migrated.loadMessages(for: conversation.id).first?.content == "hello")

        // The new tables exist and are usable on the migrated store.
        let now = Date()
        let record = JobRecord(
            id: UUID(), remoteID: "job-migrated", kind: "video",
            submissionState: .submitted, pollingState: .polling, lastRemoteStatus: "queued",
            conversationID: nil, messageID: nil, modelID: "test/model",
            usageCost: nil, recoverableError: nil, createdAt: now, updatedAt: now
        )
        try migrated.saveJobRecordChecked(record)
        #expect(migrated.findJobRecord(remoteID: "job-migrated")?.id == record.id)

        // A second launch on the same file reads everything back.
        let reopened = DatabaseManager(path: url.path)
        #expect(reopened.isFavorite("legacy/model"))
        #expect(reopened.loadMessages(for: conversation.id).first?.content == "hello")
        #expect(reopened.findJobRecord(remoteID: "job-migrated")?.pollingState == .polling)
    }
}

@Suite("Job controller recovery", .serialized)
@MainActor
struct JobRecoveryTests {
    // MARK: Restart recovery

    @Test("a job persisted before polling is recoverable after a restart")
    func jobPersistedBeforePollingSurvivesRestart() async throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-restore","status":"queued"}"#), // submit
            .hang                                              // poll hangs in flight
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        let run = Task {
            try await service.submitAndPoll(
                VideoGenRequest(model: "m", prompt: nil),
                pollInterval: .milliseconds(5)
            )
        }

        // The record must be persisted (keyed by the remote ID) before any
        // poll result is relied upon.
        var record: JobRecord?
        for _ in 0..<500 {
            record = controller.record(remoteID: "job-restore")
            if record != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(record?.remoteID == "job-restore")
        #expect(record?.submissionState == .submitted)
        #expect(record?.pollingState == .polling)

        // The user stops local polling, then the app "restarts".
        service.stopPolling()
        do {
            _ = try await run.value
            Issue.record("Expected local cancellation to surface as CancellationError.")
        } catch {
            #expect(error is CancellationError)
        }

        // A brand-new controller instance (fresh in-memory state) recovers
        // the job from durable storage.
        let revived = JobController(database: database)
        let resumable = revived.resumableJobs()
        #expect(resumable.contains {
            $0.remoteID == "job-restore"
                && $0.pollingState == .stoppedLocally
                && $0.lastRemoteStatus == "queued"
        })
        // The stopped job is explicitly NOT a remote cancellation and NOT a
        // remote failure.
        let stopped = revived.record(remoteID: "job-restore")
        #expect(stopped?.pollingState != .failed)
        #expect(stopped?.pollingState != .cancelled)
        #expect(stopped?.lastRemoteStatus == "queued")
    }

    // MARK: Terminal monotonicity

    @Test("a job never regresses from a terminal polling state")
    func terminalStatusIsMonotonic() throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(
            remoteID: "job-mono", modelID: "m", remoteStatus: "queued", cost: nil
        )

        controller.recordTerminal(remoteID: "job-mono", remoteStatus: "completed", error: nil, cost: 0.04)
        let terminal = try #require(controller.record(remoteID: "job-mono"))
        #expect(terminal.pollingState == .completed)
        #expect(terminal.usageCost == 0.04)

        // Later polls and later terminal reports must not regress it.
        controller.recordPollUpdate(remoteID: "job-mono", remoteStatus: "queued", error: nil, cost: nil)
        #expect(controller.record(remoteID: "job-mono")?.pollingState == .completed)
        controller.recordTerminal(remoteID: "job-mono", remoteStatus: "failed", error: "late failure", cost: nil)
        #expect(controller.record(remoteID: "job-mono")?.pollingState == .completed)
        controller.recordStoppedLocally(remoteID: "job-mono")
        #expect(controller.record(remoteID: "job-mono")?.pollingState == .completed)

        // A terminal job is no longer resumable.
        #expect(controller.resumableJobs().contains { $0.remoteID == "job-mono" } == false)
    }

    // MARK: Local stop semantics

    @Test("local stop preserves a resumable job and never claims remote cancellation")
    func localStopIsDistinctFromRemoteFailureOrCancellation() throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(
            remoteID: "job-stop", modelID: "m", remoteStatus: "running", cost: nil
        )

        controller.recordStoppedLocally(remoteID: "job-stop")
        let stopped = try #require(controller.record(remoteID: "job-stop"))
        #expect(stopped.pollingState == .stoppedLocally)
        // The last known remote state is preserved verbatim: stopping local
        // polling says nothing about the remote job.
        #expect(stopped.lastRemoteStatus == "running")
        #expect(stopped.recoverableError == nil)

        // Still resumable, and a resumed poll can still reach a terminal state.
        #expect(controller.resumableJobs().contains { $0.remoteID == "job-stop" })
        controller.recordTerminal(remoteID: "job-stop", remoteStatus: "completed", error: nil, cost: 0.01)
        #expect(controller.record(remoteID: "job-stop")?.pollingState == .completed)
    }

    // MARK: Unknown submission outcome

    @Test("an unknown submission outcome is persisted, reported, and not resumable")
    func unknownSubmissionOutcomeIsDurable() throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        let record = try #require(controller.recordUnknownSubmission(
            kind: "video", modelID: "m", error: "Submission outcome unknown: request timed out."
        ))
        #expect(record.submissionState == .outcomeUnknown)
        #expect(record.remoteID == nil)
        #expect(record.recoverableError != nil)

        // It survives a restart but is not resumable (no remote job ID to
        // poll — resubmitting is a user decision, never automatic).
        let revived = JobController(database: database)
        #expect(revived.record(id: record.id)?.submissionState == .outcomeUnknown)
        #expect(revived.resumableJobs().contains { $0.id == record.id } == false)
    }

    // MARK: VideoGenService integration

    @Test("terminal video flow records completion and cost in the controller")
    func videoServiceRecordsTerminalAndCost() async throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-cost","status":"queued"}"#),
            .json(#"{"id":"job-cost","status":"completed","usage":{"cost":0.07}}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        let finished = try await service.submitAndPoll(
            VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1)
        )
        #expect(finished.isSuccess)
        let record = try #require(controller.record(remoteID: "job-cost"))
        #expect(record.pollingState == .completed)
        #expect(record.usageCost == 0.07)
        #expect(record.lastRemoteStatus == "completed")
        // Exactly one submission: no duplicate paid POST.
        #expect(transport.submissions().count == 1)
        // Remote failure keeps its recoverable error distinct from a local stop.
        #expect(record.pollingState.isTerminal)
    }

    @Test("remote failure records a terminal failed state with the recoverable error")
    func remoteFailureRecordsTerminalFailed() async throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-fail-record","status":"failed","error":"Provider quota exceeded"}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        do {
            _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil))
            Issue.record("Expected the failed job to throw.")
        } catch is CancellationError {
            Issue.record("A remote failure must not surface as local cancellation.")
        } catch {
            #expect(error is MediaServiceError)
        }
        let record = try #require(controller.record(remoteID: "job-fail-record"))
        #expect(record.pollingState == .failed)
        #expect(record.recoverableError == "Provider quota exceeded")
    }
}
