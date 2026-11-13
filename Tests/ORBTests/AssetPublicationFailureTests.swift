import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Asset publication failures", .serialized)
@MainActor
struct AssetPublicationFailureTests {
    @Test("Published legacy removal succeeds despite reservation COMMIT failure and supplies usable Undo")
    func publishedRemovalCommitFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLegacyFixture(root: root, includesFirst: true)
        let store = try SavedCreationsStore(assetStore: fixture.assets, indexURL: fixture.index)
        let fault = AssetPublicationCommitFault(index: fixture.index, expected: [fixture.second])
        fault.install(on: fixture.database)
        defer { fault.uninstall(from: fixture.database) }

        var undo: [SavedCreation]?
        do { undo = try await store.remove(ids: [fixture.first.id]) }
        catch { Issue.record("Removal reported failure after publishing its JSON: \(error)") }
        fault.uninstall(from: fixture.database)

        // Prove the injection hit COMMIT AFTER the requested JSON was published,
        // rather than a migration, metadata save, or a pre-publication failure.
        #expect(fault.armed)
        #expect(fault.rejected)
        #expect(fault.observedAtCommit == [fixture.second])
        #expect(sqlite3_get_autocommit(fixture.database.db) != 0)
        #expect(undo == [fixture.first], "A published deletion must return the UI's Undo payload")
        try expectManifest(fixture, equals: [fixture.second])
        #expect(store.creations == [fixture.second])
        #expect(try await store.data(for: fixture.first) == fixture.bytes)

        // Do not reopen the live instance to repair its private CAS snapshot.
        // A subsequent, different edit must not be rejected as a stale writer.
        var secondUndo: [SavedCreation]?
        do { secondUndo = try await store.remove(ids: [fixture.second.id]) }
        catch { Issue.record("A published removal left the live store unable to edit: \(error)") }
        #expect(secondUndo == [fixture.second])
        #expect(store.creations.isEmpty)
        try expectManifest(fixture, equals: [])

