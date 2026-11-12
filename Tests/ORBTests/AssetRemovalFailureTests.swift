import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Asset removal failures", .serialized)
@MainActor
struct AssetRemovalFailureTests {
    private func fixture() throws -> (URL, DatabaseManager, AssetStore) {
        let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = temporary.appendingPathComponent("ORB-asset-removal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = DatabaseManager(path: ":memory:")
        return (root, db, AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db))
    }

    @Test("Malformed asset metadata cannot be silently skipped during removal")
    func malformedMetadataStopsRemoval() async throws {
        let (root, db, assets) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("malformed row fixture".utf8)
        let record = try await assets.store(bytes)
        try db.execChecked("UPDATE assets SET id = 'invalid-id';")
        #expect(throws: Error.self) { try assets.removeUnattached(checksum: record.checksum) }
        #expect(try await assets.data(for: record) == bytes)
        let count = try #require(db.prepare("SELECT COUNT(*) FROM assets;"))
        defer { sqlite3_finalize(count) }
        #expect(sqlite3_step(count) == SQLITE_ROW)
        #expect(sqlite3_column_int(count, 0) == 1)
    }

    @Test("An error after the first asset row never returns a partial inventory")
    func partialEnumerationThrows() async throws {
        let (root, db, assets) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await assets.store(Data("partial row fixture".utf8))
        var duplicate = record
        duplicate.id = UUID()
        duplicate.remoteReference = "fault"
        try db.saveAssetRecordChecked(duplicate)
        try db.execChecked("ALTER TABLE assets RENAME TO stored_assets;")
        try db.execChecked("CREATE VIEW assets AS SELECT id, CASE WHEN remote_reference = 'fault' THEN abs(-9223372036854775808) ELSE relative_path END AS relative_path, remote_reference, mime_type, size_bytes, checksum, job_id, message_id, retention, created_at FROM stored_assets;")
        let probe = try #require(db.prepare("SELECT relative_path FROM assets;"))
        #expect(sqlite3_step(probe) == SQLITE_ROW)
        #expect(sqlite3_step(probe) == SQLITE_ERROR)
        sqlite3_finalize(probe)
        #expect(throws: Error.self) { try assets.removeUnattached(checksum: record.checksum) }
        #expect(throws: Error.self) { try db.loadAssetRecordsChecked(checksum: record.checksum) }
        #expect(try await assets.data(for: record) == Data("partial row fixture".utf8))
        let count = try #require(db.prepare("SELECT COUNT(*) FROM stored_assets;"))
        defer { sqlite3_finalize(count) }
        #expect(sqlite3_step(count) == SQLITE_ROW)
        #expect(sqlite3_column_int(count, 0) == 2)
    }

    @Test("Failed asset enumeration leaves metadata and bytes available for retry")
    func failedEnumerationPreservesMetadata() async throws {
        let (root, db, assets) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("asset fixture".utf8)
        let record = try await assets.store(bytes, mimeType: "text/plain")
        var denied = false
        withUnsafeMutablePointer(to: &denied) { flag in
            sqlite3_set_authorizer(db.db, { context, action, table, column, _, _ in
                guard let context else { return SQLITE_OK }
                let flag = context.assumingMemoryBound(to: Bool.self)
                if !flag.pointee, action == SQLITE_READ,
                   let table, String(cString: table) == "assets",
                   let column, String(cString: column) == "relative_path" {
                    flag.pointee = true
                    return SQLITE_DENY
                }
                return SQLITE_OK
            }, flag)
            defer { sqlite3_set_authorizer(db.db, nil, nil) }
            #expect(throws: Error.self) { try assets.removeUnattached(checksum: record.checksum) }
        }
        #expect(denied)
        #expect(db.findAssetRecord(checksum: record.checksum)?.id == record.id)
        #expect(try await assets.data(for: record) == bytes)
        #expect(try assets.removeUnattached(checksum: record.checksum))
        #expect(db.findAssetRecord(checksum: record.checksum) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets").appendingPathComponent(record.relativePath).path))
    }
}
