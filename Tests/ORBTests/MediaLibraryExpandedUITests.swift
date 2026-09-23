import Foundation
import Testing
@testable import ORB

@Suite("Expanded media library controls")
struct MediaLibraryExpandedUITests {
    @Test("Unknown and explicitly unsupported voice catalogs remain distinct")
    func voiceCapabilities() throws {
        func model(_ json: String) throws -> GenerateCatalogModel {
            try JSONDecoder().decode(GenerateCatalogModel.self, from: Data(json.utf8))
        }
        #expect(CatalogCapability.voice(for: nil) == .unknown)
        #expect(CatalogCapability.voice(for: try model(#"{"id":"a/unknown","name":"Unknown"}"#)) == .unknown)
        #expect(CatalogCapability.voice(for: try model(#"{"id":"a/none","name":"None","supported_voices":[]}"#)) == .unsupported)
        #expect(CatalogCapability.voice(for: try model(#"{"id":"a/yes","name":"Yes","supported_voices":["alice"]}"#)) == .supported)
    }

    @Test("Embedding batch results pair by response index, rejecting missing or duplicate indices")
    func orderedVectors() throws {
        let items = try JSONDecoder().decode([EmbeddingResponse.Item].self,
            from: Data(#"[{"index":1,"embedding":[2.0]},{"index":0,"embedding":[1.0]}]"#.utf8))
        #expect(try orderedEmbeddingVectors(items, inputCount: 2) == [[1], [2]])
        #expect(throws: (any Error).self) { try orderedEmbeddingVectors(items, inputCount: 1) }
        let duplicate = try JSONDecoder().decode([EmbeddingResponse.Item].self,
            from: Data(#"[{"index":0,"embedding":[1.0]},{"index":0,"embedding":[2.0]}]"#.utf8))
        #expect(throws: (any Error).self) { try orderedEmbeddingVectors(duplicate, inputCount: 2) }
    }

    @Test("MP3 must be explicit, batch embeddings remain float, timestamps require verbose JSON")
    func requestOptions() throws {
        var speech = SpeechRequest(model: "discovered/model", input: "hello")
        speech.responseFormat = "mp3"
        let encodedSpeech = try JSONSerialization.jsonObject(with: JSONEncoder().encode(speech)) as! [String: Any]
        #expect(encodedSpeech["response_format"] as? String == "mp3")

        var embed = EmbeddingRequest(model: "discovered/embed", input: ["one", "two"])
        embed.dimensions = 32
        embed.inputType = "query"
        embed.encodingFormat = "float"
        let encodedEmbed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(embed)) as! [String: Any]
        #expect(encodedEmbed["input"] as? [String] == ["one", "two"])
        #expect(encodedEmbed["dimensions"] as? Int == 32)
        #expect(encodedEmbed["input_type"] as? String == "query")
        #expect(encodedEmbed["encoding_format"] as? String == "float")

        var transcription = TranscriptionRequest(model: "discovered/stt", filename: "clip.wav",
                                                  mimeType: "audio/wav", audioData: Data([0x52]))
        transcription.responseFormat = "verbose_json"
        transcription.timestampGranularities = ["word", "segment"]
        let multipart = String(decoding: transcription.multipartBody(boundary: "test"), as: UTF8.self)
        #expect(multipart.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        #expect(multipart.contains("name=\"timestamp_granularities[]\"\r\n\r\nword"))
    }

    @Test("Saved media extensions never present audio/video as text")
    func mediaExtensions() {
        func extensionFor(_ mime: String) -> String {
            creationExtension(SavedCreation(id: UUID(), kind: .audio, modelID: "m", prompt: nil,
                                           mimeType: mime, createdAt: Date(), assetPath: "", checksum: ""))
        }
        #expect(extensionFor("audio/mpeg") == "mp3")
        #expect(extensionFor("audio/pcm") == "pcm")
        #expect(extensionFor("video/mp4") == "mp4")
    }
}