        if let undo {
            do { try await store.restore(undo) }
            catch { Issue.record("Undo of the published removal failed: \(error)") }
            #expect(store.creations == [fixture.first])
            try expectManifest(fixture, equals: [fixture.first])
        }
        if let undo, let secondUndo {
            try await store.restore(secondUndo)
            #expect(store.creations == [fixture.first, fixture.second])
            try expectManifest(fixture, equals: [fixture.first, fixture.second])
            await store.purgeUnreferenced(undo + secondUndo)
            #expect(try await store.data(for: fixture.first) == fixture.bytes)
        }
    }

    @Test("Published legacy Undo succeeds despite reservation COMMIT failure and leaves future edits usable")
    func publishedRestoreCommitFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Models an Undo payload retained from a legacy removal. Calling modern
        // remove() to prepare this fixture would bind the root before the fault.
        let fixture = try makeLegacyFixture(root: root, includesFirst: false)
        let store = try SavedCreationsStore(assetStore: fixture.assets, indexURL: fixture.index)
        let fault = AssetPublicationCommitFault(index: fixture.index, expected: [fixture.first, fixture.second])
        fault.install(on: fixture.database)
        defer { fault.uninstall(from: fixture.database) }

        var restored = false
        do { try await store.restore([fixture.first]); restored = true }
        catch { Issue.record("Undo reported failure after publishing its JSON: \(error)") }
        fault.uninstall(from: fixture.database)

        #expect(fault.armed)
        #expect(fault.rejected)
        #expect(fault.observedAtCommit == [fixture.first, fixture.second])
        #expect(sqlite3_get_autocommit(fixture.database.db) != 0)
        #expect(restored)
        #expect(store.creations == [fixture.first, fixture.second])
        try expectManifest(fixture, equals: [fixture.first, fixture.second])
        #expect(try await store.data(for: fixture.first) == fixture.bytes)

        // Removing the just-restored entry also detects a stale in-memory list:
        // old code returns [] without writing because it never adopted the Undo.
        var removedAgain: [SavedCreation]?
        do { removedAgain = try await store.remove(ids: [fixture.first.id]) }
        catch { Issue.record("A published Undo left the live store unable to edit: \(error)") }
        #expect(removedAgain == [fixture.first])
        #expect(store.creations == [fixture.second])
        try expectManifest(fixture, equals: [fixture.second])
        if let removedAgain, !removedAgain.isEmpty {
            try await store.restore(removedAgain)
            #expect(store.creations == [fixture.first, fixture.second])
            try expectManifest(fixture, equals: [fixture.first, fixture.second])
        }
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/cache/scratch/ORB-asset-publication-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeLegacyFixture(root: URL, includesFirst: Bool) throws -> AssetPublicationLegacyFixture {
        let db = DatabaseManager(path: root.appendingPathComponent("metadata.sqlite3").path)
        try #require(db.launchFailure == nil)
        let base = root.appendingPathComponent("Assets", isDirectory: true)
        let assets = AssetStore(baseDirectory: base, database: db)
        let bytes = Data("offline legacy publication fixture".utf8)
        let checksum = AssetStore.sha256Hex(bytes)
        let relativePath = AssetStore.relativePath(forChecksum: checksum, mimeType: "text/plain")
        let file = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        // Seed legacy bytes and unattached metadata directly, NOT assets.store(),
        // which would bind the catalog and make writeIndex's reservation read-only.
        let record = AssetRecord(id: UUID(), relativePath: relativePath, remoteReference: nil,
                                 mimeType: "text/plain", sizeBytes: bytes.count, checksum: checksum,
                                 jobID: nil, messageID: nil, retention: .keep,
                                 createdAt: Date(timeIntervalSince1970: 10))
        try db.saveAssetRecordChecked(record)
        let first = SavedCreation(id: UUID(), kind: .transcript, modelID: "fixture/first", prompt: nil,
                                  mimeType: "text/plain", createdAt: Date(timeIntervalSince1970: 20),
                                  assetPath: relativePath, checksum: checksum)
        let second = SavedCreation(id: UUID(), kind: .transcript, modelID: "fixture/second", prompt: nil,
                                   mimeType: "text/plain", createdAt: Date(timeIntervalSince1970: 10),
                                   assetPath: relativePath, checksum: checksum)
        let index = root.appendingPathComponent("creations.json")
        let initial = includesFirst ? [first, second] : [second]
        try JSONEncoder().encode(AssetPublicationManifest(version: 1, creations: initial)).write(to: index)
        try #require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".Assets.orb-catalog").path))
        try #require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".creations.json.orb-assets").path))
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db.db, "SELECT root FROM asset_catalog WHERE singleton = 1;", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        try #require(sqlite3_column_type(statement, 0) == SQLITE_NULL, "Fixture must enter writeIndex with an unbound root")
        return AssetPublicationLegacyFixture(database: db, assets: assets, index: index,
                                             first: first, second: second, bytes: bytes)
    }

    private func expectManifest(_ fixture: AssetPublicationLegacyFixture, equals expected: [SavedCreation]) throws {
        let manifest = try JSONDecoder().decode(AssetPublicationManifest.self, from: Data(contentsOf: fixture.index))
        #expect(manifest.version == 1)
        #expect(manifest.creations == expected)
        // A fresh reader and the original live instance must agree; fresh-reader
        // success alone would conceal the old instance's poisoned CAS snapshot.
        let reopened = try SavedCreationsStore(assetStore: fixture.assets, indexURL: fixture.index)
        #expect(reopened.creations == expected)
    }
}

private struct AssetPublicationLegacyFixture {
    let database: DatabaseManager
    let assets: AssetStore
    let index: URL
    let first: SavedCreation
    let second: SavedCreation
    let bytes: Data
}

private struct AssetPublicationManifest: Codable {
    let version: Int
    let creations: [SavedCreation]
}

/// Like AssetDeletionCoordinationTests' commit fault, this uses SQLite's real
/// update/commit hooks. The commit hook only reads a fixture file: it never
/// reenters SQLite. The owning test retains this object until both hooks detach.
private final class AssetPublicationCommitFault {
    let index: URL
    let expected: [SavedCreation]
    var armed = false
    var rejected = false
    var observedAtCommit: [SavedCreation]?

    init(index: URL, expected: [SavedCreation]) {
        self.index = index
        self.expected = expected
    }

    func install(on database: DatabaseManager) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_update_hook(database.db, { context, operation, _, table, _ in
            guard let context, operation == SQLITE_UPDATE, let table,
                  String(cString: table) == "asset_catalog" else { return }
            Unmanaged<AssetPublicationCommitFault>.fromOpaque(context).takeUnretainedValue().armed = true
        }, context)
        sqlite3_commit_hook(database.db, { context in
            guard let context else { return 0 }
            let fault = Unmanaged<AssetPublicationCommitFault>.fromOpaque(context).takeUnretainedValue()
            guard fault.armed, !fault.rejected else { return 0 }
            guard let payload = try? Data(contentsOf: fault.index),
                  let manifest = try? JSONDecoder().decode(AssetPublicationManifest.self, from: payload),
                  manifest.version == 1, manifest.creations == fault.expected else { return 0 }
            fault.observedAtCommit = manifest.creations
            fault.rejected = true
            return 1
        }, context)
    }

    func uninstall(from database: DatabaseManager) {
        sqlite3_commit_hook(database.db, nil, nil)
        sqlite3_update_hook(database.db, nil, nil)
    }
}
