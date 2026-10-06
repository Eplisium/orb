import Foundation
import CryptoKit

// MARK: - Durable asset storage (W06)
//
// Generated media bytes live in per-user asset files under Application
// Support, with metadata in SQLite. Writes are atomic (write-to-temp +
// rename), filenames are derived from content checksums (never from prompts
// or secrets), and identical content is deduplicated by SHA-256. Every
// storage failure is recoverable: `AssetStoreError` cases describe what the
// user can do next instead of surfacing raw file-system errors.

/// Retention state for an asset. `keep` is the default; explicit retention
/// and export policies are layered on top of this field.
enum AssetRetention: String, Sendable, Equatable {
    case keep
    case ephemeral
}

/// Metadata for one stored asset. `relativePath` is relative to the store's
/// base directory and is derived from the content checksum — no user content
/// or secret material ever appears in a filename.
struct AssetRecord: Equatable, Identifiable, Sendable {
    var id: UUID
    var relativePath: String
    /// Remote reference (e.g. a workspace file ID or signed-URL reference),
    /// kept as a reference only — never the only copy of valuable output.
    var remoteReference: String?
    var mimeType: String?
    var sizeBytes: Int
    /// Lowercase hex SHA-256 of the stored bytes.
    var checksum: String
    var jobID: UUID?
    var messageID: UUID?
    var retention: AssetRetention
    var createdAt: Date
}

enum AssetStoreError: Error, LocalizedError, Equatable {
    /// The asset could not be written (disk full, permissions, …). The bytes
    /// the user paid for are not lost by ORB — this is a recoverable state.
    case storageFailure(String)
    /// The recorded asset file no longer exists on disk.
    case missing(relativePath: String)
    /// The file exists but its bytes no longer match the recorded checksum.
    case corrupt(relativePath: String)
    /// A relative path tried to escape the asset base directory.
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .storageFailure(let message):
            return "ORB could not store the asset (\(message)). Free up disk space or check folder permissions, then try again."
        case .missing(let path):
            return "The stored asset file is missing at \"\(path)\". It may have been moved or deleted outside ORB."
        case .corrupt(let path):
            return "The stored asset at \"\(path)\" no longer matches its checksum and may be corrupted."
        case .invalidPath(let path):
            return "Refusing to access an asset path outside the asset library: \"\(path)\"."
        }
    }
}

/// Stores generated assets durably. Not actor-isolated: file work happens on
/// the caller's task, keeping the main actor free for rendering.
final class AssetStore {
    /// Default location: Application Support/ORB/Assets.
    static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("ORB", isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
    }

    let baseDirectory: URL
    private let database: DatabaseManager

    /// - Parameters:
    ///   - baseDirectory: Root of the asset library. Created lazily on first
    ///     write. Tests inject an isolated temporary directory.
    ///   - database: Metadata store. Tests inject an isolated manager; the
    ///     default is the shared one.
    init(baseDirectory: URL? = nil, database: DatabaseManager = .shared) {
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory()
        self.database = database
    }

    // MARK: Writing

    /// Stores bytes atomically and records metadata. Identical bytes dedupe:
    /// the existing record (and its file) is returned untouched rather than
    /// overwritten.
    @discardableResult
    func store(
        _ data: Data,
        mimeType: String? = nil,
        remoteReference: String? = nil,
        jobID: UUID? = nil,
        messageID: UUID? = nil
    ) async throws -> AssetRecord {
        let checksum = Self.sha256Hex(data)

        // Dedupe by checksum: identical content already stored returns the
        // same relative path and never overwrites the existing file.
        if let existing = database.findAssetRecord(checksum: checksum) {
            guard existing.relativePath == Self.relativePath(forChecksum: checksum, mimeType: existing.mimeType) else {
                throw AssetStoreError.invalidPath(existing.relativePath)
            }
            try verifyStoredFile(existing)
            return existing
        }

        let relativePath = Self.relativePath(forChecksum: checksum, mimeType: mimeType)

        do {
            // Validate before and after creation: a pre-existing shard must
            // never redirect writes through a symbolic link.
            let finalURL = try resolvedURL(forRelativePath: relativePath)
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try resolvedURL(forRelativePath: relativePath)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                // A crash may leave an unindexed file; trust it only when
                // its bytes actually match the content-addressed filename.
                _ = try await self.data(atRelativePath: relativePath, expectedChecksum: checksum)
                return try recordStoredAsset(
                    sizeBytes: data.count, checksum: checksum, relativePath: relativePath, mimeType: mimeType,
                    remoteReference: remoteReference, jobID: jobID, messageID: messageID
                )
            }
            // Atomic write: temporary file and rename on the same volume.
            let temporaryURL = finalURL.deletingLastPathComponent().appendingPathComponent(
                ".tmp-\(UUID().uuidString)", isDirectory: false
            )
            try data.write(to: temporaryURL, options: .atomic)
            do {
                _ = try resolvedURL(forRelativePath: relativePath)
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
            return try recordStoredAsset(
                sizeBytes: data.count, checksum: checksum, relativePath: relativePath, mimeType: mimeType,
                remoteReference: remoteReference, jobID: jobID, messageID: messageID
            )
        } catch let error as AssetStoreError {
            throw error
        } catch {
            throw AssetStoreError.storageFailure(error.localizedDescription)
        }
    }

