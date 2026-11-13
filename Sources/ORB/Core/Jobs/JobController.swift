import Foundation
import Combine

// MARK: - Durable media job records (W06)
//
// A media job outlives the view that started it. `JobController` is an
// application-owned, @MainActor controller that persists a `JobRecord` for
// every submission — keyed by the remote job ID *before* polling relies on
// it — and owns the submission/polling state that used to live in
// `MediaViews`. Successfully saved records survive app restarts. Failed
// writes retain the latest full snapshot IN MEMORY for local-only retry;
// quitting loses those unsaved records/updates. This is not a durable outbox.

/// How the submission itself resolved. Distinct from polling state because
/// "we don't know whether the remote job exists" must never be presented as
/// a definite outcome.
enum JobSubmissionState: String, Sendable, Equatable {
    /// The remote submission completed and returned a job ID.
    case submitted
    /// The submission outcome is unknown (e.g. the request timed out after
    /// being sent): a remote job may or may not exist. Re-submitting is a
    /// user decision — never automatic — because it can duplicate a paid job.
    case outcomeUnknown
    /// The submission was rejected before any remote job existed.
    case failed
}

/// Local polling lifecycle. Terminal states are monotonic: once a job is
/// completed/failed/cancelled/expired it never regresses. `.stoppedLocally`
/// means only that ORB stopped its own polling loop — the remote job keeps
/// running and is never claimed cancelled by a local stop.
enum JobPollingState: String, Sendable, Equatable {
    case idle
    case polling
    /// Local polling was stopped; the job stays resumable from its last
    /// known remote status.
    case stoppedLocally
    // Terminal states (mirror the documented remote video statuses).
    case completed
    case failed
    case cancelled
    case expired

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired: return true
        case .idle, .polling, .stoppedLocally: return false
        }
    }

    /// Maps a raw remote status string. Unknown or still-running statuses
    /// map to `.polling`; terminal statuses map to their own state.
    init(remoteStatus: String?) {
        switch remoteStatus?.lowercased() {
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "expired": self = .expired
        default: self = .polling
        }
    }
}

/// One durable media job. Local `id` is ORB's own; `remoteID` is the
/// provider's job ID (the polling key). `usageCost` carries the per-request
/// usage/cost the API reported for this job. No secrets are stored.
struct JobRecord: Equatable, Identifiable, Sendable {
    var id: UUID
    var remoteID: String?
    var kind: String
    var submissionState: JobSubmissionState
    var pollingState: JobPollingState
    /// Last known raw remote status (e.g. "queued", "running", "completed").
    /// Preserved verbatim across a local stop.
    var lastRemoteStatus: String?
    var conversationID: UUID?
    var messageID: UUID?
    var modelID: String?
    var usageCost: Double?
    /// A recoverable error explanation; never thrown, always shown.
    var recoverableError: String?
    var createdAt: Date
    var updatedAt: Date
    /// The prompt that started the job, so a resumed job keeps its context.
    /// Persisted in the additive `jobs.prompt` column.
    var prompt: String? = nil
    /// The saved creation produced from this finished job. Set exactly once;
    /// a completed job without one still needs its result downloaded.
    var savedCreationID: UUID? = nil

    /// Resumable jobs have a remote ID to poll and are not terminal.
    var isResumable: Bool {
        remoteID != nil && !pollingState.isTerminal
    }

    /// A finished job whose output has not been saved in ORB yet. The bytes
    /// only exist at the provider, so the tray must offer a Download action
    /// (this survives restarts, unlike any in-memory download).
    var needsDownload: Bool {
        remoteID != nil && pollingState == .completed && savedCreationID == nil
    }
}

/// Application-owned job state. All persistence failures are surfaced as
/// `lastPersistenceError` — a failed database write must never crash or
/// abort a media flow.
@MainActor
final class JobController: ObservableObject {
    /// The controller used by the default view path. Backed by the shared
    /// database so records survive restarts. Created once per process and
    /// before any poll loop can start, so it runs the launch recovery.
    static let shared = JobController.launched()

