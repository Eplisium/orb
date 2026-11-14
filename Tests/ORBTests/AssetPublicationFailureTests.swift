import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Asset publication failures", .serialized)
@MainActor
struct AssetPublicationFailureTests {
    @Test("Rejected ownership COMMIT leaves live state, durable owners, Undo and JSON unchanged",
          arguments: [LibraryOwnershipPhase.removalCommit, .restoreCommit])
    func ownershipCommitRejected(phase: LibraryOwnershipPhase) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLegacyFixture(root: root)
        let fault = AssetPublicationCommitFault(index: fixture.index)
        var enabled = false
        let store = try SavedCreationsStore(assetStore: fixture.assets, indexURL: fixture.index,
            now: { Date(timeIntervalSince1970: 1000) }, failpoint: {
                if enabled && $0 == phase { fault.arm() }
            })
        let removal: LibraryRemoval?
        if phase == .restoreCommit {
            removal = try await store.removeWithUndo(ids: [fixture.first.id])
            #expect(removal?.creations == [fixture.first])
        } else { removal = nil }
        let observer = try openDatabase(root)
        let before = try durableState(observer)
        let beforeJSON = try Data(contentsOf: fixture.index)
        let beforeLive = store.creations
        try expectManifest(fixture, database: observer, equals: beforeLive)
        #expect(store.exportWarning == nil)
        #expect(store.cleanupWarning == nil)

        fault.install(on: fixture.database)
        defer { fault.uninstall(from: fixture.database) }
        enabled = true
        if let removal {
            await #expect(throws: Error.self) { try await store.restore(removal.token) }
        } else {
            await #expect(throws: Error.self) { try await store.removeWithUndo(ids: [fixture.first.id]) }
        }
        enabled = false
        fault.uninstall(from: fixture.database)

        // The seam only arms a real sqlite3_commit_hook rejection; it never throws.
        #expect(fault.armed)
        #expect(fault.rejected)
        #expect(!fault.rejectNext)
        #expect(fault.observedAtCommit == beforeJSON, "Ownership must commit before any JSON publication")
        #expect(sqlite3_get_autocommit(fixture.database.db) != 0)
        #expect(store.creations == beforeLive)
        #expect(try durableState(observer) == before, "A separate connection must see the unchanged owners and Undo generation")
        #expect(try Data(contentsOf: fixture.index) == beforeJSON)
        #expect(store.exportWarning == nil)
        #expect(store.cleanupWarning == nil)
        #expect(try await store.data(for: fixture.first) == fixture.bytes)
        try expectReopened(fixture, database: observer, equals: beforeLive)

