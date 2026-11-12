import Foundation
import Testing
@testable import ORB

// Regression tests for Generate-studio fixes: split image runs, endpoint
// lookup gating, transcription uploads, media file names, the Current Key
// panel and remote video failures.

@Suite("Split image requests: per-chunk seeds")
struct ImageChunkSeedTests {
    @Test("one image per request with a seed sends a different seed each time")
    func oneImagePerRequest() {
        let chunks = ImageGallery.chunks(total: 4, perRequest: 1)
        #expect(chunks == [1, 1, 1, 1])
        let seeds = ImageGallery.chunkSeeds(base: 42, chunks: chunks)
        #expect(seeds == [42, 43, 44, 45])
        #expect(Set(seeds.compactMap { $0 }).count == 4, "no two paid requests share a seed")
    }

    @Test("the same seed and count reproduce the same per-request seeds")
    func reproducible() {
        let chunks = ImageGallery.chunks(total: 5, perRequest: 2)
        #expect(ImageGallery.chunkSeeds(base: 7, chunks: chunks) == ImageGallery.chunkSeeds(base: 7, chunks: chunks))
    }

    @Test("multi-image chunks step by the images already requested")
    func multiImageChunks() {
        // A provider seeding image i of a request as seed+i never repeats one.
        #expect(ImageGallery.chunkSeeds(base: 100, chunks: [4, 4, 2]) == [100, 104, 108])
    }

    @Test("a single request keeps the typed seed, and no seed stays no seed")
    func singleAndUnseeded() {
        #expect(ImageGallery.chunkSeeds(base: 42, chunks: [4]) == [42])
        #expect(ImageGallery.chunkSeeds(base: nil, chunks: [1, 1, 1]) == [nil, nil, nil])
        #expect(ImageGallery.chunkSeeds(base: 42, chunks: []).isEmpty)
        // Overflow wraps instead of trapping.
        #expect(ImageGallery.chunkSeeds(base: Int.max, chunks: [1, 1]).count == 2)
    }
}

@Suite("Image endpoint lookup gating")
struct ImageEndpointLookupTests {
    @Test("a lookup is in flight from begin until its own finish")
    func inFlightWhileLoading() {
        var lookup = ImageEndpointLookup()
        #expect(!lookup.isInFlight)
        let token = lookup.begin()
        #expect(lookup.isInFlight, "Generate stays disabled while options are being checked")
        let published = lookup.finish(token)
        #expect(published)
        #expect(!lookup.isInFlight)
    }

    @Test("a superseded lookup may not publish, and does not end the newer one")
    func supersededLookupIsIgnored() {
        var lookup = ImageEndpointLookup()
        let first = lookup.begin()
        let second = lookup.begin() // quick model switch
        // The first model's fetch ends (cancelled or late): nothing to show.
        let stalePublished = lookup.finish(first)
        #expect(!stalePublished)
        #expect(lookup.isInFlight, "the selected model's lookup is still running")
        let currentPublished = lookup.finish(second)
        #expect(currentPublished)
        #expect(!lookup.isInFlight)
        let publishedTwice = lookup.finish(second)
        #expect(!publishedTwice, "a lookup finishes once")
    }
}

@Suite("Transcription upload request")
struct TranscriptionUploadTests {
    private func request(filename: String, format: String? = nil) -> TranscriptionRequest {
        var request = TranscriptionRequest(
            model: "openai/whisper-large-v3", filename: filename,
            mimeType: "audio/wav", audioData: Data("x".utf8)
        )
        request.responseFormat = format
        return request
    }

    @Test("a filename with quotes or line breaks cannot break the multipart header")
    func filenameIsSanitized() {
        let hostile = "my \"best\" take\\v2\r\nX-Injected: 1.wav"
        let body = String(decoding: request(filename: hostile).multipartBody(boundary: "B"), as: UTF8.self)
        let expected = "Content-Disposition: form-data; name=\"file\"; filename=\"my _best_ take_v2__X-Injected: 1.wav\"\r\n"
        #expect(body.contains(expected))
        #expect(!body.contains("\"best\""))
        #expect(!body.contains("\r\nX-Injected"))
        // Same rule as workspace file uploads.
        #expect(FileService.safeMultipartFilename(hostile) == "my _best_ take_v2__X-Injected: 1.wav")
    }

    @Test("an ordinary filename is sent unchanged")
    func ordinaryFilename() {
        let body = String(decoding: request(filename: "Interview (final).m4a").multipartBody(boundary: "B"), as: UTF8.self)
        #expect(body.contains("filename=\"Interview (final).m4a\""))
    }

