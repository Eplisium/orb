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
    var libraryManaged: Bool = false
}

struct AssetDeletionEntry: Equatable {
    let checksum: String
    let relativePath: String
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
    let recoveryDirectory: URL
    /// Foundation may leave ancestor aliases unresolved when the final directory
    /// is absent. Bind the deepest existing ancestor before the first write too.
    var canonicalBaseDirectory: URL {
        ManagedStoragePaths.canonicalURL(baseDirectory)
    }
    var metadataFileURLs: [URL] { database.storageFileURLs + [catalogMarkerURL] }
    var managedDirectoryURLs: [URL] {
        [baseDirectory, recoveryDirectory] + database.storageDirectoryURLs
    }

    /// One boundary for every exporter and every post-commit source consumer.
    /// A registry read failure must fail closed, including for deduplicated saves.
    func isManagedStoragePath(_ url: URL, additionalFiles: [URL] = []) throws -> Bool {
        let registered = try database.libraryRows("SELECT canonical_index FROM library_manifests;").flatMap { row -> [URL] in
            let index = URL(fileURLWithPath: row[0])
            return [index, index.deletingLastPathComponent().appendingPathComponent(".\(index.lastPathComponent).orb-assets")]
        }
        return try ManagedStoragePaths.contains(url, directories: managedDirectoryURLs,
            files: metadataFileURLs + registered + additionalFiles)
    }
    let database: DatabaseManager
    private let unlink: (URL) throws -> Void
    // Outside the asset tree: it is catalog metadata, not content.
    private var catalogMarkerURL: URL {
        baseDirectory.deletingLastPathComponent().appendingPathComponent(".\(baseDirectory.lastPathComponent).orb-catalog")
    }

    /// - Parameters:
    ///   - baseDirectory: Root of the asset library. Created lazily on first
    ///     write. Tests inject an isolated temporary directory.
    ///   - database: Metadata store. Tests inject an isolated manager; the
    ///     default is the shared one.
    ///   - recoveryDirectory: Reserved job journal tree. Nil selects the same
    ///     production location as JobController.shared; fixtures inject a root.
    init(baseDirectory: URL? = nil, database: DatabaseManager = .shared,
         recoveryDirectory: URL? = nil,
         unlink: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.baseDirectory = (baseDirectory ?? Self.defaultBaseDirectory()).standardizedFileURL
        self.recoveryDirectory = (recoveryDirectory ?? ManagedStoragePaths.jobRecoveryDirectory).standardizedFileURL
        self.database = database
        self.unlink = unlink
    }

    // MARK: Writing

    /// All writers (including dedupe) reserve the same SQLite catalog. Cleanup
    /// is committed separately before replacement: rolling back a failed save
    /// must never resurrect an old tombstone pointing at new bytes.
    @discardableResult
    func store(
        _ data: Data,
        mimeType: String? = nil,
        remoteReference: String? = nil,
        jobID: UUID? = nil,
        messageID: UUID? = nil
    ) async throws -> AssetRecord {
        try storePayload(checksum: Self.sha256Hex(data), size: data.count,
                         mimeType: mimeType, remoteReference: remoteReference,
                         jobID: jobID, messageID: messageID) { temporaryURL in
            try data.write(to: temporaryURL, options: .withoutOverwriting)
        }
    }

    /// The source remains available on every metadata/cleanup failure. The
    /// caller of an outer manifest transaction must pass consumeSource: false.
    @discardableResult
    func store(
        fileAt source: URL,
        mimeType: String? = nil,
        remoteReference: String? = nil,
        jobID: UUID? = nil,
        messageID: UUID? = nil,
        consumeSource: Bool = true
    ) async throws -> AssetRecord {
        do {
            let checksum = try Self.sha256Hex(fileAt: source)
            let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
            let record = try storePayload(checksum: checksum, size: size, mimeType: mimeType,
                                         remoteReference: remoteReference, jobID: jobID, messageID: messageID) { temporaryURL in
                try FileManager.default.copyItem(at: source, to: temporaryURL)
                guard try Self.sha256Hex(fileAt: temporaryURL) == checksum else {
                    throw AssetStoreError.storageFailure("Source changed while copying")
                }
            }
            if consumeSource { consumeSourceFile(source, afterStoring: record) }
            return record
        } catch let error as AssetStoreError { throw error }
        catch { throw AssetStoreError.storageFailure(error.localizedDescription) }
    }

