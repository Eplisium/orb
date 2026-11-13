import Foundation
import Darwin

/// Explicit absence is part of the compare-and-save contract, never inferred
/// from an unreadable database. Snapshot equality uses Unix date precision and
/// UTF-8 JSON bytes (not Swift String's canonical-equivalence comparison).
enum JobDurableBase: Codable, Sendable {
    case missing
    case snapshot(JobRecord)

    init(_ record: JobRecord?) {
        self = record.map(Self.snapshot) ?? .missing
    }

    func matches(_ record: JobRecord?) throws -> Bool {
        switch (self, record) {
        case (.missing, nil): return true
        case let (.snapshot(expected), actual?): return try JobRecoveryEnvelope.same(expected, actual)
        default: return false
        }
    }
}

struct JobRecoveryEnvelope: Codable, Sendable {
    let version: Int
    let generation: UUID
    let candidate: JobRecord
    let expectedDurableBase: JobDurableBase

    init(candidate: JobRecord, expectedDurableBase: JobDurableBase) {
        version = 1
        generation = UUID()
        self.candidate = candidate
        self.expectedDurableBase = expectedDurableBase
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func same(_ lhs: JobRecord, _ rhs: JobRecord) throws -> Bool {
        try encoder().encode(lhs) == encoder().encode(rhs)
    }

    func validate(id: UUID) throws {
        guard version == 1, candidate.id == id else { throw JobRecoveryJournalError.corrupt }
        if case let .snapshot(base) = expectedDurableBase {
            guard base.id == id, base.remoteID == candidate.remoteID else {
                throw JobRecoveryJournalError.corrupt
            }
        }
    }
}

enum JobPersistenceResolution: Equatable, Sendable { case keepDurable, retryCandidate, useJournal }

/// Both snapshots stay available to the local resolution UI. A different UUID
/// owning the remote ID cannot be replaced by Retry candidate.
struct JobPersistenceConflict: Sendable {
    let durable: JobRecord?
    let remoteOwner: JobRecord?
    var journal: JobRecoveryEnvelope? = nil
    var candidate: JobRecord? = nil
    var candidateGeneration: UUID? = nil
    var competingJournal = false
    var reviewToken = UUID()
    var canRetryCandidate: Bool { remoteOwner == nil }

    /// Full, copyable review data, not an abbreviated state badge. Escaping
    /// strings makes embedded NUL/newlines visible without normalizing storage.
    static func describe(_ record: JobRecord?) -> String {
        guard let record else { return "Absent — no snapshot" }
        return """
        Local UUID: \(record.id.uuidString)
        Remote ID: \(record.remoteID.map { String(reflecting: $0) } ?? "unknown")
        Kind / model: \(record.kind) / \(record.modelID ?? "unknown")
        Submission / polling: \(record.submissionState.rawValue) / \(record.pollingState.rawValue)
        Remote status: \(record.lastRemoteStatus ?? "unknown")
        Cost (USD): \(record.usageCost.map { String($0) } ?? "unknown")
        Saved creation: \(record.savedCreationID?.uuidString ?? "none")
        Prompt: \(record.prompt.map { String(reflecting: $0) } ?? "not recorded")
        Created (Unix seconds): \(record.createdAt.timeIntervalSince1970)
        Updated (Unix seconds): \(record.updatedAt.timeIntervalSince1970)
        Conversation: \(record.conversationID?.uuidString ?? "none")
        Message: \(record.messageID?.uuidString ?? "none")
        Error: \(record.recoverableError.map { String(reflecting: $0) } ?? "none")
        """
    }
}

/// The namespace mutation happened; only its directory sync failed. Retain the
/// exact generation rather than treating this as a failed rename/unlink.
enum JobJournalPartialMutation: Error, LocalizedError {
    case installed(UUID), removed(UUID)
    var errorDescription: String? { "Recovery journal directory sync failed after a filesystem change. Retry local saving or cleanup." }
}

enum JobRecoveryJournalError: Error, LocalizedError {
    case unavailable, busy, changed, corrupt

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Local job recovery journal is unavailable."
        case .busy: return "Another process is using the local job recovery journal. Retry locally."
        case .changed: return "The local recovery generation changed in another controller. Neither snapshot was overwritten; retry locally to review both candidates."
        case .corrupt: return "Local job recovery inventory is invalid or unsupported. Files were preserved; new remote identities are blocked until it is repaired."
        }
    }
}

/// One directory per database. Every read-modify-write uses an advisory flock
/// held through SQLite COMMIT and exact-generation acknowledgement. Other ORB
/// controllers/processes use the same protocol. Contention fails closed, never
/// falls back to an uncoordinated overwrite. No lifetime lease or stale PID.
///
/// Files have UUID-only names, 0600 mode, atomic rename and fsync; directory is
/// 0700. Credentials/transports are not part of this schema. Prompts/errors are
/// local private data, not encrypted. fsync is not a promise of hardware-level
/// power-loss durability. Uncommitted dot-temp files are intentionally ignored.
final class JobRecoveryJournal {
    /// Bound stat and read, including a file growing after stat.
    static let maximumEntryBytes = 8 * 1024 * 1024
    enum Operation { case write, acknowledge, afterRename, afterUnlink }
    let directory: URL
    private let fault: ((Operation) throws -> Void)?

