import Foundation
import Testing
@testable import ORB

@Suite("Video save link failures", .serialized)
@MainActor
struct VideoSaveLinkFailureTests {
    @Test("Legacy creation JSON without recovery identity remains readable")
    func legacyCreationDecodes() throws {
        let original = SavedCreation(id: UUID(), kind: .video, modelID: "fixture/model", mimeType: "video/mp4",
                                     createdAt: Date(timeIntervalSince1970: 1), assetPath: "aa/fixture.mp4", checksum: "fixture")
        let data = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["videoRemoteID"] == nil)
        #expect(try JSONDecoder().decode(SavedCreation.self, from: data) == original)
    }

    @Test("A rejected job link does not download or index the saved video again after reopening")
    func rejectedLinkReusesCommittedCreation() async throws {
        let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let root = temporary.appendingPathComponent("ORB-video-link-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: root.appendingPathComponent("jobs.sqlite3").path)
        let controller = JobController(database: db)
        let remoteID = "video-fixture"
        controller.recordVideoSubmission(remoteID: remoteID, modelID: "fixture/model", remoteStatus: "completed", prompt: "fixture prompt")
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let index = root.appendingPathComponent("creations.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let transport = VideoLinkFixtureTransport(root: root)
        let service = VideoGenService(transport: transport, jobController: controller)
        try db.execChecked("CREATE TRIGGER deny_video_link BEFORE UPDATE OF saved_creation_id ON jobs WHEN NEW.saved_creation_id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'injected link failure'); END;")

        let first = try await service.downloadAndSave(remoteID: remoteID, store: store)
        #expect(controller.lastPersistenceError != nil)
        #expect(try db.findJobRecordChecked(remoteID: remoteID)?.savedCreationID == nil)
        #expect(controller.record(remoteID: remoteID)?.savedCreationID == first.id)
        #expect(controller.unsavedRecordCount == 1)
        #expect(try await store.data(for: first) == transport.bytes)
        let repeated = try await service.downloadAndSave(remoteID: remoteID, store: store)
        #expect(repeated.id == first.id)
        #expect(transport.downloadCount == 1)
        #expect(store.creations.count == 1)

        let reopenedDB = DatabaseManager(path: root.appendingPathComponent("jobs.sqlite3").path)
        let reopenedController = JobController(database: reopenedDB)
        let reopenedAssets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: reopenedDB)
        let reopenedStore = try SavedCreationsStore(assetStore: reopenedAssets, indexURL: index)
        let reopenedService = VideoGenService(transport: transport, jobController: reopenedController)
        let stillUnlinked = try await reopenedService.downloadAndSave(remoteID: remoteID, store: reopenedStore)
        #expect(stillUnlinked.id == first.id)
        #expect(transport.downloadCount == 1)
        #expect(reopenedController.lastPersistenceError != nil)
        #expect(try reopenedDB.findJobRecordChecked(remoteID: remoteID)?.savedCreationID == nil)
        #expect(reopenedController.record(remoteID: remoteID)?.savedCreationID == first.id)
        #expect(reopenedController.unsavedRecordCount == 1)
        try db.execChecked("DROP TRIGGER deny_video_link;")
        let recovered = try await reopenedService.downloadAndSave(remoteID: remoteID, store: reopenedStore)
        #expect(recovered.id == first.id)
        #expect(reopenedStore.creations.count == 1)
        #expect(transport.downloadCount == 1)
        #expect(reopenedController.record(remoteID: remoteID)?.savedCreationID == first.id)
        #expect(reopenedController.lastPersistenceError == nil)
        #expect(reopenedController.unsavedRecordCount == 0)
        #expect(try reopenedDB.findJobRecordChecked(remoteID: remoteID)?.savedCreationID == first.id)
    }
}

private final class VideoLinkFixtureTransport: MediaTransport, @unchecked Sendable {
    let root: URL
    let bytes = Data("offline video fixture".utf8)
    private let lock = NSLock()
    private var count = 0
    var downloadCount: Int { lock.withLock { count } }

    init(root: URL) {
        self.root = root
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "fixture" })
    }

    override func downloadToFile(_ request: URLRequest) async throws -> (URL, String?) {
        lock.withLock { count += 1 }
        let file = root.appendingPathComponent("download-\(UUID()).mp4")
        try bytes.write(to: file)
        return (file, "video/mp4")
    }
}
