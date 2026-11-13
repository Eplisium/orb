import Foundation
import Combine

// MARK: - Durable media job records (W06)
//
// A media job outlives the view that started it. `JobController` is an
// application-owned, @MainActor controller that persists a `JobRecord` for
// every submission — keyed by the remote job ID *before* polling relies on
// it — and owns the submission/polling state that used to live in
// `MediaViews`. SQLite writes are preceded by an independent full-snapshot
// recovery journal. Failed journal AND SQLite writes remain explicitly memory-
// only. Recovery never submits, polls, downloads, or accounts a paid job.

/// How the submission itself resolved. Distinct from polling state because
/// "we don't know whether the remote job exists" must never be presented as
/// a definite outcome.
enum JobSubmissionState: String, Sendable, Equatable, Codable {
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
enum JobPollingState: String, Sendable, Equatable, Codable {
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
struct JobRecord: Equatable, Identifiable, Sendable, Codable {
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
    static let shared: JobController = {
        let database = DatabaseManager.shared
        // Production opts in explicitly. Existing fixtures (including implicit
        // SwiftPM shared databases) must never open the user's recovery files.
        let directory = database.testDatabasePath == nil
            ? ManagedStoragePaths.jobRecoveryDirectory
            : nil
        return launched(database: database, recoveryDirectory: directory)
    }()

    /// Builds the controller a fresh process starts with. A record still
    /// marked `.polling` in storage was being polled when the previous run
    /// quit or crashed; no loop owns it any more, so it is demoted to
    /// `.stoppedLocally`. Left alone it would read "Running" forever, with
    /// Stop as its only action and nothing to stop.
    static func launched(database: DatabaseManager = .shared, recoveryDirectory: URL? = nil) -> JobController {
        let controller = JobController(database: database, recoveryDirectory: recoveryDirectory)
        controller.retryPendingPersistence()
        controller.demoteInterruptedPolls()
        return controller
    }

    private let database: DatabaseManager
    /// Authoritative latest snapshots only while their writes remain unsaved.
    /// UUID keys also preserve distinct unknown submissions with no remote ID.
    private var pending: [UUID: JobRecord] = [:]
    private(set) var persistenceErrors: [UUID: String] = [:]
    private var readError: String?
    private let journal: JobRecoveryJournal?
    private var journalError: String?
    private var journalBlocksNewIdentities = false
    private var envelopes: [UUID: JobRecoveryEnvelope] = [:]
    private var journalGenerations: [UUID: UUID] = [:]
    private var knownBases: [UUID: JobDurableBase] = [:]
    private var acknowledgements: [UUID: JobRecoveryEnvelope] = [:]
    /// Unlink succeeded but directory fsync did not. Absence is retryable only
    /// for this exact generation, never a general permission to delete a file.
    private var removedGenerations: [UUID: UUID] = [:]
    private(set) var memoryOnlyRecordIDs: Set<UUID> = []
    private(set) var persistenceConflicts: [UUID: JobPersistenceConflict] = [:]
    /// Emitted after mutations so services can refresh even without a poll tick.
    @Published private(set) var revision = 0

    var pendingRecords: [JobRecord] { sorted(Array(pending.values)) }
    var unsavedRecordCount: Int { pending.count }
    /// Compatibility summary. Saving one row cannot hide another row's failure.
    var lastPersistenceError: String? {
        persistenceErrors.keys.sorted { $0.uuidString < $1.uuidString }
            .compactMap { persistenceErrors[$0] }.first ?? journalError ?? readError
    }

