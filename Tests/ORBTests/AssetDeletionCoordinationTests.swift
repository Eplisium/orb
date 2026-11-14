import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Asset deletion coordination", .serialized)
@MainActor
struct AssetDeletionCoordinationTests {
    private func root() throws -> URL {
        let url = ORBTestScratch.root.appendingPathComponent("ORB-deletion-coordination-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Unlink failure leaves durable cleanup; reopened writer cleans before publishing a new generation", arguments: [false, true])
    func failedUnlinkAndReplacement(fileInput: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite3").path
        let bytes = Data("retry cleanup".utf8)
        let original: AssetRecord
        do {
            let db = DatabaseManager(path: path)
            let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db,
                                   unlink: { _ in throw CocoaError(.fileWriteNoPermission) })
            original = try await store.store(bytes)
            #expect(throws: Error.self) { try store.removeUnattached(checksum: original.checksum) }
            #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).isEmpty)
            #expect(try db.loadAssetDeletionInventory().count == 1)
            #expect(try await store.data(for: original) == bytes)
            await #expect(throws: Error.self) { try await store.store(bytes) }
        }
        let db = DatabaseManager(path: path)
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let owner = UUID()
        let replacement: AssetRecord
        if fileInput {
            let source = root.appendingPathComponent("download")
            try bytes.write(to: source)
            replacement = try await store.store(fileAt: source, messageID: owner, consumeSource: false)
            #expect(try Data(contentsOf: source) == bytes)
        } else {
            replacement = try await store.store(bytes, messageID: owner)
        }
        #expect(replacement.id != original.id)
        #expect(replacement.messageID == owner)
        #expect(try db.loadAssetDeletionInventory().isEmpty)
        try store.recoverPendingDeletions()
        try store.recoverPendingDeletions()
        #expect(try await store.data(for: replacement) == bytes)
        #expect(try store.removeUnattached(checksum: replacement.checksum) == false)
    }

