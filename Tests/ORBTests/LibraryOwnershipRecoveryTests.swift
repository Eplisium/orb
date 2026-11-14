import Foundation
import Testing
@testable import ORB

/*
 DESIGN CONTRACT — proposed, not implemented or executed by this change.

 These offline tracer tests intentionally use today's public entry points so the
 parent can observe behavioral RED, rather than undefined-symbol compiler errors.
 They specify a NEW, empty root/catalog, not permission to collect legacy roots.
 purgeUnreferenced is treated as explicit Undo finalization, not elapsed time.
 Once the token API below exists, port the remove/restore/finalize calls to it.
 No local creations/pendingRemoval array is an ownership oracle.

 Smallest coherent authority:
 - SQLite stores full creation payloads, not just a refcount beside authoritative
   JSON. Existing asset_catalog identity/root and exclusive markers remain.
 - library_manifests(manifest_id TEXT PK, catalog_id TEXT NOT NULL,
     canonical_index TEXT NOT NULL UNIQUE, revision INTEGER NOT NULL,
     exported_revision INTEGER NOT NULL, state TEXT NOT NULL).
   state = registered/retired; retain retired identities as tombstones.
 - library_creations(manifest_id TEXT, creation_id TEXT, payload BLOB NOT NULL,
     checksum TEXT NOT NULL, relative_path TEXT NOT NULL,
     PRIMARY KEY(manifest_id, creation_id)). This row IS the creation owner.
 - library_undo(token TEXT, manifest_id TEXT, creation_id TEXT,
     payload BLOB NOT NULL, checksum TEXT NOT NULL, relative_path TEXT NOT NULL,
     expires_at REAL NOT NULL, PRIMARY KEY(token, creation_id)). These rows ARE
   durable holds. Multiple independent removals need different tokens, even if
   a creation was restored and removed again (prevent Undo/finalize ABA).
 - library_imports(operation_id TEXT PK, manifest_id TEXT NOT NULL,
     checksum TEXT NOT NULL, relative_path TEXT NOT NULL, state TEXT NOT NULL,
     lease_until REAL NOT NULL). A pending operation IS an owner. Commit this
   intent before publishing canonical bytes; keep source input until creation
   COMMIT. Renewal/finalization checks operation state under the writer lock.
 - assets: add library_managed INTEGER NOT NULL DEFAULT 0. Only an explicit
   Library import creates rows with 1. A standalone/generic save or dedupe must
   retain/add a row with 0; never relabel that owner's row as Library-only. The
   Library collector treats any 0 row as an opaque external hold. Existing
   explicit removeUnattached may remove generic rows at its caller's request,
   but cannot bypass registered Library/Undo/import/legacy owners. This avoids
   mistaking nil job/message IDs for proof that no standalone caller owns bytes.
 - asset_catalog: add ownership_protocol INTEGER and reclamation_mode TEXT;
   only a demonstrably new empty catalog + exclusively claimed empty root may
   start managed. Existing roots start legacy_blocked. Never infer completeness
   from the set of manifests seen so far. Keep asset_library_pins as opaque,
   permanent legacy blockers; importing one manifest NEVER clears these pins.
 All CHECKs, FK validation and checked decoders fail closed. Add checksum/path
 indexes to each owner table. No cascading deletion that bypasses journaling.

 Suggested typed API (new types intentionally not referenced by tests yet):
   openLibrary(indexURL: URL) throws -> LibrarySnapshot
     // snapshot = manifestID, revision, creations, exportWarning?
   beginLibraryImport(manifestID: UUID, expectedRevision: Int64,
       checksum: String, relativePath: String, now: Date) throws -> ImportToken
   commitLibraryImport(_ token: ImportToken, creation: SavedCreation,
       expectedRevision: Int64, now: Date) throws -> LibraryCommit
   abortLibraryImport(_ token: ImportToken) throws
   removeLibraryCreations(manifestID: UUID, expectedRevision: Int64,
       ids: Set<UUID>, undoUntil: Date) throws -> LibraryRemoval
     // removal = committed snapshot + token + exact removed payloads
   restoreLibraryRemoval(_ token: UndoToken, expectedRevision: Int64,
       now: Date) throws -> LibraryCommit
   finalizeLibraryRemoval(_ token: UndoToken) throws -> LibraryCommit
   recoverLibraryOwnership(now: Date) throws -> LibraryRecoveryReport
     // expires holds/import leases, prepares cleanup, drains journal, exports
   exportLibrarySnapshot(manifestID: UUID) throws
 LibraryCommit must distinguish committed-with-export-warning from not committed.
 Inject now and phase failpoints; no sleeps, default shared DB or real Keychain.

 Transaction protocol:
 1. Catalog writer reservation (BEGIN IMMEDIATE) binds/validates root + manifest
    identity and revision; every writer uses it, including job/message links,
    dedupe, importer, Undo and collector. Do not nest withAssetReservation.
 2. Save: durable import intent -> copy/verify -> one creation/asset metadata +
    operation-consumption + revision COMMIT. Recheck lease/state/revision before
    publication; a lease loser cannot publish. Copying to a private staging path
    may happen unlocked; canonical publication happens only under reservation.
    Abort/expiry removes the import hold and journals proven-unowned paths. An
    intent's path lets recovery find a file published before metadata COMMIT.
    Generic standalone AssetStore saves must keep their existing semantics;
    Library uses an explicit import mode, never guesses ownership from nil IDs.
 3. Remove: move full rows from creations to Undo holds + bump revision in one
    transaction. Restore consumes a live matching token and reinstates exact DB
    payloads atomically. Expiry/finalize deletes only that token's holds and
    prepares deletion inventory in the SAME transaction. Persisted expiry is
    checked even after restart. No user-supplied array can resurrect a record.
 4. Reclaim only managed-root content with no creation, Undo, import, legacy pin,
    job/message attachment or other registered owner. Conservative checksum OR
    path-alias checks cover every owner table. Remove asset metadata and record
    all candidate paths in asset_deletions before COMMIT. Retain the existing
    separate cleanup reservation, validate the WHOLE journal before unlink, and
    commit cleanup acknowledgements before any replacement save. Expiry alone
    is not permission to unlink outside this protocol. Failed SELECT = stop.
 5. JSON is a compatibility EXPORT after DB COMMIT. Include version 2 plus
    manifest/catalog identity and revision; old readers must reject it, not
    mutate it as v1. Export under reservation from the latest committed snapshot
    (not a captured old payload). Export failure leaves dirty revision + warning,
    never rolls back DB ownership. Reopen loads DB by registered locator even
    if JSON is missing/stale. Never reimport registered JSON. Future/foreign
    identity, unsafe path, non-regular file => conflict, not silent overwrite.
    Persist registry before sidecar/export; after crash repair only a missing
    marker compatible with that committed binding. An orphan/mismatched marker
    fails closed. Do not generate a new manifest identity per process.

 Legacy limit / explicit migration:
 Register validated v1 contents transactionally for continued use, but KEEP the
 whole existing root legacy_blocked, including unpinned pre-protocol assets.
 An unavailable/unknown legacy manifest is not proof of no owners. Missing JSON
 never retires a registered manifest. Do not scan just the default index and
 announce globally complete migration. Safe default maintenance is copy verified
 selected manifests/assets into a NEW managed catalog/root, preserve the old root
 untouched and report retained legacy bytes. Old-root deletion requires explicit
 owner-approved inventory/backup scope; it is not automatic reclamation. All
 supported writers must honor the protocol; arbitrary old binaries or external
 filesystem edits cannot be made transactional by a sidecar alone.

 Additional parent-owned RED sequence after these existing-API tracer bullets:
 - injected clock: expire after restart without passing remembered removed array;
   equality at expiry, repeated expiry, overlapping Undo windows, token ABA;
 - COMMIT rejection for creation, removal, restore, expiry and journal preparation;
 - crash after import intent, canonical rename, creation COMMIT, JSON rename and
   export acknowledgement; retry must neither duplicate creation nor lose input;
 - second connection attachment/save/restore during collector preparation/unlink;
 - old export worker cannot overwrite a newer revision; stale CAS is no mutation;
 - malformed/missing/unknown legacy manifests, failed migration mid-registration,
   copied manifest identity at a second path, mixed catalog/root, FK/read failure;
 - expired failed-save import cleans an unindexed canonical file, but not another
   owner's deduped bytes; cleanup acknowledgement failure + failed replacement;
 - foreground/startup maintenance surfaces retained/blocked/error counts and
   actually invokes recovery; JSON export failure is success-with-warning, not
   "Nothing was removed". Update LibraryView to retain UndoToken, not only arrays.
 Existing SavedCreationsDeleteTests explicitly expects indefinite retention and
 must be revised for managed roots, while keeping equivalent legacy-root tests.
*/

