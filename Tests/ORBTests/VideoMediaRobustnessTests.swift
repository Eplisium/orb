import Foundation
import Testing
@testable import ORB

/// Scripted transport keyed by request path. Each path has its own queue of
/// outcomes so concurrent polls of different jobs are independent. Never
/// touches the network or the Keychain.
final class ScriptedVideoTransport: MediaTransport, @unchecked Sendable {
    enum Outcome: Sendable {
        case json(String)
        case urlError(URLError.Code)
        case http(Int)
        case hang
    }

    private let lock = NSLock()
    private var scripts: [String: [Outcome]]
    private var counts: [String: Int] = [:]
    private var downloadBytes: Data
    private var downloadMIME: String?
    private(set) var downloadCount = 0

    init(scripts: [String: [Outcome]], downloadBytes: Data = Data(), downloadMIME: String? = "video/mp4") {
        self.scripts = scripts
        self.downloadBytes = downloadBytes
        self.downloadMIME = downloadMIME
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "test-key" })
    }

    func requestCount(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path, default: 0]
    }

    private func next(for path: String) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        counts[path, default: 0] += 1
        guard var queue = scripts[path], !queue.isEmpty else { return .hang }
        let first = queue.removeFirst()
        scripts[path] = queue
        return first
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        switch next(for: request.url?.path ?? "") {
        case .json(let body):
            return try JSONDecoder().decode(T.self, from: Data(body.utf8))
        case .urlError(let code):
            throw MediaServiceError.transport(URLError(code).localizedDescription)
        case .http(let status):
            throw MediaServiceError.http(status: status, message: "scripted \(status)")
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw MediaServiceError.transport("hang not cancelled")
        }
    }

    override func downloadToFile(_ request: URLRequest) async throws -> (URL, String?) {
        let (bytes, mime): (Data, String?) = {
            lock.lock(); defer { lock.unlock() }
            downloadCount += 1
            return (downloadBytes, downloadMIME)
        }()
        // Give concurrent callers a chance to overlap.
        try await Task.sleep(for: .milliseconds(20))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-test-dl-\(UUID())")
        try bytes.write(to: url)
        return (url, mime)
    }
}

private let fastRetry = PollRetryPolicy(maxConsecutiveFailures: 5, baseDelay: .milliseconds(1), maxDelay: .milliseconds(4))

@Suite("Video poll retry (transient failures)", .serialized)
@MainActor
struct VideoPollRetryTests {
    @Test("backoff doubles and is capped")
    func backoffCapped() {
        let policy = PollRetryPolicy(maxConsecutiveFailures: 5, baseDelay: .seconds(2), maxDelay: .seconds(30))
        #expect(policy.delay(forAttempt: 1) == .seconds(2))
        #expect(policy.delay(forAttempt: 2) == .seconds(4))
        #expect(policy.delay(forAttempt: 4) == .seconds(16))
        #expect(policy.delay(forAttempt: 5) == .seconds(30))
        #expect(policy.delay(forAttempt: 50) == .seconds(30))
    }

    @Test("transient classification: network, 5xx, 429 retry; 4xx and decoding do not")
    func transientClassification() {
        #expect(MediaServiceError.transport("offline").isTransient)
        #expect(MediaServiceError.http(status: 503, message: "").isTransient)
        #expect(MediaServiceError.http(status: 429, message: "").isTransient)
        #expect(!MediaServiceError.http(status: 401, message: "").isTransient)
        #expect(!MediaServiceError.http(status: 404, message: "").isTransient)
        #expect(!MediaServiceError.decoding("x").isTransient)
        #expect(!MediaServiceError.untrustedURL("x").isTransient)
    }

