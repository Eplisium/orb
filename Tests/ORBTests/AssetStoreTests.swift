import Foundation
import CryptoKit
import Testing
@testable import ORB

// W06 — AssetStore: atomic writes, checksum dedupe, and recoverable errors.

@Suite("Asset store")
struct AssetStoreTests {
    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-assets-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func allFiles(under root: URL) -> [String] {
        var results: [String] = []
        let basePath = root.path
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where !url.hasDirectoryPath {
                let path = url.path
                let relative = path.hasPrefix(basePath + "/") ? String(path.dropFirst(basePath.count + 1)) : path
                results.append(relative)
            }
        }
        return results.sorted()
    }

    @Test("store writes atomically, records a relative path, and round-trips")
    func storeWritesAtomicallyAndRoundTrips() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager()
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: database)

        let bytes = Data("orb asset payload \u{1F30A}".utf8)
        let record = try await store.store(bytes, mimeType: "image/png")

        // The path is relative to the base directory (no absolute prefix).
        #expect(!record.relativePath.hasPrefix("/"))
        #expect(!record.relativePath.contains(root.path))
        #expect(record.sizeBytes == bytes.count)
        #expect(record.checksum == Self.sha256Hex(bytes))
        #expect(record.mimeType == "image/png")

        // The file exists exactly where the record says, and no temporary
        // write file was left behind (write-to-temp + rename completed).
        let finalFile = root.appendingPathComponent("Assets").appendingPathComponent(record.relativePath)
        #expect(FileManager.default.fileExists(atPath: finalFile.path))
        let files = allFiles(under: root.appendingPathComponent("Assets"))
        #expect(files.contains { $0.hasSuffix(".tmp") } == false)
        #expect(files.count == 1)

        // Load-after-write round-trips byte for byte.
        #expect(try await store.data(for: record) == bytes)
        #expect(try await store.data(atRelativePath: record.relativePath) == bytes)
    }

    @Test("identical bytes dedupe to the same relative path and one record")
    func checksumDedupeReturnsSameRelativePath() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager()
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: database)

        let bytes = Data("dedupe me".utf8)
        let first = try await store.store(bytes)
        let second = try await store.store(bytes, mimeType: "application/octet-stream")

        #expect(first.relativePath == second.relativePath)
        #expect(first.id == second.id)
        #expect(database.loadAssetRecords().count == 1)
        #expect(allFiles(under: root.appendingPathComponent("Assets")).count == 1)

        // Different bytes get a different path.
        let other = try await store.store(Data("different".utf8))
        #expect(other.relativePath != first.relativePath)
    }

    @Test("the asset filename is derived from the checksum, never from content or secrets")
    func filenameHasNoSecrets() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(
            baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager()
        )
        let secretPrompt = Data("my secret video prompt api-key material".utf8)
        let record = try await store.store(secretPrompt)
        let checksum = Self.sha256Hex(secretPrompt)
        // Layout: <2 hex chars>/<64 hex chars> — the prompt bytes never
        // appear in the path.
        #expect(record.relativePath == "\(checksum.prefix(2))/\(checksum)")
    }

    @Test("a missing asset file surfaces a recoverable error, not a raw file error")
    func missingAssetIsRecoverable() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(
            baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager()
        )
        let record = try await store.store(Data("vanishing".utf8))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Assets").appendingPathComponent(record.relativePath)
        )
        do {
            _ = try await store.data(for: record)
            Issue.record("Expected a recoverable missing-asset error.")
        } catch let error as AssetStoreError {
            guard case .missing(let path) = error else {
                Issue.record("Expected .missing, got \(error)")
                return
            }
            #expect(path == record.relativePath)
        }
    }

    @Test("a corrupt asset file is detected by checksum and surfaces a recoverable error")
    func corruptAssetIsRecoverable() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(
            baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager()
        )
        let record = try await store.store(Data("original bytes".utf8))
        // Corrupt the file on disk behind the store's back.
        try Data("tampered".utf8).write(
            to: root.appendingPathComponent("Assets").appendingPathComponent(record.relativePath)
        )
        do {
            _ = try await store.data(for: record)
            Issue.record("Expected a recoverable corrupt-asset error.")
        } catch let error as AssetStoreError {
            guard case .corrupt(let path) = error else {
                Issue.record("Expected .corrupt, got \(error)")
                return
            }
            #expect(path == record.relativePath)
        }
    }

    @Test("a disk-full or unwritable base directory surfaces a recoverable storage failure")
    func unwritableBaseDirectoryIsRecoverable() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the asset base's parent directory should be: every
        // directory creation under it must fail (simulates disk-full/EACCES).
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = AssetStore(
            baseDirectory: blocker.appendingPathComponent("Assets"), database: DatabaseManager()
        )
        do {
            _ = try await store.store(Data([0x01, 0x02, 0x03]))
            Issue.record("Expected storage to fail recoverably.")
        } catch let error as AssetStoreError {
            guard case .storageFailure = error else {
                Issue.record("Expected .storageFailure, got \(error)")
                return
            }
        }
    }

    @Test("asset metadata round-trips through the database")
    func metadataRoundTripsThroughDatabase() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager()
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: database)

        let jobID = UUID()
        let record = try await store.store(
            Data("metadata".utf8),
            mimeType: "video/mp4",
            remoteReference: "video-job-1",
            jobID: jobID
        )
        let loaded = try #require(database.findAssetRecord(checksum: record.checksum))
        #expect(loaded.id == record.id)
        #expect(loaded.remoteReference == "video-job-1")
        #expect(loaded.jobID == jobID)
        #expect(loaded.mimeType == "video/mp4")
        #expect(loaded.retention == .keep)
        #expect(database.loadAssetRecords().count == 1)
    }
}