    func storePayload(
        checksum: String, size: Int, mimeType: String?, remoteReference: String?,
        jobID: UUID?, messageID: UUID?, libraryImport: LibraryImportToken? = nil,
        now: () -> Date = Date.init,
        commit: ((AssetRecord) throws -> Void)? = nil, stage: (URL) throws -> Void
    ) throws -> AssetRecord {
        do {
            try recoverPendingDeletions()
            return try database.withAssetReservation {
                try bindCatalog()
                if let token = libraryImport {
                    try database.requireLibraryRevision(token.manifestID, token.revision)
                    guard try !database.libraryRows("SELECT 1 FROM library_imports WHERE operation_id=? AND manifest_id=? AND lease_until>?;", [token.id.uuidString, token.manifestID.uuidString, String(now().timeIntervalSince1970)]).isEmpty else {
                        throw database.libraryConflict("Import lease expired; retry saving")
                    }
                }
                // A deletion can be prepared between recovery and this lock.
                // Fail closed; the caller still owns its input and can retry.
                guard try database.loadAssetDeletionInventory().isEmpty else {
                    throw AssetStoreError.storageFailure("Asset cleanup is pending; retry the save")
                }
                let records = try database.loadAssetRecordsChecked(checksum: checksum)
                    .sorted { $0.createdAt < $1.createdAt }
                // Quarantine reserves both the content and path, even if its old
                // file is missing or contains bytes which do not match the hash.
                try database.requireAssetPathNotQuarantined(checksum: checksum,
                    path: Self.relativePath(forChecksum: checksum, mimeType: mimeType))
                for record in records {
                    try database.requireAssetPathNotQuarantined(checksum: checksum, path: record.relativePath)
                }
                if let token = libraryImport {
                    try database.requireAssetPathNotQuarantined(checksum: token.stagingChecksum, path: token.stagingPath)
                }
                // Validate the entire inventory, not just the deduped first row.
                for record in records {
                    guard Self.isContentAddressed(record, checksum: checksum) else {
                        throw AssetStoreError.invalidPath(record.relativePath)
                    }
                    try verifyStoredFile(record)
                }
                if let existing = records.first {
                    if libraryImport != nil {
                        try commit?(existing)
                        return existing
                    }
                    if let owned = records.first(where: {
                        !$0.libraryManaged && $0.jobID == jobID && $0.messageID == messageID && $0.remoteReference == remoteReference
                    }) { return owned }
                    // Dedupe shares bytes, not ownership: never replace another
                    // job/message's attachment with the incoming owner's fields.
                    return try recordStoredAsset(sizeBytes: existing.sizeBytes, checksum: checksum,
                        relativePath: existing.relativePath, mimeType: existing.mimeType,
                        remoteReference: remoteReference, jobID: jobID, messageID: messageID)
                }
                let relativePath = Self.relativePath(forChecksum: checksum, mimeType: mimeType)
                let finalURL = try resolvedURL(forRelativePath: relativePath)
                try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try resolvedURL(forRelativePath: relativePath)
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    guard try Self.sha256Hex(fileAt: finalURL) == checksum else {
                        throw AssetStoreError.corrupt(relativePath: relativePath)
                    }
                } else {
                    let temporaryURL: URL
                    if let token = libraryImport {
                        temporaryURL = try resolvedURL(forRelativePath: token.stagingPath)
                        try FileManager.default.createDirectory(at: temporaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        _ = try resolvedURL(forRelativePath: token.stagingPath)
                    } else {
                        temporaryURL = finalURL.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
                    }
                    guard !FileManager.default.fileExists(atPath: temporaryURL.path) else {
                        throw AssetStoreError.storageFailure("Import staging path already exists; retry maintenance")
                    }
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }
                    try stage(temporaryURL)
                    _ = try resolvedURL(forRelativePath: relativePath)
                    try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                }
                // A failed commit may leave an unindexed, verified file. Retain
                // it (and the caller's source), so a retry can safely adopt it.
                let record = try recordStoredAsset(sizeBytes: size, checksum: checksum, relativePath: relativePath,
                    mimeType: mimeType, remoteReference: remoteReference, jobID: jobID, messageID: messageID,
                    libraryManaged: libraryImport != nil)
                try commit?(record)
                return record
            }
        } catch let error as AssetStoreError { throw error }
        catch { throw AssetStoreError.storageFailure(error.localizedDescription) }
    }

    /// Best-effort cleanup after all owning transactions commit. A caller may
    /// pass an existing library path; never unlink the stored asset itself.
    func consumeSourceFile(_ source: URL, afterStoring record: AssetRecord) {
        // Source cleanup is not managed-storage deletion. Keep recovery entries,
        // locks, database backups and metadata even after a successful dedupe.
        guard let managed = try? isManagedStoragePath(source), !managed else { return }
        guard let stored = try? fileURL(forRelativePath: record.relativePath),
              source.resolvingSymlinksInPath().standardizedFileURL
                != stored.resolvingSymlinksInPath().standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: source)
    }

    /// Raw attachment writers must verify under their SQLite reservation too;
    /// stale metadata cannot reattach a file already removed by cleanup.
    func validateAttachment(_ record: AssetRecord) throws {
        guard Self.isContentAddressed(record, checksum: record.checksum) else {
            throw AssetStoreError.invalidPath(record.relativePath)
        }
        try verifyStoredFile(record)
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
        messageID: UUID?,
        libraryManaged: Bool = false
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
            createdAt: Date(),
            libraryManaged: libraryManaged
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

    /// Prepare metadata deletion and its complete inventory in one committed
    /// transaction, then unlink under a NEW reservation. Never roll metadata
    /// back after unlink: only the durable cleanup acknowledgement can roll back.
    @discardableResult
    func removeUnattached(checksum: String) throws -> Bool {
        guard Self.validContentPath(Self.relativePath(forChecksum: checksum, mimeType: nil), checksum: checksum) else {
            throw AssetStoreError.invalidPath(checksum)
        }
        let recovered = try recoverPendingDeletions().contains(checksum)
        let prepared = try database.withAssetReservation {
            try bindCatalog()
            guard try database.libraryManagedRoot() else { return false }
            if try database.hasAttachedAssetRecord(checksum: checksum) { return false }
            let records = try database.loadAssetRecordsChecked(checksum: checksum)
            // Validate every row before journaling/deleting even the first one.
            let entries = Set(records.map(\.relativePath)).map {
                AssetDeletionEntry(checksum: checksum, relativePath: $0)
            }
            for entry in entries { _ = try deletionURL(entry) }
            for record in records where !Self.isContentAddressed(record, checksum: checksum) {
                throw AssetStoreError.invalidPath(record.relativePath)
            }
            for entry in entries { try database.journalAssetDeletion(entry) }
            try database.deleteUnattachedAssetRecords(checksum: checksum)
            return !records.isEmpty
        }
        try recoverPendingDeletions()
        return recovered || prepared
    }

    /// Explicit recovery is safe after reopening and is also mandatory before
    /// every writer. An error blocks publication; no replacement can reuse paths
    /// while a previous generation still has a durable deletion intent.
    @discardableResult
    func recoverPendingDeletions() throws -> Set<String> {
        try database.withAssetReservation {
            try bindCatalog()
            // bindCatalog quarantines legacy work in this transaction, before
            // loading anything that might authorize an unlink.
            let entries = try database.loadAssetDeletionInventory()
            let managed = try database.libraryManagedRoot()
            guard entries.isEmpty || managed else {
                throw AssetStoreError.storageFailure("Unreconciled legacy cleanup inventory")
            }
            // Complete validation BEFORE unlinking any file. A malformed journal,
            // symlink/directory, or unexpected live owner makes recovery fail closed.
            let urls = try entries.map { entry -> URL in
                let url = try deletionURL(entry)
                guard try !database.hasAssetRecord(checksum: entry.checksum, relativePath: entry.relativePath),
                      try !database.hasAttachedAssetRecord(checksum: entry.checksum) else {
                    throw AssetStoreError.storageFailure("Cleanup conflicts with live asset metadata")
                }
                return url
            }
            for (entry, url) in zip(entries, urls) {
                if FileManager.default.fileExists(atPath: url.path) { try unlink(url) }
                try database.acknowledgeAssetDeletion(entry)
            }
            // If COMMIT fails, rollback restores the inventory (not metadata).
            // Already absent files are successful cleanup on the next attempt.
            return Set(entries.map(\.checksum))
        }
    }

    private func deletionURL(_ entry: AssetDeletionEntry) throws -> URL {
        try database.requireAssetPathNotQuarantined(checksum: entry.checksum, path: entry.relativePath)
        guard Self.validContentPath(entry.relativePath, checksum: entry.checksum) else {
            throw AssetStoreError.invalidPath(entry.relativePath)
        }
        let url = try resolvedURL(forRelativePath: entry.relativePath)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw AssetStoreError.invalidPath(entry.relativePath)
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return url
        }
        return url
    }

    static func validContentPath(_ path: String, checksum: String) -> Bool {
        guard checksum.utf8.count == 64,
              checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        let prefix = String(checksum.prefix(2)) + "/" + checksum
        if path == prefix { return true }
        guard path.hasPrefix(prefix + ".") else { return false }
        let suffix = path.dropFirst(prefix.count + 1)
        return !suffix.isEmpty && suffix.utf8.count <= 8 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0)
        }
    }

    /// Pair one SQLite catalog with one asset root. The exclusive marker rejects
    /// independent DBs pointing at the same files (including in-memory catalogs).
    /// Moving/copying a catalog/root requires explicit reconciliation, not adoption.
    private func bindCatalog() throws {
        _ = try resolvedURL(forRelativePath: ".catalog-validation")
        try database.classifyAssetRoot(canonicalBaseDirectory,
            markerExists: FileManager.default.fileExists(atPath: catalogMarkerURL.path))
        let identity = try database.bindAssetRoot(canonicalBaseDirectory)
        let expected = Data(identity.utf8)
        let marker = catalogMarkerURL
        if let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw AssetStoreError.invalidPath(marker.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ExclusiveMarkerPublisher.publish(expected, to: marker)
        guard try Data(contentsOf: marker) == expected else {
            throw AssetStoreError.storageFailure("Asset root belongs to another metadata catalog")
        }
        try database.quarantineLegacyAssetDeletions()
    }

    /// JSON manifests are independent catalogs, not SQLite transactions. Pin
    /// newly saved content durably before publishing a manifest reference. Pins
    /// deliberately outlive removal/failed manifest writes until a future global
    /// ownership-aware GC exists; no legacy Library migration is performed.
    func preserveForLibrary(_ record: AssetRecord) throws {
        try withCatalogReservation {
            guard try database.loadAssetDeletionInventory().isEmpty,
                  try database.loadAssetRecordsChecked(checksum: record.checksum).contains(where: {
                      $0.relativePath == record.relativePath
                  }) else {
                throw AssetStoreError.storageFailure("Asset changed before the Library save; retry")
            }
            try validateAttachment(record)
            try database.pinLibraryAsset(checksum: record.checksum)
        }
    }

    /// Synchronous manifest CAS uses the same cross-connection reservation.
    /// This is not an atomic SQLite+JSON transaction; callers must preserve bytes.
    func withCatalogReservation<T>(_ work: () throws -> T) throws -> T {
        try database.withAssetReservation {
            try bindCatalog()
            let result = try work()
            // v1 registration changes the mode inside work(). Commit the durable
            // quarantine in that SAME transaction, without editing its caller.
            try database.quarantineLegacyAssetDeletions()
            return result
        }
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
        MediaFileExtension.forMIMEType(mimeType)
    }

    /// A stored record must sit at a content-addressed path for its own
    /// checksum: the current layout, or the extension-less one used before
    /// its MIME type had a known extension (kept valid so adding an
    /// extension never strands assets that are already on disk).
    private static func isContentAddressed(_ record: AssetRecord, checksum: String) -> Bool {
        validContentPath(record.relativePath, checksum: checksum) &&
            (record.relativePath == relativePath(forChecksum: checksum, mimeType: record.mimeType)
            || record.relativePath == relativePath(forChecksum: checksum, mimeType: nil))
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

/// File extensions for the media types ORB stores and exports. One table,
/// so the stored asset, Library exports, Quick Look copies and drags agree
/// on a name. `nil` means the type is unknown, never "treat it as text".
enum MediaFileExtension {
    static func forMIMEType(_ mimeType: String?) -> String? {
        // "audio/mpeg; charset=binary" names the same type as "audio/mpeg".
        let type = mimeType?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch type {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/wave", "audio/x-wav": return "wav"
        case "audio/mp4": return "m4a"
        case "audio/pcm", "audio/l16": return "pcm"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "application/json": return "json"
        case "text/plain": return "txt"
        default: return nil
        }
    }
}