    @Test("a few transient poll failures are retried and the job still completes")
    func transientFailuresRecover() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = ScriptedVideoTransport(scripts: [
            "/api/v1/videos": [.json(#"{"id":"job-r","status":"queued"}"#)],
            "/api/v1/videos/job-r": [
                .urlError(.notConnectedToInternet), .http(502), .http(429),
                .json(#"{"id":"job-r","status":"in_progress"}"#),
                .urlError(.timedOut),
                .json(#"{"id":"job-r","status":"completed"}"#)
            ]
        ])
        let service = VideoGenService(transport: transport, jobController: controller, retryPolicy: fastRetry)
        let finished = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: "p"), pollInterval: .milliseconds(1))
        #expect(finished.isSuccess)
        #expect(transport.requestCount(path: "/api/v1/videos/job-r") == 6)
        #expect(controller.record(remoteID: "job-r")?.pollingState == .completed)
    }

    @Test("exhausted retries stop locally with a recoverable error (never left Running)")
    func exhaustedRetriesStopLocally() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = ScriptedVideoTransport(scripts: [
            "/api/v1/videos": [.json(#"{"id":"job-x","status":"queued"}"#)],
            "/api/v1/videos/job-x": Array(repeating: .http(503), count: 6) + [.json(#"{"id":"job-x","status":"completed"}"#)]
        ])
        let service = VideoGenService(transport: transport, jobController: controller, retryPolicy: fastRetry)
        do {
            _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1))
            Issue.record("Expected polling to give up.")
        } catch {
            #expect(!(error is CancellationError))
        }
        // 1 initial failure + 5 retries, then it stops — no 7th request.
        #expect(transport.requestCount(path: "/api/v1/videos/job-x") == 6)
        let record = try #require(controller.record(remoteID: "job-x"))
        #expect(record.pollingState == .stoppedLocally)
        #expect(record.isResumable)
        #expect(record.recoverableError?.contains("Resume") == true)
        #expect(JobPresentation.make(record).actions == [.resume])
        #expect(service.isRunInFlight(for: record) == false)
    }

    @Test("a non-transient poll failure stops immediately and stays resumable")
    func nonTransientStopsImmediately() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = ScriptedVideoTransport(scripts: [
            "/api/v1/videos": [.json(#"{"id":"job-401","status":"queued"}"#)],
            "/api/v1/videos/job-401": [.http(401), .json(#"{"id":"job-401","status":"completed"}"#)]
        ])
        let service = VideoGenService(transport: transport, jobController: controller, retryPolicy: fastRetry)
        _ = try? await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1))
        #expect(transport.requestCount(path: "/api/v1/videos/job-401") == 1)
        #expect(controller.record(remoteID: "job-401")?.pollingState == .stoppedLocally)
    }
}

@Suite("Concurrent video polls", .serialized)
@MainActor
struct ConcurrentVideoPollTests {
    private func seed(_ controller: JobController, _ remoteID: String) throws -> JobRecord {
        _ = controller.recordVideoSubmission(remoteID: remoteID, modelID: "m", remoteStatus: "queued", prompt: "prompt \(remoteID)")
        return try #require(controller.record(remoteID: remoteID))
    }

    @Test("resuming job B does not stop job A; stopping one leaves the other polling")
    func independentLoops() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = ScriptedVideoTransport(scripts: [
            "/api/v1/videos/job-a": [.json(#"{"id":"job-a","status":"in_progress"}"#), .hang],
            "/api/v1/videos/job-b": [.hang]
        ])
        let service = VideoGenService(transport: transport, jobController: controller, retryPolicy: fastRetry)
        let a = try seed(controller, "job-a")
        let b = try seed(controller, "job-b")

        let runA = Task { try await service.resume(a, pollInterval: .milliseconds(1)) }
        #expect(await waitForCondition { transport.requestCount(path: "/api/v1/videos/job-a") >= 2 })
        let runB = Task { try await service.resume(b, pollInterval: .milliseconds(1)) }
        #expect(await waitForCondition { transport.requestCount(path: "/api/v1/videos/job-b") >= 1 })

        #expect(service.isRunInFlight(for: a))
        #expect(service.isRunInFlight(for: b))
        #expect(service.inFlightRemoteIDs == ["job-a", "job-b"])

        service.stopPolling(remoteID: "job-b")
        _ = try? await runB.value
        #expect(service.isRunInFlight(for: a), "stopping B must not stop A")
        #expect(!service.isRunInFlight(for: b))
        #expect(controller.record(remoteID: "job-b")?.pollingState == .stoppedLocally)
        #expect(controller.record(remoteID: "job-a")?.pollingState == .polling)

        service.stopPolling()
        _ = try? await runA.value
        #expect(service.inFlightRemoteIDs.isEmpty)
        #expect(!service.isPolling)
    }

    @Test("submitting a new job does not stop an existing poll")
    func submitDoesNotStopOthers() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = ScriptedVideoTransport(scripts: [
            "/api/v1/videos/job-a": [.hang],
            "/api/v1/videos": [.json(#"{"id":"job-new","status":"completed"}"#)]
        ])
        let service = VideoGenService(transport: transport, jobController: controller, retryPolicy: fastRetry)
        let a = try seed(controller, "job-a")
        let runA = Task { try await service.resume(a, pollInterval: .milliseconds(1)) }
        #expect(await waitForCondition { transport.requestCount(path: "/api/v1/videos/job-a") >= 1 })
        _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil))
        #expect(service.isRunInFlight(for: a))
        service.stopPolling()
        _ = try? await runA.value
    }
}

@Suite("Finished-but-unsaved video recovery", .serialized)
@MainActor
struct VideoDownloadRecoveryTests {
    private func store() throws -> (URL, SavedCreationsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-dl-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager())
        return (root, try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json")))
    }

    @Test("a completed job without a saved creation offers Download (not a dead Open)")
    func trayOffersDownload() {
        var record = JobRecord(id: UUID(), remoteID: "job-1", kind: "video", submissionState: .submitted,
                               pollingState: .completed, lastRemoteStatus: "completed", conversationID: nil,
                               messageID: nil, modelID: "m", usageCost: nil, recoverableError: nil,
                               createdAt: Date(), updatedAt: Date())
        #expect(record.needsDownload)
        #expect(JobPresentation.make(record).actions == [.download])
        record.savedCreationID = UUID()
        #expect(!record.needsDownload)
        #expect(JobPresentation.make(record).actions == [.open])
    }

    @Test("prompt and saved-creation link survive a reopen of the database")
    func mediaFieldsPersist() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-jobs-\(UUID()).sqlite3").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let creationID = UUID()
        do {
            let controller = JobController(database: DatabaseManager(path: path))
            _ = controller.recordVideoSubmission(remoteID: "job-p", modelID: "m", remoteStatus: "queued", prompt: "a cat surfing")
            controller.recordTerminal(remoteID: "job-p", remoteStatus: "completed", error: nil, cost: 0.1)
            #expect(controller.downloadableJobs().map(\.remoteID) == ["job-p"])
            controller.recordSavedCreation(remoteID: "job-p", creationID: creationID)
        }
        let reopened = JobController(database: DatabaseManager(path: path))
        let record = try #require(reopened.record(remoteID: "job-p"))
        #expect(record.prompt == "a cat surfing")
        #expect(record.savedCreationID == creationID)
        #expect(record.pollingState == .completed, "linking never regresses terminal state")
        #expect(reopened.downloadableJobs().isEmpty)
    }

    @Test("download+save happens exactly once, even for concurrent requests, and keeps the prompt")
    func downloadExactlyOnce() async throws {
        let (root, saved) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = JobController(database: DatabaseManager())
        _ = controller.recordVideoSubmission(remoteID: "job-d", modelID: "vendor/video", remoteStatus: "queued", prompt: "sunset timelapse")
        controller.recordTerminal(remoteID: "job-d", remoteStatus: "completed", error: nil, cost: nil)
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let transport = ScriptedVideoTransport(scripts: [:], downloadBytes: bytes)
        let service = VideoGenService(transport: transport, jobController: controller)

        async let first = service.downloadAndSave(remoteID: "job-d", store: saved)
        async let second = service.downloadAndSave(remoteID: "job-d", store: saved)
        let (c1, c2) = try await (first, second)
        #expect(c1.id == c2.id)
        let again = try await service.downloadAndSave(remoteID: "job-d", store: saved)
        #expect(again.id == c1.id)
        #expect(transport.downloadCount == 1)
        #expect(saved.creations.filter { $0.kind == .video }.count == 1)
        #expect(c1.prompt == "sunset timelapse")
        #expect(c1.modelID == "vendor/video")
        #expect(try await saved.data(for: c1) == bytes)
        #expect(controller.record(remoteID: "job-d")?.savedCreationID == c1.id)
        #expect(service.downloadableRecords.isEmpty)
    }

    @Test("deleting the saved creation re-enables download")
    func deletedCreationAllowsRedownload() async throws {
        let (root, saved) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = JobController(database: DatabaseManager())
        _ = controller.recordVideoSubmission(remoteID: "job-z", modelID: "m", remoteStatus: "completed")
        let transport = ScriptedVideoTransport(scripts: [:], downloadBytes: Data("video".utf8))
        let service = VideoGenService(transport: transport, jobController: controller)
        let creation = try await service.downloadAndSave(remoteID: "job-z", store: saved)
        _ = try await saved.remove(ids: [creation.id])
        let replacement = try await service.downloadAndSave(remoteID: "job-z", store: saved)
        #expect(replacement.id != creation.id)
        #expect(transport.downloadCount == 2)
    }

    @Test("a non-video content type is rejected and the temp file removed")
    func rejectsWrongMIME() async throws {
        let (root, saved) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = JobController(database: DatabaseManager())
        _ = controller.recordVideoSubmission(remoteID: "job-h", modelID: "m", remoteStatus: "completed")
        let transport = ScriptedVideoTransport(scripts: [:], downloadBytes: Data("<html>".utf8), downloadMIME: "text/html")
        let service = VideoGenService(transport: transport, jobController: controller)
        await #expect(throws: MediaServiceError.self) {
            _ = try await service.downloadAndSave(remoteID: "job-h", store: saved)
        }
        #expect(saved.creations.isEmpty)
        #expect(controller.record(remoteID: "job-h")?.savedCreationID == nil)
    }
}

@Suite("Streamed asset storage")
@MainActor
struct StreamedAssetStoreTests {
    @Test("chunked file checksum equals in-memory checksum (across chunk boundaries)")
    func chunkedChecksumMatches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-hash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<(3 * 1024 + 17)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try bytes.write(to: url)
        #expect(try AssetStore.sha256Hex(fileAt: url, chunkSize: 1024) == AssetStore.sha256Hex(bytes))
        #expect(try AssetStore.sha256Hex(fileAt: url) == AssetStore.sha256Hex(bytes))
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("orb-hash-empty-\(UUID())")
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        #expect(try AssetStore.sha256Hex(fileAt: empty) == AssetStore.sha256Hex(Data()))
    }