    init(database: DatabaseManager = .shared, recoveryDirectory: URL? = nil,
         recoveryFault: ((JobRecoveryJournal.Operation) throws -> Void)? = nil) {
        self.database = database
        journal = recoveryDirectory.map { JobRecoveryJournal(directory: $0, fault: recoveryFault) }
        importRecoveryJournal()
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
            guard persistenceConflicts[record.id] == nil else { continue }
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
        importRecoveryJournal()
        if let record = pending[id] { return record }
        do {
            let record = try database.findJobRecordChecked(id: id)
            knownBases[id] = JobDurableBase(record)
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
        importRecoveryJournal()
        if let record = pending.values.first(where: { $0.remoteID == remoteID }) { return record }
        let record = try database.findJobRecordChecked(remoteID: remoteID)
        if let record { knownBases[record.id] = .snapshot(record) }
        if record == nil && journalBlocksNewIdentities { throw JobRecoveryJournalError.corrupt }
        setReadError(nil)
        return record
    }

    /// Resumable listing: jobs with a remote ID and a last known status that
    /// have not reached a terminal state.
    func resumableJobs() -> [JobRecord] {
        allJobs().filter { $0.isResumable && persistenceConflicts[$0.id] == nil }
    }

    /// Finished jobs whose output was never saved in ORB.
    func downloadableJobs() -> [JobRecord] {
        allJobs().filter { $0.needsDownload && persistenceConflicts[$0.id] == nil }
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
        importRecoveryJournal()
        retryAcknowledgements(id: id)
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
        // Retain the original expected durable base through every failed write.
        // Updating a pending snapshot must NOT recapture a changed SQLite row.
        let previous = envelopes[record.id]
        let entry: JobRecoveryEnvelope
        if let previous, (try? JobRecoveryEnvelope.same(previous.candidate, record)) == true {
            entry = previous
        } else {
            entry = JobRecoveryEnvelope(candidate: record,
                expectedDurableBase: previous?.expectedDurableBase ?? knownBases[record.id] ?? .missing)
        }
        pending[record.id] = record
        envelopes[record.id] = entry
        defer { revision += 1 }
        guard let journal else {
            memoryOnlyRecordIDs.insert(record.id)
            if persistenceConflicts[record.id] != nil {
                do { try captureJournalConflict(entry, disk: nil) }
                catch { persistenceErrors[record.id] = error.localizedDescription }
                return
            }
            commitRecovery(entry, access: nil)
            return
        }
        do {
            try journal.withAccess { access in
                let disk = try access.read(record.id)
                if disk?.generation != journalGenerations[record.id] || persistenceConflicts[record.id] != nil {
                    if disk?.generation != entry.generation { memoryOnlyRecordIDs.insert(record.id) }
                    try captureJournalConflict(entry, disk: disk)
                    return
                }
                do {
                    try access.stage(entry, replacing: journalGenerations[record.id])
                    journalGenerations[record.id] = entry.generation
                    acknowledgements[record.id] = nil
                    removedGenerations[record.id] = nil
                    memoryOnlyRecordIDs.remove(record.id)
                } catch JobJournalPartialMutation.installed(let generation) {
                    journalGenerations[record.id] = generation
                    acknowledgements[record.id] = nil
                    removedGenerations[record.id] = nil
                    memoryOnlyRecordIDs.insert(record.id)
                    // The file exists, but has not completed directory sync.
                    // SQLite can still save; a later stage uses this generation.
                    commitRecovery(entry, access: access)
                    return
                } catch JobRecoveryJournalError.unavailable {
                    // Journal failure alone must not turn a working SQLite
                    // store into data loss. CAS still protects the durable base.
                    journalError = JobRecoveryJournalError.unavailable.localizedDescription
                    memoryOnlyRecordIDs.insert(record.id)
                    commitRecovery(entry, access: nil)
                    return
                }
                commitRecovery(entry, access: access)
            }
        } catch JobRecoveryJournalError.unavailable {
            journalError = JobRecoveryJournalError.unavailable.localizedDescription
            memoryOnlyRecordIDs.insert(record.id)
            guard persistenceConflicts[record.id] == nil else {
                persistenceErrors[record.id] = "The journal is unavailable; conflict resolution requires a fresh local review."
                return
            }
            commitRecovery(entry, access: nil)
        } catch {
            // Lock contention, generation CAS mismatch, and corrupt inventory
            // are NOT filesystem write failures: fail closed, without DB writes.
            if let failure = error as? JobRecoveryJournalError {
                switch failure {
                case .changed, .corrupt: memoryOnlyRecordIDs.insert(record.id)
                case .busy, .unavailable:
                    if journalGenerations[record.id] != entry.generation { memoryOnlyRecordIDs.insert(record.id) }
                }
            } else { memoryOnlyRecordIDs.insert(record.id) }
            persistenceErrors[record.id] = error.localizedDescription
        }
    }

    private func commitRecovery(_ entry: JobRecoveryEnvelope, access: JobRecoveryJournal.Access?) {
        do {
            switch try database.reconcileJobRecovery(entry, save: true) {
            case .conflict(let conflict):
                setConflict(entry.candidate.id, conflict, disk: try access?.read(entry.candidate.id))
            case .identical, .ready: finishSaved(entry, access: access)
            }
        } catch {
            let suffix = memoryOnlyRecordIDs.contains(entry.candidate.id)
                ? " Latest changes are only in memory; save before quitting." : " Local recovery journal retained."
            persistenceErrors[entry.candidate.id] = error.localizedDescription + suffix
        }
    }

    private func finishSaved(_ entry: JobRecoveryEnvelope, access: JobRecoveryJournal.Access?) {
        let id = entry.candidate.id
        pending[id] = nil
        envelopes[id] = nil
        persistenceErrors[id] = nil
        persistenceConflicts[id] = nil
        memoryOnlyRecordIDs.remove(id)
        knownBases[id] = .snapshot(entry.candidate)
        if let access {
            acknowledgeSaved(entry, access: access)
        }
    }

    private func acknowledgeSaved(_ entry: JobRecoveryEnvelope, access: JobRecoveryJournal.Access) {
        let id = entry.candidate.id
        acknowledgements[id] = entry
        do {
            try database.acknowledgeJobRecovery(entry) {
                try discardGeneration(entry, access: access)
            }
            acknowledgements[id] = nil
            removedGenerations[id] = nil
            journalGenerations[id] = nil
            persistenceErrors[id] = nil
        } catch {
            persistenceErrors[id] = "Job saved to SQLite; recovery journal acknowledgement failed. Retry local cleanup. "
                + error.localizedDescription
        }
    }

    private func discardGeneration(_ entry: JobRecoveryEnvelope, access: JobRecoveryJournal.Access) throws {
        let id = entry.candidate.id
        if removedGenerations[id] == entry.generation {
            try access.check(id, generation: nil)
            try access.syncDirectory()
        } else {
            do {
                try access.acknowledge(entry)
                // Also retain the outcome if the enclosing read reservation's
                // COMMIT subsequently fails after a successful unlink+sync.
                removedGenerations[id] = entry.generation
                journalGenerations[id] = nil
                if pending[id] != nil { memoryOnlyRecordIDs.insert(id) }
            }
            catch JobJournalPartialMutation.removed(let generation) {
                removedGenerations[id] = generation
                journalGenerations[id] = nil
                if pending[id] != nil { memoryOnlyRecordIDs.insert(id) }
                throw JobJournalPartialMutation.removed(generation)
            }
        }
    }

    private func retryAcknowledgements(id: UUID?) {
        guard let journal else { return }
        for entry in Array(acknowledgements.values) where id == nil || entry.candidate.id == id {
            // A later lifecycle write may have failed before staging. Never
            // replace that newer local snapshot with this older saved ack.
            guard pending[entry.candidate.id] == nil else { continue }
            do {
                try journal.withAccess { access in
                    let disk = try access.read(entry.candidate.id)
                    let expected = removedGenerations[entry.candidate.id] == entry.generation ? nil : entry.generation
                    let comparison = try database.reconcileJobRecovery(entry, save: false)
                    if disk?.generation == expected, case .identical = comparison {
                        acknowledgeSaved(entry, access: access)
                    } else {
                        // Retain a stale acknowledgement as a reviewable candidate,
                        // rather than requiring restart or silently deleting it.
                        pending[entry.candidate.id] = entry.candidate
                        envelopes[entry.candidate.id] = entry
                        acknowledgements[entry.candidate.id] = nil
                        if disk?.generation != entry.generation { memoryOnlyRecordIDs.insert(entry.candidate.id) }
                        try captureJournalConflict(entry, disk: disk)
                    }
                }
            } catch { persistenceErrors[entry.candidate.id] = error.localizedDescription }
            revision += 1
        }
    }

    /// Import complete snapshots, but never eagerly upsert during construction.
    /// Only exact committed duplicates are acknowledged. Launch explicitly
    /// replays pending writes before it demotes interrupted polling states.
    private func importRecoveryJournal() {
        guard let journal else { return }
        do {
            try journal.withAccess { access in
                let inventory = try access.inventory()
                let clearedWarning = journalError != nil || journalBlocksNewIdentities
                journalError = nil
                journalBlocksNewIdentities = false
                if clearedWarning { revision += 1 }
                // A peer may have committed and acknowledged a generation since
                // this controller read it. Missing disk is a change, not consent
                // to replay our older/local snapshot or resume it remotely.
                for (id, local) in envelopes where inventory[id] == nil && journalGenerations[id] != nil {
                    memoryOnlyRecordIDs.insert(id)
                    do { try captureJournalConflict(local, disk: nil) }
                    catch { persistenceErrors[id] = error.localizedDescription }
                }
                for id in inventory.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                    guard acknowledgements[id] == nil, let entry = inventory[id] else { continue }
                    if let local = envelopes[id] {
                        if entry.generation != journalGenerations[id] {
                            memoryOnlyRecordIDs.insert(id)
                            do { try captureJournalConflict(local, disk: entry) }
                            catch { persistenceErrors[id] = error.localizedDescription }
                        }
                        continue
                    }
                    pending[id] = entry.candidate
                    envelopes[id] = entry
                    journalGenerations[id] = entry.generation
                    memoryOnlyRecordIDs.remove(id)
                    do {
                        switch try database.reconcileJobRecovery(entry, save: false) {
                        case .identical: finishSaved(entry, access: access)
                        case .ready: persistenceErrors[id] = "Job snapshot recovered from the local journal; retry saving to SQLite."
                        case .conflict(let conflict): setConflict(id, conflict, disk: entry)
                        }
                    } catch { persistenceErrors[id] = error.localizedDescription + " Local recovery journal retained." }
                    revision += 1
                }
            }
        } catch {
            let next = error.localizedDescription
            let blocks: Bool
            if case JobRecoveryJournalError.unavailable = error { blocks = false } else { blocks = true }
            if journalError != next || journalBlocksNewIdentities != blocks {
                journalError = next
                journalBlocksNewIdentities = blocks
                revision += 1
            }
        }
    }

