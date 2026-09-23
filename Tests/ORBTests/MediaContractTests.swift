import Foundation
import Testing
@testable import ORB

private func contractJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Generate API wire contracts", .serialized)
@MainActor
struct MediaContractTests {
    @Test("image references are typed content parts, with sparse optional fields")
    func imageReferences() throws {
        var request = ImageGenRequest(model: "image/model", prompt: "draw")
        request.inputReferences = ["https://example.com/ref.png"]
        let body = try contractJSON(request)
        let refs = try #require(body["input_references"] as? [[String: Any]])
        #expect(refs.count == 1)
        #expect(refs[0]["type"] as? String == "image_url")
        #expect((refs[0]["image_url"] as? [String: String])?["url"] == "https://example.com/ref.png")
        #expect(body["stream"] == nil)
    }

    @Test("video frame parts use ContentPartImage shape and explicit audio off")
    func videoFrames() throws {
        var request = VideoGenRequest(model: "video/model")
        request.firstFrameImage = "data:image/png;base64,AAA"
        request.generateAudio = false
        let body = try contractJSON(request)
        let frames = try #require(body["frame_images"] as? [[String: Any]])
        #expect(frames[0]["frame_type"] as? String == "first_frame")
        #expect(frames[0]["type"] as? String == "image_url")
        #expect((frames[0]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,AAA")
        #expect(body["generate_audio"] as? Bool == false)
    }

