import Foundation
import Testing
@testable import ORB

// MARK: - Full-build codec tests (Phases A–D)
//
// Pins the wire format for every new surface: multimodal content parts,
// assistant images, new request parameters, media-service models, and the
// agent memory/task-board helpers.

private func encodeTestBody(_ request: OpenRouterRequest) throws -> [String: Any] {
    let data = try OpenRouterRequestEncoder.encodeBody(request, stream: true)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func testBody(settings: GenerationSettings, messages: [AgentAPIMessage]? = nil) throws -> [String: Any] {
    let request = OpenRouterRequest(
        apiKey: "test-key", model: "test/model",
        messages: messages ?? [.init(role: "user", content: "hi")],
        settings: settings
    )
    return try encodeTestBody(request)
}

@Suite("Multimodal message encoding")
struct MultimodalEncodingTests {
    @Test("plain messages stay strings")
    func plainStaysString() throws {
        let data = try JSONEncoder().encode(AgentAPIMessage(role: "user", content: "hello"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["content"] as? String == "hello")
    }

    @Test("parts encode as content array with text first")
    func partsArray() throws {
        let message = AgentAPIMessage.multimodal(
            text: "look",
            parts: [.imageURLPart(url: "https://example.com/a.png", detail: .high)]
        )
        let data = try JSONEncoder().encode(message)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = try #require(json["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "look")
        #expect(parts[1]["type"] as? String == "image_url")
        let imageURL = try #require(parts[1]["image_url"] as? [String: Any])
        #expect(imageURL["detail"] as? String == "high")
    }

    @Test("image bytes become data URLs")
    func imageDataURL() {
        let part = MessageContentPart.imageDataPart(Data("bytes".utf8), mimeType: "image/png")
        guard case .image(let url, _) = part else {
            Issue.record("wrong case")
            return
        }
        #expect(url.hasPrefix("data:image/png;base64,"))
    }

    @Test("audio parts carry format")
    func audioFormat() throws {
        let part = MessageContentPart.audioDataPart(Data("x".utf8), format: "wav")
        let data = try JSONEncoder().encode(part)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "input_audio")
        let payload = try #require(json["input_audio"] as? [String: Any])
        #expect(payload["format"] as? String == "wav")
    }

    @Test("file parts reference uploads by id")
    func fileIdPart() throws {
        let part = MessageContentPart.fileIdPart(filename: "doc.pdf", fileId: "or_file_123")
        let data = try JSONEncoder().encode(part)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "file")
        let payload = try #require(json["file"] as? [String: Any])
        #expect(payload["file_id"] as? String == "or_file_123")
    }

    @Test("content arrays round-trip through decode")
    func roundTrip() throws {
        let original = AgentAPIMessage.multimodal(
            text: "hi",
            parts: [.video(url: "https://example.com/v.mp4")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentAPIMessage.self, from: data)
        #expect(decoded.parts?.count == 2)
        #expect(decoded.content == nil)
    }

    @Test("assistant images decode from wire shape")
    func assistantImages() throws {
        let json = """
        {"image_url": {"url": "data:image/png;base64,AAA"}}
        """.data(using: .utf8)!
        let part = try JSONDecoder().decode(AssistantImagePart.self, from: json)
        #expect(part.url.hasPrefix("data:image/png"))
    }

    @Test("attachment helpers parse data URLs")
    func attachmentHelpers() {
        let inline = ChatImageAttachment(dataURL: "data:image/jpeg;base64,aGk=")
        #expect(inline.isDataURL)
        #expect(!inline.isRemoteURL)
        #expect(inline.mimeType == "image/jpeg")
        #expect(inline.fileExtension == "jpg")
        #expect(inline.inlineData == Data("hi".utf8))
        let remote = ChatImageAttachment(dataURL: "https://example.com/a.png")
        #expect(remote.isRemoteURL)
        #expect(remote.inlineData == nil)
    }
}

@Suite("New request parameters")
struct NewRequestParameterTests {
    @Test("response_format json_object encodes")
    func jsonObject() throws {
        var settings = GenerationSettings.default
        settings.responseFormat = .jsonObject
        let encoded = try testBody(settings: settings)
        let format = try #require(encoded["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
    }

    @Test("response_format json_schema encodes with name and schema")
    func jsonSchema() throws {
        var settings = GenerationSettings.default
        settings.responseFormat = .jsonSchema(
            name: "answer",
            schema: .object(["type": .string("object")])
        )
        let encoded = try testBody(settings: settings)
        let format = try #require(encoded["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let nested = try #require(format["json_schema"] as? [String: Any])
        #expect(nested["name"] as? String == "answer")
    }

    @Test("degenerate schemas block the request instead of being silently dropped")
    func degenerateSchemaDropped() {
        var settings = GenerationSettings.default
        settings.responseFormat = .jsonSchema(name: "  ", schema: .object([:]))
        // F08: a malformed required constraint must fail closed at the request
        // boundary — never strip it and send an unconstrained paid call.
        #expect(throws: GenerationSettingsValidationError.self) {
            try testBody(settings: settings)
        }
    }

    @Test("service tier, user, session, modalities, image config encode")
    func identityAndModalities() throws {
        var settings = GenerationSettings.default
        settings.serviceTier = .priority
        settings.endUserId = "user-1"
        settings.sessionId = "session-9"
        settings.modalities = [.text, .image]
        settings.imageConfig = ChatImageConfig(aspectRatio: "16:9", quality: "high")
        let encoded = try testBody(settings: settings)
        #expect(encoded["service_tier"] as? String == "priority")
        #expect(encoded["user"] as? String == "user-1")
        #expect(encoded["session_id"] as? String == "session-9")
        #expect(encoded["modalities"] as? [String] == ["text", "image"])
        let imageConfig = try #require(encoded["image_config"] as? [String: Any])
        #expect(imageConfig["aspect_ratio"] as? String == "16:9")
    }

    @Test("max_price caps encode under provider")
    func maxPrice() throws {
        var settings = GenerationSettings.default
        settings.provider.maxPromptPrice = 5
        settings.provider.maxRequestPrice = 0.5
        let encoded = try testBody(settings: settings)
        let provider = try #require(encoded["provider"] as? [String: Any])
        let caps = try #require(provider["max_price"] as? [String: Double])
        #expect(caps["prompt"] == 5)
        #expect(caps["request"] == 0.5)
    }

    @Test("extra plugins join the web plugin in one array")
    func pluginsCombined() throws {
        var settings = GenerationSettings.default
        settings.webSearch = true
        settings.extraPlugins = [ExtraPlugin(kind: .moderation)]
        let encoded = try testBody(settings: settings)
        let plugins = try #require(encoded["plugins"] as? [[String: Any]])
        let ids = Set(plugins.compactMap { $0["id"] as? String })
        #expect(ids == ["web", "moderation"])
    }

    @Test("max_completion_tokens encodes alongside max_tokens")
    func maxCompletionTokens() throws {
        var settings = GenerationSettings.default
        settings.maxTokens = 100
        settings.maxCompletionTokens = 200
        let encoded = try testBody(settings: settings)
        #expect(encoded["max_tokens"] as? Int == 100)
        #expect(encoded["max_completion_tokens"] as? Int == 200)
    }
}

