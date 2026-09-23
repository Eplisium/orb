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
            return existing
        }

        let relativePath = Self.relativePath(forChecksum: checksum, mimeType: mimeType)
        let finalURL = baseDirectory.appendingPathComponent(relativePath)

        do {
            // Ensure the base and shard directory exist. A failure here
            // (disk full, permissions, parent-is-a-file) is recoverable.
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                // The file is present but had no record (e.g. a crash between
                // file write and metadata write). Record it instead of
                // rewriting it.
                return try recordStoredAsset(
                    data: data, relativePath: relativePath, mimeType: mimeType,
                    remoteReference: remoteReference, jobID: jobID, messageID: messageID
                )
            }
            // Atomic write: write to a temporary file in the same directory
            // (same volume) and rename into place.
            let temporaryURL = baseDirectory.appendingPathComponent(
                ".tmp-\(UUID().uuidString)", isDirectory: false
            )
            try data.write(to: temporaryURL, options: .atomic)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
            return try recordStoredAsset(
                data: data, relativePath: relativePath, mimeType: mimeType,
                remoteReference: remoteReference, jobID: jobID, messageID: messageID
            )
        } catch let error as AssetStoreError {
            throw error
        } catch {
            throw AssetStoreError.storageFailure(error.localizedDescription)
        }
    }

    private func recordStoredAsset(
        data: Data,
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
            sizeBytes: data.count,
            checksum: Self.sha256Hex(data),
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

    /// Resolves a relative path inside the base directory, rejecting
    /// absolute paths and traversal (`..`, symlink-free standardization).
    private func resolvedURL(forRelativePath relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.contains(".."),
              !relativePath.isEmpty
        else {
            throw AssetStoreError.invalidPath(relativePath)
        }
        let url = baseDirectory.appendingPathComponent(relativePath)
        let standardized = url.standardizedFileURL.path
        let base = baseDirectory.standardizedFileURL.path
        guard standardized.hasPrefix(base + "/") else {
            throw AssetStoreError.invalidPath(relativePath)
        }
        return url
    }
}
