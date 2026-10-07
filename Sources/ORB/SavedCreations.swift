import Foundation

/// An individual generation. Several creations may reference the same content-addressed asset.
struct SavedCreation: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case image, video, audio, transcript, embedding
    }

    var id: UUID
    var kind: Kind
    var modelID: String
    var prompt: String?
    var mimeType: String
    var createdAt: Date
    /// Relative to AssetStore.baseDirectory; never a user-supplied filename.
    var assetPath: String
    var checksum: String
}

enum SavedCreationsError: Error, LocalizedError {
    case invalidIndex(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidIndex(let detail): return "The saved creations index is invalid: \(detail). It was not replaced."
        case .unavailable(let detail): return "Saved creations are unavailable: \(detail)"
        }
    }
}

private struct CreationsManifest: Codable {
    let version: Int
    let creations: [SavedCreation]
}

/// Main-actor serialization ensures saves cannot lose entries to concurrent UI writes.
@MainActor
final class SavedCreationsStore: ObservableObject {
    static let shared: SavedCreationsStore = {
        do { return try SavedCreationsStore() }
        catch { return SavedCreationsStore(loadFailure: error) }
    }()

    @Published private(set) var creations: [SavedCreation]
    /// Non-nil when the default manifest cannot be read. Saves fail closed in this state.
    let loadError: Error?
    private let assetStore: AssetStore
    private let indexURL: URL
    /// Serialize the entire read-modify-write across suspension points. MainActor alone
    /// does not prevent two concurrent saves from reading the same manifest state.
    private var previousSave: Task<Void, Never>?

    private static func defaultIndexURL() -> URL {
        AssetStore.defaultBaseDirectory().deletingLastPathComponent()
            .appendingPathComponent("creations.json", isDirectory: false)
    }

    init(assetStore: AssetStore = AssetStore(), indexURL: URL? = nil) throws {
        self.assetStore = assetStore
        self.indexURL = indexURL ?? Self.defaultIndexURL()
        let url = self.indexURL
        if FileManager.default.fileExists(atPath: url.path) {
            let manifest: CreationsManifest
            do { manifest = try JSONDecoder().decode(CreationsManifest.self, from: Data(contentsOf: url)) }
            catch { throw SavedCreationsError.invalidIndex(error.localizedDescription) }
            guard manifest.version == 1 else { throw SavedCreationsError.invalidIndex("unsupported version") }
            guard Set(manifest.creations.map(\.id)).count == manifest.creations.count else {
                throw SavedCreationsError.invalidIndex("duplicate creation IDs")
            }
            for item in manifest.creations {
                guard Self.isValidAssetPath(item.assetPath, checksum: item.checksum) else {
                    throw SavedCreationsError.invalidIndex("untrusted asset path")
                }
            }
            creations = manifest.creations
        } else {
            creations = []
        }
        loadError = nil
    }

    private init(loadFailure: Error) {
        assetStore = AssetStore()
        indexURL = Self.defaultIndexURL()
        creations = []
        loadError = loadFailure
    }

    func save(_ data: Data, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?) async throws -> SavedCreation {
        let predecessor = previousSave
        let operation = Task {
            await predecessor?.value
            return try await performSave(data, mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt)
        }
        previousSave = Task { _ = try? await operation.value }
        return try await operation.value
    }

    /// Saves a file already on disk (a streamed download) without loading it
    /// into memory. The source file is moved into the library on success and
    /// left in place on failure so the caller can retry or export it.
    func save(fileAt source: URL, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?) async throws -> SavedCreation {
        try await serialized { [self] in
            if let loadError { throw loadError }
            let asset = try await assetStore.store(fileAt: source, mimeType: mimeType)
            return try indexNewCreation(asset: asset, mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt)
        }
    }

    private func performSave(_ data: Data, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?) async throws -> SavedCreation {
        if let loadError { throw loadError }
        let asset = try await assetStore.store(data, mimeType: mimeType)
        return try indexNewCreation(asset: asset, mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt)
    }

