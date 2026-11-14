import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Registered Library protocol", .serialized)
@MainActor
struct RegisteredLibraryProtocolTests {
    private func root() throws -> URL {
        let root = ORBTestScratch.root.appendingPathComponent("ORB-registered-library-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func assets(_ root: URL) throws -> (DatabaseManager, AssetStore) {
        let db = DatabaseManager(path: root.appendingPathComponent("catalog.sqlite3").path)
        try #require(db.launchFailure == nil)
        return (db, AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db))
    }
    private func save(_ store: SavedCreationsStore, _ text: String = "owned") async throws -> SavedCreation {
        try await store.save(Data(text.utf8), mimeType: "text/plain", kind: .transcript, modelID: "offline/model", prompt: "payload\u{0}完整")
    }

    @Test("Token generation prevents stale restore and stale finalization ABA")
    func tokenABA() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let clock = RegisteredLibraryClock()
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("a.json"), now: { clock.date })
        let item = try await save(store)
        let first = try await store.removeWithUndo(ids: [item.id])
        try await store.restore(first.token)
        let second = try await store.removeWithUndo(ids: [item.id])
        #expect(first.token != second.token)
        try await store.finalize(first.token)
        await #expect(throws: Error.self) { try await store.restore(first.token) }
        #expect(try db.libraryRows("SELECT token FROM library_undo;") == [[second.token.id.uuidString]])
        try await store.restore(second.token)
        #expect(store.creations == [item])
    }

    @Test("Undo expiry equality survives reopen and repeated recovery")
    func expiryOnReopen() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, assets) = try assets(root)
        let clock = RegisteredLibraryClock()
        let index = root.appendingPathComponent("a.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index, now: { clock.date })
        let item = try await save(store)
        let removal = try await store.removeWithUndo(ids: [item.id])
        clock.date = removal.expiresAt
        let (otherDB, otherAssets) = try self.assets(root)
        let reopened = try SavedCreationsStore(assetStore: otherAssets, indexURL: index, now: { clock.date })
        await #expect(throws: Error.self) { try await reopened.restore(removal.token) }
        await reopened.retryMaintenance()
        #expect(try otherDB.libraryRows("SELECT token FROM library_undo;").isEmpty)
        #expect(try otherDB.loadAssetDeletionInventory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(item.assetPath).path))
    }

    @Test("Export failure is committed success and retry exports latest SQLite revision", arguments: [LibraryOwnershipPhase.exportWrite, .exportAcknowledgement])
    func exportFailure(phase: LibraryOwnershipPhase) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        var failing = false
        let index = root.appendingPathComponent("a.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index, failpoint: {
            if failing && $0 == phase { throw CocoaError(.fileWriteNoPermission) }
        })
        failing = true
        let item = try await save(store)
        #expect(store.creations == [item])
        #expect(store.exportWarning != nil)
        let row = try #require(db.libraryRows("SELECT revision,exported_revision FROM library_manifests;").first)
        #expect(row[0] != row[1])
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(reopened.creations == [item])
        failing = false
        await store.retryMaintenance()
        #expect(store.exportWarning == nil)
        let latest = try #require(db.libraryRows("SELECT revision,exported_revision FROM library_manifests;").first)
        #expect(latest[0] == latest[1])
    }

    @Test("Actual rejected creation COMMIT retains input and removes orphan through journal")
    func creationCommitRejected() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let fault = RegisteredLibraryCommitFault()
        fault.install(db); defer { fault.uninstall(db) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("a.json"), failpoint: {
            if $0 == .creationCommit { fault.rejectNext = true }
        })
        let bytes = Data("file input must survive".utf8)
        let source = root.appendingPathComponent("download.txt")
        try bytes.write(to: source)
        await #expect(throws: Error.self) {
            try await store.save(fileAt: source, mimeType: "text/plain", kind: .transcript, modelID: "offline", prompt: nil)
        }
        #expect(fault.rejected)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(store.creations.isEmpty)
        #expect(try db.libraryRows("SELECT creation_id FROM library_creations;").isEmpty)
        #expect(try db.libraryRows("SELECT operation_id FROM library_imports;").isEmpty)
        #expect(try db.loadAssetRecordsChecked(checksum: AssetStore.sha256Hex(bytes)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(AssetStore.relativePath(forChecksum: AssetStore.sha256Hex(bytes), mimeType: "text/plain")).path))
    }

    @Test("Actual rejected remove, restore and finalization COMMIT preserves owner", arguments: [LibraryOwnershipPhase.removalCommit, .restoreCommit, .finalizationCommit])
    func ownershipCommitRejected(phase: LibraryOwnershipPhase) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let fault = RegisteredLibraryCommitFault()
        fault.install(db); defer { fault.uninstall(db) }
        var armed = false
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("a.json"), failpoint: {
            if armed && $0 == phase { fault.rejectNext = true }
        })
        let item = try await save(store)
        if phase == .removalCommit {
            armed = true
            await #expect(throws: Error.self) { try await store.removeWithUndo(ids: [item.id]) }
            #expect(store.creations == [item])
            #expect(try db.libraryRows("SELECT token FROM library_undo;").isEmpty)
        } else {
            let removal = try await store.removeWithUndo(ids: [item.id])
            armed = true
            if phase == .restoreCommit {
                await #expect(throws: Error.self) { try await store.restore(removal.token) }
            } else {
                await #expect(throws: Error.self) { try await store.finalize(removal.token) }
            }
            #expect(store.creations.isEmpty)
            #expect(try db.libraryRows("SELECT token FROM library_undo;") == [[removal.token.id.uuidString]])
        }
        #expect(fault.rejected)
        #expect(try await store.data(for: item) == Data("owned".utf8))
        #expect(try db.loadAssetDeletionInventory().isEmpty)
    }

    @Test("Expired import lease collects an unindexed canonical file after reopen")
    func abandonedImport() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let clock = RegisteredLibraryClock()
        let index = root.appendingPathComponent("a.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index, now: { clock.date }, failpoint: {
            if $0 == .importIntentCommitted { throw CocoaError(.fileWriteUnknown) }
        })
        await #expect(throws: Error.self) { try await save(store, "crashed") }
        let intent = try #require(db.libraryRows("SELECT checksum,relative_path,lease_until FROM library_imports;").first)
        // Models process death after canonical rename, before metadata COMMIT.
        let file = assets.baseDirectory.appendingPathComponent(intent[1])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("crashed".utf8).write(to: file)
        clock.date = Date(timeIntervalSince1970: try #require(Double(intent[2])))
        let (otherDB, otherAssets) = try self.assets(root)
        let reopened = try SavedCreationsStore(assetStore: otherAssets, indexURL: index, now: { clock.date })
        #expect(reopened.creations.isEmpty)
        #expect(try otherDB.libraryRows("SELECT operation_id FROM library_imports;").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Abandoned partial staging is reclaimed while deduped final bytes remain owned")
    func abandonedStagingWithLiveOwner() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let clock = RegisteredLibraryClock()
        let index = root.appendingPathComponent("a.json")
        let owner = try SavedCreationsStore(assetStore: assets, indexURL: index, now: { clock.date })
        let item = try await save(owner, "shared")
        let interrupted = try SavedCreationsStore(assetStore: assets, indexURL: index, now: { clock.date }, failpoint: {
            if $0 == .importIntentCommitted { throw CocoaError(.fileWriteUnknown) }
        })
        await #expect(throws: Error.self) { try await save(interrupted, "shared") }
        let intent = try #require(db.libraryRows("SELECT staging_path,lease_until FROM library_imports;").first)
        let partial = assets.baseDirectory.appendingPathComponent(intent[0])
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial)
        clock.date = Date(timeIntervalSince1970: try #require(Double(intent[1])))
        await owner.retryMaintenance()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try await owner.data(for: item) == Data("shared".utf8))
        #expect(try db.libraryRows("SELECT operation_id FROM library_imports;").isEmpty)
    }

    @Test("Expired lease cannot publish after another connection reclaims it")
    func leaseLoserCannotPublish() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let (_, otherAssets) = try self.assets(root)
        let clock = RegisteredLibraryClock()
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("a.json"), now: { clock.date }, failpoint: {
            if $0 == .importIntentCommitted {
                clock.date = clock.date.addingTimeInterval(300)
                try otherAssets.recoverLibraryOwnership(now: clock.date)
            }
        })
        await #expect(throws: Error.self) { try await save(store, "expired") }
        #expect(store.creations.isEmpty)
        #expect(try db.libraryRows("SELECT operation_id FROM library_imports;").isEmpty)
        #expect(try db.loadAssetRecordsChecked(checksum: AssetStore.sha256Hex(Data("expired".utf8))).isEmpty)
    }

    @Test("Cross-connection writer is excluded throughout Library unlink")
    func unlinkReservation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, _) = try assets(root)
        let (otherDB, otherAssets) = try assets(root)
        sqlite3_busy_timeout(otherDB.db, 0)
        var attempted = false
        var refused = false
        let deleting = AssetStore(baseDirectory: otherAssets.baseDirectory, database: db, unlink: { url in
            attempted = true
            do { try otherDB.withAssetReservation { } }
            catch { refused = true }
            try FileManager.default.removeItem(at: url)
        })
        let store = try SavedCreationsStore(assetStore: deleting, indexURL: root.appendingPathComponent("a.json"))
        let item = try await save(store)
        let removal = try await store.removeWithUndo(ids: [item.id])
        try await store.finalize(removal.token)
        #expect(attempted && refused)
        let replacement = try await otherAssets.store(Data("owned".utf8), mimeType: "text/plain")
        #expect(try await otherAssets.data(for: replacement) == Data("owned".utf8))
        #expect(try db.loadAssetDeletionInventory().isEmpty)
    }

    @Test("Unregistered old root stays blocked even with no visible legacy manifest")
    func oldRootNeverAutocollected() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let unknown = base.appendingPathComponent("unknown-old-file")
        try Data("legacy".utf8).write(to: unknown)
        let (db, assets) = try assets(root)
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("a.json"))
        let item = try await save(store)
        let removal = try await store.removeWithUndo(ids: [item.id])
        try await store.finalize(removal.token)
        #expect(try db.libraryManagedRoot() == false)
        #expect(store.reclamationStatus.contains("Legacy"))
        #expect(try await store.data(for: item) == Data("owned".utf8))
        #expect(try Data(contentsOf: unknown) == Data("legacy".utf8))
        #expect(try assets.removeUnattached(checksum: item.checksum) == false)
    }

    @Test("Legacy registration preserves IDs and full payload but never declares old ownership complete")
    func legacyRegistration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let bytes = Data("legacy payload".utf8)
        let checksum = AssetStore.sha256Hex(bytes)
        let path = AssetStore.relativePath(forChecksum: checksum, mimeType: "text/plain")
        let file = assets.baseDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let item = SavedCreation(id: UUID(), kind: .transcript, modelID: "legacy/model", prompt: "keep metadata",
            mimeType: "text/plain", createdAt: Date(timeIntervalSince1970: 10), assetPath: path,
            checksum: checksum, videoRemoteID: "remote-identity")
        let index = root.appendingPathComponent("a.json")
        let legacy = RegisteredLibraryLegacyManifest(version: 1, creations: [item])
        try JSONEncoder().encode(legacy).write(to: index)
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(store.creations == [item])
        #expect(try db.libraryManagedRoot() == false)
        let removal = try await store.removeWithUndo(ids: [item.id])
        try await store.finalize(removal.token)
        #expect(try Data(contentsOf: file) == bytes)
        // Stale legacy JSON must not reimport a committed removal.
        try JSONEncoder().encode(legacy).write(to: index)
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(reopened.creations.isEmpty)
        #expect(try db.libraryRows("SELECT manifest_id FROM library_manifests;").count == 1)
    }

    @Test("Registered foreign export warns without replacing it or importing its contents")
    func foreignExportIsNotOverwritten() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, assets) = try assets(root)
        let index = root.appendingPathComponent("a.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let item = try await save(store)
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        payload["manifestID"] = UUID().uuidString
        let foreign = try JSONSerialization.data(withJSONObject: payload)
        try foreign.write(to: index)
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(reopened.creations == [item])
        #expect(reopened.exportWarning != nil)
        #expect(try Data(contentsOf: index) == foreign)
    }

    @Test("Rejected expiry COMMIT retains the hold and retry performs cleanup")
    func expiryCommitRejected() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try assets(root)
        let clock = RegisteredLibraryClock()
        let fault = RegisteredLibraryCommitFault()
        fault.install(db); defer { fault.uninstall(db) }
        var armed = false
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("a.json"), now: { clock.date }, failpoint: {
            if armed && $0 == .recoveryCommit { fault.rejectNext = true }
        })
        let item = try await save(store)
        let removal = try await store.removeWithUndo(ids: [item.id])
        clock.date = removal.expiresAt; armed = true
        await store.retryMaintenance()
        #expect(fault.rejected)
        #expect(store.cleanupWarning != nil)
        #expect(try db.libraryRows("SELECT token FROM library_undo;") == [[removal.token.id.uuidString]])
        #expect(try await store.data(for: item) == Data("owned".utf8))
        armed = false
        await store.retryMaintenance()
        #expect(store.cleanupWarning == nil)
        #expect(!FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(item.assetPath).path))
    }
}

private struct RegisteredLibraryLegacyManifest: Codable {
    let version: Int
    let creations: [SavedCreation]
}
private final class RegisteredLibraryClock {
    var date = Date(timeIntervalSince1970: 1000)
}
private final class RegisteredLibraryCommitFault {
    var rejectNext = false
    var rejected = false
    func install(_ db: DatabaseManager) {
        sqlite3_commit_hook(db.db, { context in
            guard let context else { return 0 }
            let fault = Unmanaged<RegisteredLibraryCommitFault>.fromOpaque(context).takeUnretainedValue()
            guard fault.rejectNext else { return 0 }
            fault.rejectNext = false; fault.rejected = true
            return 1
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func uninstall(_ db: DatabaseManager) { sqlite3_commit_hook(db.db, nil, nil) }
}