    @Test("Cleanup acknowledgement failure cannot leave a tombstone that deletes replacement bytes")
    func failedAcknowledgement() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("db.sqlite3").path)
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let bytes = Data("acknowledgement".utf8)
        let original = try await store.store(bytes)
        try db.execChecked("CREATE TRIGGER reject_cleanup BEFORE DELETE ON asset_deletions BEGIN SELECT RAISE(ABORT, 'cleanup acknowledgement rejected'); END;")
        #expect(throws: Error.self) { try store.removeUnattached(checksum: original.checksum) }
        #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).isEmpty)
        #expect(try db.loadAssetDeletionInventory().count == 1)
        await #expect(throws: Error.self) { try await store.store(bytes) }
        #expect(!FileManager.default.fileExists(atPath: store.baseDirectory.appendingPathComponent(original.relativePath).path))
        try db.execChecked("DROP TRIGGER reject_cleanup;")
        let fresh = try await store.store(bytes)
        try store.recoverPendingDeletions()
        #expect(try await store.data(for: fresh) == bytes)
    }

    @Test("A failed replacement save cannot roll back already committed cleanup", arguments: [false, true])
    func cleanupThenFailedSave(fileInput: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite3").path
        let db = DatabaseManager(path: path)
        let base = root.appendingPathComponent("Assets")
        let bytes = Data("cleanup then failed replacement".utf8)
        let blocked = AssetStore(baseDirectory: base, database: db,
                                 unlink: { _ in throw CocoaError(.fileWriteNoPermission) })
        let original = try await blocked.store(bytes)
        #expect(throws: Error.self) { try blocked.removeUnattached(checksum: original.checksum) }
        try db.execChecked("CREATE TRIGGER reject_replacement BEFORE INSERT ON assets BEGIN SELECT RAISE(ABORT, 'replacement rejected'); END;")
        let store = AssetStore(baseDirectory: base, database: db)
        let source = root.appendingPathComponent("input")
        try bytes.write(to: source)
        if fileInput {
            await #expect(throws: Error.self) { try await store.store(fileAt: source) }
        } else {
            await #expect(throws: Error.self) { try await store.store(bytes) }
        }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try db.loadAssetDeletionInventory().isEmpty,
                "A failed metadata insert must not restore the prior generation's tombstone")
        #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).isEmpty)
        try store.recoverPendingDeletions()
        #expect(try Data(contentsOf: base.appendingPathComponent(original.relativePath)) == bytes)
        try db.execChecked("DROP TRIGGER reject_replacement;")
        let reopenedDB = DatabaseManager(path: path)
        let reopened = AssetStore(baseDirectory: base, database: reopenedDB)
        let fresh = try await reopened.store(bytes)
        try reopened.recoverPendingDeletions()
        #expect(try await reopened.data(for: fresh) == bytes)
    }

    @Test("Every journal path is validated before any unlink")
    func malformedJournal() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("db.sqlite3").path)
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db,
                               unlink: { _ in throw CocoaError(.fileWriteNoPermission) })
        let bytes = Data("valid entry first".utf8)
        let original = try await store.store(bytes)
        #expect(throws: Error.self) { try store.removeUnattached(checksum: original.checksum) }
        // Sorts AFTER the valid path: per-entry validation/unlink would already
        // have destroyed that first file before discovering this malformed row.
        try db.execChecked("INSERT INTO asset_deletions(checksum, relative_path) VALUES ('\(original.checksum)', 'zz/../outside');")
        let retry = AssetStore(baseDirectory: store.baseDirectory, database: db)
        #expect(throws: Error.self) { try retry.recoverPendingDeletions() }
        #expect(try await retry.data(for: original) == bytes)
        #expect(try db.loadAssetDeletionInventory().count == 2)
    }

    @Test("An invalid metadata path rejects the whole preparation before deleting any row or file")
    func invalidPreparationPath() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("db.sqlite3").path)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let bytes = Data("validate complete inventory".utf8)
        let original = try await assets.store(bytes)
        var invalid = original
        invalid.id = UUID()
        invalid.relativePath = "../outside"
        try db.saveAssetRecordChecked(invalid)
        #expect(throws: Error.self) { try assets.removeUnattached(checksum: original.checksum) }
        #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).count == 2)
        #expect(try db.loadAssetDeletionInventory().isEmpty)
        #expect(try await assets.data(for: original) == bytes)
    }

    @Test("A journal entry conflicting with an existing attachment never unlinks its bytes")
    func journalCannotDeleteAttachment() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("db.sqlite3").path)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let bytes = Data("live owner wins".utf8)
        let original = try await assets.store(bytes, messageID: UUID())
        try db.execChecked("INSERT INTO asset_deletions(checksum, relative_path) VALUES ('\(original.checksum)', '\(original.relativePath)');")
        #expect(throws: Error.self) { try assets.recoverPendingDeletions() }
        #expect(try await assets.data(for: original) == bytes)
        #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).count == 1)
        #expect(try db.loadAssetDeletionInventory().count == 1)
    }

    @Test("Dedupe retains each requested owner without replacing earlier attachments", arguments: [false, true])
    func dedupeOwnership(fileInput: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("db.sqlite3").path)
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let bytes = Data("owned bytes".utf8)
        let first = try await store.store(bytes, jobID: UUID())
        let owner = UUID()
        let second: AssetRecord
        if fileInput {
            let source = root.appendingPathComponent("source")
            try bytes.write(to: source)
            second = try await store.store(fileAt: source, messageID: owner, consumeSource: false)
        } else {
            second = try await store.store(bytes, messageID: owner)
        }
        #expect(second.messageID == owner)
        #expect(second.relativePath == first.relativePath)
        let records = try db.loadAssetRecordsChecked(checksum: first.checksum)
        #expect(records.contains { $0.id == first.id && $0.jobID == first.jobID })
        #expect(records.contains { $0.id == second.id && $0.messageID == owner })
        #expect(try store.removeUnattached(checksum: first.checksum) == false)
    }

    @Test("One asset root cannot be mutated using independent metadata catalogs")
    func mixedCatalogsRejected() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager(path: root.appendingPathComponent("a.sqlite3").path))
        let b = AssetStore(baseDirectory: a.baseDirectory, database: DatabaseManager(path: root.appendingPathComponent("b.sqlite3").path))
        let bytes = Data("catalog identity".utf8)
        let first = try await a.store(bytes)
        await #expect(throws: Error.self) { try await b.store(bytes) }
        #expect(throws: Error.self) { try b.removeUnattached(checksum: first.checksum) }
        #expect(try await a.data(for: first) == bytes)
    }

    @Test("Prepare and cleanup COMMIT failures remain recoverable after reopening", arguments: ["assets", "asset_deletions"])
    func commitFailureReopens(table: String) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite3").path
        let bytes = Data("commit failure recovery".utf8)
        let original: AssetRecord
        do {
            let db = DatabaseManager(path: path)
            let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
            original = try await store.store(bytes)
            let fault = AssetDeletionCommitFault(table: table)
            let context = Unmanaged.passUnretained(fault).toOpaque()
            sqlite3_update_hook(db.db, { context, operation, _, table, _ in
                guard let context, operation == SQLITE_DELETE, let table else { return }
                let fault = Unmanaged<AssetDeletionCommitFault>.fromOpaque(context).takeUnretainedValue()
                if String(cString: table) == fault.table { fault.armed = true }
            }, context)
            sqlite3_commit_hook(db.db, { context in
                guard let context else { return 0 }
                let fault = Unmanaged<AssetDeletionCommitFault>.fromOpaque(context).takeUnretainedValue()
                guard fault.armed, !fault.rejected else { return 0 }
                fault.rejected = true
                return 1
            }, context)
            #expect(throws: Error.self) { try store.removeUnattached(checksum: original.checksum) }
            sqlite3_commit_hook(db.db, nil, nil)
            sqlite3_update_hook(db.db, nil, nil)
            #expect(fault.rejected)
            if table == "assets" {
                #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).count == 1)
                #expect(try db.loadAssetDeletionInventory().isEmpty)
                #expect(try await store.data(for: original) == bytes)
            } else {
                #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).isEmpty)
                #expect(try db.loadAssetDeletionInventory().count == 1)
                #expect(!FileManager.default.fileExists(atPath: store.baseDirectory.appendingPathComponent(original.relativePath).path))
            }
        }
        let db = DatabaseManager(path: path)
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        try store.recoverPendingDeletions()
        let fresh = try await store.store(bytes)
        try store.recoverPendingDeletions()
        #expect(try await store.data(for: fresh) == bytes)
        #expect(try db.loadAssetDeletionInventory().isEmpty)
    }

    @Test("An attachment cannot commit from a second connection during unlink")
    func attachmentDuringUnlink() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite3").path
        let deletingDB = DatabaseManager(path: path)
        let attachingDB = DatabaseManager(path: path)
        try #require(sqlite3_busy_timeout(attachingDB.db, 0) == SQLITE_OK)
        let base = root.appendingPathComponent("Assets")
        let bytes = Data("unlink reservation".utf8)
        let original = try await AssetStore(baseDirectory: base, database: deletingDB).store(bytes)
        var attachment = original
        attachment.id = UUID()
        attachment.messageID = UUID()
        var attempted = false
        var committed = false
        let deleting = AssetStore(baseDirectory: base, database: deletingDB, unlink: { url in
            attempted = true
            do { try attachingDB.saveAssetRecordChecked(attachment); committed = true }
            catch { #expect(sqlite3_errcode(attachingDB.db) == SQLITE_BUSY || sqlite3_errcode(attachingDB.db) == SQLITE_LOCKED) }
            try FileManager.default.removeItem(at: url)
        })
        #expect(try deleting.removeUnattached(checksum: original.checksum))
        #expect(attempted && !committed)
        // A stale raw metadata retry is rejected even after cleanup is finished.
        #expect(throws: Error.self) { try attachingDB.saveAssetRecordChecked(attachment) }
        let retry = AssetStore(baseDirectory: base, database: attachingDB)
        let saved = try await retry.store(bytes, messageID: attachment.messageID)
        #expect(try await retry.data(for: saved) == bytes)
    }

    @Test("Dedupe holds the writer reservation while checking existing content", arguments: [false, true])
    func dedupeExcludesDeletion(fileInput: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite3").path
        let writerDB = DatabaseManager(path: path)
        let deletingDB = DatabaseManager(path: path)
        try #require(sqlite3_busy_timeout(deletingDB.db, 0) == SQLITE_OK)
        let base = root.appendingPathComponent("Assets")
        let store = AssetStore(baseDirectory: base, database: writerDB)
        let bytes = Data("dedupe owns reservation".utf8)
        let original = try await store.store(bytes)
        let gate = AssetDedupeDeletionGate(store: AssetStore(baseDirectory: base, database: deletingDB), checksum: original.checksum)
        let context = Unmanaged.passUnretained(gate).toOpaque()
        sqlite3_set_authorizer(writerDB.db, { context, action, table, column, _, _ in
            guard let context, action == SQLITE_READ,
                  let table, String(cString: table) == "assets",
                  let column, String(cString: column) == "relative_path" else { return SQLITE_OK }
            Unmanaged<AssetDedupeDeletionGate>.fromOpaque(context).takeUnretainedValue().attempt()
            return SQLITE_OK
        }, context)
        defer { sqlite3_set_authorizer(writerDB.db, nil, nil) }
        let owner = UUID()
        let saved: AssetRecord
        if fileInput {
            let source = root.appendingPathComponent("input")
            try bytes.write(to: source)
            saved = try await store.store(fileAt: source, messageID: owner, consumeSource: false)
        } else {
            saved = try await store.store(bytes, messageID: owner)
        }
        sqlite3_set_authorizer(writerDB.db, nil, nil)
        #expect(gate.attempted && gate.failed && !gate.removed)
        #expect(saved.messageID == owner)
        #expect(try await store.data(for: saved) == bytes)
        #expect(try deletingDB.hasAttachedAssetRecord(checksum: original.checksum))
    }

    @Test("One catalog cannot reinterpret paths under a second asset root")
    func mixedRootsRejected() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("db.sqlite3").path)
        let a = AssetStore(baseDirectory: root.appendingPathComponent("A"), database: db)
        let b = AssetStore(baseDirectory: root.appendingPathComponent("B"), database: db)
        let bytes = Data("root identity".utf8)
        let record = try await a.store(bytes)
        await #expect(throws: Error.self) { try await b.store(bytes) }
        #expect(throws: Error.self) { try b.removeUnattached(checksum: record.checksum) }
        #expect(try await a.data(for: record) == bytes)
    }

    @Test("Independent stale Library manifests cannot erase newer entries or purge shared bytes")
    func staleLibraryPreservesBytes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("db.sqlite3").path)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let index = root.appendingPathComponent("creations.json")
        let a = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let bytes = Data("independent catalog ownership".utf8)
        let first = try await a.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "a", prompt: nil)
        let b = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let removed = try await a.remove(ids: [first.id])
        let newer = try await a.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "new", prompt: nil)
        await #expect(throws: Error.self) { try await b.remove(ids: [first.id]) }
        await b.purgeUnreferenced([first])
        await a.purgeUnreferenced(removed)
        #expect(try await assets.data(atRelativePath: newer.assetPath) == bytes)
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(reopened.creations.map(\.id) == [newer.id])
        #expect(try assets.removeUnattached(checksum: newer.checksum) == false,
                "New Library references are durably pinned, independently of in-memory manifests")
    }
}

private final class AssetDedupeDeletionGate {
    let store: AssetStore
    let checksum: String
    var attempted = false
    var failed = false
    var removed = false
    init(store: AssetStore, checksum: String) {
        self.store = store
        self.checksum = checksum
    }
    func attempt() {
        guard !attempted else { return }
        attempted = true
        do { removed = try store.removeUnattached(checksum: checksum) }
        catch { failed = true }
    }
}

private final class AssetDeletionCommitFault {
    let table: String
    var armed = false
    var rejected = false
    init(table: String) { self.table = table }
}