    @Test("the saved shape follows the format the request asked for")
    func structuredFollowsRequest() {
        #expect(request(filename: "a.wav", format: "verbose_json").wantsStructuredTranscript)
        #expect(!request(filename: "a.wav", format: "json").wantsStructuredTranscript)
        #expect(!request(filename: "a.wav", format: "text").wantsStructuredTranscript)
        #expect(!request(filename: "a.wav").wantsStructuredTranscript)
    }
}

@Suite("Media file extensions")
struct MediaFileExtensionTests {
    private func creation(_ kind: SavedCreation.Kind, _ mime: String) -> SavedCreation {
        SavedCreation(id: UUID(), kind: kind, modelID: "m", prompt: nil, mimeType: mime,
                      createdAt: Date(timeIntervalSince1970: 1_790_866_800), assetPath: "", checksum: "")
    }

    @Test("QuickTime video and GIF images get their own extension, not .txt")
    func quickTimeAndGIF() {
        #expect(MediaFileExtension.forMIMEType("video/quicktime") == "mov")
        #expect(MediaFileExtension.forMIMEType("image/gif") == "gif")
        #expect(creationExtension(creation(.video, "video/quicktime")) == "mov")
        #expect(creationExtension(creation(.image, "image/gif")) == "gif")
        #expect(LibraryExport.fileName(for: creation(.video, "video/quicktime")).hasSuffix(".mov"))
        #expect(LibraryExport.fileName(for: creation(.image, "image/gif")).hasSuffix(".gif"))
    }

    @Test("the asset store and Library exports name every known type the same way")
    func oneTable() {
        let checksum = String(repeating: "ab", count: 32)
        let types: [(String, String)] = [
            ("image/png", "png"), ("image/jpeg", "jpg"), ("image/webp", "webp"), ("image/gif", "gif"),
            ("video/mp4", "mp4"), ("video/webm", "webm"), ("video/quicktime", "mov"),
            ("audio/mpeg", "mp3"), ("audio/mp3", "mp3"), ("audio/wav", "wav"), ("audio/x-wav", "wav"),
            ("audio/mp4", "m4a"), ("audio/pcm", "pcm"), ("audio/l16", "pcm"), ("audio/aac", "aac"),
            ("audio/ogg", "ogg"), ("application/json", "json"), ("text/plain", "txt")
        ]
        for (mime, ext) in types {
            #expect(MediaFileExtension.forMIMEType(mime) == ext)
            #expect(creationExtension(creation(.audio, mime)) == ext)
            #expect(AssetStore.relativePath(forChecksum: checksum, mimeType: mime) == "ab/\(checksum).\(ext)")
        }
    }

    @Test("parameters and case are ignored; unknown types have no extension")
    func normalisationAndUnknown() {
        #expect(MediaFileExtension.forMIMEType("Video/QuickTime; codecs=avc1") == "mov")
        #expect(MediaFileExtension.forMIMEType(" audio/mpeg ;charset=binary") == "mp3")
        #expect(MediaFileExtension.forMIMEType("application/x-unknown") == nil)
        #expect(MediaFileExtension.forMIMEType("") == nil)
        #expect(MediaFileExtension.forMIMEType(nil) == nil)
        // The Library still needs some name for a type it does not know.
        #expect(creationExtension(creation(.transcript, "application/x-unknown")) == "txt")
        let checksum = String(repeating: "cd", count: 32)
        #expect(AssetStore.relativePath(forChecksum: checksum, mimeType: "application/x-unknown") == "cd/\(checksum)")
    }

    @Test("a QuickTime asset is stored as .mov, and one stored before the mapping still dedupes")
    func storedQuickTime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager()
        let store = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: database)

        let fresh = try await store.store(Data("new quicktime bytes".utf8), mimeType: "video/quicktime")
        #expect(fresh.relativePath.hasSuffix(".mov"))

        // Stored by an earlier build: same type, extension-less path.
        let legacyBytes = Data("old quicktime bytes".utf8)
        let checksum = AssetStore.sha256Hex(legacyBytes)
        let legacyPath = AssetStore.relativePath(forChecksum: checksum, mimeType: nil)
        let legacyURL = store.baseDirectory.appendingPathComponent(legacyPath)
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyBytes.write(to: legacyURL)
        try database.saveAssetRecordChecked(AssetRecord(
            id: UUID(), relativePath: legacyPath, remoteReference: nil, mimeType: "video/quicktime",
            sizeBytes: legacyBytes.count, checksum: checksum, jobID: nil, messageID: nil,
            retention: .keep, createdAt: Date()
        ))
        let again = try await store.store(legacyBytes, mimeType: "video/quicktime")
        #expect(again.relativePath == legacyPath)
        #expect(try await store.data(for: again) == legacyBytes)
    }
}

