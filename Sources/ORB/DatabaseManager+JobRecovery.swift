import Foundation
import SQLite3

enum JobRecoveryComparison {
    case identical
    case ready
    case conflict(JobPersistenceConflict)
}

extension DatabaseManager {
    /// Compare and save within ONE SQLite writer transaction, under the shared
    /// connection lock. BEGIN IMMEDIATE also excludes other connections/processes.
    /// Reject outer transactions: a successful nested write is not a commit and
    /// must never permit journal acknowledgement.
    func reconcileJobRecovery(_ envelope: JobRecoveryEnvelope, save: Bool) throws -> JobRecoveryComparison {
        try withJobRecoveryReservation {
            let candidate = envelope.candidate
            let records = try loadJobRecordsChecked()
            let durable = records.first { $0.id == candidate.id }
            let otherOwner = records.first { $0.id != candidate.id && candidate.remoteID != nil && $0.remoteID == candidate.remoteID }
            if otherOwner != nil {
                return .conflict(JobPersistenceConflict(durable: durable, remoteOwner: otherOwner))
            }
            if let durable, try JobRecoveryEnvelope.same(candidate, durable) { return .identical }
            guard try envelope.expectedDurableBase.matches(durable) else {
                return .conflict(JobPersistenceConflict(durable: durable, remoteOwner: nil))
            }
            if save {
                try saveJobRecordChecked(candidate)
                // The general lifecycle upsert deliberately keeps created_at.
                // Recovery, however, applies a full CAS-reviewed snapshot: an
                // explicitly selected candidate must retain BOTH timestamps.
                if let durable, durable.createdAt.timeIntervalSince1970 != candidate.createdAt.timeIntervalSince1970 {
                    guard let statement = prepare("UPDATE jobs SET created_at = ? WHERE id = ?;") else {
                        throw DatabaseManagerError.operationFailed(currentError())
                    }
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_bind_double(statement, 1, candidate.createdAt.timeIntervalSince1970) == SQLITE_OK,
                          Self.bindText(statement, 2, candidate.id.uuidString) == SQLITE_OK else {
                        throw DatabaseManagerError.operationFailed(currentError())
                    }
                    try requireDone(statement)
                }
                guard let stored = try findJobRecordChecked(id: candidate.id),
                      try JobRecoveryEnvelope.same(candidate, stored) else {
                    throw DatabaseManagerError.operationFailed("Job save did not retain the complete candidate snapshot")
                }
            }
            return .ready
        }
    }

    /// A resolution applies only to the durable state that was shown to the
    /// user. Later independent changes require a fresh review, not a blind rebase.
    func checkJobRecoveryResolution(_ candidate: JobRecord, reviewed: JobPersistenceConflict) throws -> Bool {
        try withJobRecoveryReservation {
            let records = try loadJobRecordsChecked()
            let durable = records.first { $0.id == candidate.id }
            let otherOwner = records.first { $0.id != candidate.id && candidate.remoteID != nil && $0.remoteID == candidate.remoteID }
            return try JobDurableBase(reviewed.durable).matches(durable)
                && JobDurableBase(reviewed.remoteOwner).matches(otherOwner)
        }
    }

    /// Capture SQLite alongside a competing filesystem generation without
    /// treating an unchanged base as permission to replace that generation.
    func jobRecoveryConflict(_ candidate: JobRecord) throws -> JobPersistenceConflict {
        try withJobRecoveryReservation {
            let records = try loadJobRecordsChecked()
            return JobPersistenceConflict(durable: records.first { $0.id == candidate.id },
                remoteOwner: records.first { $0.id != candidate.id && candidate.remoteID != nil && $0.remoteID == candidate.remoteID })
        }
    }

    /// Caller owns the journal flock FIRST. Keep SQLite's writer reservation,
    /// dbLock and FULLMUTEX through validation AND the filesystem discard.
    /// Raw SQLite API calls on another thread cannot join this transaction.
    func withReviewedJobRecovery(_ candidate: JobRecord, reviewed: JobPersistenceConflict,
                                 discard: () throws -> Void) throws -> Bool {
        try withJobRecoveryReservation {
            let records = try loadJobRecordsChecked()
            let durable = records.first { $0.id == candidate.id }
            let owner = records.first { $0.id != candidate.id && candidate.remoteID != nil && $0.remoteID == candidate.remoteID }
            guard try JobDurableBase(reviewed.durable).matches(durable),
                  try JobDurableBase(reviewed.remoteOwner).matches(owner) else { return false }
            try discard()
            return true
        }
    }

    /// A prior commit is not a lifetime permit to delete a journal snapshot.
    /// Validate equality again while excluding every SQLite writer through ack.
    func acknowledgeJobRecovery(_ entry: JobRecoveryEnvelope, discard: () throws -> Void) throws {
        try withJobRecoveryReservation {
            let records = try loadJobRecordsChecked()
            guard let durable = records.first(where: { $0.id == entry.candidate.id }),
                  try JobRecoveryEnvelope.same(durable, entry.candidate),
                  !records.contains(where: { $0.id != entry.candidate.id && entry.candidate.remoteID != nil && $0.remoteID == entry.candidate.remoteID }) else {
                throw DatabaseManagerError.operationFailed("Durable job changed before recovery cleanup. Retry locally to review both snapshots.")
            }
            try discard()
        }
    }

    private func withJobRecoveryReservation<T>(_ work: () throws -> T) throws -> T {
        dbLock.lock()
        defer { dbLock.unlock() }
        // A functioning launch fallback is volatile, not a durable commit.
        // Refuse even read-only reconciliation before it can authorize an ack.
        guard let db, launchFailure == nil else { throw DatabaseManagerError.notAvailable }
        // FULLMUTEX connection: also reserve SQLite's recursive connection
        // mutex. Legacy single-statement writers do not all take dbLock, and
        // SQLite otherwise serializes only each API call, not this transaction.
        guard let connectionMutex = sqlite3_db_mutex(db) else {
            throw DatabaseManagerError.operationFailed("Job recovery requires a serialized SQLite connection")
        }
        sqlite3_mutex_enter(connectionMutex)
        defer { sqlite3_mutex_leave(connectionMutex) }
        guard sqlite3_get_autocommit(db) != 0 else {
            throw DatabaseManagerError.operationFailed("Job recovery requires its own commit boundary")
        }
        try execChecked("BEGIN IMMEDIATE;")
        do {
            let result = try work()
            try execChecked("COMMIT;")
            return result
        } catch {
            try? execChecked("ROLLBACK;")
            throw error
        }
    }
}
