import AppKit
import Foundation
import Testing
@testable import ORB

// Wave 1 — studio track. No network: every flow uses MockMediaTransport.

private func w1StudioSource(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/ORB/\(name)"), encoding: .utf8)
}

private func w1StudioCreation(_ kind: SavedCreation.Kind, prompt: String? = "a cat", model: String = "acme/model",
                              mime: String = "image/png") -> SavedCreation {
    SavedCreation(id: UUID(), kind: kind, modelID: model, prompt: prompt, mimeType: mime,
                  createdAt: Date(), assetPath: "", checksum: "")
}

// MARK: - V-4 public catalog discovery

@MainActor
@Suite("W1 studio: model discovery without a key (V-4)")
struct W1StudioPublicCatalogTests {
    @Test("Image, video, speech and embeddings catalogs attach no credential")
    func catalogsAreUnauthenticated() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"data":[]}"#), .json(#"{"data":[]}"#), .json(#"{"data":[]}"#), .json(#"{"data":[]}"#),
            .json(#"{"id":"a/b","endpoints":[]}"#)
        ])
        await ImageGenService(transport: transport).fetchModels()
        await VideoGenService(transport: transport, jobController: JobController(database: DatabaseManager())).fetchModels()
        _ = try await GenerateModelCatalog(transport: transport).fetch(outputModalities: ["speech"])
        _ = try await GenerateModelCatalog(transport: transport).fetch(outputModalities: ["embeddings"])
        _ = try await ImageGenService(transport: transport).fetchImageModelEndpoints(modelID: "a/b")
        let sent = transport.sentRequests()
        #expect(sent.count == 5)
        for request in sent {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "\(request.url?.absoluteString ?? "")")
            #expect(request.url?.host == "openrouter.ai")
        }
        #expect(transport.keyCounter?.current == 0)
        let paths = sent.compactMap { $0.url?.path }
        #expect(paths.contains("/api/v1/images/models"))
        #expect(paths.contains("/api/v1/videos/models"))
        #expect(paths.contains("/api/v1/embeddings/models"))
        #expect(paths.contains("/api/v1/models"))
        #expect(paths.contains("/api/v1/images/models/a/b/endpoints"))
    }

    @Test("Paid and non-catalog routes are refused by publicRequest")
    func publicRequestRefusesOtherRoutes() {
        let transport = MockMediaTransport(responses: [])
        for path in ["videos", "images", "embeddings", "rerank", "files", "images/models/a/b/c/endpoints",
                     "images/models//endpoints", "https://evil.example/models"] {
            #expect(throws: (any Error).self) { _ = try transport.publicRequest(path: path) }
        }
        #expect(MediaTransport.isPublicCatalogPath("images/models/a/b/endpoints"))
        #expect(!MediaTransport.isPublicCatalogPath("audio/speech"))
    }

    @Test("Paid requests still carry the key")
    func paidRequestsStillAuthenticated() throws {
        let transport = MockMediaTransport(responses: [])
        let request = try transport.request(path: "videos", method: "POST", body: Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test("A failed discovery offers Retry that reloads the same modality")
    func discoveryRetry() async {
        let transport = MockMediaTransport(responses: [
            .status(503, #"{"error":{"message":"busy"}}"#),
            .json(#"{"data":[{"id":"x/tts","name":"TTS","pricing":{"prompt":"0.000015"}}]}"#)
        ])
        let choices = ModalityModelChoices(catalog: GenerateModelCatalog(transport: transport))
        await choices.load("speech")
        #expect(choices.error != nil)
        #expect(choices.lastModality == "speech")
        await choices.retry()
        #expect(choices.error == nil)
        #expect(choices.models.map(\.id) == ["x/tts"])
        #expect(choices.models.first?.pricing?.prompt == "0.000015")
    }

    @Test("Catalog pricing decodes leniently and never drops a model")
    func lenientPricing() throws {
        let json = #"""
        {"data":[
          {"id":"a","name":"A","pricing":{"prompt":"0.1"}},
          {"id":"b","name":"B","pricing":{"prompt":0.2}},
          {"id":"c","name":"C"},
          {"id":"d","name":"D","pricing":"weird"}
        ]}
        """#
        struct List: Decodable { let data: [GenerateCatalogModel] }
        let list = try JSONDecoder().decode(List.self, from: Data(json.utf8))
        #expect(list.data.map(\.id) == ["a", "b", "c", "d"])
        #expect(list.data[0].pricing?.prompt == "0.1")
        #expect(list.data[1].pricing?.prompt == "0.2")
        #expect(list.data[2].pricing == nil)
        #expect(list.data[3].pricing == nil)
    }
}

// MARK: - STUDIO-12 cost estimates

@Suite("W1 studio: cost estimates (STUDIO-12)")
struct W1StudioCostEstimateTests {
    @Test("Images multiply per-image endpoint pricing and range across providers")
    func images() {
        let a = [ImageEndpointPricing(billable: "output_image", unit: "image", costUSD: 0.04, variant: nil)]
        let b = [ImageEndpointPricing(billable: "output_image", unit: "image", costUSD: 0.06, variant: nil)]
        let estimate = StudioCostEstimate.images(endpoints: [a, b], count: 2)
        #expect(estimate?.low == 0.08)
        #expect(abs((estimate?.high ?? 0) - 0.12) < 1e-9)
        #expect(estimate?.label == "Estimated ≈ $0.080–$0.120 for 2 images")
        let single = StudioCostEstimate.images(endpoints: [a], count: 1)
        #expect(single?.label == "Estimated ≈ $0.040 for 1 image")
    }

    @Test("Unknown or non-per-image pricing is nil, never $0")
    func imagesUnknown() {
        let tokens = [ImageEndpointPricing(billable: "output_image", unit: "token", costUSD: 0.00003, variant: nil)]
        #expect(StudioCostEstimate.images(endpoints: [tokens], count: 1) == nil)
        #expect(StudioCostEstimate.images(endpoints: [], count: 1) == nil)
        #expect(StudioCostEstimate.images(endpoints: [[]], count: 1) == nil)
        #expect(StudioCostEstimate.speech(promptPrice: nil, characters: 10) == nil)
        #expect(StudioCostEstimate.speech(promptPrice: "abc", characters: 10) == nil)
        #expect(StudioCostEstimate.embeddings(promptPrice: "0.1", characters: 0) == nil)
        #expect(StudioCostEstimate.video(skus: nil, durationSeconds: 5, resolution: nil, audio: nil, usesFrames: false) == nil)
    }

    @Test("Speech is per character; embeddings give a token range")
    func perCharacterAndToken() {
        let speech = StudioCostEstimate.speech(promptPrice: "0.000015", characters: 1000)
        #expect(abs((speech?.low ?? 0) - 0.015) < 1e-9)
        #expect(speech?.basis == "1000 characters")
        #expect(speech?.label.hasPrefix("Estimated ≈") == true)
        let embed = StudioCostEstimate.embeddings(promptPrice: "0.0000001", characters: 400)
        #expect(embed?.basis == "~100–200 tokens")
        #expect(embed?.isRange == true)
    }

    @Test("Video uses the matching SKU × duration, in dollars from cents")
    func video() {
        let gemini = ["duration_seconds_with_audio": "0.1", "duration_seconds_with_audio_720p": "0.07",
                      "duration_seconds_with_audio_4k": "0.2"]
        let e720 = StudioCostEstimate.video(skus: gemini, durationSeconds: 8, resolution: "720p", audio: nil, usesFrames: false)
        #expect(abs((e720?.low ?? 0) - 0.56) < 1e-9)
        #expect(e720?.basis == "8 s at 720p")
        let eDefault = StudioCostEstimate.video(skus: gemini, durationSeconds: 5, resolution: nil, audio: nil, usesFrames: false)
        #expect(abs((eDefault?.low ?? 0) - 0.5) < 1e-9)

        let grok = ["cents_per_image_input": "1", "cents_per_video_output_second_480p": "2",
                    "cents_per_video_output_second_720p": "3"]
        let g = StudioCostEstimate.video(skus: grok, durationSeconds: 10, resolution: "720p", audio: nil, usesFrames: true)
        #expect(abs((g?.low ?? 0) - 0.30) < 1e-9)
        // Per-second pricing without a duration cannot be estimated.
        #expect(StudioCostEstimate.video(skus: grok, durationSeconds: nil, resolution: "720p", audio: nil, usesFrames: false) == nil)
        // Reference/long/input SKUs are never used.
        #expect(StudioCostEstimate.parseVideoSKU(key: "reference_duration_seconds_480p", value: "0.07") == nil)
        #expect(StudioCostEstimate.parseVideoSKU(key: "cents_per_image_input", value: "1") == nil)
    }

    @Test("Video rate lines carry units")
    func rateLines() {
        let lines = StudioCostEstimate.videoRateLines(["cents_per_video_output_second_720p": "3", "video_tokens": "0.000001"])
        #expect(lines.contains("$0.030/s (720p)"))
        #expect(lines.contains("video_tokens: 0.000001 (rate)"))
    }
}

// MARK: - STUDIO-4 dismiss + Show in Library

@MainActor
@Suite("W1 studio: job dismissal (STUDIO-4)", .serialized)
struct W1StudioJobDismissTests {
    @Test("A failed job can be dismissed; it stays dismissed across controllers; the row is kept")
    func dismissFailed() throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        let failed = try #require(controller.recordRejectedSubmission(modelID: "m", error: "bad prompt"))
        #expect(JobTray.isDismissible(failed))
        #expect(controller.canDismiss(failed))
        #expect(controller.allJobs().contains { $0.id == failed.id })

        #expect(controller.dismiss(id: failed.id))
        #expect(!controller.allJobs().contains { $0.id == failed.id })
        #expect(JobTray.activeCount(controller.allJobs()) == 0)
        // Recovery passes still see every row.
        #expect(controller.allJobs(includeDismissed: true).contains { $0.id == failed.id })

        let revived = JobController(database: database)
        #expect(!revived.allJobs().contains { $0.id == failed.id })
        #expect(try database.loadDismissedJobIDsChecked().contains(failed.id))
        #expect(controller.record(id: failed.id) != nil)
    }

    @Test("Resumable jobs are never dismissible")
    func resumableNotDismissible() throws {
        let controller = JobController(database: DatabaseManager())
        let active = try #require(controller.recordVideoSubmission(remoteID: "job-w1-active", modelID: "m", remoteStatus: "queued"))
        #expect(!controller.canDismiss(active))
        #expect(!controller.dismiss(id: active.id))
        #expect(controller.allJobs().contains { $0.id == active.id })
    }

    @Test("Dismissal storage is idempotent and round-trips")
    func storageRoundTrip() throws {
        let database = DatabaseManager()
        let id = UUID()
        try database.dismissJobChecked(id: id)
        try database.dismissJobChecked(id: id)
        #expect(try database.loadDismissedJobIDsChecked() == [id])
    }

    @Test("The tray counts dismissible jobs")
    func trayCounts() throws {
        let controller = JobController(database: DatabaseManager())
        _ = controller.recordRejectedSubmission(modelID: "m", error: "x")
        _ = controller.recordRejectedSubmission(modelID: "m", error: "y")
        #expect(JobTray.dismissibleCount(controller.allJobs()) == 2)
    }

    @Test("Show in Library opens ORB's Library with the item focused, not Finder")
    func showInLibraryTargetsLibrary() throws {
        let store = StudioStore()
        let shell = ShellController()
        let id = UUID()
        StudioNavigation.showInLibrary(id, shell: shell, store: store)
        #expect(store.box(StudioNavigation.showingCreationsKey, initial: { false }).value == true)
        #expect(store.box(StudioNavigation.libraryFocusKey, initial: { UUID?.none }).value == id)
        let video = try w1StudioSource("VideoView.swift")
        let trayBlock = try #require(video.range(of: "private var jobTray: some View")).upperBound
        let tail = String(video[trayBlock...].prefix(1500))
        #expect(tail.contains("StudioNavigation.showInLibrary"))
        #expect(!tail.contains("CreationActions.reveal"))
        let tray = try w1StudioSource("JobTrayLogic.swift")
        #expect(tray.contains("case .dismiss: Button(\"Dismiss\")"))
    }
}

// MARK: - STUDIO-6 submit release / STUDIO-5 snapshot

@MainActor
@Suite("W1 studio: video submit and job snapshot (STUDIO-5/6)", .serialized)
struct W1StudioVideoSubmitTests {
    @Test("onSubmitted fires once the POST returns, while polling continues")
    func onSubmittedBeforePolling() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = MockMediaTransport(responses: [.json(#"{"id":"job-w1-submit","status":"queued"}"#), .hang])
        let service = VideoGenService(transport: transport, jobController: controller)
        let submitted = W1StudioFlag()
        let run = Task {
            try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: "p"),
                                            pollInterval: .milliseconds(5),
                                            reportingSubmission: { job in submitted.set(job.id) },
                                            onUpdate: { _ in })
        }
        for _ in 0..<300 where submitted.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(submitted.value == "job-w1-submit")
        #expect(service.inFlightRemoteIDs.contains("job-w1-submit"))
        service.stopPolling()
        _ = try? await run.value
    }

    @Test("A failed POST never reports submitted")
    func failedPostNeverSubmitted() async {
        let controller = JobController(database: DatabaseManager())
        let transport = MockMediaTransport(responses: [.status(400, #"{"error":{"message":"nope"}}"#)])
        let service = VideoGenService(transport: transport, jobController: controller)
        let submitted = W1StudioFlag()
        _ = try? await service.submitAndPoll(VideoGenRequest(model: "m", prompt: "p"),
                                             reportingSubmission: { job in submitted.set(job.id) },
                                             onUpdate: { _ in })
        #expect(transport.submissions().count == 1)
        #expect(submitted.value == nil)
    }

    @Test("Trailing-closure callers still receive updates, not the submission hook")
    func trailingClosureStillBindsOnUpdate() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-w1-tc","status":"queued"}"#),
            .json(#"{"id":"job-w1-tc","status":"completed"}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: JobController(database: DatabaseManager()))
        let updates = W1StudioCounter()
        _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1)) { _ in
            updates.increment()
        }
        #expect(updates.value == 2)
    }

    @Test("Submit gate: only an unanswered POST or the concurrency cap blocks")
    func gate() {
        #expect(VideoSubmitGate.canSubmit(hasModel: true, hasPrompt: true, hasKey: true, postingSubmits: 0, pollingJobs: 2))
        #expect(!VideoSubmitGate.canSubmit(hasModel: true, hasPrompt: true, hasKey: true, postingSubmits: 1, pollingJobs: 0))
        #expect(!VideoSubmitGate.canSubmit(hasModel: true, hasPrompt: true, hasKey: true, postingSubmits: 0,
                                           pollingJobs: VideoSubmitGate.maxConcurrentJobs))
        #expect(!VideoSubmitGate.canSubmit(hasModel: true, hasPrompt: true, hasKey: false, postingSubmits: 0, pollingJobs: 0))
    }

    @Test("One snapshot read yields all, resumable and downloadable records")
    func snapshot() throws {
        let controller = JobController(database: DatabaseManager())
        let service = VideoGenService(transport: MockMediaTransport(responses: []), jobController: controller)
        _ = controller.recordVideoSubmission(remoteID: "job-w1-snap", modelID: "m", remoteStatus: "queued")
        let before = service.jobSnapshotReads
        let snapshot = service.jobRecordSnapshot()
        #expect(service.jobSnapshotReads == before + 1)
        #expect(snapshot.all.count == 1)
        #expect(snapshot.resumable.map(\.remoteID) == ["job-w1-snap"])
        #expect(snapshot.downloadable.isEmpty)
    }

    @Test("VideoView body no longer reads job storage directly")
    func noStorageReadsInBody() throws {
        let video = try w1StudioSource("VideoView.swift")
        #expect(!video.contains("service.allJobRecords"))
        #expect(!video.contains("resumableRecords = service.resumableRecords"))
        #expect(video.contains("service.jobRecordSnapshot()"))
    }
}

final class W1StudioCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
}

final class W1StudioFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: String) { lock.lock(); stored = v; lock.unlock() }
}

// MARK: - STUDIO-3 embed vs rerank

@MainActor
@Suite("W1 studio: embed and rerank busy flags (STUDIO-3)")
struct W1StudioEmbeddingFlagsTests {
    @Test("A running rerank does not mark Embed busy")
    func separateFlags() async throws {
        let service = EmbeddingService(transport: MockMediaTransport(responses: [.hang]))
        let run = Task { try await service.rerank(RerankRequest(model: "m", query: "q", documents: ["a"], topN: nil)) }
        for _ in 0..<300 where !service.isReranking { try await Task.sleep(for: .milliseconds(5)) }
        #expect(service.isReranking)
        #expect(!service.isEmbedding)
        #expect(service.isWorking)
        run.cancel()
        _ = try? await run.value
        #expect(!service.isReranking)
    }
}

// MARK: - STUDIO-7 Library selection

@Suite("W1 studio: Finder-like Library selection (STUDIO-7)")
struct W1StudioLibrarySelectionTests {
    let ids = (0..<6).map { _ in UUID() }

    @Test("Plain click selects one; ⌘ toggles; ⇧ extends from the anchor")
    func clicks() {
        var s = LibrarySelection()
        s.click(ids[1], command: false, shift: false, in: ids)
        s.click(ids[3], command: false, shift: false, in: ids)
        #expect(s.ids == [ids[3]])
        s.click(ids[5], command: true, shift: false, in: ids)
        #expect(s.ids == [ids[3], ids[5]])
        s.click(ids[5], command: true, shift: false, in: ids)
        #expect(s.ids == [ids[3]])
        // ⌘-click moved the anchor to #5 (as in Finder), so ⇧ extends from there.
        s.click(ids[1], command: false, shift: true, in: ids)
        #expect(s.ids == Set(ids[1...5]))
        s.click(ids[2], command: false, shift: false, in: ids)
        s.click(ids[4], command: false, shift: true, in: ids)
        #expect(s.ids == Set(ids[2...4]))
        s.clear()
        #expect(s.isEmpty)
    }

    @Test("Arrow keys move the selection and ⇧ extends it")
    func arrows() {
        var s = LibrarySelection()
        s.move(by: 1, in: ids, extending: false)
        #expect(s.ids == [ids[0]])
        s.move(by: 3, in: ids, extending: false)
        #expect(s.ids == [ids[3]])
        s.move(by: 1, in: ids, extending: true)
        #expect(s.ids == [ids[3], ids[4]])
        s.move(by: 10, in: ids, extending: false)
        #expect(s.ids == [ids[5]])
        s.move(by: -100, in: ids, extending: false)
        #expect(s.ids == [ids[0]])
        s.selectAll(ids)
        #expect(s.count == 6)
    }

    @Test("Space previews the item just clicked; grid columns follow width")
    func previewTargetAndColumns() {
        let items = (0..<3).map { _ in w1StudioCreation(.image) }
        var s = LibrarySelection()
        s.click(items[2].id, command: false, shift: false, in: items.map(\.id))
        s.click(items[0].id, command: true, shift: false, in: items.map(\.id))
        s.click(items[2].id, command: true, shift: false, in: items.map(\.id))
        s.click(items[2].id, command: true, shift: false, in: items.map(\.id))
        #expect(LibraryPreview.target(selection: s.ids, anchor: s.anchorID, visible: items)?.id == items[2].id)
        #expect(LibraryPreview.gridColumns(width: 0) == 1)
        #expect(LibraryPreview.gridColumns(width: 320) == 2)
        #expect(LibraryPreview.gridColumns(width: 640) == 4)
    }

    @Test("Library cells use one tap handler (no double-tap delay)")
    func singleTapHandler() throws {
        let library = try w1StudioSource("LibraryView.swift")
        #expect(!library.contains(".onTapGesture(count: 2)"))
        #expect(library.contains(".onExitCommand { selection.clear() }"))
        #expect(library.contains("selectAll(_:)"))
    }
}

// MARK: - STUDIO-13 prompt history and Open in Studio

@MainActor
@Suite("W1 studio: prompt history and Open in Studio (STUDIO-13)")
struct W1StudioReuseTests {
    @Test("History keeps distinct trimmed prompts, newest first, capped")
    func historyAdding() {
        var list: [String] = []
        list = StudioPromptHistory.adding("  a  ", to: list)
        list = StudioPromptHistory.adding("b", to: list)
        list = StudioPromptHistory.adding("a", to: list)
        list = StudioPromptHistory.adding("   ", to: list)
        #expect(list == ["a", "b"])
        let capped = (0..<40).reduce([String]()) { StudioPromptHistory.adding("p\($1)", to: $0) }
        #expect(capped.count == StudioPromptHistory.limit)
        #expect(capped.first == "p39")
        #expect(StudioPromptHistory.menuTitle(String(repeating: "x", count: 100)).count == 60)
    }

    @Test("History persists per studio")
    func historyPersistence() throws {
        let suite = "orb.w1studio.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let images = StudioPromptHistory(studio: .images, defaults: defaults)
        let video = StudioPromptHistory(studio: .video, defaults: defaults)
        images.record("sunset")
        #expect(images.prompts == ["sunset"])
        #expect(video.prompts.isEmpty)
        images.clear()
        #expect(images.prompts.isEmpty)
    }

    @Test("Open in Studio writes the prompt and model into the matching studio")
    func reusePlan() {
        let store = StudioStore()
        let image = w1StudioCreation(.image, prompt: "red fox", model: "x/img")
        let plan = StudioReusePlan.plan(for: image)
        #expect(plan?.section == .images)
        plan?.apply(store: store)
        #expect(store.box("ImagesView.prompt", initial: { "" }).value == "red fox")
        #expect(store.box("ImagesView.selectedModelId", initial: { "" }).value == "x/img")

        let audio = w1StudioCreation(.audio, prompt: "hello", model: "x/tts", mime: "audio/mpeg")
        StudioReusePlan.plan(for: audio)?.apply(store: store)
        #expect(store.box("SpeechView.text", initial: { "" }).value == "hello")
        #expect(store.box("SpeechView.modelId", initial: { "" }).value == "x/tts")
        #expect(store.box("SpeechView.mode", initial: { SpeechView.Mode.stt }).value == .tts)

        #expect(StudioReusePlan.plan(for: w1StudioCreation(.video))?.section == .video)
        #expect(StudioReusePlan.plan(for: w1StudioCreation(.transcript)) == nil)
        #expect(StudioReusePlan.plan(for: w1StudioCreation(.embedding)) == nil)
    }

    @Test("The shared creation menu offers Open and Open in Studio")
    func menuTitles() {
        let image = w1StudioCreation(.image)
        #expect(CreationActions.menuTitles(for: image, canOpenInStudio: true).prefix(2) == ["Open", "Open in Studio"])
        #expect(!CreationActions.menuTitles(for: image, canOpenInStudio: false).contains("Open in Studio"))
        let pcm = w1StudioCreation(.audio, mime: "audio/pcm")
        #expect(!CreationActions.menuTitles(for: pcm, canOpenInStudio: true).contains("Open"))
    }
}

// MARK: - STUDIO-14 drag and drop, WebP

@Suite("W1 studio: drag and drop (STUDIO-14)")
struct W1StudioDropTests {
    @Test("Drops keep matching local files only, once each")
    func accept() {
        let png = URL(fileURLWithPath: "/tmp/a.png"), webp = URL(fileURLWithPath: "/tmp/b.webp")
        let mp3 = URL(fileURLWithPath: "/tmp/c.mp3"), txt = URL(fileURLWithPath: "/tmp/d.txt")
        let remote = URL(string: "https://example.com/e.png")!
        let dir = URL(fileURLWithPath: "/tmp/folder/", isDirectory: true)
        let all = [png, webp, mp3, txt, remote, dir, png]
        #expect(StudioDropFilter.accept(urls: all, kind: .image) == [png, webp])
        #expect(StudioDropFilter.accept(urls: all, kind: .audio) == [mp3])
        #expect(StudioDropFilter.accept(urls: all, kind: .anyFile) == [png, webp, mp3, txt])
        #expect(StudioDropFilter.imageTypes.contains(.webP))
    }

    @Test("Dropped references respect the limit")
    func merge() {
        let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/r\($0).png") }
        let merged = StudioDropFilter.merge(Array(urls[1...4]), into: [urls[0], urls[1]], limit: 4)
        #expect(merged.urls == Array(urls[0...3]))
        #expect(merged.refused == 1)
    }

    @Test("Pickers allow WebP")
    func pickersAllowWebP() throws {
        for file in ["ImagesView.swift", "VideoView.swift"] {
            let source = try w1StudioSource(file)
            #expect(!source.contains("allowedContentTypes = [.png, .jpeg, .gif, .heic]"), "\(file)")
            #expect(source.contains("StudioDropFilter.imageTypes"), "\(file)")
        }
    }
}

// MARK: - STUDIO-9 embedding maths

@Suite("W1 studio: embedding similarity (STUDIO-9)")
struct W1StudioEmbeddingMathTests {
    @Test("Cosine is bounded, symmetric, and nil for zero or mismatched vectors")
    func cosine() {
        #expect(EmbeddingMath.cosine([1, 0], [1, 0]) == 1)
        #expect(EmbeddingMath.cosine([1, 0], [-1, 0]) == -1)
        #expect(abs((EmbeddingMath.cosine([1, 0], [0, 1]) ?? 9)) < 1e-12)
        #expect(EmbeddingMath.cosine([0, 0], [1, 0]) == nil)
        #expect(EmbeddingMath.cosine([1], [1, 2]) == nil)
        #expect(EmbeddingMath.cosine([], []) == nil)
        #expect(EmbeddingMath.cosine([.nan, 1], [1, 1]) == nil)
    }

    @Test("Matrix and summary are computed once, off main")
    func summary() async {
        let vectors: [(input: String, embedding: [Double])] = [("a", [1, 0]), ("b", [0.9, 0.1]), ("c", [0, 1])]
        let summary = await EmbeddingResultSummary.compute(vectors)
        #expect(summary.rows.count == 3)
        #expect(summary.matrix.count == 3)
        #expect(summary.matrix[0][1] == summary.matrix[1][0])
        #expect(summary.bestPair?.hasPrefix("Most similar: #1 and #2") == true)
        #expect(summary.rows[0].json == "[1.0,0.0]")
        #expect(!summary.matrixTruncated)
        let many = (0..<25).map { (input: "\($0)", embedding: [Double($0) + 1, 1]) }
        let big = EmbeddingResultSummary.make(many)
        #expect(big.matrix.count == EmbeddingResultSummary.matrixLimit)
        #expect(big.matrixTruncated)
        #expect(EmbeddingSimilarityHeatMap.cellOpacity(nil) == 0)
        #expect(EmbeddingSimilarityHeatMap.cellOpacity(1) == 1)
    }
}

// MARK: - STUDIO-8 audio playback

@MainActor
final class W1StudioFakeAudio: StudioAudioEngine {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 10
    var stops = 0
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; stops += 1 }
}

@MainActor
@Suite("W1 studio: audio playback (STUDIO-8)")
struct W1StudioAudioTests {
    @Test("Play, pause, seek and stop drive one player")
    func transport() {
        let playback = StudioAudioPlayback()
        let engine = W1StudioFakeAudio()
        let id = UUID()
        playback.load(engine, id: id)
        #expect(playback.duration == 10)
        playback.play()
        #expect(playback.isPlaying && engine.isPlaying)
        playback.seek(to: 4)
        #expect(playback.currentTime == 4)
        playback.toggle()
        #expect(!playback.isPlaying && !engine.isPlaying)
        playback.seek(to: 99)
        #expect(playback.currentTime == 10)
        playback.play()
        playback.stop()
        #expect(!playback.isPlaying && playback.currentTime == 0 && engine.stops >= 1)
    }

    @Test("Loading another clip stops the first")
    func loadingStopsPrevious() {
        let playback = StudioAudioPlayback()
        let first = W1StudioFakeAudio(), second = W1StudioFakeAudio()
        playback.load(first, id: UUID())
        playback.play()
        playback.load(second, id: UUID())
        #expect(!first.isPlaying)
        #expect(!playback.isPlaying)
    }

    @Test("Raw PCM is never offered for playback")
    func pcm() {
        #expect(!StudioAudioPlayback.canPlay(mimeType: "audio/pcm"))
        #expect(!StudioAudioPlayback.canPlay(mimeType: "audio/L16; rate=24000"))
        #expect(StudioAudioPlayback.canPlay(mimeType: "audio/mpeg"))
        #expect(!StudioAudioPlayback.canPlay(mimeType: "application/json"))
        #expect(StudioAudioPlayback.timeText(75) == "1:15")
        #expect(StudioAudioPlayback.timeText(.nan) == "0:00")
    }

    @Test("Speech stops playback when the page is left")
    func stopsOnDisappear() throws {
        let speech = try w1StudioSource("SpeechView.swift")
        #expect(speech.contains(".onDisappear { playback.stop() }"))
        #expect(!speech.contains("AVAudioPlayer(data:"))
    }
}

// MARK: - STUDIO-10 off-main reads, STUDIO-11 Library default

@Suite("W1 studio: off-main file reads and Library default (STUDIO-10/11)")
struct W1StudioFileTests {
    private func pngFile() throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w1studio-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    @Test("Off-main data URLs match the synchronous encoder, in order")
    func dataURLsMatch() async throws {
        let a = try pngFile(), b = try pngFile()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let off = try await MediaStudioImageFile.dataURLsOffMain([a, b])
        #expect(off == [try MediaStudioImageFile.dataURL(for: a), try MediaStudioImageFile.dataURL(for: b)])
        #expect(try await MediaStudioImageFile.dataURLsOffMain([]).isEmpty)
        let raw = try await LocalFileRead.data(at: a)
        #expect(raw == (try Data(contentsOf: a)))
    }

    @Test("Studios no longer read whole files on the main actor")
    func noMainActorReads() throws {
        #expect(!(try w1StudioSource("SpeechView.swift")).contains("let data = try Data(contentsOf: url)"))
        #expect(!(try w1StudioSource("FilesView.swift")).contains("let data = try Data(contentsOf: url)"))
        #expect((try w1StudioSource("ImagesView.swift")).contains("try await referenceDataURLs()"))
    }

    @Test("Files opens on the local Library and only lists remote files on that tab")
    func libraryDefault() {
        #expect(FilesViewDefaults.showsLibraryFirst)
        #expect(!FilesViewDefaults.shouldFetchRemote(showingCreations: true))
        #expect(FilesViewDefaults.shouldFetchRemote(showingCreations: false))
    }

    @Test("A non-video file yields no poster and no crash")
    func posterForGarbage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w1studio-\(UUID().uuidString)")
        try Data("not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = await CreationThumbnails.decodeVideoPoster(fileURL: url, mimeType: "video/mp4", maxPixel: 64)
        #expect(image == nil)
    }
}

// MARK: - STUDIO-1/2, V-2/V-3 layout contracts

@Suite("W1 studio: shared layout contracts (STUDIO-1/2, V-2, V-3)")
struct W1StudioLayoutContractTests {
    @Test("Errors sit in the pinned footer in every studio")
    func errorsInFooter() throws {
        for file in ["ImagesView.swift", "VideoView.swift", "SpeechView.swift", "EmbeddingsView.swift"] {
            let source = try w1StudioSource(file)
            let footer = source.range(of: "StudioPinnedFooter {") ?? source.range(of: "private var footer: some View {")
            let start = try #require(footer, "\(file)").upperBound
            let window = String(source[start...].prefix(600))
            #expect(window.contains("PlaygroundErrorBanner(message: errorMessage)"), "\(file)")
        }
    }

    @Test("Speech and Embeddings use the shared scaffold with a results pane")
    func scaffold() throws {
        #expect((try w1StudioSource("SpeechView.swift")).contains("StudioScaffold {"))
        #expect((try w1StudioSource("EmbeddingsView.swift")).contains("StudioScaffold {"))
        #expect((try w1StudioSource("DesignSystem/StudioUI.swift")).contains(".safeAreaInset(edge: .bottom"))
    }

    @Test("No studio repeats the NeedsKeyGate no-key warning")
    func noDuplicateKeyWarnings() throws {
        for file in ["ImagesView.swift", "VideoView.swift", "SpeechView.swift", "EmbeddingsView.swift"] {
            let source = try w1StudioSource(file)
            #expect(!source.contains("Add an inference API key"), "\(file)")
            #expect(!source.contains("Add your OpenRouter API key in Settings"), "\(file)")
        }
    }

    @Test("Finished videos play in the studio with AVKit")
    func inStudioPlayback() throws {
        let actions = try w1StudioSource("CreationActions.swift")
        #expect(actions.contains("VideoPlayer(player: player)"))
        #expect(actions.contains(".onDisappear { player?.pause(); player = nil }"))
        #expect((try w1StudioSource("VideoView.swift")).contains("SavedVideoPlayerCard("))
        #expect((try w1StudioSource("LibraryView.swift")).contains("videoPoster("))
    }
}
