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

    private func performSave(_ data: Data, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?) async throws -> SavedCreation {
        if let loadError { throw loadError }
        let asset = try await assetStore.store(data, mimeType: mimeType)
        // AssetStore may return an existing record for these bytes, including its original path.
        guard Self.isValidAssetPath(asset.relativePath, checksum: asset.checksum) else {
            throw SavedCreationsError.unavailable("asset metadata has an untrusted path")
        }
        // Dedupe can return an older file: never index corrupt or replaced bytes.
        let base = assetStore.baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let file = assetStore.baseDirectory.appendingPathComponent(asset.relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else {
            throw AssetStoreError.invalidPath(asset.relativePath)
        }
        _ = try await assetStore.data(for: asset)
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

    func data(for creation: SavedCreation) async throws -> Data {
        let path = creation.assetPath
        guard Self.isValidAssetPath(path, checksum: creation.checksum) else {
            throw AssetStoreError.invalidPath(path)
        }
        // AssetStore rejects lexical traversal; additionally reject symlinks out of the library.
        let base = assetStore.baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let file = assetStore.baseDirectory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { throw AssetStoreError.invalidPath(path) }
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
