import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Asset deletion recovery", .serialized)
@MainActor
struct AssetDeletionRecoveryTests {
    private func makeRoot() throws -> URL {
        // Deliberately avoid the user's library and the system temporary directory.
        let scratch = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/cache/scratch", isDirectory: true)
        let root = scratch.appendingPathComponent("ORB-asset-deletion-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seedRejectedDeletion(root: URL, bytes: Data) async throws -> AssetRecord {
        let db = DatabaseManager(path: root.appendingPathComponent("metadata.sqlite3").path)
        try #require(db.launchFailure == nil)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let stored = try await assets.store(bytes, mimeType: "text/plain")
        // Compare persisted values, not Date's sub-SQLite round-trip precision.
        let record = try #require(db.loadAssetRecordsChecked(checksum: stored.checksum).first)
        try db.execChecked("""
            CREATE TRIGGER reject_asset_delete BEFORE DELETE ON assets
            BEGIN SELECT RAISE(ABORT, 'fixture metadata deletion rejected'); END;
            """)
        #expect(throws: Error.self) { try assets.removeUnattached(checksum: record.checksum) }
        #expect(try db.loadAssetRecordsChecked(checksum: record.checksum) == [record])
        #expect(FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(record.relativePath).path),
                "A rejected metadata DELETE must not destroy the only stored bytes")
        return record // No connection or store escapes: the next phase opens persisted state afresh.
    }

    @Test("Rejected metadata deletion survives reopen without poisoning dedupe", arguments: [false, true])
    func rejectedDeletePreservesBytesAndDedupe(fileInput: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("recoverable asset deletion fixture".utf8)
        let original = try await seedRejectedDeletion(root: root, bytes: bytes)
        let db = DatabaseManager(path: root.appendingPathComponent("metadata.sqlite3").path)
        try #require(db.launchFailure == nil)
        let reopened = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)

        // The persisted fault still applies after reopening; retry must remain non-destructive.
        #expect(throws: Error.self) { try reopened.removeUnattached(checksum: original.checksum) }
        let retainedBytes = try? await reopened.data(for: original)
        #expect(retainedBytes == bytes)
        #expect(try db.loadAssetRecordsChecked(checksum: original.checksum) == [original])
        try db.execChecked("DROP TRIGGER reject_asset_delete;")

        let deduped: AssetRecord?
        if fileInput {
            let source = root.appendingPathComponent("retry-input.txt")
            try bytes.write(to: source)
            deduped = try? await reopened.store(fileAt: source, mimeType: "text/plain", consumeSource: false)
            #expect(try Data(contentsOf: source) == bytes)
        } else {
            deduped = try? await reopened.store(bytes, mimeType: "text/plain")
        }
        #expect(deduped == original, "Deletion failure must not strand checksum dedupe on a missing file")
        #expect(try db.loadAssetRecordsChecked(checksum: original.checksum) == [original])

        #expect(try reopened.removeUnattached(checksum: original.checksum))
        #expect(try db.loadAssetRecordsChecked(checksum: original.checksum).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reopened.baseDirectory.appendingPathComponent(original.relativePath).path))
        #expect(try reopened.removeUnattached(checksum: original.checksum) == false)
        let fresh = try await reopened.store(bytes, mimeType: "text/plain")
        #expect(try await reopened.data(for: fresh) == bytes)
        #expect(try db.loadAssetRecordsChecked(checksum: fresh.checksum).count == 1)
    }

    @Test("A second connection cannot commit an attachment whose bytes cleanup unlinks")
    func attachmentBetweenCheckAndInventoryKeepsBytes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("metadata.sqlite3").path
        let deletingDB = DatabaseManager(path: path)
        let attachingDB = DatabaseManager(path: path)
        try #require(deletingDB.launchFailure == nil && attachingDB.launchFailure == nil)
        // No wait/deadlock if a repaired implementation already holds BEGIN IMMEDIATE.
        try #require(sqlite3_busy_timeout(attachingDB.db, 0) == SQLITE_OK)
        let deletingStore = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: deletingDB)
        let attachingStore = AssetStore(baseDirectory: deletingStore.baseDirectory, database: attachingDB)
        let bytes = Data("cross-connection attachment fixture".utf8)
        let original = try await deletingStore.store(bytes)
        var attachment = original
        attachment.id = UUID()
        attachment.messageID = UUID()
        attachment.createdAt = Date(timeIntervalSince1970: 1)
        let gate = AssetDeletionAttachmentGate(database: attachingDB, record: attachment)

        // Existing SQLite authorizer seam: interleave a second-connection metadata
        // INSERT after the first attachment check, before inventory is stepped.
        // This models the storage writer, NOT a normal two-window Library action.
        let context = Unmanaged.passUnretained(gate).toOpaque()
        try #require(sqlite3_set_authorizer(deletingDB.db, { context, action, table, column, _, _ in
            guard let context, action == SQLITE_READ,
                  let table, String(cString: table) == "assets",
                  let column, String(cString: column) == "relative_path" else { return SQLITE_OK }
            let gate = Unmanaged<AssetDeletionAttachmentGate>.fromOpaque(context).takeUnretainedValue()
            gate.attachOnce()
            return SQLITE_OK
        }, context) == SQLITE_OK)
        defer { sqlite3_set_authorizer(deletingDB.db, nil, nil) }
        var removed: Bool?
        do { removed = try deletingStore.removeUnattached(checksum: original.checksum) }
        catch { /* Fail-closed rejection is permitted, but cannot excuse lost attached bytes. */ }
        sqlite3_set_authorizer(deletingDB.db, nil, nil)
        try #require(gate.attempted, "The intended interleaving must actually be exercised")

        if gate.committed {
            #expect(removed != true)
            let rows = try attachingDB.loadAssetRecordsChecked(checksum: original.checksum)
            #expect(rows.contains(attachment))
            let retainedBytes = try? await attachingStore.data(for: attachment)
            #expect(retainedBytes == bytes, "A committed attachment must retain its shared content")
            let deduped = try? await attachingStore.store(bytes)
            #expect(deduped != nil, "The other store must still be able to dedupe the attached content")
        } else {
            // A DB-wide write reservation is a valid serialization outcome. The
            // caller retains its bytes and retries through AssetStore, not a raw
            // metadata INSERT which could resurrect an already-deleted path.
            #expect(gate.failureCode == SQLITE_BUSY || gate.failureCode == SQLITE_LOCKED)
            let retry = try await attachingStore.store(bytes, messageID: attachment.messageID)
            #expect(try await attachingStore.data(for: retry) == bytes)
            #expect(try attachingDB.hasAttachedAssetRecord(checksum: retry.checksum))
        }
    }
}

/// Accessed synchronously by the authorizer on the invoking thread only. Its
/// second SQLite connection is essential: writing on the authorizing connection
/// itself would be an unsupported reentrant mutation rather than an interleaving.
private final class AssetDeletionAttachmentGate {
    let database: DatabaseManager
    let record: AssetRecord
    private(set) var attempted = false
    private(set) var committed = false
    private(set) var failureCode: Int32?

    init(database: DatabaseManager, record: AssetRecord) {
        self.database = database
        self.record = record
    }

    func attachOnce() {
        guard !attempted else { return }
        attempted = true
        do {
            try database.saveAssetRecordChecked(record)
            committed = true
        } catch {
            failureCode = sqlite3_errcode(database.db)
        }
    }
}