    init(directory: URL, fault: ((Operation) throws -> Void)? = nil) {
        self.directory = directory
        self.fault = fault
    }

    func withAccess<T>(_ work: (Access) throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw JobRecoveryJournalError.unavailable }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw JobRecoveryJournalError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
            throw JobRecoveryJournalError.unavailable
        }
        let lock = openat(fd, ".lock", O_RDWR | O_NONBLOCK | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard lock >= 0 else { throw JobRecoveryJournalError.unavailable }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_uid == geteuid(), fchmod(lock, 0o600) == 0 else {
            throw JobRecoveryJournalError.corrupt
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw JobRecoveryJournalError.busy }
        defer { flock(lock, LOCK_UN) }
        return try work(Access(directory: directory, fd: fd, fault: fault))
    }

    struct Access {
        let directory: URL
        let fd: Int32
        let fault: ((Operation) throws -> Void)?

        func inventory() throws -> [UUID: JobRecoveryEnvelope] {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch { throw JobRecoveryJournalError.unavailable }
            var entries: [UUID: JobRecoveryEnvelope] = [:]
            var remoteIDs = Set<String>()
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      file.lastPathComponent == "\(id.uuidString).json", entries[id] == nil,
                      let entry = try read(id) else { throw JobRecoveryJournalError.corrupt }
                if let remote = entry.candidate.remoteID, !remoteIDs.insert(remote).inserted {
                    throw JobRecoveryJournalError.corrupt
                }
                entries[id] = entry
            }
            return entries
        }

        func read(_ id: UUID) throws -> JobRecoveryEnvelope? {
            let entryFD = openat(fd, "\(id.uuidString).json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard entryFD >= 0 else {
                if errno == ENOENT { return nil }
                throw JobRecoveryJournalError.corrupt
            }
            let handle = FileHandle(fileDescriptor: entryFD, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(entryFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(), info.st_size >= 0,
                  info.st_size <= off_t(JobRecoveryJournal.maximumEntryBytes),
                  fchmod(entryFD, 0o600) == 0 else { throw JobRecoveryJournalError.corrupt }
            do {
                var data = Data()
                while data.count <= JobRecoveryJournal.maximumEntryBytes {
                    let chunk = try handle.read(upToCount: min(64 * 1024, JobRecoveryJournal.maximumEntryBytes + 1 - data.count)) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                guard data.count <= JobRecoveryJournal.maximumEntryBytes else { throw JobRecoveryJournalError.corrupt }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let envelope = try decoder.decode(JobRecoveryEnvelope.self, from: data)
                try envelope.validate(id: id)
                return envelope
            } catch { throw JobRecoveryJournalError.corrupt }
        }

        func syncDirectory() throws {
            guard fsync(fd) == 0 else { throw JobRecoveryJournalError.unavailable }
        }

        func check(_ id: UUID, generation: UUID?) throws {
            guard try read(id)?.generation == generation else { throw JobRecoveryJournalError.changed }
        }

        func stage(_ entry: JobRecoveryEnvelope, replacing generation: UUID?) throws {
            try entry.validate(id: entry.candidate.id)
            // Validate the WHOLE inventory before staging a new remote identity.
            let entries = try inventory()
            guard entries[entry.candidate.id]?.generation == generation else { throw JobRecoveryJournalError.changed }
            if let remote = entry.candidate.remoteID,
               entries.values.contains(where: { $0.candidate.id != entry.candidate.id && $0.candidate.remoteID == remote }) {
                throw JobRecoveryJournalError.changed
            }
            do { try fault?(.write) } catch { throw JobRecoveryJournalError.unavailable }
            let bytes = try JobRecoveryEnvelope.encoder().encode(entry)
            guard bytes.count <= JobRecoveryJournal.maximumEntryBytes else { throw JobRecoveryJournalError.unavailable }
            let temporary = ".\(UUID().uuidString).tmp"
            let out = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard out >= 0 else { throw JobRecoveryJournalError.unavailable }
            defer { close(out); unlinkat(fd, temporary, 0) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(out, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw JobRecoveryJournalError.unavailable }
                    offset += written
                }
            }
            guard fsync(out) == 0,
                  renameat(fd, temporary, fd, "\(entry.candidate.id.uuidString).json") == 0 else {
                throw JobRecoveryJournalError.unavailable
            }
            do {
                try fault?(.afterRename)
                try syncDirectory()
            } catch { throw JobJournalPartialMutation.installed(entry.generation) }
        }

        func acknowledge(_ entry: JobRecoveryEnvelope) throws {
            try check(entry.candidate.id, generation: entry.generation)
            try fault?(.acknowledge)
            guard unlinkat(fd, "\(entry.candidate.id.uuidString).json", 0) == 0 else {
                throw JobRecoveryJournalError.unavailable
            }
            do {
                try fault?(.afterUnlink)
                try syncDirectory()
            } catch { throw JobJournalPartialMutation.removed(entry.generation) }
        }
    }
}