    /// Stores a file that is already on disk (e.g. a streamed video
    /// download) without loading it into memory: the checksum is computed
    /// in fixed-size chunks and the file is MOVED into the library. The
    /// source file is consumed on success and on dedupe; on failure it is
    /// left in place so the caller can retry or export it.
    @discardableResult
    func store(
        fileAt source: URL,
        mimeType: String? = nil,
        remoteReference: String? = nil,
        jobID: UUID? = nil,
        messageID: UUID? = nil
    ) async throws -> AssetRecord {
        let checksum: String
        let size: Int
        do {
            checksum = try Self.sha256Hex(fileAt: source)
            size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw AssetStoreError.storageFailure(error.localizedDescription)
        }
        if let existing = database.findAssetRecord(checksum: checksum) {
            guard existing.relativePath == Self.relativePath(forChecksum: checksum, mimeType: existing.mimeType) else {
                throw AssetStoreError.invalidPath(existing.relativePath)
            }
            try verifyStoredFile(existing)
            try? FileManager.default.removeItem(at: source)
            return existing
        }
        let relativePath = Self.relativePath(forChecksum: checksum, mimeType: mimeType)
        do {
            let finalURL = try resolvedURL(forRelativePath: relativePath)
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            _ = try resolvedURL(forRelativePath: relativePath)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                guard try Self.sha256Hex(fileAt: finalURL) == checksum else {
                    throw AssetStoreError.corrupt(relativePath: relativePath)
                }
                try? FileManager.default.removeItem(at: source)
            } else {
                // Move into the shard under a temporary name first (a copy when
                // crossing volumes), then rename atomically into place.
                let temporaryURL = finalURL.deletingLastPathComponent().appendingPathComponent(
                    ".tmp-\(UUID().uuidString)", isDirectory: false
                )
                try FileManager.default.moveItem(at: source, to: temporaryURL)
                do {
                    _ = try resolvedURL(forRelativePath: relativePath)
                    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                } catch {
                    // Hand the bytes back to the caller rather than losing them.
                    try? FileManager.default.moveItem(at: temporaryURL, to: source)
                    throw error
                }
            }
            return try recordStoredAsset(
                sizeBytes: size, checksum: checksum, relativePath: relativePath, mimeType: mimeType,
                remoteReference: remoteReference, jobID: jobID, messageID: messageID
            )
        } catch let error as AssetStoreError {
            throw error
        } catch {
            throw AssetStoreError.storageFailure(error.localizedDescription)
        }
    }

    /// Streams the stored file through SHA-256 (no full read into memory).
    private func verifyStoredFile(_ record: AssetRecord) throws {
        let url = try fileURL(forRelativePath: record.relativePath)
        let actual: String
        do { actual = try Self.sha256Hex(fileAt: url) }
        catch { throw AssetStoreError.storageFailure(error.localizedDescription) }
        guard actual == record.checksum else {
            throw AssetStoreError.corrupt(relativePath: record.relativePath)
        }
    }

    private func recordStoredAsset(
        sizeBytes: Int,
        checksum: String,
        relativePath: String,
        mimeType: String?,
        remoteReference: String?,
        jobID: UUID?,
        messageID: UUID?
    ) throws -> AssetRecord {
        let record = AssetRecord(
            id: UUID(),
            relativePath: relativePath,
            remoteReference: remoteReference,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            checksum: checksum,
            jobID: jobID,
            messageID: messageID,
            retention: .keep,
            createdAt: Date()
        )
        do {
            try database.saveAssetRecordChecked(record)
        } catch {
            throw AssetStoreError.storageFailure("Could not record asset metadata: \(error.localizedDescription)")
        }
        return record
    }

    // MARK: Reading

    /// Loads bytes and verifies the checksum. Missing or corrupt files
    /// surface as recoverable `AssetStoreError`s, never raw file errors.
    func data(for record: AssetRecord) async throws -> Data {
        try await data(atRelativePath: record.relativePath, expectedChecksum: record.checksum)
    }

    /// Validated on-disk location of a stored asset, without reading or
    /// hashing it — for export (copyItem), drag-out, Quick Look, and
    /// thumbnails. Same containment/symlink rules as reads; throws
    /// `.missing` when the file is gone.
    func fileURL(forRelativePath relativePath: String) throws -> URL {
        let url = try resolvedURL(forRelativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AssetStoreError.missing(relativePath: relativePath)
        }
        return url
    }

    func data(atRelativePath relativePath: String) async throws -> Data {
        try await data(atRelativePath: relativePath, expectedChecksum: nil)
    }

    private func data(atRelativePath relativePath: String, expectedChecksum: String?) async throws -> Data {
        let url = try resolvedURL(forRelativePath: relativePath)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw AssetStoreError.missing(relativePath: relativePath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AssetStoreError.storageFailure(error.localizedDescription)
        }
        if let expectedChecksum, Self.sha256Hex(data) != expectedChecksum {
            throw AssetStoreError.corrupt(relativePath: relativePath)
        }
        return data
    }

    // MARK: Deleting

    /// Deletes the bytes and metadata for a checksum, unless a job or message still
    /// references it. Returns whether anything was removed. Missing files are fine.
    @discardableResult
    func removeUnattached(checksum: String) throws -> Bool {
        if database.hasAttachedAssetRecord(checksum: checksum) { return false }
        let records = database.loadAssetRecords().filter { $0.checksum == checksum }
        for record in records {
            let url = try resolvedURL(forRelativePath: record.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try database.deleteUnattachedAssetRecords(checksum: checksum)
        return !records.isEmpty
    }

    // MARK: Layout

    /// `<2 hex chars>/<checksum>[.<ext>]` — content-addressed and secret-free.
    static func relativePath(forChecksum checksum: String, mimeType: String?) -> String {
        let shard = String(checksum.prefix(2))
        if let ext = fileExtension(forMimeType: mimeType), !ext.isEmpty {
            return "\(shard)/\(checksum).\(ext)"
        }
        return "\(shard)/\(checksum)"
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file computed in 1 MiB chunks, so large media never has
    /// to be resident in memory. Equal to `sha256Hex(Data(contentsOf:))`.
    static func sha256Hex(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileExtension(forMimeType mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "audio/mpeg": return "mp3"
        case "audio/wav", "audio/wave", "audio/x-wav": return "wav"
        case "audio/mp4": return "m4a"
        case "application/json": return "json"
        case "text/plain": return "txt"
        default: return nil
        }
    }

    /// Check both lexical and filesystem containment. Foundation's lexical
    /// standardization alone does not catch a shard redirected by a symlink.
    private func resolvedURL(forRelativePath relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw AssetStoreError.invalidPath(relativePath)
        }
        let base = baseDirectory.standardizedFileURL
        let url = base.appendingPathComponent(relativePath)
        guard url.standardizedFileURL.path.hasPrefix(base.path + "/") else {
            throw AssetStoreError.invalidPath(relativePath)
        }

        // Reject links even if their target happens to be inside the library:
        // a shard or final file can otherwise be retargeted outside later.
        // attributesOfItem sees dangling symlinks too, unlike fileExists.
        var componentURL = base
        for component in [nil] + components.map({ Optional(String($0)) }) {
            if let component { componentURL.appendPathComponent(component) }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: componentURL.path),
               let type = attributes[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                throw AssetStoreError.invalidPath(relativePath)
            }
        }
        let canonicalBase = base.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalFile = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalFile.hasPrefix(canonicalBase + "/") else {
            throw AssetStoreError.invalidPath(relativePath)
        }
        return url
    }
}