    private func captureJournalConflict(_ entry: JobRecoveryEnvelope, disk: JobRecoveryEnvelope?) throws {
        let conflict = try database.jobRecoveryConflict(entry.candidate)
        setConflict(entry.candidate.id, conflict, disk: disk)
    }

    private func setConflict(_ id: UUID, _ value: JobPersistenceConflict, disk: JobRecoveryEnvelope?) {
        let previousReviewToken = persistenceConflicts[id]?.reviewToken
        var conflict = value
        conflict.journal = disk
        conflict.candidate = envelopes[id]?.candidate
        conflict.candidateGeneration = envelopes[id]?.generation
        conflict.competingJournal = disk != nil && disk?.generation != conflict.candidateGeneration
        // Reads of an unchanged conflict must not invalidate an open review.
        if let old = persistenceConflicts[id], old.candidateGeneration == conflict.candidateGeneration,
           old.journal?.generation == disk?.generation,
           (try? JobDurableBase(old.durable).matches(conflict.durable)) == true,
           (try? JobDurableBase(old.remoteOwner).matches(conflict.remoteOwner)) == true {
            conflict.reviewToken = old.reviewToken
        }
        persistenceConflicts[id] = conflict
        persistenceErrors[id] = conflict.remoteOwner == nil
            ? "Local job snapshots differ. Review the candidate, SQLite and journal snapshots, then choose which to keep locally."
            : "Another durable UUID owns this remote job. All snapshots are retained; only Keep SQLite is allowed."
        // Repeated reads of the same review do not publish another revision.
        if previousReviewToken != conflict.reviewToken { revision += 1 }
    }