    /// Builds the controller a fresh process starts with. A record still
    /// marked `.polling` in storage was being polled when the previous run
    /// quit or crashed; no loop owns it any more, so it is demoted to
    /// `.stoppedLocally`. Left alone it would read "Running" forever, with
    /// Stop as its only action and nothing to stop.
    static func launched(database: DatabaseManager = .shared) -> JobController {
        let controller = JobController(database: database)
        controller.demoteInterruptedPolls()
        return controller
    }

    private let database: DatabaseManager
    /// Authoritative latest snapshots only while their writes remain unsaved.
    /// UUID keys also preserve distinct unknown submissions with no remote ID.
    private var pending: [UUID: JobRecord] = [:]
    private(set) var persistenceErrors: [UUID: String] = [:]
    private var readError: String?
    /// Emitted after mutations so services can refresh even without a poll tick.
    @Published private(set) var revision = 0

    var pendingRecords: [JobRecord] { sorted(Array(pending.values)) }
    var unsavedRecordCount: Int { pending.count }
    /// Compatibility summary. Saving one row cannot hide another row's failure.
    var lastPersistenceError: String? {
        pendingRecords.compactMap { persistenceErrors[$0.id] }.first ?? readError
    }

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    // MARK: Recording lifecycle events (called by VideoGenService)

    /// Records a completed submission keyed by the remote job ID, before
    /// polling relies on it. Idempotent: a repeated submit for the same
    /// remote ID updates the existing record instead of duplicating it or
    /// regressing a terminal state.
    @discardableResult
    func recordVideoSubmission(
        remoteID: String,
        modelID: String?,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        remoteStatus: String?,
        error: String? = nil,
        cost: Double? = nil,
        prompt: String? = nil
    ) -> JobRecord? {
        let existing: JobRecord?
        do {
            existing = try recordChecked(remoteID: remoteID)
        } catch {
            setReadError(error.localizedDescription)
            return nil
        }
        if existing != nil {
            update(remoteID: remoteID) { record in
                record.submissionState = .submitted
                if let prompt, record.prompt == nil { record.prompt = prompt }
                record.lastRemoteStatus = remoteStatus ?? record.lastRemoteStatus
                if let error { record.recoverableError = error }
                if let cost { record.usageCost = cost }
                let mapped = JobPollingState(remoteStatus: remoteStatus)
                if mapped.isTerminal { record.pollingState = mapped }
            }
            return self.record(remoteID: remoteID)
        }
        let now = Date()
        let record = JobRecord(
            id: UUID(),
            remoteID: remoteID,
            kind: "video",
            submissionState: .submitted,
            pollingState: JobPollingState(remoteStatus: remoteStatus),
            lastRemoteStatus: remoteStatus,
            conversationID: conversationID,
            messageID: messageID,
            modelID: modelID,
            usageCost: cost,
            recoverableError: error,
            createdAt: now,
            updatedAt: now,
            prompt: prompt
        )
        persist(record)
        return record
    }

    /// Records a submission whose outcome is unknown (never an automatic
    /// resubmission candidate).
    @discardableResult
    func recordUnknownSubmission(kind: String = "video", modelID: String?, error: String?) -> JobRecord? {
        recordUnsubmitted(.outcomeUnknown, kind: kind, modelID: modelID, error: error)
    }

    /// Records a submission the provider definitively rejected: no remote
    /// job exists and nothing was billed, so it is safe to correct the
    /// request and submit again.
    @discardableResult
    func recordRejectedSubmission(kind: String = "video", modelID: String?, error: String?) -> JobRecord? {
        recordUnsubmitted(.failed, kind: kind, modelID: modelID, error: error)
    }

    private func recordUnsubmitted(
        _ state: JobSubmissionState, kind: String, modelID: String?, error: String?
    ) -> JobRecord? {
        let now = Date()
        let record = JobRecord(
            id: UUID(),
            remoteID: nil,
            kind: kind,
            submissionState: state,
            pollingState: .idle,
            lastRemoteStatus: nil,
            conversationID: nil,
            messageID: nil,
            modelID: modelID,
            usageCost: nil,
            recoverableError: error,
            createdAt: now,
            updatedAt: now
        )
        persist(record)
        return record
    }

