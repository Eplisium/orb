import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Library extended audit", .serialized)
@MainActor
struct LibraryExtendedAuditTests {
    private func fixture(fileBacked: Bool = false) throws -> (URL, DatabaseManager, AssetStore, SavedCreationsStore) {
        let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = temporary.appendingPathComponent("ORB-library-audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = DatabaseManager(path: fileBacked ? root.appendingPathComponent("library.sqlite3").path : ":memory:")
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json"))
        return (root, db, assets, store)
    }

    @Test("E03: export cannot replace the library SQLite database or its sidecars",
          arguments: ["", "-wal", "-shm", "-journal"])
    func exportCannotOverwriteDatabase(suffix: String) async throws {
        let (root, db, _, store) = try fixture(fileBacked: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite3")
        let item = try await store.save(Data("output".utf8), mimeType: "text/plain", kind: .transcript, modelID: "fixture", prompt: nil)
        let destination = URL(fileURLWithPath: databaseURL.path + suffix)
        let before = try? Data(contentsOf: destination)
        let changes = sqlite3_total_changes(db.db)
        do {
            try store.export(item, to: destination)
            Issue.record("Managed database export was allowed")
        } catch SavedCreationsError.managedExportDestination {
            // Expected rejection before the output is staged.
        } catch { Issue.record("Unexpected export error: \(error)") }
        #expect(sqlite3_total_changes(db.db) == changes)
        // A read transaction can change transient WAL-index lock/read marks;
        // those SHM bytes are not durable database content or exported output.
        if suffix == "-shm" {
            #expect((try? Data(contentsOf: destination).count) == before?.count)
        } else {
            #expect((try? Data(contentsOf: destination)) == before)
        }
        #expect(db.findAssetRecord(checksum: item.checksum) != nil)
    }

    @Test("E03: export rejects managed assets and manifest including symlink aliases",
          arguments: ["self", "other", "alias", "manifest", "case"])
    func exportCannotOverwriteManagedFiles(target: String) async throws {
        let (root, _, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBytes = Data("first output".utf8)
        let secondBytes = Data("second output".utf8)
        let first = try await store.save(firstBytes, mimeType: "text/plain", kind: .transcript, modelID: "fixture/a", prompt: nil)
        let second = try await store.save(secondBytes, mimeType: "text/plain", kind: .transcript, modelID: "fixture/b", prompt: nil)
        let index = root.appendingPathComponent("creations.json")
        let manifest = try Data(contentsOf: index)
        let destination: URL
        switch target {
        case "self": destination = try store.fileURL(for: first)
        case "other": destination = try store.fileURL(for: second)
        case "case": destination = root.appendingPathComponent("ASSETS").appendingPathComponent(second.assetPath)
        case "alias":
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("Assets"))
            destination = alias.appendingPathComponent(second.assetPath)
        default: destination = index
        }
        #expect(throws: Error.self) { try store.export(first, to: destination) }
        #expect(try await store.data(for: first) == firstBytes)
        #expect(try await store.data(for: second) == secondBytes)
        #expect(try Data(contentsOf: index) == manifest)
    }

    @Test("E03: failed export replacement preserves an existing destination directory")
    func failedExportPreservesDestination() async throws {
        let (root, _, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await store.save(Data("output".utf8), mimeType: "text/plain", kind: .transcript, modelID: "fixture", prompt: nil)
        let destination = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let existing = destination.appendingPathComponent("keep.txt")
        try Data("do not delete".utf8).write(to: existing)
        #expect(throws: Error.self) { try store.export(item, to: destination) }
        #expect(try Data(contentsOf: existing) == Data("do not delete".utf8))
    }

    @Test("E03: normal export replaces a file and leaves source intact")
    func exportReplacesOrdinaryFile() async throws {
        let (root, _, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("output".utf8)
        let item = try await store.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "fixture", prompt: nil)
        let destination = root.appendingPathComponent("export.txt")
        try Data("previous".utf8).write(to: destination)
        try store.export(item, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try await store.data(for: item) == bytes)
    }

    @Test("E03: export rejects a firmlink alias of managed assets")
    func exportRejectsFirmlinkAlias() async throws {
        let (root, _, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("firmlink output".utf8)
        let item = try await store.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "fixture", prompt: nil)
        let source = try store.fileURL(for: item)
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + source.path)
        // The fixture lives on the macOS Data volume during local verification.
        // On layouts without that alias, the target is inaccessible and must still fail safely.
        #expect(throws: Error.self) { try store.export(item, to: alias) }
        #expect(try await store.data(for: item) == bytes)
    }

    @Test("E03: export cannot create a differently cased absent SQLite journal")
    func exportRejectsAbsentCaseVariant() async throws {
        let (root, _, _, store) = try fixture(fileBacked: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await store.save(Data("output".utf8), mimeType: "text/plain", kind: .transcript, modelID: "fixture", prompt: nil)
        let destination = root.appendingPathComponent("LIBRARY.SQLITE3-JOURNAL")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(throws: Error.self) { try store.export(item, to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("E03: generated byte exports cannot overwrite managed files", arguments: ["asset", "manifest"])
    func generatedBytesProtectManagedFiles(target: String) async throws {
        let (root, _, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await store.save(Data("saved".utf8), mimeType: "text/plain", kind: .transcript, modelID: "fixture", prompt: nil)
        let destination = target == "asset" ? try store.fileURL(for: item) : root.appendingPathComponent("creations.json")
        let before = try Data(contentsOf: destination)
        #expect(throws: Error.self) { try store.export(data: Data("generated".utf8), to: destination) }
        #expect(try Data(contentsOf: destination) == before)
    }

    @Test("E03: recovery export works before the first successful library save")
    func generatedBytesWithoutLibrary() throws {
        let (root, _, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("unsaved output".utf8)
        let destination = root.appendingPathComponent("export.txt")
        // Registration claims the new root before the first asset publication.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path).isEmpty)
        #expect(store.creations.isEmpty)
        try store.export(data: bytes, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test("E02: failed attachment lookup cannot delete an attached asset")
    func attachmentReadFailurePreservesBytes() async throws {
        let (root, db, assets, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("attached output".utf8)
        let asset = try await assets.store(bytes, mimeType: "text/plain", jobID: UUID())
        // Deny only the first attachment read. The old fail-open implementation
        // then successfully loads all metadata and deletes the protected file.
        var denied = false
        withUnsafeMutablePointer(to: &denied) { flag in
            sqlite3_set_authorizer(db.db, { context, action, table, column, _, _ in
                guard let context else { return SQLITE_OK }
                let flag = context.assumingMemoryBound(to: Bool.self)
                if !flag.pointee, action == SQLITE_READ,
                   let table, String(cString: table) == "assets",
                   let column, String(cString: column) == "job_id" {
                    flag.pointee = true
                    return SQLITE_DENY
                }
                return SQLITE_OK
            }, flag)
            defer { sqlite3_set_authorizer(db.db, nil, nil) }
            #expect(throws: Error.self) { try assets.removeUnattached(checksum: asset.checksum) }
        }
        #expect(denied)
        #expect(try await assets.data(for: asset) == bytes)
        let retained = try #require(db.findAssetRecord(checksum: asset.checksum))
        #expect(retained.id == asset.id)
        #expect(retained.jobID == asset.jobID)
        #expect(retained.checksum == asset.checksum)
    }

    @Test("E01: expiring one window's Undo preserves another window's deleted shared bytes")
    func pendingUndoProtectsSharedBytes() async throws {
        let (root, _, assets, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("shared output".utf8)
        let a = try await store.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "fixture/a", prompt: nil)
        let b = try await store.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "fixture/b", prompt: nil)
        let removedA = try await store.removeWithUndo(ids: [a.id])
        let removedB = try await store.removeWithUndo(ids: [b.id])
        try await store.finalize(removedA.token)
        #expect(try await store.data(for: b) == bytes)
        try await store.restore(removedB.token)
        #expect(try await store.data(for: b) == bytes)
        #expect(store.creations == [b])
        let deletedAgain = try await store.removeWithUndo(ids: [b.id])
        try await store.finalize(deletedAgain.token)
        #expect(store.creations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: assets.baseDirectory.appendingPathComponent(b.assetPath).path))
    }
}
