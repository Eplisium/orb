import Foundation

// MARK: - Durable media job records (W06)
//
// A media job outlives the view that started it. `JobController` is an
// application-owned, @MainActor controller that persists a `JobRecord` for
// every submission — keyed by the remote job ID *before* polling relies on
// it — and owns the submission/polling state that used to live in
// `MediaViews`. Records survive app restarts, so a queued generation can be
// recovered instead of silently lost.

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
final class JobController {
    /// The controller used by the default view path. Backed by the shared
    /// database so records survive restarts.
    static let shared = JobController()

    private let database: DatabaseManager
    private(set) var lastPersistenceError: String?

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
        if database.findJobRecord(remoteID: remoteID) != nil {
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
        let now = Date()
        let record = JobRecord(
            id: UUID(),
            remoteID: nil,
            kind: kind,
            submissionState: .outcomeUnknown,
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
    func recordPollUpdate(remoteID: String, remoteStatus: String, error: String?, cost: Double?) {
        update(remoteID: remoteID) { record in
            record.lastRemoteStatus = remoteStatus
            record.recoverableError = error
            if let cost { record.usageCost = cost }
            let mapped = JobPollingState(remoteStatus: remoteStatus)
            if mapped.isTerminal {
                record.pollingState = mapped
            } else if record.pollingState == .idle || record.pollingState == .stoppedLocally {
                record.pollingState = .polling
            }
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

    /// Links a finished job to the saved creation made from its output. Set
    /// at most once (the first link wins), and allowed on terminal records —
    /// it never changes the polling state.
    func recordSavedCreation(remoteID: String, creationID: UUID) {
        guard var record = record(remoteID: remoteID), record.savedCreationID == nil else { return }
        record.savedCreationID = creationID
        record.updatedAt = Date()
        persist(record)
    }

    /// Clears a link whose creation no longer exists (deleted from Library),
    /// so the result can be downloaded again while the provider still has it.
    func clearSavedCreation(remoteID: String) {
        guard var record = record(remoteID: remoteID), record.savedCreationID != nil else { return }
        record.savedCreationID = nil
        record.updatedAt = Date()
        persist(record)
    }

    // MARK: Queries

    func record(id: UUID) -> JobRecord? {
        database.withMediaFields(database.findJobRecord(id: id))
    }

    func record(remoteID: String) -> JobRecord? {
        database.withMediaFields(database.findJobRecord(remoteID: remoteID))
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
        database.withMediaFields(database.loadJobRecords())
    }

    // MARK: Persistence

    private func update(remoteID: String, mutate: (inout JobRecord) -> Void) {
        guard var record = record(remoteID: remoteID) else { return }
        // Terminal states are monotonic: a completed/failed/cancelled/expired
        // job never regresses to an earlier state.
        guard !record.pollingState.isTerminal else { return }
        mutate(&record)
        record.updatedAt = Date()
        persist(record)
    }

    private func persist(_ record: JobRecord) {
        do {
            try database.saveJobRecordChecked(record)
            try database.saveJobMediaFieldsChecked(record)
            lastPersistenceError = nil
        } catch {
            // Storage-first: a failed write is surfaced, never fatal.
            lastPersistenceError = error.localizedDescription
        }
    }
}
