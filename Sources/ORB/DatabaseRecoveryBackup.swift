import CryptoKit
import Darwin
import Foundation

/// A forensic byte copy, NOT a transactionally consistent SQLite snapshot.
/// Never moves, truncates, or deletes originals, even after complete verification.
/// No writer exclusion or fsync/power-loss guarantee is provided.
struct DatabaseRecoveryBackup {
    enum Phase: Equatable { case beforeCopy, beforeVerification }
    /// Fault injection cannot bypass the production copy or verification checks.
    typealias FaultHook = (Phase, URL, URL) throws -> Void
    var faultHook: FaultHook? = nil

    struct IncompletePreservation: Error, LocalizedError {
        let directory: URL?
        let reason: String
        var errorDescription: String? {
            "Corruption backup incomplete: \(reason)"
                + (directory.map { ". Partial copies, if any, remain at \($0.path)" } ?? "")
        }
    }

    static func container(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".orb-database-backups", isDirectory: true)
    }

    /// Returns the copied MAIN-file URL only after the complete observed member
    /// set passes verification. Failed attempts are retained, never advertised as
    /// complete. Short exclusive directories avoid suffixing near-NAME_MAX files.
    func preserve(at databaseURL: URL) throws -> URL {
        var directory: URL?
        do {
            let members = try inventory(databaseURL)
            let fingerprints = try members.map { try fingerprint($0) }
            let container = Self.container(for: databaseURL)
            try ensureContainer(container)
            let destination = try allocateDirectory(in: container)
            directory = destination
            for source in members {
                let copy = destination.appendingPathComponent(source.lastPathComponent)
                try faultHook?(.beforeCopy, source, copy)
                try FileManager.default.copyItem(at: source, to: copy)
            }
            for (index, source) in members.enumerated() {
                let copy = destination.appendingPathComponent(source.lastPathComponent)
                try faultHook?(.beforeVerification, source, copy)
                guard try fingerprint(source) == fingerprints[index],
                      try fingerprint(copy) == fingerprints[index] else {
                    throw failure("Bytes changed or did not copy completely: \(source.lastPathComponent)")
                }
            }
            guard try inventory(databaseURL) == members else {
                throw failure("Database member set changed during copying")
            }
            return destination.appendingPathComponent(databaseURL.lastPathComponent)
        } catch {
            throw IncompletePreservation(directory: directory, reason: error.localizedDescription)
        }
    }

    private func failure(_ reason: String) -> NSError {
        NSError(domain: "ORB.DatabaseRecoveryBackup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason])
    }

    private func inventory(_ databaseURL: URL) throws -> [URL] {
        try ["", "-wal", "-shm", "-journal"].compactMap { suffix in
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                // Only ENOENT means an optional member is absent. Permission and
                // I/O failures must not silently narrow the preservation set.
                if errno == ENOENT && !suffix.isEmpty { return nil }
                throw failure("Cannot inspect \(url.lastPathComponent) (errno \(errno))")
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw failure("Refusing non-regular member: \(url.lastPathComponent)")
            }
            return url
        }
    }

    private func fingerprint(_ url: URL) throws -> SHA256.Digest {
        // Bounded memory for large catalogs/WALs. Reject symlinks and non-regular
        // files rather than copying through an unexpected filesystem alias.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot read \(url.lastPathComponent) (errno \(errno))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw failure("Cannot verify regular file \(url.lastPathComponent)")
        }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw failure("File changed while verifying \(url.lastPathComponent)")
        }
        return hash.finalize()
    }

    private func ensureContainer(_ url: URL) throws {
        if mkdir(url.path, S_IRWXU) != 0 && errno != EEXIST {
            throw failure("Cannot create backup container (errno \(errno))")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw failure("Backup container is not a regular directory")
        }
    }

    private func allocateDirectory(in container: URL) throws -> URL {
        for _ in 0..<8 {
            let url = container.appendingPathComponent(String(UUID().uuidString.prefix(12)), isDirectory: true)
            if mkdir(url.path, S_IRWXU) == 0 { return url }
            guard errno == EEXIST else {
                throw failure("Cannot exclusively create backup directory (errno \(errno))")
            }
        }
        throw failure("Cannot allocate a unique backup directory")
    }
}
