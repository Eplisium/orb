import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Database contention recovery", .serialized)
struct DatabaseContentionRecoveryTests {
    private func tempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-\(label)-\(UUID().uuidString).sqlite3").path
    }

    private func removeAll(_ path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix(base) {
            try? fm.removeItem(atPath: dir + "/" + name)
        }
    }

    private func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? -1
    }

    private func open(_ path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else { return nil }
        return handle
    }

    @Test("a writer holding BEGIN IMMEDIATE does not trigger destructive corruption recovery")
    func busyWriterPreservesDatabaseAndWAL() throws {
        let path = tempPath("busy")
        defer { removeAll(path) }
        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }

        // Create a fully migrated database, then release it so the schema is stable.
        do { _ = DatabaseManager(path: path) }
        DatabaseManager.lastLaunchFailure = nil

        // Connection A commits a row that stays in the WAL (autocheckpoint off, kept open).
        let a = try #require(open(path))
        defer { sqlite3_close(a) }
        #expect(sqlite3_exec(a, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(a, "INSERT INTO favorites (model_id, added_at) VALUES ('wal/committed', 1);", nil, nil, nil) == SQLITE_OK)
        #expect(fileSize(path + "-wal") > 0)

        // Connection B holds the write lock.
        let b = try #require(open(path))
        defer { sqlite3_close(b) }
        #expect(sqlite3_exec(b, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)

        // The startup migration's INSERT OR IGNORE needs the write lock held by B.
        let manager = DatabaseManager(path: path)

        // Nothing was moved or deleted.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(fileSize(path + "-wal") > 0)
        #expect(FileManager.default.fileExists(atPath: path + "-shm"))
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)) ?? []
        #expect(siblings.filter { $0.contains((path as NSString).lastPathComponent) && $0.contains(".corrupt-") }.isEmpty)

        // Honest failure surfaced; no backup claimed; manager still usable (temporary DB).
        let failure = try #require(manager.launchFailure)
        #expect(failure.backupPath == nil)
        #expect(!failure.detail.contains("moved to"))
        manager.addFavorite("temp/model")
        #expect(manager.isFavorite("temp/model"))

        // Release the lock; the committed WAL row must still be in the original DB.
        #expect(sqlite3_exec(b, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
        let reader = DatabaseManager(path: path)
        #expect(reader.isFavorite("wal/committed"))
        #expect(reader.isFavorite("temp/model") == false)
        #expect(reader.launchFailure == nil)
    }

    @Test("real corruption backup carries the -wal and -shm sidecars")
    func corruptionBackupMovesSidecars() throws {
        let path = tempPath("corrupt-sidecars")
        defer { removeAll(path) }
        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }

        try Data("this is definitely not a sqlite database".utf8).write(to: URL(fileURLWithPath: path))
        try Data("wal-bytes".utf8).write(to: URL(fileURLWithPath: path + "-wal"))
        try Data("shm-bytes".utf8).write(to: URL(fileURLWithPath: path + "-shm"))

        let manager = DatabaseManager(path: path)
        let failure = try #require(manager.launchFailure)
        let backup = try #require(failure.backupPath)
        #expect(FileManager.default.fileExists(atPath: backup))
        // SQLite may truncate/resize bogus sidecars while opening, so assert the
        // files travelled with the backup rather than their exact bytes.
        #expect(FileManager.default.fileExists(atPath: backup + "-wal"))
        #expect(FileManager.default.fileExists(atPath: backup + "-shm"))
        #expect(FileManager.default.fileExists(atPath: path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: path + "-shm") == false)
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }
}