    @Test("store(fileAt:) moves the file in, records the same checksum as store(data), and dedupes")
    func storeFileMatchesData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-assets-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore(baseDirectory: root, database: DatabaseManager())
        let bytes = Data((0..<10_000).map { UInt8($0 % 256) })
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("orb-src-\(UUID())")
        try bytes.write(to: source)
        let record = try await store.store(fileAt: source, mimeType: "video/mp4")
        #expect(record.checksum == AssetStore.sha256Hex(bytes))
        #expect(record.sizeBytes == bytes.count)
        #expect(!FileManager.default.fileExists(atPath: source.path), "the source is consumed")
        #expect(try await store.data(for: record) == bytes)

        let duplicate = FileManager.default.temporaryDirectory.appendingPathComponent("orb-src-\(UUID())")
        try bytes.write(to: duplicate)
        let deduped = try await store.store(fileAt: duplicate, mimeType: "video/mp4")
        #expect(deduped.id == record.id)
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
    }
}

@Suite("Saved creation file URLs")
@MainActor
struct SavedCreationFileURLTests {
    private func fixture() throws -> (URL, AssetStore, SavedCreationsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-fileurl-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: DatabaseManager())
        return (root, assets, try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json")))
    }

    @Test("fileURL points at the stored bytes inside the library")
    func validURL() async throws {
        let (root, assets, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let creation = try await store.save(Data("png".utf8), mimeType: "image/png", kind: .image, modelID: "m", prompt: nil)
        let url = try store.fileURL(for: creation)
        #expect(url.path.hasPrefix(assets.baseDirectory.path + "/"))
        #expect(try Data(contentsOf: url) == Data("png".utf8))
        let out = root.appendingPathComponent("exported.png")
        try store.export(creation, to: out)
        #expect(try Data(contentsOf: out) == Data("png".utf8))
    }

    @Test("fileURL rejects traversal and malformed paths")
    func rejectsTraversal() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try await store.save(Data("x".utf8), mimeType: "image/png", kind: .image, modelID: "m", prompt: nil)
        for path in ["../../etc/passwd", "/etc/passwd", "\(real.checksum.prefix(2))/../\(real.checksum).png",
                     "\(real.checksum.prefix(2))/\(real.checksum).png/../../x"] {
            var forged = real
            forged.assetPath = path
            #expect(throws: (any Error).self) { _ = try store.fileURL(for: forged) }
        }
    }