@Suite("Media service models")
struct MediaServiceModelTests {
    @Test("image request omits unset knobs")
    func imageRequestSparse() throws {
        let request = ImageGenRequest(model: "m", prompt: "a cat")
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "m")
        #expect(json["aspect_ratio"] == nil)
        #expect(json["input_references"] == nil)
    }

    @Test("video job terminal states")
    func videoTerminal() {
        for status in ["completed", "failed", "cancelled", "expired"] {
            #expect(VideoJob(id: "j", status: status).isTerminal)
        }
        #expect(!VideoJob(id: "j", status: "pending").isTerminal)
        #expect(VideoJob(id: "j", status: "completed").isSuccess)
    }

    @Test("video request encodes frame images")
    func videoFrames() throws {
        var request = VideoGenRequest(model: "m")
        request.firstFrameImage = "data:image/png;base64,AAA"
        let data = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frames = try #require(json["frame_images"] as? [[String: Any]])
        #expect(frames.count == 1)
        #expect(frames[0]["frame_type"] as? String == "first_frame")
    }

    @Test("transcription multipart body carries model and file")
    func transcriptionMultipart() {
        let request = TranscriptionRequest(
            model: "openai/whisper-large-v3", filename: "a.wav",
            mimeType: "audio/wav", audioData: Data("x".utf8)
        )
        let body = request.multipartBody(boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"model\""))
        #expect(text.contains("openai/whisper-large-v3"))
        #expect(text.contains("filename=\"a.wav\""))
    }

    @Test("key info decodes the documented shape")
    func keyInfo() throws {
        let json = """
        {"data": {"label": "sk-or-v1-ab..cd", "usage": 25.5, "limit": 100,
                  "limit_remaining": 74.5, "limit_reset": "monthly",
                  "is_free_tier": false, "is_provisioning_key": false}}
        """.data(using: .utf8)!
        struct Envelope: Decodable { let data: KeyInfo }
        let info = try JSONDecoder().decode(Envelope.self, from: json).data
        #expect(info.limitRemaining == 74.5)
        #expect(info.limitReset == "monthly")
    }
}