    @Test("video content goes through authenticated canonical route, without unsigned URL")
    func videoDownload() async throws {
        let transport = MockMediaTransport(responses: [], rawResponses: [.bytes(Data([1, 2]), "video/mp4")])
        let service = VideoGenService(transport: transport)
        let (data, mime) = try await service.download(VideoJob(id: "job-dl", status: "completed", unsignedURLs: ["https://evil.example/steal"]))
        #expect(data == Data([1, 2]))
        #expect(mime == "video/mp4")
        let sent = try #require(transport.sentRawRequests().first)
        #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/videos/job-dl/content?index=0")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test("embedding request options and result metadata round-trip")
    func embedding() async throws {
        var request = EmbeddingRequest(model: "embed/model", input: ["hello"])
        request.dimensions = 128
        request.inputType = "search_query"
        request.encodingFormat = "float"
        let transport = MockMediaTransport(responses: [.json(#"{"id":"embd-1","model":"embed/model","object":"list","data":[{"object":"embedding","index":0,"embedding":[0.1,0.2]}],"usage":{"prompt_tokens":2,"cost":0.001}}"#)])
        let response = try await EmbeddingService(transport: transport).embed(request)
        let sent = try #require(transport.sentRequests().first)
        let body = try #require(sent.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["dimensions"] as? Int == 128)
        #expect(json["input_type"] as? String == "search_query")
        #expect(json["encoding_format"] as? String == "float")
        #expect(response.id == "embd-1")
        #expect(response.model == "embed/model")
    }

    @Test("rerank result retains document, model, provider and usage")
    func rerank() async throws {
        let transport = MockMediaTransport(responses: [.json(#"{"id":"gen-rerank-1","model":"rank/model","provider":"Cohere","results":[{"index":0,"relevance_score":0.9,"document":{"text":"one"}}],"usage":{"search_units":1,"total_tokens":12}}"#)])
        var request = RerankRequest(model: "rank/model", query: "q", documents: ["one"])
        request.topN = 1
        let response = try await EmbeddingService(transport: transport).rerank(request)
        #expect(response.id == "gen-rerank-1")
        #expect(response.model == "rank/model")
        #expect(response.provider == "Cohere")
        #expect(response.results.first?.document?.text == "one")
        #expect(response.usage?.searchUnits == 1)
        #expect(try contractJSON(request)["top_n"] as? Int == 1)
    }

    @Test("catalog uses explicit output modality filter, not text default")
    func catalog() async throws {
        let transport = MockMediaTransport(responses: [.json(#"{"data":[{"id":"speech/m","name":"Speech","architecture":{"output_modalities":["speech"]},"supported_voices":["speaker"]}]}"#)])
        let models = try await GenerateModelCatalog(transport: transport).fetch(outputModalities: ["speech", "transcription", "rerank"])
        #expect(models.first?.id == "speech/m")
        #expect(models.first?.outputModalities == ["speech"])
        #expect(models.first?.supportedVoices == ["speaker"])
        let sent = try #require(transport.sentRequests().first)
        #expect(sent.url?.query == "output_modalities=speech,transcription,rerank")
    }

    @Test("file page retains cursor and has_more, and query is encoded")
    func filePage() async throws {
        let transport = MockMediaTransport(responses: [.json(#"{"data":[],"has_more":true,"cursor":"next/token"}"#)])
        let page = try await FileService(transport: transport).listPage(cursor: "before/token", limit: 25)
        #expect(page.hasMore == true)
        #expect(page.cursor == "next/token")
        #expect(transport.sentRequests().first?.url?.query == "limit=25&cursor=before/token")
    }

    @Test("filename cannot inject multipart fields")
    func multipartFilename() async throws {
        let transport = MockMediaTransport(responses: [.json(#"{"id":"f"}"#)])
        _ = try await FileService(transport: transport).upload(filename: "bad\"\r\nX-Evil: yes", mimeType: "text/plain", data: Data("x".utf8))
        let body = String(decoding: try #require(transport.sentRequests().first?.httpBody), as: UTF8.self)
        #expect(!body.contains("\r\nX-Evil:"))
        #expect(!body.contains("filename=\"bad\""))
    }

    @Test("speech explicitly requests mp3 and propagates authenticated HTTP errors")
    func speech() async throws {
        let transport = MockMediaTransport(responses: [], rawResponses: [.bytes(Data([3, 4]), "audio/mpeg")])
        var request = SpeechRequest(model: "speech/m", input: "Hello")
        request.responseFormat = "mp3"
        let (bytes, mime) = try await SpeechService(transport: transport).synthesize(request)
        #expect(bytes == Data([3, 4]))
        #expect(mime == "audio/mpeg")
        let sent = try #require(transport.sentRawRequests().first)
        #expect(sent.url?.path == "/api/v1/audio/speech")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let bytesBody = try #require(sent.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bytesBody) as? [String: Any])
        #expect(body["response_format"] as? String == "mp3")
        let errorTransport = MockMediaTransport(responses: [.status(402, #"{"error":{"message":"Insufficient credits"}}"#)])
        do {
            _ = try await ImageGenService(transport: errorTransport).generate(ImageGenRequest(model: "m", prompt: "a"))
            Issue.record("Expected HTTP failure")
        } catch let error as MediaServiceError {
            #expect(error == .http(status: 402, message: "Insufficient credits"))
        }
    }

    @Test("invalid image reference count and page limit fail before credentials")
    func localValidation() async throws {
        let transport = MockMediaTransport(responses: [])
        var image = ImageGenRequest(model: "m", prompt: "a")
        image.inputReferences = Array(repeating: "https://example.com/a.png", count: 17)
        await #expect(throws: MediaServiceError.self) { try await ImageGenService(transport: transport).generate(image) }
        await #expect(throws: MediaServiceError.self) { try await FileService(transport: transport).listPage(limit: 1001) }
        await #expect(throws: MediaServiceError.self) { try await VideoGenService(transport: transport).download(VideoJob(id: "bad/segment", status: "completed")) }
        #expect(transport.keyCounter?.current == 0)
        #expect(transport.sentRequests().isEmpty)
        #expect(transport.sentRawRequests().isEmpty)
    }

    @Test("catalog decodes nullable capability without claiming lack of support")
    func nullableCatalogAndEmbeddingRoute() async throws {
        let transport = MockMediaTransport(responses: [.json(#"{"data":[{"id":"e/m","name":"Embed","architecture":{"output_modalities":["embeddings"]},"supported_voices":null}]}"#)])
        let result = try await GenerateModelCatalog(transport: transport).fetch(outputModalities: ["embeddings"])
        #expect(result.first?.supportedVoices == nil)
        #expect(result.first?.outputModalities == ["embeddings"])
        #expect(transport.sentRequests().first?.url?.absoluteString == "https://openrouter.ai/api/v1/embeddings/models")
    }

    @Test("transcription sends authenticated multipart and decodes result")
    func transcription() async throws {
        let transport = MockMediaTransport(responses: [.json(#"{"text":"hello","language":"en","duration":2.5}"#)])
        var request = TranscriptionRequest(model: "stt/model", filename: "voice.wav", mimeType: "audio/wav", audioData: Data([0, 1]))
        request.responseFormat = "verbose_json"
        let result = try await SpeechService(transport: transport).transcribe(request)
        #expect(result.text == "hello")
        #expect(result.duration == 2.5)
        let sent = try #require(transport.sentRequests().first)
        #expect(sent.url?.path == "/api/v1/audio/transcriptions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nstt/model"))
        #expect(body.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        #expect(body.contains("filename=\"voice.wav\""))
    }

    @Test("video indexed content remains canonical and invalid index sends nothing")
    func videoIndex() async throws {
        let transport = MockMediaTransport(responses: [], rawResponses: [.bytes(Data([9]), "video/mp4")])
        let service = VideoGenService(transport: transport)
        _ = try await service.download(VideoJob(id: "job-1", status: "completed"), index: 2)
        #expect(transport.sentRawRequests().first?.url?.query == "index=2")
        await #expect(throws: MediaServiceError.self) { try await service.download(VideoJob(id: "job-1", status: "completed"), index: -1) }
        #expect(transport.sentRawRequests().count == 1)
    }
}