    @Test("fileURL rejects a symlinked asset file and a symlinked shard")
    func rejectsSymlinks() async throws {
        let (root, assets, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let creation = try await store.save(Data("y".utf8), mimeType: "image/png", kind: .image, modelID: "m", prompt: nil)
        let file = assets.baseDirectory.appendingPathComponent(creation.assetPath)
        let outside = root.appendingPathComponent("outside.png")
        try Data("y".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(throws: AssetStoreError.self) { _ = try store.fileURL(for: creation) }

        // Shard directory replaced by a symlink to an outside folder.
        let shard = file.deletingLastPathComponent()
        let outsideDir = root.appendingPathComponent("outside-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: outsideDir.appendingPathComponent(file.lastPathComponent))
        try FileManager.default.removeItem(at: shard)
        try FileManager.default.createSymbolicLink(at: shard, withDestinationURL: outsideDir)
        #expect(throws: AssetStoreError.self) { _ = try store.fileURL(for: creation) }
    }

    @Test("fileURL reports a missing file")
    func missingFile() async throws {
        let (root, assets, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let creation = try await store.save(Data("z".utf8), mimeType: "image/png", kind: .image, modelID: "m", prompt: nil)
        try FileManager.default.removeItem(at: assets.baseDirectory.appendingPathComponent(creation.assetPath))
        #expect(throws: AssetStoreError.missing(relativePath: creation.assetPath)) { _ = try store.fileURL(for: creation) }
    }
}
