import Foundation
import SQLite3
import Testing
@testable import ORB

/// Review regressions: behavioral RED is to be run by the lead before source edits.
/// Only UUID-scoped disposable files/SQLite connections are used. No shared stores,
/// credentials, network, production database, or app bundle are involved.
@Suite("Library ownership review", .serialized)
@MainActor
struct LibraryOwnershipReviewTests {
    private func fixtureRoot() throws -> URL {
        let root = ORBTestScratch.root
            .appendingPathComponent("ORB-library-ownership-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func openDatabase(_ root: URL) throws -> DatabaseManager {
        let db = DatabaseManager(path: root.appendingPathComponent("catalog.sqlite3").path)
        try #require(db.launchFailure == nil)
        return db
    }

    private func creation(_ bytes: Data) -> SavedCreation {
        let checksum = AssetStore.sha256Hex(bytes)
        return SavedCreation(id: UUID(), kind: .transcript, modelID: "offline/legacy",
            prompt: "Undiscovered external manifest", mimeType: "text/plain",
            createdAt: Date(timeIntervalSince1970: 10),
            assetPath: AssetStore.relativePath(forChecksum: checksum, mimeType: "text/plain"),
            checksum: checksum)
    }

    private func writeLegacyManifest(_ item: SavedCreation, to index: URL) throws -> Data {
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(LibraryOwnershipReviewV1Manifest(version: 1, creations: [item]))
        try data.write(to: index)
        return data
    }

    private func save(_ store: SavedCreationsStore, _ bytes: Data) async throws -> SavedCreation {
        try await store.save(bytes, mimeType: "text/plain", kind: .transcript,
                             modelID: "offline/review", prompt: nil)
    }

    /// Construct an actual pre-protocol database before DatabaseManager migration,
    /// rather than resetting modern ownership columns to simulate an upgrade.
    /// Both old schema variants are relevant: no catalog table, and an existing
    /// catalog identity whose root is NULL. Neither carries a new-storage claim.
    private func seedOldDatabase(_ root: URL, catalogExists: Bool,
                                 pending: SavedCreation? = nil) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open(root.appendingPathComponent("catalog.sqlite3").path, &connection)
        defer { sqlite3_close(connection) }
        try #require(result == SQLITE_OK)
        let db = try #require(connection)
        var sql = """
        PRAGMA user_version=7;
        CREATE TABLE assets (
            id TEXT PRIMARY KEY, relative_path TEXT NOT NULL, remote_reference TEXT,
            mime_type TEXT, size_bytes INTEGER NOT NULL, checksum TEXT NOT NULL,
            job_id TEXT, message_id TEXT, retention TEXT NOT NULL DEFAULT 'keep',
            created_at REAL NOT NULL
        );
        CREATE TABLE asset_deletions (
            checksum TEXT NOT NULL, relative_path TEXT NOT NULL,
            PRIMARY KEY(checksum, relative_path)
        );
        CREATE TABLE asset_library_pins (checksum TEXT PRIMARY KEY);
        """
        if catalogExists {
            sql += """
            CREATE TABLE asset_catalog (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1), identity TEXT NOT NULL, root TEXT
            );
            INSERT INTO asset_catalog(singleton,identity,root) VALUES (1,'\(UUID().uuidString)',NULL);
            """
        }
        // Values are generated SHA-256 hex and content-addressed fixture paths.
        if let pending {
            sql += "INSERT INTO asset_deletions(checksum,relative_path) VALUES ('\(pending.checksum)','\(pending.assetPath)');"
        }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    /// The manifest is deliberately never registered until after the new Library
    /// has removed its copy. Its file currently being absent is NOT proof that
    /// there are no legacy owners of this content-addressed path.
    private func assertUnknownMissingOwnerIsPreserved(_ root: URL) async throws {
        let bytes = Data("legacy content temporarily missing from disk".utf8)
        let legacy = creation(bytes)
        let outside = root.appendingPathComponent("outside-library/unknown-v1.json")
        let manifestBytes = try writeLegacyManifest(legacy, to: outside)
        let db = try openDatabase(root)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let file = assets.baseDirectory.appendingPathComponent(legacy.assetPath)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("new-library.json"))
        #expect(try !db.libraryManagedRoot(),
                "An empty/missing root and empty tables do not establish exclusive managed provenance")
        #expect(try db.libraryRows("SELECT manifest_id FROM library_manifests WHERE canonical_index=?;", [outside.path]).isEmpty)

