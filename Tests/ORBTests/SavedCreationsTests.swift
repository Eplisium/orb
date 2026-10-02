import Foundation
import Testing
@testable import ORB

@Suite("Saved creations")
@MainActor
struct SavedCreationsTests {
    private func fixture() throws -> (URL, AssetStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-creations-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager()), root.appendingPathComponent("creations.json"))
    }

    @Test("save, reopen, list and read bytes with durable metadata")
    func reopens() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let bytes = Data([0, 1, 255, 42])
        let first = try await store.save(bytes, mimeType: "image/png", kind: .image, modelID: "vendor/model", prompt: "draw this")
        #expect(store.creations.map(\.id) == [first.id])
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(reopened.creations == [first])
        #expect(try await reopened.data(for: first) == bytes)
        let raw = try String(contentsOf: index, encoding: .utf8)
        #expect(!raw.contains("AAH/Kg=="))
        #expect(first.assetPath.hasPrefix(String(first.checksum.prefix(2)) + "/"))
    }

    @Test("concurrent saves retain every creation")
    func concurrentSaves() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for number in 0..<20 {
                group.addTask {
                    let creation = try await store.save(Data("item-\(number)".utf8),
                        mimeType: "text/plain", kind: .transcript, modelID: "test", prompt: nil)
                    return creation.id
                }
            }
            var ids: Set<UUID> = []
            for try await id in group { ids.insert(id) }
            return ids
        }
        #expect(ids.count == 20)
        #expect(store.creations.count == ids.count)
        #expect(Set(try SavedCreationsStore(assetStore: assets, indexURL: index).creations.map(\.id)) == ids)
    }

    @Test("same bytes reuse one asset but preserve distinct creations")
    func deduplicatesBytes() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let bytes = Data("same media".utf8)
        let a = try await store.save(bytes, mimeType: "audio/mpeg", kind: .audio, modelID: "one", prompt: nil)
        let b = try await store.save(bytes, mimeType: "audio/mpeg", kind: .audio, modelID: "two", prompt: "voice")
        #expect(a.id != b.id)
        #expect(a.assetPath == b.assetPath)
        #expect(a.checksum == b.checksum)
        #expect(store.creations.count == 2)
        #expect(try await store.data(for: b) == bytes)
    }

    @Test("invalid manifest is reported and never replaced")
    func invalidManifest() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = Data("{ broken".utf8)
        try invalid.write(to: index)
        #expect(throws: Error.self) { try SavedCreationsStore(assetStore: assets, indexURL: index) }
        #expect(try Data(contentsOf: index) == invalid)
    }

    @Test("failed manifest write leaves published and persisted prior entries intact")
    func failedWrite() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let first = try await store.save(Data("first".utf8), mimeType: "text/plain", kind: .transcript, modelID: "a", prompt: nil)
        let original = try Data(contentsOf: index)
        // A directory at the manifest path makes atomic replacement fail on all users (including root).
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        await #expect(throws: Error.self) {
            try await store.save(Data("second".utf8), mimeType: "text/plain", kind: .transcript, modelID: "b", prompt: nil)
        }
        #expect(store.creations == [first])
        try FileManager.default.removeItem(at: index)
        try original.write(to: index)
        #expect(try SavedCreationsStore(assetStore: assets, indexURL: index).creations == [first])
    }

    @Test("tampered bytes are rejected by checksum")
    func corruptBytes() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let item = try await store.save(Data("original".utf8), mimeType: "video/mp4", kind: .video, modelID: "a", prompt: nil)
        try Data("corrupt".utf8).write(to: assets.baseDirectory.appendingPathComponent(item.assetPath))
        await #expect(throws: AssetStoreError.self) { try await store.data(for: item) }
    }

    @Test("symlinked asset shard cannot escape the library")
    func symlinkEscape() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let item = try await store.save(Data("linked".utf8), mimeType: "image/png", kind: .image, modelID: "a", prompt: nil)
        let shard = assets.baseDirectory.appendingPathComponent(String(item.checksum.prefix(2)))
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.moveItem(at: shard, to: outside)
        try FileManager.default.createSymbolicLink(at: shard, withDestinationURL: outside)
        await #expect(throws: AssetStoreError.self) { try await store.data(for: item) }
    }

    @Test("untrusted paths in persisted metadata are rejected")
    func untrustedPath() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let item = try await store.save(Data("safe".utf8), mimeType: "image/png", kind: .image, modelID: "a", prompt: nil)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var entries = try #require(json["creations"] as? [[String: Any]])
        entries[0]["assetPath"] = "../../private"
        json["creations"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: index)
        #expect(throws: Error.self) { try SavedCreationsStore(assetStore: assets, indexURL: index) }
        var forged = item
        forged.assetPath = "../../private"
        await #expect(throws: AssetStoreError.self) { try await store.data(for: forged) }
    }
}

@Suite("Saved creations: delete")
@MainActor
struct SavedCreationsDeleteTests {
    private func fixture() throws -> (URL, AssetStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-del-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager()), root.appendingPathComponent("creations.json"))
    }

    @Test("remove updates the index, restore brings it back in order, purge deletes bytes")
    func lifecycle() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let a = try await store.save(Data("one".utf8), mimeType: "text/plain", kind: .transcript, modelID: "m", prompt: nil)
        let b = try await store.save(Data("two".utf8), mimeType: "text/plain", kind: .transcript, modelID: "m", prompt: nil)

        let removed = try await store.remove(ids: [a.id])
        #expect(removed == [a])
        #expect(store.creations.map(\.id) == [b.id])
        #expect(try SavedCreationsStore(assetStore: assets, indexURL: index).creations.map(\.id) == [b.id])
        // Bytes survive until purge so Undo is lossless.
        #expect(try await assets.data(atRelativePath: a.assetPath) == Data("one".utf8))

        try await store.restore(removed)
        let dates = store.creations.map(\.createdAt)
        #expect(dates == dates.sorted(by: >))
        #expect(Set(store.creations.map(\.id)) == [a.id, b.id])

        let again = try await store.remove(ids: [a.id])
        await store.purgeUnreferenced(again)
        await #expect(throws: AssetStoreError.self) { _ = try await assets.data(atRelativePath: a.assetPath) }
        #expect(try await assets.data(atRelativePath: b.assetPath) == Data("two".utf8))
    }

    @Test("purge keeps bytes still used by another creation")
    func sharedBytes() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let bytes = Data("shared".utf8)
        let a = try await store.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "one", prompt: nil)
        let b = try await store.save(bytes, mimeType: "text/plain", kind: .transcript, modelID: "two", prompt: nil)
        let removed = try await store.remove(ids: [a.id])
        await store.purgeUnreferenced(removed)
        #expect(try await assets.data(atRelativePath: b.assetPath) == bytes)
    }

    @Test("removing nothing is a no-op")
    func noop() async throws {
        let (root, assets, index) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(try await store.remove(ids: [UUID()]).isEmpty)
    }
}
