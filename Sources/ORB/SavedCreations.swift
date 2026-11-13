import Foundation
import Darwin

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
    /// Recovery identity committed with the Library entry before the separate job link.
    /// Optional so existing manifests remain readable.
    var videoRemoteID: String? = nil
}

enum SavedCreationsError: Error, LocalizedError {
    case invalidIndex(String)
    case unavailable(String)
    case managedExportDestination

    var errorDescription: String? {
        switch self {
        case .invalidIndex(let detail): return "The saved creations index is invalid: \(detail). It was not replaced."
        case .unavailable(let detail): return "Saved creations are unavailable: \(detail)"
        case .managedExportDestination: return "Choose an export location outside ORB's managed library files."
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
    /// Optimistic snapshot, compared under the shared SQLite writer reservation.
    /// Independent instances must reopen after another instance edits the index.
    private var indexSnapshot: Data?
    private var indexBindingURL: URL {
        indexURL.deletingLastPathComponent().appendingPathComponent(".\(indexURL.lastPathComponent).orb-assets")
    }
    /// Serialize the entire read-modify-write across suspension points. MainActor alone
    /// does not prevent two concurrent saves from reading the same manifest state.
    private var previousSave: Task<Void, Never>?
    /// Undo belongs to individual windows, but their shared bytes belong to the store.
    private var pendingRemoval: [UUID: SavedCreation] = [:]

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
            do {
                let payload = try Data(contentsOf: url)
                manifest = try JSONDecoder().decode(CreationsManifest.self, from: payload)
                indexSnapshot = payload
            }
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
    /// into memory. The source is consumed only after asset metadata AND the
    /// manifest commit, and left in place on failure for retry or export.
    func save(fileAt source: URL, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?, videoRemoteID: String? = nil) async throws -> SavedCreation {
        try await serialized { [self] in
            if let loadError { throw loadError }
            let asset = try await assetStore.store(fileAt: source, mimeType: mimeType, consumeSource: false)
            let creation = try indexNewCreation(asset: asset, mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt, videoRemoteID: videoRemoteID)
            assetStore.consumeSourceFile(source, afterStoring: asset)
            return creation
        }
    }

    private func performSave(_ data: Data, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?) async throws -> SavedCreation {
        if let loadError { throw loadError }
        let asset = try await assetStore.store(data, mimeType: mimeType)
        return try indexNewCreation(asset: asset, mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt)
    }

    private func indexNewCreation(asset: AssetRecord, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?, videoRemoteID: String? = nil) throws -> SavedCreation {
        // AssetStore may return an existing record for these bytes, including its original path.
        guard Self.isValidAssetPath(asset.relativePath, checksum: asset.checksum) else {
            throw SavedCreationsError.unavailable("asset metadata has an untrusted path")
        }
        // Containment + symlink check (AssetStore already verified the checksum
        // of new and deduped files by streaming them).
        _ = try validatedFileURL(path: asset.relativePath, checksum: asset.checksum)
        try assetStore.preserveForLibrary(asset)
        let item = SavedCreation(id: UUID(), kind: kind, modelID: modelID, prompt: prompt,
                                 mimeType: mimeType, createdAt: Date(), assetPath: asset.relativePath,
                                 checksum: asset.checksum, videoRemoteID: videoRemoteID)
        try writeIndex([item] + creations)
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
            for item in removed { pendingRemoval[item.id] = item }
            return removed
        }
    }

    /// Puts removed creations back (Undo), keeping newest-first order.
    func restore(_ items: [SavedCreation]) async throws {
        try await serialized { [self] in
            let existing = Set(creations.map(\.id))
            let merged = (creations + items.filter { !existing.contains($0.id) }).sorted { $0.createdAt > $1.createdAt }
            try writeIndex(merged)
            for item in items { pendingRemoval.removeValue(forKey: item.id) }
        }
    }

    /// Expire this instance's Undo bookkeeping only. JSON manifests (including
    /// independent instances and legacy catalogs) do not provide a global owner
    /// inventory. Preserve bytes rather than pretending this is atomic GC. New
    /// Library saves also carry durable conservative pins in the asset catalog.
    func purgeUnreferenced(_ removed: [SavedCreation]) async {
        _ = try? await serialized { [self] in
            for item in removed { pendingRemoval.removeValue(forKey: item.id) }
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
        if let loadError { throw loadError }
        guard Set(updated.map(\.id)).count == updated.count,
              updated.allSatisfy({ Self.isValidAssetPath($0.assetPath, checksum: $0.checksum) }) else {
            throw SavedCreationsError.invalidIndex("duplicate identity or untrusted asset path")
        }
        let payload = try JSONEncoder().encode(CreationsManifest(version: 1, creations: updated))
        var published = false
        do {
            try assetStore.withCatalogReservation {
                let base = assetStore.canonicalBaseDirectory.path
                let index = indexURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard index != base, !index.hasPrefix(base + "/"),
                      !assetStore.metadataFileURLs.contains(where: {
                          $0.resolvingSymlinksInPath().standardizedFileURL.path == index
                      }) else { throw SavedCreationsError.unavailable("index overlaps managed asset storage") }
                // The marker rejects one manifest shared by independently locked
                // roots/catalogs. Existing v1 JSON remains unchanged and readable.
                let expected = Data(base.utf8)
                let marker = indexBindingURL
                let existingBinding = try Self.readIndexFile(marker)
                guard existingBinding == nil || existingBinding == expected else {
                    throw SavedCreationsError.unavailable("index belongs to another asset root")
                }
                guard try Self.readIndexFile(indexURL) == indexSnapshot else {
                    throw SavedCreationsError.unavailable("index changed in another store; reopen the Library before editing")
                }
                let fm = FileManager.default
                try fm.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if existingBinding == nil {
                    try ExclusiveMarkerPublisher.publish(expected, to: marker, fileManager: fm)
                }
                try payload.write(to: indexURL, options: .atomic)
                published = true
            }
        } catch {
            // JSON publication cannot be rolled back by a failed reservation COMMIT.
            // Adopt that actual outcome so callers finish their Undo bookkeeping;
            // all errors before publication still fail closed without changing memory.
            guard published else { throw error }
        }
        indexSnapshot = payload
        creations = updated
    }

    /// Missing is the only acceptable read failure; unreadable files, directories,
    /// and symlinks cannot masquerade as an absent manifest or binding.
    private static func readIndexFile(_ url: URL) throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw SavedCreationsError.invalidIndex("index or binding is not a regular file")
            }
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    /// On-disk location of a creation's bytes for export (copyItem), drag-out,
    /// Reveal in Finder, Share, Quick Look, and thumbnails — without reading
    /// or hashing the file. Applies the same path validation as `data(for:)`:
    /// content-addressed path shape, containment, and no symlinks anywhere.
    func fileURL(for creation: SavedCreation) throws -> URL {
        try validatedFileURL(path: creation.assetPath, checksum: creation.checksum)
    }

    /// Exports generated bytes retained after a local save failure.
    func export(data: Data, to destination: URL) throws {
        try export(to: destination) { staged in
            try data.write(to: staged, options: .withoutOverwriting)
        }
    }

    /// Stage the copy beside the destination, then atomically replace it. Never
    /// remove the user's previous export before the replacement is ready.
    func export(_ creation: SavedCreation, to destination: URL) throws {
        let source = try fileURL(for: creation)
        try export(to: destination) { staged in
            try FileManager.default.copyItem(at: source, to: staged)
        }
    }

    private func export(to destination: URL, stage: (URL) throws -> Void) throws {
        guard destination.isFileURL else { throw SavedCreationsError.managedExportDestination }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(destination.lastPathComponent)
        let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
        let base = assetStore.baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let metadataURLs = assetStore.metadataFileURLs + [indexURL, indexBindingURL]
        let metadata = metadataURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard canonicalTarget.path != base,
              !canonicalTarget.path.hasPrefix(base + "/"),
              !metadata.contains(canonicalTarget.path) else { throw SavedCreationsError.managedExportDestination }
        // Filesystem identity also covers firmlinks and spelling aliases. Walk
        // parents so even a new filename inside an aliased asset shard is denied.
        var ancestor = parent
        while true {
            if try Self.sameDirectory(ancestor, assetStore.baseDirectory) {
                throw SavedCreationsError.managedExportDestination
            }
            if ancestor.path == "/" { break }
            let next = ancestor.deletingLastPathComponent().standardizedFileURL
            if next.path == ancestor.path { break }
            ancestor = next
        }
        for url in metadataURLs + [assetStore.baseDirectory] where try Self.sameDirectory(parent, url.deletingLastPathComponent()) {
            let caseSensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames ?? false
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            if target.lastPathComponent.compare(url.lastPathComponent, options: options) == .orderedSame {
                throw SavedCreationsError.managedExportDestination
            }
        }

        let fm = FileManager.default
        let staged = parent.appendingPathComponent(".orb-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try stage(staged)
        // POSIX rename replaces a file atomically, refuses a directory, and does
        // not follow a final symlink or mutate another hard link to that file.
        guard Darwin.rename(staged.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func sameDirectory(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        let left = try lhs.resourceValues(forKeys: keys)
        let right: URLResourceValues
        do { right = try rhs.resourceValues(forKeys: keys) }
        catch let error as NSError where
            (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            // Managed directories are created lazily. Recovery exports must work
            // before the first successful save; other lookup errors fail closed.
            return false
        }
        guard let leftFile = left.fileResourceIdentifier as? NSObject,
              let rightFile = right.fileResourceIdentifier as? NSObject,
              let leftVolume = left.volumeIdentifier as? NSObject,
              let rightVolume = right.volumeIdentifier as? NSObject else {
            throw SavedCreationsError.unavailable("could not verify export destination identity")
        }
        return leftFile.isEqual(rightFile) && leftVolume.isEqual(rightVolume)
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
