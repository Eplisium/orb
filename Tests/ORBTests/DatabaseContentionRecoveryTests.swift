import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Database contention recovery", .serialized)
struct DatabaseContentionRecoveryTests {
    private func tempPath(_ label: String) throws -> String {
        let fm = FileManager.default
        let scratch = ProcessInfo.processInfo.environment["TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fm.temporaryDirectory
        let root = scratch.appendingPathComponent("ORB-\(label)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("catalog.sqlite3").path
    }

    private func removeAll(_ path: String) {
        // Each fixture owns its entire parent, including corruption-copy trees.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
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
        let path = try tempPath("busy")
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
        var attemptedBackup = false
        let manager = DatabaseManager(path: path, recoveryBackup: DatabaseRecoveryBackup(faultHook: { _, _, _ in
            attemptedBackup = true
        }))

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(fileSize(path + "-wal") > 0)
        #expect(FileManager.default.fileExists(atPath: path + "-shm"))
        #expect(!attemptedBackup)
        #expect(manager.storageDirectoryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

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

    @Test("real corruption copies all member bytes and retains originals across reopen")
    func corruptionBackupCopiesSidecars() throws {
        let path = try tempPath("corrupt-sidecars")
        defer { removeAll(path) }
        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }

        // Opaque malformed fixtures, not an active SQLite WAL or hot journal.
        let members: [(String, Data)] = [
            ("", Data("this is definitely not a sqlite database".utf8)),
            ("-wal", Data("wal-bytes".utf8)),
            ("-shm", Data("shm-bytes".utf8)),
            ("-journal", Data("\u{0000}non-hot-journal-bytes".utf8))
        ]
        for (suffix, bytes) in members {
            try bytes.write(to: URL(fileURLWithPath: path + suffix))
        }

        // Opening malformed sidecars can make SQLite truncate WAL/rewrite SHM.
        // Snapshot all four files at the first copy hook, after SQLite closes;
        // the backup helper must preserve exactly that complete boundary state.
        var launchSnapshot: [(String, Data)]?
        let recovery = DatabaseRecoveryBackup(faultHook: { phase, _, _ in
            if phase == .beforeCopy && launchSnapshot == nil {
                launchSnapshot = try members.map { suffix, _ in
                    (suffix, try Data(contentsOf: URL(fileURLWithPath: path + suffix)))
                }
            }
        })
        let manager = DatabaseManager(path: path, recoveryBackup: recovery)
        let firstSnapshot = try #require(launchSnapshot)
        let failure = try #require(manager.launchFailure)
        let backup = try #require(failure.backupPath)
        #expect(failure.detail.contains("copied and byte-verified"))
        #expect(!failure.detail.contains("moved to"))
        expectMemoryOnly(manager)
        for (suffix, bytes) in firstSnapshot {
            #expect(try Data(contentsOf: URL(fileURLWithPath: backup + suffix)) == bytes)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path + suffix)) == bytes)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == members[0].1)
        manager.addFavorite("memory/only")
        #expect(manager.isFavorite("memory/only"))
        launchSnapshot = nil
        let reopened = DatabaseManager(path: path, recoveryBackup: recovery)
        let reopenSnapshot = try #require(launchSnapshot)
        let secondBackup = try #require(reopened.launchFailure?.backupPath)
        #expect(secondBackup != backup)
        expectMemoryOnly(reopened)
        #expect(!reopened.isFavorite("memory/only"))
        for (suffix, bytes) in reopenSnapshot {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path + suffix)) == bytes)
            #expect(try Data(contentsOf: URL(fileURLWithPath: secondBackup + suffix)) == bytes)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == members[0].1)
        // Reopening must not overwrite or consume the first independent copy.
        for (suffix, bytes) in firstSnapshot {
            #expect(try Data(contentsOf: URL(fileURLWithPath: backup + suffix)) == bytes)
        }
    }

    private func expectMemoryOnly(_ manager: DatabaseManager) {
        let filename = manager.db.flatMap { sqlite3_db_filename($0, "main") }
            .map { String(cString: $0) }
        #expect(filename == "", "Recovery must use memory, never the original disk path")
    }

    @Test("an operational open failure does not create corruption copies")
    func unavailableDatabaseDoesNotBackup() throws {
        let path = try tempPath("unavailable")
        defer { removeAll(path) }
        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        var attemptedBackup = false
        let manager = DatabaseManager(path: path, recoveryBackup: DatabaseRecoveryBackup(faultHook: { _, _, _ in
            attemptedBackup = true
        }))
        #expect(manager.launchFailure?.title == "Database Unavailable")
        #expect(manager.launchFailure?.backupPath == nil)
        #expect(!attemptedBackup)
        #expect(manager.storageDirectoryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        #expect(exists)
        #expect(directory.boolValue)
        manager.addFavorite("memory/unavailable")
        #expect(manager.isFavorite("memory/unavailable"))
    }
}