    private func indexNewCreation(asset: AssetRecord, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?) throws -> SavedCreation {
        // AssetStore may return an existing record for these bytes, including its original path.
        guard Self.isValidAssetPath(asset.relativePath, checksum: asset.checksum) else {
            throw SavedCreationsError.unavailable("asset metadata has an untrusted path")
        }
        // Containment + symlink check (AssetStore already verified the checksum
        // of new and deduped files by streaming them).
        _ = try validatedFileURL(path: asset.relativePath, checksum: asset.checksum)
        let item = SavedCreation(id: UUID(), kind: kind, modelID: modelID, prompt: prompt,
                                 mimeType: mimeType, createdAt: Date(), assetPath: asset.relativePath,
                                 checksum: asset.checksum)
        let updated = [item] + creations
        let payload = try JSONEncoder().encode(CreationsManifest(version: 1, creations: updated))
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // .atomic writes a sibling temporary file and replaces the manifest only on success.
        try payload.write(to: indexURL, options: .atomic)
        creations = updated
        return item
    }

    /// Removes creations from the index only (bytes stay so Undo works). If the index
    /// write fails the in-memory list is untouched, so nothing disappears that would
    /// come back after a restart.
    @discardableResult
    func remove(ids: Set<UUID>) async throws -> [SavedCreation] {
        try await serialized { [self] in
            if let loadError { throw loadError }
            let removed = creations.filter { ids.contains($0.id) }
            guard !removed.isEmpty else { return [] }
            try writeIndex(creations.filter { !ids.contains($0.id) })
            return removed
        }
    }

    /// Puts removed creations back (Undo), keeping newest-first order.
    func restore(_ items: [SavedCreation]) async throws {
        try await serialized { [self] in
            let existing = Set(creations.map(\.id))
            let merged = (creations + items.filter { !existing.contains($0.id) }).sorted { $0.createdAt > $1.createdAt }
            try writeIndex(merged)
        }
    }

    /// Deletes bytes no remaining creation references. Call once Undo is no longer possible.
    func purgeUnreferenced(_ removed: [SavedCreation]) async {
        _ = try? await serialized { [self] in
            let live = Set(creations.map(\.checksum))
            for checksum in Set(removed.map(\.checksum)) where !live.contains(checksum) {
                _ = try? assetStore.removeUnattached(checksum: checksum)
            }
        }
    }

    private func serialized<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let predecessor = previousSave
        let operation = Task { @MainActor () async throws -> T in
            await predecessor?.value
            return try await work()
        }
        previousSave = Task { _ = try? await operation.value }
        return try await operation.value
    }

    private func writeIndex(_ updated: [SavedCreation]) throws {
        let payload = try JSONEncoder().encode(CreationsManifest(version: 1, creations: updated))
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: indexURL, options: .atomic)
        creations = updated
    }

    /// On-disk location of a creation's bytes for export (copyItem), drag-out,
    /// Reveal in Finder, Share, Quick Look, and thumbnails — without reading
    /// or hashing the file. Applies the same path validation as `data(for:)`:
    /// content-addressed path shape, containment, and no symlinks anywhere.
    func fileURL(for creation: SavedCreation) throws -> URL {
        try validatedFileURL(path: creation.assetPath, checksum: creation.checksum)
    }

    /// Copies a creation's file to a user-chosen destination (no in-memory
    /// read). Replaces an existing file at `destination`.
    func export(_ creation: SavedCreation, to destination: URL) throws {
        let source = try fileURL(for: creation)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }

    private func validatedFileURL(path: String, checksum: String) throws -> URL {
        guard Self.isValidAssetPath(path, checksum: checksum) else {
            throw AssetStoreError.invalidPath(path)
        }
        // AssetStore rejects lexical traversal and any symlinked component.
        let url = try assetStore.fileURL(forRelativePath: path)
        // Defence in depth: the canonical location must stay inside the library.
        let base = assetStore.baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { throw AssetStoreError.invalidPath(path) }
        return url
    }

    func data(for creation: SavedCreation) async throws -> Data {
        let path = creation.assetPath
        _ = try validatedFileURL(path: path, checksum: creation.checksum)
        // Verify against the creation's persisted checksum, not only the database's current record.
        let record = AssetRecord(id: creation.id, relativePath: path, remoteReference: nil,
                                 mimeType: creation.mimeType, sizeBytes: 0, checksum: creation.checksum,
                                 jobID: nil, messageID: nil, retention: .keep, createdAt: creation.createdAt)
        return try await assetStore.data(for: record)
    }

    private static func isValidAssetPath(_ path: String, checksum: String) -> Bool {
        guard checksum.count == 64, checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        let prefix = String(checksum.prefix(2)) + "/" + checksum
        guard path == prefix || path.hasPrefix(prefix + ".") else { return false }
        if path == prefix { return true }
        let suffix = path.dropFirst(prefix.count + 1)
        return !suffix.isEmpty && suffix.count <= 8 && suffix.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }
}
