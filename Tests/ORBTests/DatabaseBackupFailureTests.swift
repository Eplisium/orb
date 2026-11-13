import Darwin
import Foundation
import SQLite3
import Testing
@testable import ORB

@Suite("Database backup failure", .serialized)
struct DatabaseBackupFailureTests {
    private let suffixes = ["", "-wal", "-shm", "-journal"]

    @Test("every copy-stage failure preserves originals and reports incomplete on reopen",
          arguments: ["", "-wal", "-shm", "-journal"])
    func copyFailure(suffix: String) throws {
        try exerciseLaunchFailure(suffix: suffix, phase: .beforeCopy, changeCopy: false)
    }

    @Test("every verification-stage failure is incomplete and preserves originals",
          arguments: ["", "-wal", "-shm", "-journal"])
    func verificationFailure(suffix: String) throws {
        try exerciseLaunchFailure(suffix: suffix, phase: .beforeVerification, changeCopy: false)
    }

    @Test("changed copy bytes are rejected for every member, same-length when nonempty",
          arguments: ["", "-wal", "-shm", "-journal"])
    func changedCopyBytes(suffix: String) throws {
        try exerciseLaunchFailure(suffix: suffix, phase: .beforeVerification, changeCopy: true)
    }

    private func exerciseLaunchFailure(suffix: String, phase: DatabaseRecoveryBackup.Phase,
                                       changeCopy: Bool) throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("catalog.sqlite3")
        let expected = try writeMembers(database)
        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }
        var injected = false
        var captureLaunch = false
        var launchSnapshot: [(suffix: String, bytes: Data)]?
        let recovery = DatabaseRecoveryBackup(faultHook: { currentPhase, source, destination in
            // SQLite can truncate a bogus WAL and rewrite SHM before closing.
            // Measure the copy-only helper's boundary, before any copy/fault.
            if captureLaunch && currentPhase == .beforeCopy && launchSnapshot == nil {
                launchSnapshot = try snapshotMembers(database)
            }
            guard currentPhase == phase, source.path == database.path + suffix else { return }
            injected = true
            if changeCopy {
                var data = try Data(contentsOf: destination)
                let originalCount = data.count
                if !captureLaunch { try #require(!data.isEmpty) }
                if data.isEmpty {
                    data.append(0xff)
                } else {
                    data[data.startIndex] ^= 0xff
                    #expect(data.count == originalCount)
                }
                try data.write(to: destination)
            } else {
                throw NSError(domain: "ORB.BackupFaultFixture", code: 1)
            }
        })
        // First exercise the throwing helper directly, independent of SQLite's
        // own file-opening behavior. Incomplete copies must never return a URL.
        var rejected = false
        do { _ = try recovery.preserve(at: database) }
        catch let failure as DatabaseRecoveryBackup.IncompletePreservation {
            rejected = true
            #expect(failure.directory != nil)
        }
        #expect(rejected)
        #expect(injected)
        expectOriginals(database, expected: expected)

        injected = false
        captureLaunch = true
        do {
            let manager = DatabaseManager(path: database.path, recoveryBackup: recovery)
            let snapshot = try #require(launchSnapshot)
            let failure = try #require(manager.launchFailure)
            #expect(injected, "Startup must reach the selected preservation fault")
            #expect(failure.title == "Database Migration Failed")
            #expect(failure.backupPath == nil)
            #expect(failure.detail.lowercased().contains("backup incomplete"))
            #expect(!failure.detail.contains("were copied and byte-verified"))
            expectMemoryOnly(manager)
            expectOriginals(database, expected: snapshot)
            expectOriginals(database, expected: expected.filter { $0.suffix.isEmpty })
            #expect(manager.storageDirectoryURLs == [root.appendingPathComponent(".orb-database-backups", isDirectory: true)])
            manager.addFavorite("temporary/first-launch")
            #expect(manager.isFavorite("temporary/first-launch"))
        }
        // With the injected fault removed, the original corruption still forces
        // memory fallback. Successful copying never enables a new disk database.
        var reopenSnapshot: [(suffix: String, bytes: Data)]?
        let reopened = DatabaseManager(path: database.path, recoveryBackup: DatabaseRecoveryBackup(faultHook: { phase, _, _ in
            if phase == .beforeCopy && reopenSnapshot == nil {
                reopenSnapshot = try snapshotMembers(database)
            }
        }))
        let snapshot = try #require(reopenSnapshot)
        let failure = try #require(reopened.launchFailure)
        let backup = try #require(failure.backupPath)
        expectMemoryOnly(reopened)
        #expect(!reopened.isFavorite("temporary/first-launch"))
        expectOriginals(database, expected: snapshot)
        expectOriginals(database, expected: expected.filter { $0.suffix.isEmpty })
        expectCopies(backup, expected: snapshot)
    }

    @Test("all members are copied byte-for-byte into distinct exclusive directories")
    func successPreservesCompleteSet() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("catalog.sqlite3")
        let expected = try writeMembers(database)
        let recovery = DatabaseRecoveryBackup()
        let first = try recovery.preserve(at: database)
        let second = try recovery.preserve(at: database)
        #expect(first != second)
        let container = root.appendingPathComponent(".orb-database-backups", isDirectory: true)
        for copy in [first, second] {
            #expect(copy.deletingLastPathComponent().deletingLastPathComponent() == container)
            #expect(copy.deletingLastPathComponent().lastPathComponent.utf8.count == 12)
            let names = try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path)
            #expect(Set(names) == Set(suffixes.map { database.lastPathComponent + $0 }))
            expectCopies(copy.path, expected: expected)
        }
        expectOriginals(database, expected: expected)
    }

    @Test("near-NAME_MAX main and sidecars need no appended backup suffix")
    func longNamePreservesOriginalSetAcrossLaunches() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }
        let maximumNameLength = pathconf(root.path, _PC_NAME_MAX)
        try #require(maximumNameLength > 64)
        // The former timestamp-appending implementation fit the main but failed
        // on the sidecar destination. Every original member still fits here.
        let oldSuffix = ".corrupt-2000-01-01T00-00-00Z"
        let database = root.appendingPathComponent(String(repeating: "d", count: maximumNameLength - oldSuffix.utf8.count))
        let expected = try writeMembers(database)
        var launchSnapshot: [(suffix: String, bytes: Data)]?
        let recovery = DatabaseRecoveryBackup(faultHook: { phase, _, _ in
            // SQLite's own recovery precedes this post-close copy boundary.
            if phase == .beforeCopy && launchSnapshot == nil {
                launchSnapshot = try snapshotMembers(database)
            }
        })
        var firstBackup: String?
        do {
            let manager = DatabaseManager(path: database.path, recoveryBackup: recovery)
            let snapshot = try #require(launchSnapshot)
            let failure = try #require(manager.launchFailure)
            let backup = try #require(failure.backupPath)
            firstBackup = backup
            expectMemoryOnly(manager)
            expectOriginals(database, expected: snapshot)
            expectOriginals(database, expected: expected.filter { $0.suffix.isEmpty })
            expectCopies(backup, expected: snapshot)
            #expect(failure.detail.contains("copied and byte-verified"))
            #expect(failure.detail.contains("concurrent writer"))
            #expect(failure.detail.contains("power loss"))
            #expect(!failure.detail.contains("moved to"))
            manager.addFavorite("temporary/long-name")
            #expect(manager.isFavorite("temporary/long-name"))
        }
        let firstSnapshot = try #require(launchSnapshot)
        let firstCopy = try #require(firstBackup)
        launchSnapshot = nil
        let reopened = DatabaseManager(path: database.path, recoveryBackup: recovery)
        let snapshot = try #require(launchSnapshot)
        let secondCopy = try #require(reopened.launchFailure?.backupPath)
        #expect(secondCopy != firstCopy)
        expectMemoryOnly(reopened)
        #expect(!reopened.isFavorite("temporary/long-name"))
        expectOriginals(database, expected: snapshot)
        expectOriginals(database, expected: expected.filter { $0.suffix.isEmpty })
        expectCopies(secondCopy, expected: snapshot)
        expectCopies(firstCopy, expected: firstSnapshot)
    }

    @Test("changed source bytes are rejected rather than blessing a stale copy")
    func changedSource() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("catalog.sqlite3")
        _ = try writeMembers(database)
        let changed = Data("external writer changed WAL".utf8)
        let recovery = DatabaseRecoveryBackup(faultHook: { phase, source, _ in
            if phase == .beforeVerification && source.path == database.path + "-wal" {
                try changed.write(to: source)
            }
        })
        #expect(throws: DatabaseRecoveryBackup.IncompletePreservation.self) {
            try recovery.preserve(at: database)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: database.path + "-wal")) == changed)
    }

    @Test("main-only copies succeed but missing main and added sidecars fail closed")
    func inventoryValidation() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("catalog.sqlite3")
        let recovery = DatabaseRecoveryBackup()
        #expect(throws: DatabaseRecoveryBackup.IncompletePreservation.self) {
            try recovery.preserve(at: database)
        }
        let bytes = Data("not a database".utf8)
        try bytes.write(to: database)
        let copy = try recovery.preserve(at: database)
        #expect(try Data(contentsOf: copy) == bytes)
        let addingSidecar = DatabaseRecoveryBackup(faultHook: { phase, _, _ in
            if phase == .beforeVerification {
                try Data("new journal".utf8).write(to: URL(fileURLWithPath: database.path + "-journal"))
            }
        })
        #expect(throws: DatabaseRecoveryBackup.IncompletePreservation.self) {
            try addingSidecar.preserve(at: database)
        }
        #expect(try Data(contentsOf: database) == bytes)
    }

    @Test("memory-only databases reserve no filesystem storage")
    func memoryStorageDirectories() {
        let manager = DatabaseManager(path: ":memory:")
        #expect(manager.storageDirectoryURLs.isEmpty)
        #expect(manager.storageFileURLs.isEmpty)
    }

    private func fixtureRoot() throws -> URL {
        let fm = FileManager.default
        let scratch = ProcessInfo.processInfo.environment["TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fm.temporaryDirectory
        let root = scratch.appendingPathComponent("ORB-backup-failure-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeMembers(_ database: URL) throws -> [(suffix: String, bytes: Data)] {
        let members = suffixes.map { suffix in
            // A zero first byte makes this an explicitly non-hot journal;
            // SQLite's own rollback recovery is outside the copy-only helper.
            let prefix = suffix == "-journal" ? "\u{0000}" : ""
            return (suffix: suffix, bytes: Data((prefix + String(repeating: "not SQLite; original \(suffix) bytes\u{0000}\u{0001}\n", count: 8)).utf8))
        }
        for member in members {
            try member.bytes.write(to: URL(fileURLWithPath: database.path + member.suffix))
        }
        return members
    }

    private func snapshotMembers(_ database: URL) throws -> [(suffix: String, bytes: Data)] {
        // Read every fixture member, including empty files; never silently omit
        // a missing/unreadable sidecar from the expected preservation inventory.
        try suffixes.map { suffix in
            (suffix: suffix, bytes: try Data(contentsOf: URL(fileURLWithPath: database.path + suffix)))
        }
    }

    private func expectMemoryOnly(_ manager: DatabaseManager) {
        let filename = manager.db.flatMap { sqlite3_db_filename($0, "main") }
            .map { String(cString: $0) }
        #expect(filename == "", "Recovery must use memory, never the original disk path")
    }

    private func expectOriginals(_ database: URL, expected: [(suffix: String, bytes: Data)]) {
        for member in expected {
            #expect((try? Data(contentsOf: URL(fileURLWithPath: database.path + member.suffix))) == member.bytes,
                    "Original \(member.suffix) bytes must remain at their original path")
        }
    }

    private func expectCopies(_ path: String, expected: [(suffix: String, bytes: Data)]) {
        for member in expected {
            #expect((try? Data(contentsOf: URL(fileURLWithPath: path + member.suffix))) == member.bytes,
                    "A complete backup claim requires all \(member.suffix) bytes")
        }
    }
}
