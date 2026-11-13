import Foundation
import Testing
@testable import ORB

/// Offline regressions for backend audit B06/B14/B15/B19/B20.
/// Job/asset persistence is explicitly in-memory. VideoGenService currently
/// hardcodes UsageLedger.shared; only that ledger uses SwiftPM's test-isolated
/// DatabaseManager.shared. UUID model IDs isolate assertions from parallel tests.
@Suite("Media backend fixes")
@MainActor
struct MediaBackendFixTests {
    private func fixtureRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermes/cache/scratch/ORB-media-fixes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func videoService(_ transport: MediaTransport, _ controller: JobController) -> VideoGenService {
        VideoGenService(transport: transport, jobController: controller,
                        retryPolicy: PollRetryPolicy(maxConsecutiveFailures: 0,
                                                     baseDelay: .milliseconds(1), maxDelay: .milliseconds(1)))
    }

    private func usage(for model: String) -> UsageBucket? {
        UsageLedger.shared.buckets(.model).first { $0.key == model }
    }

    @Test("B06: metadata rejection preserves the streamed input file")
    func b06MetadataFailurePreservesSource() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: ":memory:")
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        try db.execChecked("CREATE TRIGGER deny_asset_insert BEFORE INSERT ON assets BEGIN SELECT RAISE(ABORT, 'injected metadata failure'); END;")
        let source = root.appendingPathComponent("download.mp4")
        let bytes = Data("paid video bytes".utf8)
        try bytes.write(to: source)

        await #expect(throws: (any Error).self) {
            _ = try await assets.store(fileAt: source, mimeType: "video/mp4")
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect((try? Data(contentsOf: source)) == bytes)
    }

    @Test("B06: creation rejection preserves input, including deduped assets", arguments: [false, true])
    func b06ManifestFailurePreservesSource(deduplicated: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: ":memory:")
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let index = root.appendingPathComponent("creations.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let source = root.appendingPathComponent("download.mp4")
        let bytes = Data("paid video bytes".utf8)
        if deduplicated { _ = try await assets.store(bytes, mimeType: "video/mp4") }
        try bytes.write(to: source)
        // A failed authoritative creation transaction must not consume paid input.
        try db.execChecked("CREATE TRIGGER deny_library_creation BEFORE INSERT ON library_creations BEGIN SELECT RAISE(ABORT, 'injected creation failure'); END;")

        await #expect(throws: (any Error).self) {
            _ = try await store.save(fileAt: source, mimeType: "video/mp4", kind: .video,
                                     modelID: "fixture/model", prompt: nil)
        }
        #expect(store.creations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect((try? Data(contentsOf: source)) == bytes)
    }

    @Test("B06: video save failure does not delete the retained download")
    func b06VideoSaveFailurePreservesDownload() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: ":memory:")
        let controller = JobController(database: db)
        let remoteID = "video-\(UUID().uuidString)"
        controller.recordVideoSubmission(remoteID: remoteID, modelID: "fixture/model", remoteStatus: "completed")
        let source = root.appendingPathComponent("download.mp4")
        let bytes = Data("paid video bytes".utf8)
        try bytes.write(to: source)
        let transport = MediaBackendDownloadedFileTransport(file: source)
        let service = videoService(transport, controller)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let index = root.appendingPathComponent("creations.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        try db.execChecked("CREATE TRIGGER deny_library_creation BEFORE INSERT ON library_creations BEGIN SELECT RAISE(ABORT, 'injected creation failure'); END;")

        await #expect(throws: (any Error).self) {
            _ = try await service.downloadAndSave(remoteID: remoteID, store: store)
        }
        #expect((try? Data(contentsOf: source)) == bytes)
        #expect(store.creations.isEmpty)
        #expect(controller.record(remoteID: remoteID)?.savedCreationID == nil)
        #expect(service.downloadingRemoteIDs.isEmpty)
        #expect(service.retainedDownloads[remoteID]?.file == source)

        // Retry the retained bytes, not a second remote download.
        try db.execChecked("DROP TRIGGER deny_library_creation;")
        let saved = try await service.downloadAndSave(remoteID: remoteID, store: store)
        #expect(transport.downloadCount == 1)
        #expect(service.retainedDownloads[remoteID] == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await store.data(for: saved) == bytes)
        #expect(controller.record(remoteID: remoteID)?.savedCreationID == saved.id)
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        #expect(reopened.creations == [saved])
    }

    @Test("B06: JSON export failure is a saved video, not another paid download")
    func b06VideoExportWarningDoesNotDuplicate() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = DatabaseManager(path: ":memory:")
        let controller = JobController(database: db)
        let remoteID = "video-\(UUID())"
        controller.recordVideoSubmission(remoteID: remoteID, modelID: "fixture/model", remoteStatus: "completed")
        let source = root.appendingPathComponent("download.mp4")
        let bytes = Data("paid output with failed export".utf8)
        try bytes.write(to: source)
        let transport = MediaBackendDownloadedFileTransport(file: source)
        let service = videoService(transport, controller)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        let index = root.appendingPathComponent("creations.json")
        let store = try SavedCreationsStore(assetStore: assets, indexURL: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let saved = try await service.downloadAndSave(remoteID: remoteID, store: store)
        #expect(store.exportWarning != nil)
        #expect(store.creations == [saved])
        #expect(controller.record(remoteID: remoteID)?.savedCreationID == saved.id)
        #expect(service.retainedDownloads[remoteID] == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let reopened = try SavedCreationsStore(assetStore: assets, indexURL: index)
        let again = try await service.downloadAndSave(remoteID: remoteID, store: reopened)
        #expect(again == saved)
        #expect(transport.downloadCount == 1)
        #expect(try await reopened.data(for: saved) == bytes)
    }

    @Test("B06: consuming an existing library path never deletes the stored asset")
    func b06LibrarySourceIsNotDeleted() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"),
                                database: DatabaseManager(path: ":memory:"))
        let bytes = Data("already saved bytes".utf8)
        let asset = try await assets.store(bytes, mimeType: "video/mp4")
        let source = try assets.fileURL(forRelativePath: asset.relativePath)
        _ = try await assets.store(fileAt: source, mimeType: "video/mp4")
        #expect((try? Data(contentsOf: source)) == bytes)
        let store = try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json"))
        let saved = try await store.save(fileAt: source, mimeType: "video/mp4", kind: .video,
                                         modelID: "fixture/model", prompt: nil)
        #expect(try await store.data(for: saved) == bytes)
    }

    @Test("B14: unconfirmed or wrong-target deletion preserves the local file", arguments: [
        #"{"id":"file-A","deleted":false}"#,
        #"{"id":"file-A"}"#,
        #"{"id":"file-B","deleted":true}"#,
        #"{"id":"file-A","type":"file_deleted","deleted":false}"#,
        #"{"id":"file-B","type":"file_deleted"}"#
    ])
    func b14RejectsNegativeDelete(body: String) async throws {
        let transport = MockMediaTransport(responses: [.json(body)])
        let service = FileService(transport: transport)
        service.files = [WorkspaceFile(id: "file-A", filename: "a.txt", mimeType: "text/plain",
                                       sizeBytes: 1, createdAt: nil, downloadable: false)]
        await #expect(throws: (any Error).self) {
            _ = try await service.delete(id: "file-A", confirming: true)
        }
        #expect(service.files.map(\.id) == ["file-A"])
        #expect(transport.sentRequests().map(\.httpMethod) == ["DELETE"])
    }

    @Test("B15: a replacement view awaits its catalog despite old-view cancellation", arguments: ["image", "video"])
    func b15CancelledCatalogCallerDoesNotStarveReplacement(kind: String) async throws {
        let transport = MediaBackendHeldCatalogTransport(kind: kind)
        let images = ImageGenService(transport: transport)
        let videos = videoService(transport, JobController(database: DatabaseManager(path: ":memory:")))
        let fetch: @MainActor () async -> Void = {
            if kind == "image" { await images.fetchModels() }
            else { await videos.fetchModels() }
        }
        let first = Task { await fetch() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await transport.gate.isWaiting), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let waiting = await transport.gate.isWaiting
        guard waiting else {
            first.cancel()
            await transport.gate.release()
            await first.value
            Issue.record("Catalog fixture never reached its gate")
            return
        }
        first.cancel()
        var secondBegan = false
        let second = Task { @MainActor in
            secondBegan = true
            await fetch()
            return kind == "image" ? images.models.map(\.id) : videos.models.map(\.id)
        }
        while !secondBegan { await Task.yield() }
        await transport.gate.release()
        await first.value
        let received = await second.value
        #expect(received == ["\(kind)/mock"])
        #expect(!images.isLoadingModels && !videos.isLoadingModels)
    }

    @Test("B19: a poll cannot publish, persist, charge, or follow another job", arguments: ["queued", "completed"])
    func b19RejectsWrongPollIdentity(wrongStatus: String) async throws {
        let db = DatabaseManager(path: ":memory:")
        let controller = JobController(database: db)
        let a = "A-\(UUID().uuidString)"
        let b = "B-\(UUID().uuidString)"
        let model = "identity/\(UUID().uuidString)"
        controller.recordVideoSubmission(remoteID: a, modelID: model, remoteStatus: "queued")
        controller.recordVideoSubmission(remoteID: b, modelID: model, remoteStatus: "queued", cost: 0.125)
        let originalB = try #require(controller.record(remoteID: b))
        let recordA = try #require(controller.record(remoteID: a))
        let transport = MockMediaTransport(responses: [
            .json("{\"id\":\"\(b)\",\"status\":\"\(wrongStatus)\",\"polling_url\":\"/api/v1/videos/\(b)\",\"usage\":{\"cost\":0.75}}"),
            .json("{\"id\":\"\(b)\",\"status\":\"completed\",\"usage\":{\"cost\":0.75}}")
        ])
        let service = videoService(transport, controller)
        let updates = JobUpdateCollector()
        await #expect(throws: (any Error).self) {
            _ = try await service.resume(recordA, pollInterval: .milliseconds(1), onUpdate: { updates.append($0) })
        }
        #expect(transport.sentRequests().map { $0.url?.path } == ["/api/v1/videos/\(a)"])
        #expect(transport.submissions().isEmpty)
        #expect(updates.all.allSatisfy { $0.id == a && !$0.isTerminal })
        #expect(service.activeJob?.id == a)
        #expect(controller.record(remoteID: b) == originalB)
        #expect(controller.record(remoteID: a)?.pollingState == .stoppedLocally)
        #expect(controller.record(remoteID: a)?.recoverableError != nil)
        #expect(usage(for: model) == nil)
        #expect(!service.isPolling)
    }

    @Test("B20: sparse terminal polls retain the latest reported price", arguments: ["completed", "failed"])
    func b20SparsePollRetainsCost(status: String) async throws {
        let controller = JobController(database: DatabaseManager(path: ":memory:"))
        let id = "sparse-\(UUID().uuidString)"
        let model = "sparse/\(UUID().uuidString)"
        let transport = MockMediaTransport(responses: [
            .json("{\"id\":\"\(id)\",\"status\":\"queued\",\"usage\":{\"cost\":0.125}}"),
            .json("{\"id\":\"\(id)\",\"status\":\"running\",\"usage\":{\"cost\":0.25}}"),
            .json("{\"id\":\"\(id)\",\"status\":\"\(status)\"}")
        ])
        let service = videoService(transport, controller)
        let updates = JobUpdateCollector()
        do {
            let result = try await service.submitAndPoll(.init(model: model, prompt: "fixture"),
                pollInterval: .milliseconds(1), onUpdate: { updates.append($0) })
            #expect(status == "completed")
            #expect(result.cost == 0.25)
        } catch let failure as VideoJobFailure {
            #expect(status == "failed")
            #expect(failure.status == status)
        }
        #expect(updates.all.last?.cost == 0.25)
        #expect(service.activeJob?.cost == 0.25)
        #expect(controller.record(remoteID: id)?.usageCost == 0.25)
        #expect(controller.record(remoteID: id)?.pollingState == JobPollingState(remoteStatus: status))
        let bucket = usage(for: model)
        #expect(bucket?.cost == 0.25)
        #expect(bucket?.requests == 1)
        #expect(bucket?.unpricedRequests == 0)
        #expect(transport.submissions().count == 1)
    }

    @Test("B20: resumed sparse completion/failure inherits durable cost, including zero",
          arguments: ["completed", "failed"], [0.25, 0.0])
    func b20ResumeRetainsDurableCost(status: String, retainedCost: Double) async throws {
        let db = DatabaseManager(path: ":memory:")
        let original = JobController(database: db)
        let id = "resume-\(UUID().uuidString)"
        let model = "resume/\(UUID().uuidString)"
        original.recordVideoSubmission(remoteID: id, modelID: model, remoteStatus: "running", cost: retainedCost)
        original.recordStoppedLocally(remoteID: id)
        // New controller/service: the only available cost is persisted SQLite state.
        let reopened = JobController(database: db)
        let record = try #require(reopened.record(remoteID: id))
        let transport = MockMediaTransport(responses: [.json("{\"id\":\"\(id)\",\"status\":\"\(status)\"}")])
        let service = videoService(transport, reopened)
        let updates = JobUpdateCollector()
        do {
            let result = try await service.resume(record, pollInterval: .milliseconds(1), onUpdate: { updates.append($0) })
            #expect(status == "completed")
            #expect(result.cost == retainedCost)
        } catch let failure as VideoJobFailure {
            #expect(status == "failed")
            #expect(failure.status == status)
        }
        #expect(updates.all.first?.cost == retainedCost)
        #expect(updates.all.last?.cost == retainedCost)
        #expect(reopened.record(remoteID: id)?.usageCost == retainedCost)
        #expect(reopened.record(remoteID: id)?.pollingState == JobPollingState(remoteStatus: status))
        let bucket = usage(for: model)
        #expect(bucket?.cost == retainedCost)
        #expect(bucket?.requests == 1)
        #expect(bucket?.unpricedRequests == 0)
        #expect(transport.submissions().isEmpty)
        #expect(transport.sentCount() == 1)
    }

    @Test("B20 guard: explicit zero overrides a prior price")
    func b20ExplicitZeroOverridesCost() async throws {
        let controller = JobController(database: DatabaseManager(path: ":memory:"))
        let id = "zero-\(UUID().uuidString)"
        let model = "zero/\(UUID().uuidString)"
        controller.recordVideoSubmission(remoteID: id, modelID: model, remoteStatus: "queued", cost: 0.25)
        let record = try #require(controller.record(remoteID: id))
        let transport = MockMediaTransport(responses: [.json("{\"id\":\"\(id)\",\"status\":\"completed\",\"usage\":{\"cost\":0}}")])
        let service = videoService(transport, controller)
        let result = try await service.resume(record, pollInterval: .milliseconds(1))
        #expect(result.cost == 0)
        #expect(controller.record(remoteID: id)?.usageCost == 0)
        #expect(usage(for: model)?.cost == 0)
        #expect(usage(for: model)?.unpricedRequests == 0)
        #expect(usage(for: model)?.requests == 1)
    }

    @Test("B20 guard: never-reported cost stays unknown, not zero")
    func b20AbsentCostRemainsUnknown() async throws {
        let controller = JobController(database: DatabaseManager(path: ":memory:"))
        let id = "unknown-\(UUID().uuidString)"
        let model = "unknown/\(UUID().uuidString)"
        controller.recordVideoSubmission(remoteID: id, modelID: model, remoteStatus: "queued")
        let record = try #require(controller.record(remoteID: id))
        let transport = MockMediaTransport(responses: [.json("{\"id\":\"\(id)\",\"status\":\"completed\"}")])
        let service = videoService(transport, controller)
        let result = try await service.resume(record, pollInterval: .milliseconds(1))
        #expect(result.cost == nil)
        #expect(controller.record(remoteID: id)?.usageCost == nil)
        #expect(usage(for: model)?.unpricedRequests == 1)
        #expect(usage(for: model)?.requests == 1)
    }
}

private actor MediaBackendCatalogGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var isWaiting: Bool { !continuations.isEmpty }

    func pause() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private final class MediaBackendHeldCatalogTransport: MediaTransport, @unchecked Sendable {
    let gate = MediaBackendCatalogGate()
    private let kind: String

    init(kind: String) {
        self.kind = kind
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "test-key" })
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        await gate.pause()
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: Data("{\"data\":[{\"id\":\"\(kind)/mock\",\"name\":\"Mock\"}]}".utf8))
    }
}

private final class MediaBackendDownloadedFileTransport: MediaTransport, @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var downloads = 0
    var downloadCount: Int { lock.withLock { downloads } }

    init(file: URL) {
        self.file = file
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "test-key" })
    }

    override func downloadToFile(_ request: URLRequest) async throws -> (URL, String?) {
        lock.withLock { downloads += 1 }
        return (file, "video/mp4")
    }
}