    /// Deliberate LOCAL resolution. The UI supplies the token it actually showed;
    /// legacy synchronous callers may omit it. Candidate and disk generations
    /// are checked independently, then SQLite is checked under its reservation.
    @discardableResult
    func resolvePendingPersistence(id: UUID, resolution: JobPersistenceResolution, reviewToken: UUID? = nil) -> Bool {
        guard let conflict = persistenceConflicts[id], let entry = envelopes[id],
              reviewToken == nil || reviewToken == conflict.reviewToken,
              conflict.candidateGeneration == entry.generation else { return false }
        guard resolution == .keepDurable || conflict.canRetryCandidate else { return false }
        if resolution == .useJournal && conflict.journal == nil { return false }
        defer { revision += 1 }
        do {
            if let journal {
                return try journal.withAccess { access in
                    // A previous failed discard may have unlinked precisely the
                    // reviewed generation. Only that recorded absence is allowed.
                    let wasRemoved = conflict.journal.map { removedGenerations[id] == $0.generation } ?? false
                    try access.check(id, generation: wasRemoved ? nil : conflict.journal?.generation)
                    return try resolveReviewed(entry, conflict: conflict, resolution: resolution, access: access)
                }
            }
            return try resolveReviewed(entry, conflict: conflict, resolution: resolution, access: nil)
        } catch {
            persistenceErrors[id] = error.localizedDescription
            return false
        }
    }