@Suite("Library ownership recovery", .serialized)
@MainActor
struct LibraryOwnershipRecoveryTests {
    private func fixtureRoot() throws -> URL {
        let root = ORBTestScratch.root
            .appendingPathComponent("ORB-library-ownership-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func connection(_ root: URL) throws -> (DatabaseManager, AssetStore) {
        let db = DatabaseManager(path: root.appendingPathComponent("catalog.sqlite3").path)
        try #require(db.launchFailure == nil)
        return (db, AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db))
    }

    private func save(_ bytes: Data, in store: SavedCreationsStore) async throws -> SavedCreation {
        try await store.save(bytes, mimeType: "text/plain", kind: .transcript,
                             modelID: "offline/library-owner", prompt: nil)
    }

    @Test("Registered SQLite contents cannot roll back when an old JSON export reappears")
    func staleJSONCannotRollBackSave() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, assets) = try connection(root)
        let index = root.appendingPathComponent("creations.json")
        let library = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let first = try await save(Data("first".utf8), in: library)
        let oldExport = try Data(contentsOf: index)
        let second = try await save(Data("second".utf8), in: library)
        try oldExport.write(to: index, options: .atomic)
        let (_, reopenedAssets) = try connection(root)
        let reopened = try SavedCreationsStore(assetStore: reopenedAssets, indexURL: index)
        #expect(Set(reopened.creations.map(\.id)) == [first.id, second.id])
    }

    @Test("Old JSON cannot resurrect a committed removal")
    func staleJSONCannotResurrectRemoval() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, assets) = try connection(root)
        let index = root.appendingPathComponent("creations.json")
        let library = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let item = try await save(Data("removed".utf8), in: library)
        let oldExport = try Data(contentsOf: index)
        _ = try await library.remove(ids: [item.id])
        try oldExport.write(to: index, options: .atomic)
        let (_, reopenedAssets) = try connection(root)
        let reopened = try SavedCreationsStore(assetStore: reopenedAssets, indexURL: index)
        #expect(reopened.creations.isEmpty)
        #expect(try await reopened.data(for: item) == Data("removed".utf8), "The durable Undo hold still owns the bytes")
    }

    @Test("Missing compatibility JSON is recovered from the registered manifest, not interpreted as empty")
    func missingExportDoesNotEraseLibrary() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, assets) = try connection(root)
        let index = root.appendingPathComponent("creations.json")
        let library = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let item = try await save(Data("export recovery".utf8), in: library)
        try FileManager.default.removeItem(at: index)
        let (_, reopenedAssets) = try connection(root)
        let reopened = try SavedCreationsStore(assetStore: reopenedAssets, indexURL: index)
        #expect(reopened.creations.map(\.id) == [item.id])
    }

    @Test("Independent registered manifests share bytes until the last durable owner is finalized")
    func independentManifestsReleaseOnlyLastOwner() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, assetsA) = try connection(root)
        let (_, assetsB) = try connection(root)
        let a = try SavedCreationsStore(assetStore: assetsA, indexURL: root.appendingPathComponent("a.json"))
        let b = try SavedCreationsStore(assetStore: assetsB, indexURL: root.appendingPathComponent("b.json"))
        let bytes = Data("shared across manifests".utf8)
        let first = try await save(bytes, in: a)
        let second = try await save(bytes, in: b)
        #expect(first.assetPath == second.assetPath)
        let removedA = try await a.remove(ids: [first.id])
        await a.purgeUnreferenced(removedA)
        #expect(try await b.data(for: second) == bytes)
        let removedB = try await b.remove(ids: [second.id])
        await b.purgeUnreferenced(removedB)
        let (reopenedDB, reopenedAssets) = try connection(root)
        try reopenedAssets.recoverPendingDeletions()
        #expect(try reopenedDB.loadAssetRecordsChecked(checksum: first.checksum).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: assetsA.baseDirectory.appendingPathComponent(first.assetPath).path))
    }

    @Test("Undo holds protect bytes across reopen and explicit finalization releases the last hold")
    func durableUndoThenFinalization() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("creations.json")
        let removed: LibraryRemoval
        do {
            let (_, assets) = try connection(root)
            let library = try SavedCreationsStore(assetStore: assets, indexURL: index)
            let item = try await save(Data("durable Undo".utf8), in: library)
            removed = try await library.removeWithUndo(ids: [item.id])
        }
        let (db, assets) = try connection(root)
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let item = try #require(removed.creations.first)
        #expect(try assets.removeUnattached(checksum: item.checksum) == false)
        #expect(try await reopened.data(for: item) == Data("durable Undo".utf8))
        try await reopened.finalize(removed.token)
        try assets.recoverPendingDeletions()
        #expect(try db.loadAssetRecordsChecked(checksum: item.checksum).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(item.assetPath).path))
    }

    @Test("Finalized Undo cannot be replayed merely because another manifest still owns the same bytes")
    func finalizedUndoCannotBeReplayed() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, assetsA) = try connection(root)
        let (_, assetsB) = try connection(root)
        let a = try SavedCreationsStore(assetStore: assetsA, indexURL: root.appendingPathComponent("a.json"))
        let b = try SavedCreationsStore(assetStore: assetsB, indexURL: root.appendingPathComponent("b.json"))
        let bytes = Data("replay must check the hold".utf8)
        let first = try await save(bytes, in: a)
        let other = try await save(bytes, in: b)
        let removed = try await a.remove(ids: [first.id])
        await a.purgeUnreferenced(removed)
        await #expect(throws: Error.self) { try await a.restore(removed) }
        #expect(a.creations.isEmpty)
        #expect(try await b.data(for: other) == bytes)
    }

    @Test("Rejected stale save preserves its input and does not leave an indefinite orphan pin")
    func failedSaveDoesNotPinOrphanForever() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, assetsA) = try connection(root)
        let (dbB, assetsB) = try connection(root)
        let index = root.appendingPathComponent("creations.json")
        let current = try SavedCreationsStore(assetStore: assetsA, indexURL: index)
        let stale = try SavedCreationsStore(assetStore: assetsB, indexURL: index)
        let retained = try await save(Data("committed owner".utf8), in: current)
        let bytes = Data("failed save input".utf8)
        let source = root.appendingPathComponent("download.txt")
        try bytes.write(to: source)
        await #expect(throws: Error.self) {
            try await stale.save(fileAt: source, mimeType: "text/plain", kind: .transcript,
                                 modelID: "offline/library-owner", prompt: nil)
        }
        #expect(try Data(contentsOf: source) == bytes)
        let checksum = AssetStore.sha256Hex(bytes)
        // Preflight may reject before storing, or abort may release a staged
        // owner. Either path must allow ordinary journal-backed cleanup now.
        _ = try assetsB.removeUnattached(checksum: checksum)
        try assetsB.recoverPendingDeletions()
        #expect(try dbB.loadAssetRecordsChecked(checksum: checksum).isEmpty)
        let path = AssetStore.relativePath(forChecksum: checksum, mimeType: "text/plain")
        #expect(!FileManager.default.fileExists(atPath: assetsB.baseDirectory.appendingPathComponent(path).path))
        #expect(try await current.data(for: retained) == Data("committed owner".utf8))
    }

    @Test("Library finalization journals failed unlink and reopened cleanup completes it")
    func libraryDeletionUsesDurableJournal() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (db, _) = try connection(root)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db,
                                unlink: { _ in throw CocoaError(.fileWriteNoPermission) })
        let library = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json"))
        let item = try await save(Data("journal Library cleanup".utf8), in: library)
        let removed = try await library.remove(ids: [item.id])
        await library.purgeUnreferenced(removed)
        #expect(try db.loadAssetRecordsChecked(checksum: item.checksum).isEmpty)
        #expect(try db.loadAssetDeletionInventory().contains {
            $0.checksum == item.checksum && $0.relativePath == item.assetPath
        })
        #expect(FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(item.assetPath).path))
        let (reopenedDB, reopenedAssets) = try connection(root)
        try reopenedAssets.recoverPendingDeletions()
        #expect(try reopenedDB.loadAssetDeletionInventory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(item.assetPath).path))
    }

    @Test("Library collection preserves independently saved content, even without job or message IDs",
          arguments: ["standalone", "job", "message", "remote"])
    func externalAssetOwnersSurviveLibraryFinalization(ownerKind: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, assets) = try connection(root)
        let library = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json"))
        let bytes = Data("external owner deduped after Library save".utf8)
        let item = try await save(bytes, in: library)
        let external = try await assets.store(bytes, mimeType: "text/plain",
            remoteReference: ownerKind == "remote" ? "offline-remote-reference" : nil,
            jobID: ownerKind == "job" ? UUID() : nil,
            messageID: ownerKind == "message" ? UUID() : nil)
        #expect(external.relativePath == item.assetPath)
        let removed = try await library.remove(ids: [item.id])
        await library.purgeUnreferenced(removed)
        try assets.recoverPendingDeletions()
        #expect(try await assets.data(for: external) == bytes)
    }

    @Test("An opaque legacy pin remains a blocker after registered owners finalize")
    func legacyPinIsNeverGuessedAway() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (db, assets) = try connection(root)
        let library = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json"))
        let bytes = Data("unknown legacy owner".utf8)
        let item = try await save(bytes, in: library)
        try assets.withCatalogReservation { try db.pinLibraryAsset(checksum: item.checksum) }
        let removed = try await library.remove(ids: [item.id])
        await library.purgeUnreferenced(removed)
        #expect(try assets.removeUnattached(checksum: item.checksum) == false)
        #expect(try await assets.data(atRelativePath: item.assetPath) == bytes)
        #expect(try db.loadAssetDeletionInventory().isEmpty)
    }
}
