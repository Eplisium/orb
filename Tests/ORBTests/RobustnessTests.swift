import Foundation
import Testing
@testable import ORB

@Suite("Network timeouts", .serialized)
struct NetworkTimeoutsTests {
    private let savedFetch = NetworkTimeouts.fetch
    private let savedRequest = NetworkTimeouts.request

    private func restore() {
        NetworkTimeouts.fetch = savedFetch
        NetworkTimeouts.request = savedRequest
    }

    @Test("defaults are returned when nothing is stored")
    func defaultsWhenUnset() {
        NetworkTimeouts.resetToDefaults()
        #expect(NetworkTimeouts.fetch == NetworkTimeouts.defaultFetch)
        #expect(NetworkTimeouts.request == NetworkTimeouts.defaultRequest)
        restore()
    }

    @Test("values are clamped into the supported range")
    func clamping() {
        NetworkTimeouts.fetch = 0.5
        #expect(NetworkTimeouts.fetch == NetworkTimeouts.minFetch)
        NetworkTimeouts.fetch = 10_000
        #expect(NetworkTimeouts.fetch == NetworkTimeouts.maxFetch)
        NetworkTimeouts.request = 1
        #expect(NetworkTimeouts.request == NetworkTimeouts.minRequest)
        NetworkTimeouts.request = 99_999
        #expect(NetworkTimeouts.request == NetworkTimeouts.maxRequest)
        restore()
    }

    @Test("in-range values persist across reads")
    func persistenceRoundTrip() {
        NetworkTimeouts.fetch = 45
        NetworkTimeouts.request = 240
        #expect(NetworkTimeouts.fetch == 45)
        #expect(NetworkTimeouts.request == 240)
        restore()
    }
}

@Suite("Database recovery", .serialized)
struct DatabaseRecoveryTests {
    @Test("a corrupt database file degrades to in-memory instead of crashing")
    func corruptDatabaseFallsBackToInMemory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-corrupt-\(UUID().uuidString).sqlite3")
        try Data("this is definitely not a sqlite database".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }

        let manager = DatabaseManager(path: url.path)

        // The manager is fully functional on the in-memory fallback…
        let modelID = "test/recovery-\(UUID().uuidString)"
        manager.addFavorite(modelID)
        #expect(manager.isFavorite(modelID))

        // …and the failure was surfaced, with the corrupt file backed up.
        let failure = try #require(DatabaseManager.lastLaunchFailure)
        #expect(failure.backupPath != nil)
        let backup = try #require(failure.backupPath)
        #expect(FileManager.default.fileExists(atPath: backup))
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        try? FileManager.default.removeItem(atPath: backup)
    }

    @Test("a healthy database produces no launch failure")
    func healthyDatabaseHasNoFailure() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-healthy-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let savedFailure = DatabaseManager.lastLaunchFailure
        defer { DatabaseManager.lastLaunchFailure = savedFailure }

        _ = DatabaseManager(path: url.path)
        #expect(DatabaseManager.lastLaunchFailure == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