    /// Updates polling state after a successful poll. Terminal remote
    /// statuses are recorded immediately; non-terminal statuses never
    /// regress a terminal local state.
    ///
    /// A non-terminal status also never revives a `.stoppedLocally` record:
    /// a response that lands just after Stop belongs to a loop that is
    /// already cancelled, and flipping the record back to `.polling` would
    /// leave it "Running" with nothing polling it. Only an owned loop
    /// starting (`recordPollingStarted`) makes a stopped record poll again.
    func recordPollUpdate(remoteID: String, remoteStatus: String, error: String?, cost: Double?) {
        update(remoteID: remoteID) { record in
            record.lastRemoteStatus = remoteStatus
            if let cost { record.usageCost = cost }
            let mapped = JobPollingState(remoteStatus: remoteStatus)
            if mapped.isTerminal {
                record.pollingState = mapped
                record.recoverableError = error
            } else if record.pollingState != .stoppedLocally {
                record.pollingState = .polling
                record.recoverableError = error
            }
        }
    }

    /// Marks the record as polled by a live loop. Called when a poll loop
    /// starts (first submit or Resume), so a resumed job reads as running
    /// from the moment it is picked up. No-op for a terminal job.
    func recordPollingStarted(remoteID: String) {
        update(remoteID: remoteID) { record in
            record.pollingState = .polling
        }
    }

    /// Marks the job's terminal state from a remote report. Terminal states
    /// are monotonic (enforced by `update`): later reports cannot regress it.
    func recordTerminal(remoteID: String, remoteStatus: String, error: String?, cost: Double?) {
        update(remoteID: remoteID) { record in
            record.lastRemoteStatus = remoteStatus
            record.recoverableError = error
            if let cost { record.usageCost = cost }
            let mapped = JobPollingState(remoteStatus: remoteStatus)
            if mapped.isTerminal { record.pollingState = mapped }
        }
    }

    /// Records an explicit local stop: polling ends, the record stays
    /// resumable, and the remote job is never claimed cancelled or failed.
    /// No-op for a terminal job (stopping cannot un-complete it).
    func recordStoppedLocally(remoteID: String) {
        update(remoteID: remoteID) { record in
            record.pollingState = .stoppedLocally
        }
    }

    /// Polling gave up after repeated failures: the remote job may still be
    /// running, so the record becomes resumable (`.stoppedLocally`) with a
    /// recoverable explanation instead of claiming it is still Running.
    func recordPollFailure(remoteID: String, error: String) {
        update(remoteID: remoteID) { record in
            record.pollingState = .stoppedLocally
            record.recoverableError = error
        }
    }

    /// Demotes every record still marked `.polling` to `.stoppedLocally`,
    /// except those whose remote ID is in `live` (jobs a loop in this
    /// process is polling right now). The last known remote status is kept
    /// and the remote job is never claimed stopped, failed or cancelled.
    /// Returns how many records were demoted.
    @discardableResult
    func demoteInterruptedPolls(excluding live: Set<String> = []) -> Int {
        var demoted = 0
        for record in allJobs() where record.pollingState == .polling {
            guard let remoteID = record.remoteID, !live.contains(remoteID) else { continue }
            recordStoppedLocally(remoteID: remoteID)
            demoted += 1
        }
        return demoted
    }

    /// Links a finished job to the saved creation made from its output. Set
    /// at most once (the first link wins), and allowed on terminal records —
    /// it never changes the polling state.
    func recordSavedCreation(remoteID: String, creationID: UUID) {
        guard var record = record(remoteID: remoteID) else { return }
        guard record.savedCreationID == nil else {
            retryPendingPersistence(id: record.id)
            return
        }
        record.savedCreationID = creationID
        record.updatedAt = Date()
        persist(record)
    }

