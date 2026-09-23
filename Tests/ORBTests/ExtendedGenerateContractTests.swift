import Foundation
import Testing
@testable import ORB

@Suite("Extended Generate OpenAPI contracts", .serialized)
@MainActor
struct ExtendedGenerateContractTests {
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test("image provider pin and optional background/compression use documented keys")
    func imageOptions() throws {
        var request = ImageGenRequest(model: "image/model", prompt: "draw")
        #expect(try object(request).keys.sorted() == ["model", "prompt"])
        request.provider = ImageGenerationProviderPreferences(only: ["google-ai-studio"], allowFallbacks: false)
        request.background = "transparent"
        request.outputFormat = "png"
        request.outputCompression = 75
        let json = try object(request)
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["google-ai-studio"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        #expect(json["background"] as? String == "transparent")
        #expect(json["output_compression"] as? Int == 75)
    }

    @Test("invalid image options are rejected before credential lookup")
    func imageValidation() async throws {
        let transport = MockMediaTransport(responses: [])
        let service = ImageGenService(transport: transport)
        var request = ImageGenRequest(model: "m", prompt: "x")
        request.n = 11
        await #expect(throws: MediaServiceError.self) { try await service.generate(request) }
        request.n = nil
        request.background = "transparent"
        request.outputFormat = "jpeg"
        await #expect(throws: MediaServiceError.self) { try await service.generate(request) }
        request.background = nil
        request.outputCompression = 101
        await #expect(throws: MediaServiceError.self) { try await service.generate(request) }
        #expect(transport.keyCounter?.current == 0)
    }

    @Test("video references serialize as discriminated image/audio/video parts")
    func videoReferences() throws {
        var request = VideoGenRequest(model: "video/model")
        #expect(try object(request)["input_references"] == nil)
        request.inputReferences = [.image(url: "https://example.com/i.png"), .audio(url: "https://example.com/a.mp3"), .video(url: "https://example.com/v.mp4")]
        let references = try #require(object(request)["input_references"] as? [[String: Any]])
        for (index, type) in ["image", "audio", "video"].enumerated() {
            #expect(references[index]["type"] as? String == "\(type)_url")
            #expect((references[index]["\(type)_url"] as? [String: String])?["url"] == ["https://example.com/i.png", "https://example.com/a.mp3", "https://example.com/v.mp4"][index])
        }
    }

    @Test("nullable video model capabilities retain supported sizes and passthrough names")
    func videoCapabilities() throws {
        let json = #"{"data":[{"id":"v/m","name":"Video","supported_sizes":["1280x720"],"allowed_passthrough_parameters":["style"],"canonical_slug":"v/m","creativity":[1,2],"upscale_factor":{"min":1,"max":4}},{"id":"v/other","name":"Other","supported_sizes":null}]}"#
        let list = try JSONDecoder().decode(VideoGenModelList.self, from: Data(json.utf8))
        #expect(list.data[0].supportedSizes == ["1280x720"])
        #expect(list.data[0].allowedPassthroughParameters == ["style"])
        #expect(list.data[0].canonicalSlug == "v/m")
        #expect(list.data[0].creativity == [1, 2])
        #expect(list.data[0].upscaleFactor?.max == 4)
        #expect(list.data[1].supportedSizes == nil)
    }

    @Test("multipart timestamps use bracket field; JSON audio is raw base64 with plural timestamps")
    func transcriptionOptions() throws {
        var request = TranscriptionRequest(model: "stt/m", filename: "a.wav", mimeType: "audio/wav", audioData: Data([1, 2]))
        request.responseFormat = "verbose_json"
        request.timestampGranularities = ["segment", "word"]
        let multipart = String(decoding: request.multipartBody(boundary: "test"), as: UTF8.self)
        #expect(multipart.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment"))
        #expect(multipart.contains("name=\"timestamp_granularities[]\"\r\n\r\nword"))
        let json = try #require(JSONSerialization.jsonObject(with: request.jsonBody()) as? [String: Any])
        #expect((json["input_audio"] as? [String: String]) == ["data": "AQI=", "format": "wav"])
        #expect(json["timestamp_granularities"] as? [String] == ["segment", "word"])
        #expect(TranscriptionRequest.usesJSONInputAudio(byteCount: 25_000_001))
        #expect(!TranscriptionRequest.usesJSONInputAudio(byteCount: 25_000_000))
        request.timestampGranularities = nil
        request.responseFormat = nil
        let sparse = try #require(JSONSerialization.jsonObject(with: request.jsonBody()) as? [String: Any])
        #expect(sparse["timestamp_granularities"] == nil)
        #expect(sparse["response_format"] == nil)
    }

    @Test("transcription optional usage, segments and words decode without inventing values")
    func transcriptionResponse() throws {
        let detailed = #"{"text":"Hello","usage":{"cost":0.01,"input_tokens":2,"output_tokens":3,"seconds":1.2,"total_tokens":5},"segments":[{"id":0,"start":0,"end":1,"text":"Hello","speaker":1}],"words":[{"word":"Hello","start":0,"end":1,"confidence":0.98}],"confidence":0.94}"#
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(detailed.utf8))
        #expect(response.usage?.totalTokens == 5)
        #expect(response.segments?.first?.speaker == 1)
        #expect(response.words?.first?.confidence == 0.98)
        #expect(response.confidence == 0.94)
        let sparse = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(#"{"text":"Hi"}"#.utf8))
        #expect(sparse.usage == nil)
        #expect(sparse.words == nil)
        #expect(sparse.segments == nil)
    }

    @Test("file metadata uses documented GET route")
    func fileMetadata() async throws {
        let transport = MockMediaTransport(responses: [.json(#"{"id":"or_file_123","filename":"a.pdf","size_bytes":12,"downloadable":false}"#)])
        let file = try await FileService(transport: transport).getMetadata(id: "or_file_123")
        #expect(file.sizeBytes == 12)
        #expect(transport.sentRequests().first?.url?.path == "/api/v1/files/or_file_123")
        #expect(transport.sentRequests().first?.httpMethod == "GET")
    }
}