@Suite("Agent support")
struct AgentSupportTests {
    @Test("task board normalizes statuses")
    func taskBoard() {
        AgentTaskBoard.shared.replace(with: [
            ["title": "Done thing", "status": "completed"],
            ["title": "Doing thing", "status": "in_progress"],
            ["title": "Todo thing", "status": "bogus"],
        ])
        let snapshot = AgentTaskBoard.shared.snapshot
        #expect(snapshot.count == 3)
        #expect(snapshot[2]["status"] == "pending")
        #expect(AgentTaskBoard.shared.summary.contains("[x] Done thing"))
        AgentTaskBoard.shared.replace(with: [])
    }

    @Test("memory round-trips through SQLite")
    func memoryRoundTrip() throws {
        let db = DatabaseManager(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-memory-\(UUID().uuidString).sqlite3").path)
        let marker = "orb-test-memory-\(UUID().uuidString)"
        try db.saveMemory(content: "The test marker is \(marker).")
        let hits = db.searchMemories(query: marker)
        #expect(hits.count == 1)
        #expect(hits[0].content.contains(marker))
        // LIKE wildcards match literally, not as patterns.
        #expect(db.searchMemories(query: "%").isEmpty)
        if let path = db.testDatabasePath {
            DatabaseManager.cleanupTestDatabaseForTesting(at: path)
        }
    }

    @Test("attachment classifier rejects unknown types and dupes")
    func attachmentClassify() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("a.png")
        try Data(repeating: 1, count: 16).write(to: image)
        let unknown = dir.appendingPathComponent("a.xyzzy")
        try Data("x".utf8).write(to: unknown)
        let result = ChatAttachmentBuilder.classify(urls: [image, image, unknown])
        #expect(result.drafts.count == 1)
        #expect(result.warnings.count == 2)
        #expect(result.drafts[0].typeLabel == "png")
    }

    @Test("new native tools are registered")
    func toolRegistration() {
        let names = Set(NativeAgentTools.definitions(fullComputerAccess: true).map(\.function.name))
        for expected in ["view_image", "remember", "recall", "plan_tasks", "web_search", "speak_text", "generate_image"] {
            #expect(names.contains(expected), "missing tool \(expected)")
        }
        // Gated tools stay hidden without computer access; memory/search stay
        // gated too since they act on behalf of the user.
        let restricted = Set(NativeAgentTools.definitions(fullComputerAccess: false).map(\.function.name))
        #expect(restricted == ["fetch_url"])
    }
}

@Suite("Stream image events")
struct StreamImageEventTests {
    @Test("images in a delta decode to image events")
    func imageDeltaDecodes() throws {
        var decoder = ServerSentEventDecoder()
        let payload = #"data: {"choices":[{"index":0,"delta":{"images":[{"image_url":{"url":"data:image/png;base64,AAA"}}]}}]}"# + "\n\n"
        let events = try decoder.consume(Data(payload.utf8))
        #expect(events == [.imageDelta(choiceIndex: 0, imageURL: "data:image/png;base64,AAA")])
    }
}