    /// Clears a link whose creation no longer exists (deleted from Library),
    /// so the result can be downloaded again while the provider still has it.
    func clearSavedCreation(remoteID: String) {
        guard var record = record(remoteID: remoteID) else { return }
        guard record.savedCreationID != nil else {
            retryPendingPersistence(id: record.id)
            return
        }
        record.savedCreationID = nil
        record.updatedAt = Date()
        persist(record)
    }

    // MARK: Queries

    func record(id: UUID) -> JobRecord? {
        if let record = pending[id] { return record }
        do {
            let record = try database.findJobRecordChecked(id: id)
            setReadError(nil)
            return record
        } catch {
            setReadError(error.localizedDescription)
            return nil
        }
    }

    func record(remoteID: String) -> JobRecord? {
        do { return try recordChecked(remoteID: remoteID) }
        catch {
            setReadError(error.localizedDescription)
            return nil
        }
    }

    /// Throwing lookup is essential for submission: a failed read is NOT
    /// evidence that a remote ID is new and must not allocate another UUID.
    private func recordChecked(remoteID: String) throws -> JobRecord? {
        if let record = pending.values.first(where: { $0.remoteID == remoteID }) { return record }
        let record = try database.findJobRecordChecked(remoteID: remoteID)
        setReadError(nil)
        return record
    }

    /// Resumable listing: jobs with a remote ID and a last known status that
    /// have not reached a terminal state.
    func resumableJobs() -> [JobRecord] {
        allJobs().filter(\.isResumable)
    }

    /// Finished jobs whose output was never saved in ORB.
    func downloadableJobs() -> [JobRecord] {
        allJobs().filter(\.needsDownload)
    }

    func allJobs() -> [JobRecord] {
        do {
            let stored = try database.loadJobRecordsChecked()
            setReadError(nil)
            var merged: [UUID: JobRecord] = [:]
            for record in stored where merged[record.id] == nil { merged[record.id] = record }
            for (id, record) in pending { merged[id] = record }
            return sorted(Array(merged.values))
        } catch {
            // Do not return a partial database inventory. Owned pending rows
            // remain usable, but the read error explicitly marks incompleteness.
            setReadError(error.localizedDescription)
            return pendingRecords
        }
    }

    private func sorted(_ records: [JobRecord]) -> [JobRecord] {
        records.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }

    private func setReadError(_ error: String?) {
        guard readError != error else { return }
        readError = error
        revision += 1
    }

    // MARK: Persistence

    /// Retry full snapshots locally, including terminal and unknown-ID rows.
    /// No submission, polling, accounting, UUID allocation or timestamp change.
    /// Returns the number saved; each unsuccessful row retains its own error.
    @discardableResult
    func retryPendingPersistence(id: UUID? = nil) -> Int {
        let records = pendingRecords.filter { id == nil || $0.id == id }
        var saved = 0
        for record in records {
            persist(record)
            if pending[record.id] == nil { saved += 1 }
        }
        return saved
    }

    private func update(remoteID: String, mutate: (inout JobRecord) -> Void) {
        guard var record = record(remoteID: remoteID) else { return }
        // Terminal states are monotonic: a completed/failed/cancelled/expired
        // job never regresses to an earlier state.
        guard !record.pollingState.isTerminal else {
            // A lifecycle no-op must not strand an already terminal snapshot
            // after storage recovers. Retry locally without changing its state.
            retryPendingPersistence(id: record.id)
            return
        }
        mutate(&record)
        record.updatedAt = Date()
        persist(record)
    }

    private func persist(_ record: JobRecord) {
        // Own the complete latest state before attempting storage. A later
        // sparse update must merge against this, not the stale SQLite row.
        pending[record.id] = record
        do {
            try database.saveJobRecordChecked(record)
            pending[record.id] = nil
            persistenceErrors[record.id] = nil
        } catch {
            persistenceErrors[record.id] = error.localizedDescription
        }
        revision += 1
    }
}