    private func resolveReviewed(_ entry: JobRecoveryEnvelope, conflict: JobPersistenceConflict,
                                 resolution: JobPersistenceResolution, access: JobRecoveryJournal.Access?) throws -> Bool {
        let id = entry.candidate.id
        if resolution == .keepDurable {
            // Lock order is always journal -> dbLock -> SQLite connection mutex
            // -> BEGIN IMMEDIATE. Never release SQLite between review and unlink.
            let accepted = try database.withReviewedJobRecovery(entry.candidate, reviewed: conflict) {
                if let access, let disk = conflict.journal {
                    try discardGeneration(disk, access: access)
                } else if let access, removedGenerations[id] != nil {
                    try access.check(id, generation: nil)
                    try access.syncDirectory()
                }
            }
            guard accepted else {
                persistenceErrors[id] = "Durable job changed since review. Retry local saving to refresh the conflict before resolving."
                return false
            }
            pending[id] = nil
            envelopes[id] = nil
            journalGenerations[id] = nil
            acknowledgements[id] = nil
            removedGenerations[id] = nil
            memoryOnlyRecordIDs.remove(id)
            persistenceErrors[id] = nil
            persistenceConflicts[id] = nil
            knownBases[id] = JobDurableBase(conflict.durable)
            return true
        }
        guard try database.checkJobRecoveryResolution(entry.candidate, reviewed: conflict) else {
            persistenceErrors[id] = "Durable job changed since review. Retry local saving to refresh the conflict before resolving."
            return false
        }
        let chosen = resolution == .useJournal ? conflict.journal!.candidate : entry.candidate
        let replacement = JobRecoveryEnvelope(candidate: chosen, expectedDurableBase: JobDurableBase(conflict.durable))
        // Do not mutate the in-memory candidate until a replacement was installed.
        // If stage fails before rename, the reviewed choice remains retryable.
        if let access {
            do {
                try access.stage(replacement, replacing: try access.read(id)?.generation)
                memoryOnlyRecordIDs.remove(id)
            } catch JobJournalPartialMutation.installed(let generation) {
                journalGenerations[id] = generation
                memoryOnlyRecordIDs.insert(id)
            }
            journalGenerations[id] = replacement.generation
        } else { memoryOnlyRecordIDs.insert(id) }
        pending[id] = chosen
        envelopes[id] = replacement
        persistenceConflicts[id] = nil
        acknowledgements[id] = nil
        removedGenerations[id] = nil
        commitRecovery(replacement, access: access)
        return pending[id] == nil
    }
}
