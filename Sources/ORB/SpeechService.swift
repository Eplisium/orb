import Foundation

// MARK: - Speech: TTS (`POST /audio/speech`) + STT (`POST /audio/transcriptions`)

struct SpeechRequest: Encodable {
    var model: String
    var input: String
    var voice: String?
    var responseFormat: String? = nil
    var speed: Double? = nil

    enum CodingKeys: String, CodingKey {
        case model, input, voice, speed
        case responseFormat = "response_format"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(input, forKey: .input)
        try container.encodeIfPresent(voice, forKey: .voice)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        try container.encodeIfPresent(speed, forKey: .speed)
    }
}

struct TranscriptionRequest: Encodable {
    var model: String
    var filename: String
    var mimeType: String
    var audioData: Data
    var language: String? = nil
    var responseFormat: String? = nil
    var temperature: Double? = nil
    var timestampGranularities: [String]? = nil

    /// Multipart is limited to 25 MB; the documented JSON input_audio form
    /// accepts larger files. Keep threshold independently testable without
    /// allocating a giant fixture.
    static func usesJSONInputAudio(byteCount: Int) -> Bool { byteCount > 25_000_000 }

    /// STTRequest JSON: raw base64 bytes, never a data URI.
    func jsonBody() throws -> Data {
        struct InputAudio: Encodable { let data: String; let format: String }
        struct Body: Encodable {
            let model: String
            let inputAudio: InputAudio
            let language: String?
            let responseFormat: String?
            let temperature: Double?
            let timestampGranularities: [String]?
            enum CodingKeys: String, CodingKey {
                case model, language, temperature
                case inputAudio = "input_audio"
                case responseFormat = "response_format"
                case timestampGranularities = "timestamp_granularities"
            }
        }
        let format = (filename as NSString).pathExtension.lowercased()
        guard !format.isEmpty, format.range(of: "^[a-zA-Z0-9][a-zA-Z0-9+._-]{0,15}$", options: .regularExpression) != nil else {
            throw MediaServiceError.invalidUpload("JSON transcription requires a supported audio filename extension (format).")
        }
        return try JSONEncoder().encode(Body(model: model,
            inputAudio: InputAudio(data: audioData.base64EncodedString(), format: format),
            language: language, responseFormat: responseFormat,
            temperature: temperature, timestampGranularities: timestampGranularities))
    }

    /// Multipart body. OpenRouter also accepts a JSON `input_audio` form,
    /// but multipart avoids an extra ~33% base64 overhead on device.
    /// Files above 25 MB use the documented JSON input_audio form instead.
    func multipartBody(boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("model", model)
        if let language { field("language", language) }
        if let responseFormat { field("response_format", responseFormat) }
        if let temperature { field("temperature", String(temperature)) }
        for granularity in timestampGranularities ?? [] { field("timestamp_granularities[]", granularity) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

struct TranscriptionResponse: Decodable {
    let text: String
    let language: String?
    let duration: Double?
    let task: String?
    let confidence: Double?
    let usage: Usage?
    let segments: [Segment]?
    let words: [Word]?

    struct Usage: Decodable {
        let cost: Double?
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        let seconds: Double?
        enum CodingKeys: String, CodingKey {
            case cost, seconds
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }
    }
    struct Segment: Decodable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
        let speaker: Int?
        let seek: Int?
        let tokens: [Int]?
        let temperature: Double?
        let avgLogprob: Double?
        let compressionRatio: Double?
        let noSpeechProb: Double?
        enum CodingKeys: String, CodingKey {
            case id, start, end, text, speaker, seek, tokens, temperature
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
            case noSpeechProb = "no_speech_prob"
        }
    }
    struct Word: Decodable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Double?
        let speaker: Int?
    }

    enum CodingKeys: String, CodingKey { case text, language, duration, task, confidence, usage, segments, words }
}

@MainActor
final class SpeechService: ObservableObject {
    @Published var isWorking = false
    @Published var lastError: String?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    /// Synthesizes speech; returns raw audio bytes plus the MIME type.
    func synthesize(_ request: SpeechRequest) async throws -> (Data, String?) {
        isWorking = true
        defer { isWorking = false }
        let body = try JSONEncoder().encode(request)
        let urlRequest = try transport.request(path: "audio/speech", method: "POST", body: body)
        let output = try await transport.sendRaw(urlRequest)
        // Raw audio bodies carry no usage block, so spend is unknown here.
        UsageLedger.shared.record(.speech, model: request.model, cost: nil)
        return output
    }

    /// Transcribes audio bytes to text via multipart upload.
    /// Multipart through 25 MB, documented base64 JSON for larger files.
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        guard request.timestampGranularities?.allSatisfy({ ["word", "segment"].contains($0) }) ?? true else {
            throw MediaServiceError.invalidUpload("Timestamp granularity must be word or segment.")
        }
        guard request.audioData.count <= LocalFilePreflight.maxTranscriptionBytes else {
            throw MediaServiceError.invalidUpload("\"\(request.filename)\" exceeds the 100 MB transcription limit.")
        }
        isWorking = true
        defer { isWorking = false }
        if TranscriptionRequest.usesJSONInputAudio(byteCount: request.audioData.count) {
            let body = try request.jsonBody()
            let large: TranscriptionResponse = try await transport.send(transport.request(path: "audio/transcriptions", method: "POST", body: body))
            recordTranscription(large, model: request.model)
            return large
        }
        let boundary = "ORB-\(UUID().uuidString)"
        var urlRequest = try transport.request(path: "audio/transcriptions", method: "POST")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.multipartBody(boundary: boundary)
        let response: TranscriptionResponse = try await transport.send(urlRequest)
        recordTranscription(response, model: request.model)
        return response
    }

    private func recordTranscription(_ response: TranscriptionResponse, model: String) {
        UsageLedger.shared.record(.transcription, model: model, cost: response.usage?.cost,
                                  promptTokens: response.usage?.inputTokens,
                                  completionTokens: response.usage?.outputTokens,
                                  totalTokens: response.usage?.totalTokens)
    }
}
