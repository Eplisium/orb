import Foundation
import Darwin

struct SavedCreation: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case image, video, audio, transcript, embedding }
    var id: UUID
    var kind: Kind
    var modelID: String
    var prompt: String?
    var mimeType: String
    var createdAt: Date
    var assetPath: String
    var checksum: String
    var videoRemoteID: String? = nil
}

enum SavedCreationsError: Error, LocalizedError {
    case invalidIndex(String), unavailable(String), managedExportDestination
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
    var manifestID: UUID? = nil
    var catalogID: String? = nil
    var revision: Int64? = nil
    let creations: [SavedCreation]
}

/// SQLite is authoritative after registration. JSON is a retryable compatibility
/// export, never an owner inventory or an input on subsequent opens.
@MainActor
final class SavedCreationsStore: ObservableObject {
    static let shared: SavedCreationsStore = {
        do { return try SavedCreationsStore() }
        catch { return SavedCreationsStore(loadFailure: error) }
    }()
    @Published private(set) var creations: [SavedCreation] = []
    @Published private(set) var exportWarning: String?
    @Published private(set) var cleanupWarning: String?
    @Published private(set) var reclamationStatus = ""
    let loadError: Error?
    private let assetStore: AssetStore
    private let indexURL: URL
    private let now: () -> Date
    private let failpoint: (LibraryOwnershipPhase) throws -> Void
    private let undoDuration: TimeInterval
    private var snapshot: LibrarySnapshot?
    private var previousSave: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var foregroundMaintenanceTask: Task<Void, Never>?
    private var foregroundObservers: Set<UUID> = []
    private(set) var foregroundMaintenanceGeneration = 0
    var foregroundMaintenanceObserverCount: Int { foregroundObservers.count }
    var isForegroundMaintenanceRunning: Bool { foregroundMaintenanceTask != nil }
    // Legacy array APIs cannot identify an ABA generation. Only the first removal
    // of an ID in this process may use that adapter; subsequent removals require
    // the explicit token API. Never infer a token from persisted payload arrays.
    private var compatibilityRemovals: [LibraryRemoval] = []
    private var compatibilitySeen: Set<UUID> = []
    private var indexBindingURL: URL {
        indexURL.deletingLastPathComponent().appendingPathComponent(".\(indexURL.lastPathComponent).orb-assets")
    }
    private static func defaultIndexURL() -> URL {
        AssetStore.defaultBaseDirectory().deletingLastPathComponent().appendingPathComponent("creations.json")
    }
    init(assetStore: AssetStore = AssetStore(), indexURL: URL? = nil,
         now: @escaping () -> Date = Date.init, undoDuration: TimeInterval = 8,
         failpoint: @escaping (LibraryOwnershipPhase) throws -> Void = { _ in }) throws {
        self.assetStore = assetStore
        let requested = indexURL ?? Self.defaultIndexURL()
        // Resolve existing ancestors even when the index does not exist yet.
        var ancestor = requested.deletingLastPathComponent().standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        let parent = suffix.reversed().reduce(ancestor.resolvingSymlinksInPath().standardizedFileURL) { $0.appendingPathComponent($1) }
        self.indexURL = parent.appendingPathComponent(requested.lastPathComponent)
        self.now = now; self.failpoint = failpoint
        guard undoDuration.isFinite, undoDuration > 0, undoDuration <= 86400 else {
            throw SavedCreationsError.unavailable("Invalid Undo duration")
        }
        self.undoDuration = undoDuration
        loadError = nil
        try openRegisteredLibrary()
        maintenanceAndExport()
    }
    init(loadFailure: Error, assetStore: AssetStore = AssetStore(), indexURL: URL? = nil) {
        self.assetStore = assetStore; self.indexURL = indexURL ?? Self.defaultIndexURL()
        now = Date.init; undoDuration = 8; failpoint = { _ in }; loadError = loadFailure
    }
    private func requireSnapshot() throws -> LibrarySnapshot {
        if let loadError { throw loadError }
        guard let snapshot else { throw SavedCreationsError.unavailable("Library is not registered") }
        return snapshot
    }
    private func adopt(_ value: LibrarySnapshot) { snapshot = value; creations = value.creations }