        // Re-importing the same bytes repairs a missing legacy reference. Removing
        // only the known Library owner must not destroy that repaired reference.
        let imported = try await save(store, bytes)
        #expect(imported.assetPath == legacy.assetPath)
        let removal = try await store.removeWithUndo(ids: [imported.id])
        try await store.finalize(removal.token)
        await store.retryMaintenance()
        #expect(FileManager.default.fileExists(atPath: file.path),
                "Finalizing the known owner must retain bytes potentially owned by an undiscovered v1 manifest")
        #expect(try Data(contentsOf: outside) == manifestBytes)

        let reopenedDB = try openDatabase(root)
        let reopenedAssets = AssetStore(baseDirectory: assets.baseDirectory, database: reopenedDB)
        let reopened = try SavedCreationsStore(assetStore: reopenedAssets, indexURL: root.appendingPathComponent("new-library.json"))
        #expect(try !reopenedDB.libraryManagedRoot())
        #expect(reopened.creations.isEmpty)
        await reopened.retryMaintenance()
        // Register the previously unknown owner only after the unsafe cleanup
        // opportunity; earlier registration would mask the provenance bug.
        let discovered = try SavedCreationsStore(assetStore: reopenedAssets, indexURL: outside)
        #expect(discovered.creations == [legacy])
        #expect(try await discovered.data(for: legacy) == bytes)
    }

    @Test("An already-existing EMPTY root is not a managed claim, even with a new catalog")
    func existingEmptyRootDoesNotEstablishProvenance() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        try await assertUnknownMissingOwnerIsPreserved(root)
    }

    @Test("Old empty/unbound catalogs cannot gain managed provenance from empty or missing roots",
          arguments: [false, true], [false, true])
    func oldCatalogDoesNotEstablishProvenance(catalogExists: Bool, rootExists: Bool) async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try seedOldDatabase(root, catalogExists: catalogExists)
        if rootExists {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        }
        try await assertUnknownMissingOwnerIsPreserved(root)
    }

    @Test("A genuinely new root/catalog claim is durable before any content is saved")
    func newStorageClaimSurvivesEmptyReopen() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("Assets")
        let index = root.appendingPathComponent("new-library.json")
        let identity: [[String]]
        do {
            let db = try openDatabase(root)
            let assets = AssetStore(baseDirectory: base, database: db)
            _ = try SavedCreationsStore(assetStore: assets, indexURL: index)
            #expect(try db.libraryManagedRoot())
            #expect(try db.libraryRows("SELECT id FROM assets;").isEmpty)
            identity = try db.libraryRows("SELECT identity,root FROM asset_catalog;")
        }
        // No content exists. A persisted claim, not rechecking emptiness, must
        // distinguish this reopen from the pre-existing empty-root regression.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        let reopenedDB = try openDatabase(root)
        _ = try SavedCreationsStore(assetStore: AssetStore(baseDirectory: base, database: reopenedDB), indexURL: index)
        #expect(try reopenedDB.libraryManagedRoot())
        #expect(try reopenedDB.libraryRows("SELECT identity,root FROM asset_catalog;") == identity)
    }

    /// Exercise both publication paths, then another connection/recovery cycle.
    /// No assertion requires a particular quarantine table/schema. Valid uncertain
    /// intents may be retained or durably reconciled, but must neither unlink the
    /// uncertain file nor globally prevent unrelated saves (including after reopen).
    private func assertUnrelatedWritesRemainAvailable(_ root: URL, db: DatabaseManager,
                                                     protected: SavedCreation, bytes: Data) async throws {
        let base = root.appendingPathComponent("Assets")
        let protectedFile = base.appendingPathComponent(protected.assetPath)
        var unlinked: [String] = []
        let assets = AssetStore(baseDirectory: base, database: db, unlink: { url in
            unlinked.append(url.path)
            try FileManager.default.removeItem(at: url)
        })
        let index = root.appendingPathComponent("unrelated-library.json")
        let library = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let directBytes = Data("unrelated standalone publication".utf8)
        let libraryBytes = Data("unrelated Library publication".utf8)
        var direct: AssetRecord?
        var item: SavedCreation?
        do { direct = try await assets.store(directBytes, mimeType: "text/plain") }
        catch { Issue.record("Valid legacy cleanup inventory must not block an unrelated AssetStore save: \(error)") }
        do { item = try await save(library, libraryBytes) }
        catch { Issue.record("Valid legacy cleanup inventory must not block an unrelated Library save: \(error)") }
        #expect(unlinked.isEmpty, "Uncertain legacy inventory must be quarantined/reconciled without unlinking")
        #expect(try Data(contentsOf: protectedFile) == bytes)
        #expect(try !db.libraryManagedRoot())

        let otherDB = try openDatabase(root)
        let otherAssets = AssetStore(baseDirectory: base, database: otherDB)
        let reopened = try SavedCreationsStore(assetStore: otherAssets, indexURL: index)
        await reopened.retryMaintenance()
        await reopened.retryMaintenance()
        if let direct { #expect(try await otherAssets.data(for: direct) == directBytes) }
        if let item {
            #expect(reopened.creations.contains(item))
            #expect(try await reopened.data(for: item) == libraryBytes)
        }
        // A one-instance bypass is insufficient: quarantine/reconciliation and
        // the conservative root classification must survive a new connection.
        do {
            let next = try await save(reopened, Data("publication after reopen".utf8))
            #expect(try await reopened.data(for: next) == Data("publication after reopen".utf8))
        } catch { Issue.record("Legacy inventory must not re-block publication after reopen: \(error)") }
        #expect(try !otherDB.libraryManagedRoot())
        #expect(try Data(contentsOf: protectedFile) == bytes)
    }

    @Test("Upgrading an old catalog with pending deletion retains uncertain bytes without freezing saves",
          arguments: [false, true])
    func oldPendingDeletionDoesNotBlockUnrelatedWrites(catalogExists: Bool) async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("old cleanup may still have unknown Library owners".utf8)
        let legacy = creation(bytes)
        let file = root.appendingPathComponent("Assets").appendingPathComponent(legacy.assetPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        let outside = root.appendingPathComponent("outside-library/unknown-v1.json")
        let manifestBytes = try writeLegacyManifest(legacy, to: outside)
        try seedOldDatabase(root, catalogExists: catalogExists, pending: legacy)
        let db = try openDatabase(root)
        // Migration may already have safely quarantined the old intent.
        try await assertUnrelatedWritesRemainAvailable(root, db: db, protected: legacy, bytes: bytes)
        #expect(try Data(contentsOf: outside) == manifestBytes)
    }

    @Test("Registering v1 during managed pending cleanup downgrades safely without globally blocking saves")
    func legacyRegistrationWithPendingManagedDeletion() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try openDatabase(root)
        let base = root.appendingPathComponent("Assets")
        let failingAssets = AssetStore(baseDirectory: base, database: db,
            unlink: { _ in throw CocoaError(.fileWriteNoPermission) })
        let store = try SavedCreationsStore(assetStore: failingAssets, indexURL: root.appendingPathComponent("managed.json"))
        let bytes = Data("managed cleanup later discovered to have a legacy owner".utf8)
        let item = try await save(store, bytes)
        try #require(try db.libraryManagedRoot())
        let removal = try await store.removeWithUndo(ids: [item.id])
        try await store.finalize(removal.token)
        try #require(db.loadAssetDeletionInventory().contains(AssetDeletionEntry(checksum: item.checksum, relativePath: item.assetPath)))
        #expect(try Data(contentsOf: base.appendingPathComponent(item.assetPath)) == bytes)

        let outside = root.appendingPathComponent("outside-library/discovered-v1.json")
        _ = try writeLegacyManifest(item, to: outside)
        // Real unlink is available now. Registration must downgrade/reconcile
        // before maintenance gets any opportunity to drain the pending intent.
        var unlinkedDuringRegistration = false
        let assets = AssetStore(baseDirectory: base, database: db, unlink: { url in
            unlinkedDuringRegistration = true
            try FileManager.default.removeItem(at: url)
        })
        let legacy = try SavedCreationsStore(assetStore: assets, indexURL: outside)
        #expect(legacy.creations == [item])
        #expect(try !db.libraryManagedRoot())
        #expect(!unlinkedDuringRegistration)
        #expect(try await legacy.data(for: item) == bytes)
        try await assertUnrelatedWritesRemainAvailable(root, db: db, protected: item, bytes: bytes)
        let otherDB = try openDatabase(root)
        let reopened = try SavedCreationsStore(assetStore: AssetStore(baseDirectory: base, database: otherDB), indexURL: outside)
        #expect(reopened.creations == [item])
        #expect(try await reopened.data(for: item) == bytes)
    }
    @Test("Existing zero-byte database is ambiguous, never a fresh catalog claim")
    func emptyExistingDatabaseIsLegacy() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("catalog.sqlite3"))
        try await assertUnknownMissingOwnerIsPreserved(root)
    }

    @Test("New catalog provenance survives reopen before any asset root is touched")
    func catalogOriginPrecedesRootAccess() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let origin: [[String]]
        do {
            let db = try openDatabase(root)
            origin = try db.libraryRows("SELECT identity,version,database_path FROM asset_catalog_origin;")
            #expect(origin.count == 1)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets").path))
        }
        let db = try openDatabase(root)
        #expect(try db.libraryRows("SELECT identity,version,database_path FROM asset_catalog_origin;") == origin)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        try assets.withCatalogReservation { }
        #expect(try db.libraryManagedRoot())
    }

    @Test("Concurrent initializers serialize origin capture and root CAS", arguments: [false, true])
    func concurrentRootClaim(independentCatalogs: Bool) throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("Assets")
        let results = LibraryReviewClaimResults()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for worker in 0..<2 {
            let path = root.appendingPathComponent(independentCatalogs ? "catalog-\(worker).sqlite3" : "catalog.sqlite3").path
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                start.wait()
                let db = DatabaseManager(path: path)
                do {
                    guard db.launchFailure == nil else { throw DatabaseManagerError.notAvailable }
                    let assets = AssetStore(baseDirectory: base, database: db)
                    try assets.withCatalogReservation { }
                    results.append(path: path, managed: try db.libraryManagedRoot(), error: nil)
                } catch { results.append(path: path, managed: false, error: error) }
            }
        }
        start.signal(); start.signal()
        try #require(group.wait(timeout: .now() + 15) == .success)
        let outcomes = results.snapshot()
        #expect(outcomes.count == 2)
        let winners = outcomes.filter { $0.error == nil }
        #expect(winners.count == (independentCatalogs ? 1 : 2))
        if !independentCatalogs { #expect(winners.allSatisfy { $0.managed }) }
        let winner = try #require(winners.first)
        let marker = root.appendingPathComponent(".Assets.orb-catalog")
        let originalMarker = try Data(contentsOf: marker)
        for outcome in outcomes {
            let db = DatabaseManager(path: outcome.path)
            let assets = AssetStore(baseDirectory: base, database: db)
            if outcome.error == nil {
                try assets.withCatalogReservation { }
                #expect(try db.libraryManagedRoot() == winner.managed)
            } else {
                #expect(throws: Error.self) { try assets.withCatalogReservation { } }
            }
            #expect(try Data(contentsOf: marker) == originalMarker)
        }
    }

    @Test("Quarantine preserves malformed/conflicting inventory and reserves normalized aliases")
    func conflictingQuarantinePath() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let intended = Data("target with mismatched journal checksum".utf8)
        let item = creation(intended)
        let unrelatedChecksum = AssetStore.sha256Hex(Data("different checksum".utf8))
        try seedOldDatabase(root, catalogExists: true)
        let db = try openDatabase(root)
        let alias = "unused/../" + item.assetPath
        try db.libraryExecute("INSERT INTO asset_deletions(checksum,relative_path) VALUES (?,?);", [unrelatedChecksum, alias])
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        try assets.recoverPendingDeletions()
        #expect(try db.loadAssetDeletionInventory().isEmpty)
        #expect(try db.libraryRows("SELECT checksum,relative_path FROM asset_deletion_quarantine;") == [[unrelatedChecksum,alias]])
        await #expect(throws: Error.self) { try await assets.store(intended, mimeType: "text/plain") }
        #expect(!FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(item.assetPath).path))
        let saved = try await assets.store(Data("unrelated safe path".utf8), mimeType: "text/plain")
        #expect(try await assets.data(for: saved) == Data("unrelated safe path".utf8))
    }

    @Test("Corrupt or absent provenance downgrades a formerly managed claim", arguments: ["origin", "claim", "root"])
    func corruptClaimIsConservative(part: String) async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try openDatabase(root)
        let base = root.appendingPathComponent("Assets")
        let assets = AssetStore(baseDirectory: base, database: db)
        let index = root.appendingPathComponent("managed.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let bytes = Data("claim corruption must never authorize cleanup".utf8)
        let item = try await save(store, bytes)
        if part == "origin" {
            try db.libraryExecute("DELETE FROM asset_catalog_origin;")
        } else if part == "claim" {
            try db.libraryExecute("UPDATE asset_catalog SET root_claim='not-json';")
        } else {
            // A replacement at the same pathname is not the claimed directory.
            let old = root.appendingPathComponent("retained-original-root")
            try FileManager.default.moveItem(at: base, to: old)
            try FileManager.default.copyItem(at: old, to: base)
        }
        let otherDB = try openDatabase(root)
        let reopened = try SavedCreationsStore(assetStore: AssetStore(baseDirectory: base, database: otherDB), indexURL: index)
        #expect(try !otherDB.libraryManagedRoot())
        let removal = try await reopened.removeWithUndo(ids: [item.id])
        try await reopened.finalize(removal.token)
        #expect(try await reopened.data(for: item) == bytes)
    }

    @Test("A corrupt catalog marker is never replaced or treated as a new-root claim")
    func corruptCatalogMarkerIsNotOverwritten() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try openDatabase(root)
        let base = root.appendingPathComponent("Assets")
        let assets = AssetStore(baseDirectory: base, database: db)
        try assets.withCatalogReservation { }
        let marker = root.appendingPathComponent(".Assets.orb-catalog")
        let corrupt = Data("incomplete or foreign claim".utf8)
        try corrupt.write(to: marker)
        #expect(throws: Error.self) { try assets.withCatalogReservation { } }
        #expect(try Data(contentsOf: marker) == corrupt)
        let reopened = AssetStore(baseDirectory: base, database: try openDatabase(root))
        #expect(throws: Error.self) { try reopened.recoverPendingDeletions() }
        #expect(try Data(contentsOf: marker) == corrupt)
    }

    @Test("A rejected first root-claim COMMIT cannot adopt the leftover directory on reopen")
    func rootClaimCommitFailure() throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try openDatabase(root)
        let base = root.appendingPathComponent("Assets")
        let assets = AssetStore(baseDirectory: base, database: db)
        sqlite3_commit_hook(db.db, { _ in 1 }, nil)
        #expect(throws: Error.self) { try assets.withCatalogReservation { } }
        sqlite3_commit_hook(db.db, nil, nil)
        #expect(FileManager.default.fileExists(atPath: base.path))
        let reopenedDB = try openDatabase(root)
        let reopenedAssets = AssetStore(baseDirectory: base, database: reopenedDB)
        try reopenedAssets.withCatalogReservation { }
        #expect(try !reopenedDB.libraryManagedRoot())
    }

    @Test("Legacy quarantine and mode transition roll back together when COMMIT is rejected")
    func quarantineCommitFailure() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try openDatabase(root)
        let base = root.appendingPathComponent("Assets")
        let failing = AssetStore(baseDirectory: base, database: db, unlink: { _ in throw CocoaError(.fileWriteNoPermission) })
        let store = try SavedCreationsStore(assetStore: failing, indexURL: root.appendingPathComponent("managed.json"))
        let bytes = Data("pending cleanup before failed downgrade".utf8)
        let item = try await save(store, bytes)
        let removal = try await store.removeWithUndo(ids: [item.id])
        try await store.finalize(removal.token)
        let pending = try db.loadAssetDeletionInventory()
        try #require(!pending.isEmpty)
        let outside = root.appendingPathComponent("external.json")
        let original = try writeLegacyManifest(item, to: outside)
        sqlite3_commit_hook(db.db, { _ in 1 }, nil)
        #expect(throws: Error.self) { _ = try SavedCreationsStore(assetStore: failing, indexURL: outside) }
        sqlite3_commit_hook(db.db, nil, nil)
        #expect(try db.libraryManagedRoot())
        #expect(try db.loadAssetDeletionInventory() == pending)
        #expect(try db.libraryRows("SELECT checksum FROM asset_deletion_quarantine;").isEmpty)
        #expect(try Data(contentsOf: outside) == original)
        #expect(try Data(contentsOf: base.appendingPathComponent(item.assetPath)) == bytes)
        _ = try SavedCreationsStore(assetStore: failing, indexURL: outside)
        #expect(try !db.libraryManagedRoot())
        #expect(try db.loadAssetDeletionInventory().isEmpty)
        #expect(try db.libraryRows("SELECT checksum,relative_path FROM asset_deletion_quarantine;") == [[item.checksum,item.assetPath]])
    }

    @Test("Quarantine retains conflicting paths and forbids adoption or replacement", arguments: [false, true])
    func quarantineNeverOverwritesUncertainPaths(fileExists: Bool) async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let intended = Data("same target name".utf8)
        let item = creation(intended)
        let base = root.appendingPathComponent("Assets")
        let file = base.appendingPathComponent(item.assetPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let uncertain = Data("uncertain existing bytes, not the checksum".utf8)
        if fileExists { try uncertain.write(to: file) }
        try seedOldDatabase(root, catalogExists: true, pending: item)
        let db = try openDatabase(root)
        let assets = AssetStore(baseDirectory: base, database: db)
        let library = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("library.json"))
        await #expect(throws: Error.self) { try await assets.store(intended, mimeType: "text/plain") }
        await #expect(throws: Error.self) { try await save(library, intended) }
        if fileExists { #expect(try Data(contentsOf: file) == uncertain) }
        else { #expect(!FileManager.default.fileExists(atPath: file.path)) }
        let other = try await save(library, Data("unrelated remains writable".utf8))
        #expect(try await library.data(for: other) == Data("unrelated remains writable".utf8))
        #expect(try db.libraryRows("SELECT checksum,relative_path FROM asset_deletion_quarantine;") == [[item.checksum,item.assetPath]])
    }
}

private final class LibraryReviewClaimResults: @unchecked Sendable {
    struct Outcome {
        let path: String
        let managed: Bool
        let error: Error?
    }
    private let lock = NSLock()
    private var outcomes: [Outcome] = []
    func append(path: String, managed: Bool, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        outcomes.append(Outcome(path: path, managed: managed, error: error))
    }
    func snapshot() -> [Outcome] {
        lock.lock(); defer { lock.unlock() }
        return outcomes
    }
}

private struct LibraryOwnershipReviewV1Manifest: Codable {
    let version: Int
    let creations: [SavedCreation]
}