        // Retry on the ORIGINAL instance, without refresh repairing a stale snapshot.
        if let removal {
            try await store.restore(removal.token)
        } else {
            let retry = try await store.removeWithUndo(ids: [fixture.first.id])
            #expect(retry.creations == [fixture.first])
            try expectUndo(observer, removal: retry)
            try await store.restore(retry.token)
        }
        #expect(store.creations == [fixture.first, fixture.second])
        #expect(try observer.libraryRows("SELECT token FROM library_undo;").isEmpty)
        try expectManifest(fixture, database: observer, equals: store.creations)
        try await finalizeAllAndExpectLegacyRetention(store, fixture: fixture, database: observer)
    }

    @Test("Rejected JSON acknowledgement COMMIT is committed success with warning and usable token state",
          arguments: [LibraryOwnershipPhase.removalCommit, .restoreCommit])
    func exportAcknowledgementCommitRejected(operation: LibraryOwnershipPhase) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLegacyFixture(root: root)
        let fault = AssetPublicationCommitFault(index: fixture.index)
        var enabled = false
        let store = try SavedCreationsStore(assetStore: fixture.assets, indexURL: fixture.index,
            now: { Date(timeIntervalSince1970: 1000) }, failpoint: {
                if enabled && $0 == .exportAcknowledgement { fault.arm() }
            })
        let priorRemoval: LibraryRemoval?
        if operation == .restoreCommit {
            priorRemoval = try await store.removeWithUndo(ids: [fixture.first.id])
        } else { priorRemoval = nil }
        let observer = try openDatabase(root)
        let before = try manifestRow(observer)
        let beforeRevision = try #require(Int64(before[2]))
        let beforeJSON = try Data(contentsOf: fixture.index)
        fault.install(on: fixture.database)
        defer { fault.uninstall(from: fixture.database) }
        enabled = true

        // A thrown error here is a test failure: ownership already committed.
        let committedRemoval: LibraryRemoval?
        let expected: [SavedCreation]
        if let priorRemoval {
            try await store.restore(priorRemoval.token)
            committedRemoval = nil
            expected = [fixture.first, fixture.second]
        } else {
            committedRemoval = try await store.removeWithUndo(ids: [fixture.first.id])
            expected = [fixture.second]
        }
        enabled = false
        fault.uninstall(from: fixture.database)

        #expect(fault.armed)
        #expect(fault.rejected)
        #expect(!fault.rejectNext)
        #expect(sqlite3_get_autocommit(fixture.database.db) != 0)
        let publishedJSON = try Data(contentsOf: fixture.index)
        #expect(publishedJSON != beforeJSON)
        #expect(fault.observedAtCommit == publishedJSON, "Reject the acknowledgement only after the v2 export was written")
        #expect(store.creations == expected)
        #expect(store.exportWarning != nil)
        #expect(store.cleanupWarning == nil)
        let after = try manifestRow(observer)
        #expect(after[0] == before[0])
        #expect(after[1] == before[1])
        #expect(Int64(after[2]) == beforeRevision + 1)
        #expect(after[3] == before[3], "Rejected acknowledgement must not advance exported_revision")
        #expect(after[2] != after[3])
        try expectManifest(fixture, database: observer, equals: expected)
        if let committedRemoval {
            #expect(committedRemoval.creations == [fixture.first])
            try expectUndo(observer, removal: committedRemoval)
        } else {
            #expect(try observer.libraryRows("SELECT token FROM library_undo;").isEmpty)
        }
        #expect(try await store.data(for: fixture.first) == fixture.bytes)

        // Reopen through an independent connection; then edit the original store
        // without refreshing it. Reopening may retry export, never ownership.
        try expectReopened(fixture, database: observer, equals: expected)
        let acknowledged = try manifestRow(observer)
        #expect(acknowledged[2] == after[2])
        #expect(acknowledged[3] == after[2])
        if let committedRemoval {
            try expectUndo(observer, removal: committedRemoval)
            let secondRemoval = try await store.removeWithUndo(ids: [fixture.second.id])
            #expect(secondRemoval.creations == [fixture.second])
            #expect(store.creations.isEmpty)
            try await store.restore(committedRemoval.token)
            #expect(store.creations == [fixture.first])
            try await store.restore(secondRemoval.token)
        } else {
            let priorRemoval = try #require(priorRemoval)
            await #expect(throws: Error.self) { try await store.restore(priorRemoval.token) }
            let nextRemoval = try await store.removeWithUndo(ids: [fixture.first.id])
            #expect(nextRemoval.creations == [fixture.first])
            #expect(nextRemoval.token != priorRemoval.token)
            #expect(store.creations == [fixture.second])
            try await store.restore(nextRemoval.token)
        }
        #expect(store.exportWarning == nil)
        #expect(store.creations == [fixture.first, fixture.second])
        #expect(try observer.libraryRows("SELECT token FROM library_undo;").isEmpty)
        try expectManifest(fixture, database: observer, equals: store.creations)
        try await finalizeAllAndExpectLegacyRetention(store, fixture: fixture, database: observer)
    }

    private func makeRoot() throws -> URL {
        let root = ORBTestScratch.root
            .appendingPathComponent("ORB-asset-publication-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func openDatabase(_ root: URL) throws -> DatabaseManager {
        let db = DatabaseManager(path: root.appendingPathComponent("metadata.sqlite3").path)
        try #require(db.launchFailure == nil)
        return db
    }

    private func makeLegacyFixture(root: URL) throws -> AssetPublicationLegacyFixture {
        let db = try openDatabase(root)
        let base = root.appendingPathComponent("Assets", isDirectory: true)
        let assets = AssetStore(baseDirectory: base, database: db)
        let bytes = Data("offline legacy publication fixture".utf8)
        let checksum = AssetStore.sha256Hex(bytes)
        let relativePath = AssetStore.relativePath(forChecksum: checksum, mimeType: "text/plain")
        let file = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        // Pre-existing bytes, unattached metadata and v1 JSON must remain a
        // legacy-blocked root, not be silently promoted to managed ownership.
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
        try JSONEncoder().encode(AssetPublicationManifest(version: 1, creations: [first, second])).write(to: index)
        try #require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".Assets.orb-catalog").path))
        try #require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".creations.json.orb-assets").path))
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db.db, "SELECT root FROM asset_catalog WHERE singleton = 1;", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        try #require(sqlite3_column_type(statement, 0) == SQLITE_NULL, "Fixture must start with an unbound legacy root")
        return AssetPublicationLegacyFixture(database: db, assets: assets, index: index,
                                             first: first, second: second, bytes: bytes)
    }

    private func manifestRow(_ db: DatabaseManager) throws -> [String] {
        let rows = try db.libraryRows("SELECT manifest_id,catalog_id,revision,exported_revision FROM library_manifests;")
        try #require(rows.count == 1)
        return try #require(rows.first)
    }

    private func durableState(_ db: DatabaseManager) throws -> [[[String]]] {
        try [
            db.libraryRows("SELECT * FROM library_manifests ORDER BY manifest_id;"),
            db.libraryRows("SELECT * FROM library_creations ORDER BY manifest_id,creation_id;"),
            db.libraryRows("SELECT * FROM library_undo ORDER BY token,creation_id;"),
            db.libraryRows("SELECT * FROM library_imports ORDER BY operation_id;"),
            db.libraryRows("SELECT * FROM assets ORDER BY id;"),
            db.libraryRows("SELECT * FROM asset_deletions ORDER BY checksum,relative_path;"),
            db.libraryRows("SELECT * FROM asset_catalog ORDER BY singleton;")
        ]
    }

    private func expectUndo(_ db: DatabaseManager, removal: LibraryRemoval) throws {
        let rows = try db.libraryRows("SELECT creation_id,payload,checksum,relative_path,expires_at FROM library_undo WHERE token=? AND manifest_id=? ORDER BY creation_id;",
                                     [removal.token.id.uuidString, removal.token.manifestID.uuidString])
        #expect(try rows.map { try db.decodeLibraryCreation($0) } == removal.creations.sorted { $0.id.uuidString < $1.id.uuidString })
        #expect(rows.allSatisfy { Double($0[4]) == removal.expiresAt.timeIntervalSince1970 })
    }

    private func expectManifest(_ fixture: AssetPublicationLegacyFixture, database: DatabaseManager,
                                equals expected: [SavedCreation]) throws {
        let manifest = try JSONDecoder().decode(AssetPublicationManifest.self, from: Data(contentsOf: fixture.index))
        let row = try manifestRow(database)
        #expect(manifest.version == 2)
        #expect(manifest.manifestID?.uuidString == row[0])
        #expect(manifest.catalogID == row[1])
        #expect(manifest.revision == Int64(row[2]))
        #expect(manifest.creations == expected)
        let id = try #require(UUID(uuidString: row[0]))
        #expect(try database.librarySnapshot(id).creations == expected)
        #expect(try database.libraryManagedRoot() == false)
        #expect(try database.libraryRows("SELECT reclamation_mode FROM asset_catalog;") == [["legacy_blocked"]])
    }

    private func expectReopened(_ fixture: AssetPublicationLegacyFixture, database: DatabaseManager,
                                equals expected: [SavedCreation]) throws {
        let assets = AssetStore(baseDirectory: fixture.assets.baseDirectory, database: database)
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: fixture.index,
                                               now: { Date(timeIntervalSince1970: 1000) })
        #expect(reopened.creations == expected)
        #expect(reopened.exportWarning == nil)
        #expect(reopened.reclamationStatus.contains("Legacy"))
        try expectManifest(fixture, database: database, equals: expected)
    }

    private func finalizeAllAndExpectLegacyRetention(_ store: SavedCreationsStore,
        fixture: AssetPublicationLegacyFixture, database: DatabaseManager) async throws {
        let removal = try await store.removeWithUndo(ids: [fixture.first.id, fixture.second.id])
        #expect(removal.creations == [fixture.first, fixture.second])
        try await store.finalize(removal.token)
        #expect(store.creations.isEmpty)
        #expect(try database.libraryRows("SELECT token FROM library_undo;").isEmpty)
        #expect(try database.loadAssetDeletionInventory().isEmpty)
        #expect(try await store.data(for: fixture.first) == fixture.bytes)
        #expect(try fixture.assets.removeUnattached(checksum: fixture.first.checksum) == false)
        try expectManifest(fixture, database: database, equals: [])
        try expectReopened(fixture, database: database, equals: [])
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
    var manifestID: UUID? = nil
    var catalogID: String? = nil
    var revision: Int64? = nil
    let creations: [SavedCreation]
}

/// A phase seam arms the next actual SQLite COMMIT. The hook records only the
/// fixture's JSON bytes (never reenters SQLite), then rejects that COMMIT once.
/// The owning test retains this object until its hook is detached.
private final class AssetPublicationCommitFault {
    let index: URL
    var armed = false
    var rejectNext = false
    var rejected = false
    var observedAtCommit: Data?

    init(index: URL) { self.index = index }

    func arm() { armed = true; rejectNext = true }

    func install(on database: DatabaseManager) {
        sqlite3_commit_hook(database.db, { context in
            guard let context else { return 0 }
            let fault = Unmanaged<AssetPublicationCommitFault>.fromOpaque(context).takeUnretainedValue()
            guard fault.rejectNext else { return 0 }
            fault.rejectNext = false
            fault.observedAtCommit = try? Data(contentsOf: fault.index)
            fault.rejected = true
            return 1
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func uninstall(from database: DatabaseManager) {
        sqlite3_commit_hook(database.db, nil, nil)
    }
}