@Suite("Current Key panel state")
@MainActor
struct DirectoryKeyInfoTests {
    private static let keyJSON = #"{"data":{"label":"Primary","usage":1.5,"limit":10}}"#
    private static let rejected = #"{"error":{"message":"No auth credentials found"}}"#

    @Test("a key that can no longer be read clears the previous key's details")
    func failureClearsStaleKeyInfo() async {
        let transport = MockMediaTransport(responses: [.json(Self.keyJSON), .status(401, Self.rejected)])
        let directory = DirectoryService(transport: transport)

        await directory.fetchKeyInfo()
        #expect(directory.keyInfo?.label == "Primary")
        #expect(directory.lastError == nil)

        // The key was replaced with an invalid one and the panel refreshed.
        await directory.fetchKeyInfo()
        #expect(directory.keyInfo == nil, "the old key's label and limits must not stay on screen")
        #expect(directory.lastError?.contains("rejected the API key") == true)
    }

    @Test("a successful lookup clears its earlier error")
    func successClearsKeyError() async {
        let transport = MockMediaTransport(responses: [.status(401, Self.rejected), .json(Self.keyJSON)])
        let directory = DirectoryService(transport: transport)

        await directory.fetchKeyInfo()
        #expect(directory.keyInfo == nil)
        #expect(directory.lastError != nil)

        await directory.fetchKeyInfo()
        #expect(directory.keyInfo?.label == "Primary")
        #expect(directory.lastError == nil)
    }

    @Test("a successful key lookup leaves an unrelated error alone")
    func successKeepsOtherErrors() async {
        let directory = DirectoryService(transport: MockMediaTransport(responses: [.json(Self.keyJSON)]))
        directory.lastError = "Could not load providers."
        await directory.fetchKeyInfo()
        #expect(directory.keyInfo?.label == "Primary")
        #expect(directory.lastError == "Could not load providers.")
    }
}

@Suite("Remote video failure wording", .serialized)
@MainActor
struct VideoJobFailureTests {
    @Test("a provider failure names the provider's reason and never reads as a network error")
    func failureCopy() {
        let failure = VideoJobFailure(status: "failed", reason: "Prompt was rejected by content moderation.")
        let text = failure.localizedDescription
        #expect(text == "The provider could not generate this video: Prompt was rejected by content moderation. Submitting again starts a new job, which is billed separately.")
        #expect(!text.contains("Network error"))
        // Not a MediaServiceError, so no poll or retry path can treat it as transient.
        let asError: Error = failure
        #expect(!(asError is MediaServiceError))
    }

    @Test("each terminal status has its own sentence, with or without a reason")
    func statusCopy() {
        #expect(VideoJobFailure(status: "failed", reason: nil).localizedDescription
            == "The provider could not generate this video. Submitting again starts a new job, which is billed separately.")
        #expect(VideoJobFailure(status: "cancelled", reason: nil).localizedDescription
            .hasPrefix("The provider cancelled this video job."))
        #expect(VideoJobFailure(status: "expired", reason: " ").localizedDescription
            .hasPrefix("This video job expired at the provider."))
    }

    @Test("a moderation refusal during polling surfaces as a remote failure")
    func moderationRefusalIsNotTransport() async throws {
        let controller = JobController(database: DatabaseManager())
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-moderated","status":"queued"}"#),
            .json(#"{"id":"job-moderated","status":"failed","error":"Rejected by content moderation"}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        do {
            _ = try await service.submitAndPoll(
                VideoGenRequest(model: "m", prompt: "p"), pollInterval: .milliseconds(1))
            Issue.record("Expected the failed job to throw.")
        } catch let failure as VideoJobFailure {
            #expect(failure == VideoJobFailure(status: "failed", reason: "Rejected by content moderation"))
            #expect(failure.localizedDescription.contains("Rejected by content moderation"))
            #expect(!failure.localizedDescription.contains("Network error"))
        }
        // One submit, one poll: a remote failure is never retried.
        #expect(transport.sentCount() == 2)
        #expect(controller.record(remoteID: "job-moderated")?.pollingState == .failed)
    }
}