    /// A cache is not evidence of absence. Read and validate the entire registered
    /// snapshot under one catalog reservation before either lookup can return nil.
    /// In particular, a broken row/load must not clear a job link or redownload.
    func creationForVideo(savedID: UUID?, remoteID: String) throws -> SavedCreation? {
        let before = try requireSnapshot()
        let latest = try assetStore.withCatalogReservation {
            try assetStore.database.librarySnapshot(before.manifestID)
        }
        adopt(latest)
        if let savedID, let linked = latest.creations.first(where: {
            $0.id == savedID && $0.kind == .video && ($0.videoRemoteID == nil || $0.videoRemoteID == remoteID)
        }) { return linked }
        return latest.creations.first { $0.kind == .video && $0.videoRemoteID == remoteID }
    }

    private func openRegisteredLibrary() throws {
        let db = assetStore.database
        let opened = try assetStore.withCatalogReservation { () -> LibrarySnapshot in
            let base = assetStore.canonicalBaseDirectory.path
            guard indexURL.path != base, !indexURL.path.hasPrefix(base + "/"),
                  !assetStore.metadataFileURLs.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == indexURL.path }) else {
                throw SavedCreationsError.unavailable("index overlaps managed asset storage")
            }
            if let row = try db.libraryRows("SELECT manifest_id FROM library_manifests WHERE canonical_index=?;", [indexURL.path]).first {
                guard let id = UUID(uuidString: row[0]) else { throw db.libraryConflict("Invalid registered manifest") }
                return try db.librarySnapshot(id)
            }
            let payload = try Self.readIndexFile(indexURL)
            let manifest = try payload.map { try JSONDecoder().decode(CreationsManifest.self, from: $0) }
            if let manifest {
                guard manifest.version == 1, Set(manifest.creations.map(\.id)).count == manifest.creations.count,
                      manifest.creations.allSatisfy({ AssetStore.validContentPath($0.assetPath, checksum: $0.checksum) }) else {
                    throw SavedCreationsError.invalidIndex("unregistered identity, unsupported version, duplicate IDs or untrusted paths")
                }
            }
            if let marker = try Self.readIndexFile(indexBindingURL), marker != Data(base.utf8) {
                throw db.libraryConflict("Unregistered or foreign Library binding")
            }
            let id = UUID()
            guard let catalog = try db.libraryRows("SELECT identity FROM asset_catalog WHERE singleton=1;").first?.first else {
                throw db.libraryConflict("Missing catalog identity")
            }
            try db.libraryExecute("INSERT INTO library_manifests(manifest_id,catalog_id,canonical_index,revision) VALUES (?,?,?,0);", [id.uuidString,catalog,indexURL.path])
            if let manifest {
                // Seeing one legacy manifest never establishes global completeness.
                try db.libraryExecute("UPDATE asset_catalog SET reclamation_mode='legacy_blocked' WHERE singleton=1;")
                for item in manifest.creations { try db.insertLibraryCreation(item, manifestID: id) }
            }
            return try db.librarySnapshot(id)
        }
        adopt(opened)
        // Registry commit precedes sidecar/export. A missing sidecar is repairable.
        // A bad export is warning-only; the registered database still loads.
    }

    func save(_ data: Data, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?) async throws -> SavedCreation {
        try await serialized { [self] in
            try publish(data: data, source: nil, mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt, videoRemoteID: nil)
        }
    }
    func save(fileAt source: URL, mimeType: String, kind: SavedCreation.Kind, modelID: String, prompt: String?, videoRemoteID: String? = nil) async throws -> SavedCreation {
        try await serialized { [self] in
            try publish(data: nil, source: source, mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt, videoRemoteID: videoRemoteID)
        }
    }
    private func publish(data: Data?, source: URL?, mimeType: String, kind: SavedCreation.Kind,
                         modelID: String, prompt: String?, videoRemoteID: String?) throws -> SavedCreation {
        let before = try requireSnapshot()
        let item = try assetStore.publishLibraryCreation(data: data, source: source, snapshot: before,
            mimeType: mimeType, kind: kind, modelID: modelID, prompt: prompt, videoRemoteID: videoRemoteID,
            now: now, failpoint: failpoint)
        // Publication COMMIT succeeded. Later refresh/export failures are warnings,
        // not failed saves (which would cause duplicate paid-output retries).
        creations.insert(item, at: 0)
        snapshot = LibrarySnapshot(manifestID: before.manifestID, catalogID: before.catalogID,
            index: before.index, revision: before.revision + 1, creations: creations)
        maintenanceAndExport()
        return item
    }

    func removeWithUndo(ids: Set<UUID>) async throws -> LibraryRemoval {
        try await serialized { [self] in
            let before = try requireSnapshot()
            let removal = try assetStore.removeLibraryCreations(snapshot: before, ids: ids, now: now(), undoDuration: undoDuration, failpoint: failpoint)
            let removedIDs = Set(removal.creations.map(\.id))
            creations.removeAll { removedIDs.contains($0.id) }
            snapshot = LibrarySnapshot(manifestID: before.manifestID, catalogID: before.catalogID, index: before.index,
                revision: before.revision + (removedIDs.isEmpty ? 0 : 1), creations: creations)
            maintenanceAndExport()
            return removal
        }
    }
    func restore(_ token: LibraryUndoToken) async throws {
        try await serialized { [self] in
            guard token.manifestID == (try requireSnapshot()).manifestID else { throw SavedCreationsError.unavailable("Undo belongs to another Library") }
            try assetStore.restoreLibraryRemoval(token, now: now(), failpoint: failpoint)
            maintenanceAndExport()
        }
    }
    func finalize(_ token: LibraryUndoToken) async throws {
        try await serialized { [self] in
            guard token.manifestID == (try requireSnapshot()).manifestID else { throw SavedCreationsError.unavailable("Undo belongs to another Library") }
            try assetStore.finalizeLibraryRemoval(token, failpoint: failpoint)
            maintenanceAndExport()
        }
    }
    @discardableResult
    func remove(ids: Set<UUID>) async throws -> [SavedCreation] {
        let removal = try await removeWithUndo(ids: ids)
        let removedIDs = Set(removal.creations.map(\.id))
        if compatibilitySeen.isDisjoint(with: removedIDs) { compatibilityRemovals.append(removal) }
        compatibilitySeen.formUnion(removedIDs)
        return removal.creations
    }
    func restore(_ items: [SavedCreation]) async throws {
        guard let removal = compatibilityRemovals.first(where: { $0.creations == items }) else {
            throw SavedCreationsError.unavailable("This Undo requires its original removal token")
        }
        try await restore(removal.token)
        compatibilityRemovals.removeAll { $0.token == removal.token }
    }
    func purgeUnreferenced(_ removed: [SavedCreation]) async {
        guard let removal = compatibilityRemovals.first(where: { $0.creations == removed }) else {
            cleanupWarning = "Finalization requires the original Undo token. Durable holds expire automatically."
            return
        }
        do {
            try await finalize(removal.token)
            compatibilityRemovals.removeAll { $0.token == removal.token }
        } catch { cleanupWarning = error.localizedDescription }
    }

    /// Foreground/startup recovery expires durable holds/intents, drains cleanup,
    /// refreshes from SQLite and retries the latest JSON export. No network work.
    func retryMaintenance() async {
        if let maintenanceTask { await maintenanceTask.value; return }
        let task = Task { @MainActor [self] in
            _ = try? await serialized { [self] in maintenanceAndExport() }
        }
        maintenanceTask = task
        await task.value
        maintenanceTask = nil
    }

    /// All Library windows observe the shared store. Only it owns the periodic
    /// loop; leaving one window cannot cancel another window's maintenance.
    func startForegroundMaintenance(observer: UUID) {
        foregroundObservers.insert(observer)
        guard foregroundMaintenanceTask == nil else { return }
        foregroundMaintenanceGeneration += 1
        foregroundMaintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.retryMaintenance()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func stopForegroundMaintenance(observer: UUID) {
        foregroundObservers.remove(observer)
        guard foregroundObservers.isEmpty else { return }
        foregroundMaintenanceTask?.cancel()
        foregroundMaintenanceTask = nil
    }
    private func maintenanceAndExport() {
        do {
            try assetStore.recoverLibraryOwnership(now: now(), failpoint: failpoint)
            cleanupWarning = nil
        } catch { cleanupWarning = "Cleanup pending: \(error.localizedDescription)" }
        do {
            let before = try requireSnapshot()
            try assetStore.withCatalogReservation {
                let latest = try assetStore.database.librarySnapshot(before.manifestID)
                adopt(latest)
                let managed = try assetStore.database.libraryManagedRoot()
                reclamationStatus = managed
                    ? "Managed storage: maintenance reclaims unowned files after Undo expires, while Library is open or on its next open/save. Shared or standalone files remain protected."
                    : "Legacy storage: removed files are retained. Reclamation requires migration to a new managed root; the old root is not deleted."
                try exportSnapshot(latest)
            }
            exportWarning = nil
        } catch { exportWarning = "Library changes are stored in SQLite; JSON export needs retry: \(error.localizedDescription)" }
    }
    /// Called under the writer reservation from the LATEST DB snapshot. A stale
    /// worker cannot publish an older revision over a newer export.
    private func exportSnapshot(_ value: LibrarySnapshot) throws {
        let expected = Data((value.catalogID + "\n" + value.manifestID.uuidString + "\n" + assetStore.canonicalBaseDirectory.path).utf8)
        let marker = try Self.readIndexFile(indexBindingURL)
        if let marker, marker != expected && marker != Data(assetStore.canonicalBaseDirectory.path.utf8) {
            throw SavedCreationsError.unavailable("Library binding belongs to another identity")
        }
        var currentExport = false
        if let payload = try Self.readIndexFile(indexURL) {
            let existing = try JSONDecoder().decode(CreationsManifest.self, from: payload)
            guard Set(existing.creations.map(\.id)).count == existing.creations.count,
                  existing.creations.allSatisfy({ AssetStore.validContentPath($0.assetPath, checksum: $0.checksum) }) else {
                throw SavedCreationsError.invalidIndex("untrusted export paths or duplicate identities")
            }
            guard existing.version == 1 || (existing.version == 2 && existing.manifestID == value.manifestID && existing.catalogID == value.catalogID && (existing.revision ?? Int64.max) <= value.revision) else {
                throw SavedCreationsError.invalidIndex("foreign identity or future revision")
            }
            currentExport = existing.version == 2 && existing.revision == value.revision
                && existing.creations == value.creations
        }
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if marker == nil { try ExclusiveMarkerPublisher.publish(expected, to: indexBindingURL) }
        // Keep compatible legacy sidecars unchanged; the committed registry is
        // the authoritative binding. New sidecars include both identities.
        if !currentExport {
            let manifest = CreationsManifest(version: 2, manifestID: value.manifestID, catalogID: value.catalogID,
                                             revision: value.revision, creations: value.creations)
            try failpoint(.exportWrite)
            try JSONEncoder().encode(manifest).write(to: indexURL, options: .atomic)
        }
        let exportedText = try assetStore.database.libraryRows(
            "SELECT exported_revision FROM library_manifests WHERE manifest_id=?;", [value.manifestID.uuidString]
        ).first?.first
        let exported = exportedText.flatMap { Int64($0) }
        // Repair a lost acknowledgement without rewriting a verified current
        // export. Conversely, an acknowledgement never substitutes for reading
        // and validating the actual file and its binding above.
        if exported != value.revision {
            try failpoint(.exportAcknowledgement)
            try assetStore.database.libraryExecute("UPDATE library_manifests SET exported_revision=? WHERE manifest_id=?;", [String(value.revision),value.manifestID.uuidString])
        }
    }
    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let predecessor = previousSave
        let operation = Task { @MainActor () async throws -> T in
            await predecessor?.value
            return try await work()
        }
        previousSave = Task { _ = try? await operation.value }
        return try await operation.value
    }
    private static func readIndexFile(_ url: URL) throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw SavedCreationsError.invalidIndex("index or binding is not a regular file")
            }
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    func fileURL(for creation: SavedCreation) throws -> URL {
        try validatedFileURL(path: creation.assetPath, checksum: creation.checksum)
    }
    func export(data: Data, to destination: URL) throws {
        try export(to: destination) { try data.write(to: $0, options: .withoutOverwriting) }
    }
    func export(_ creation: SavedCreation, to destination: URL) throws {
        let source = try fileURL(for: creation)
        try export(to: destination) { try FileManager.default.copyItem(at: source, to: $0) }
    }
    /// Shared by single and bulk export. Reserved names stay reserved even when
    /// the compatibility file/SQLite sidecar is temporarily absent.
    @discardableResult
    func validateExportDestination(_ destination: URL) throws -> URL {
        guard destination.isFileURL else { throw SavedCreationsError.managedExportDestination }
        guard try !assetStore.isManagedStoragePath(destination, additionalFiles: [indexURL, indexBindingURL]) else {
            throw SavedCreationsError.managedExportDestination
        }
        let parent = ManagedStoragePaths.canonicalURL(destination.deletingLastPathComponent())
        return parent.appendingPathComponent(destination.lastPathComponent)
    }
    private func export(to destination: URL, stage: (URL) throws -> Void) throws {
        let target = try validateExportDestination(destination)
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".orb-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try stage(staged)
        guard try validateExportDestination(destination) == target else {
            throw SavedCreationsError.managedExportDestination
        }
        guard Darwin.rename(staged.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Bulk never uses the overwrite-capable save-panel rename path. Publishing
    /// a staged copy with link(2) is atomic and exclusive, including a destination
    /// created after enumeration/copy. It fails closed on filesystems without hard
    /// links instead of falling back to an overwrite-capable operation.
    func exportExclusive(_ creation: SavedCreation, to destination: URL,
                         beforePublication: (URL) throws -> Void = { _ in }) throws {
        try assetStore.withCatalogReservation {
            let target = try validateExportDestination(destination)
            let staged = target.deletingLastPathComponent().appendingPathComponent(".orb-export-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: fileURL(for: creation), to: staged)
            try beforePublication(target)
            // Recheck metadata and aliases at the publication boundary too.
            guard try validateExportDestination(destination) == target else {
                throw SavedCreationsError.managedExportDestination
            }
            guard Darwin.link(staged.path, target.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    private func validatedFileURL(path: String, checksum: String) throws -> URL {
        guard AssetStore.validContentPath(path, checksum: checksum) else { throw AssetStoreError.invalidPath(path) }
        let url = try assetStore.fileURL(forRelativePath: path)
        let base = assetStore.baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { throw AssetStoreError.invalidPath(path) }
        return url
    }
    func data(for creation: SavedCreation) async throws -> Data {
        _ = try validatedFileURL(path: creation.assetPath, checksum: creation.checksum)
        let record = AssetRecord(id: creation.id, relativePath: creation.assetPath, remoteReference: nil,
            mimeType: creation.mimeType, sizeBytes: 0, checksum: creation.checksum, jobID: nil,
            messageID: nil, retention: .keep, createdAt: creation.createdAt)
        return try await assetStore.data(for: record)
    }
}
