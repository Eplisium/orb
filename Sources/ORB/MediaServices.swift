import Foundation

// MARK: - Dedicated media-generation APIs
//
// Chat completions cover text, but OpenRouter ships separate routers for
// image generation (`POST /images`), video (`POST /videos` + polling),
// speech synthesis (`POST /audio/speech`), transcription
// (`POST /audio/transcriptions`), embeddings (`POST /embeddings`), and
// reranking (`POST /rerank`). This service owns all of them so ChatService
// stays focused on the streaming chat loop.

// MARK: - Shared authenticated transport

/// Minimal authenticated JSON client shared by every dedicated media API.
/// Every method throws `MediaServiceError` — never a raw URL error — so the
/// UI can show one coherent failure shape.
final class MediaTransport: Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    init(session: URLSession = .shared) { self.session = session }

    func apiKey() throws -> String {
        guard let key = KeychainManager.getAPIKey(), !key.isEmpty else {
            throw MediaServiceError.missingAPIKey
        }
        return key
    }

    func request(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(path),
            timeoutInterval: NetworkTimeouts.request
        )
        request.httpMethod = method
        request.setValue("Bearer \(try apiKey())", forHTTPHeaderField: "Authorization")
        request.setValue("ORB", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends the request and decodes a `Decodable` body, mapping HTTP
    /// failures to typed `MediaServiceError` cases.
    func send<T: Decodable>(_ request: URLRequest, as type: T.Type = T.self) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaServiceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MediaServiceError.transport("Invalid response from OpenRouter.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaServiceError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MediaServiceError.decoding(error.localizedDescription)
        }
    }

    /// Sends the request and returns raw bytes (audio/video downloads).
    func sendRaw(_ request: URLRequest) async throws -> (Data, String?) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaServiceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MediaServiceError.transport("Invalid response from OpenRouter.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaServiceError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(MediaErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        return text.isEmpty ? "Unknown error" : text
    }
}

private struct MediaErrorEnvelope: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}

enum MediaServiceError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, message: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Account first."
        case .http(let status, let message):
            switch status {
            case 401: return "OpenRouter rejected the API key. Check it in Account. \(message)"
            case 402: return "OpenRouter credits are exhausted. Add credits, then try again. \(message)"
            case 429: return "OpenRouter rate limit reached. Try again shortly. \(message)"
            default: return "OpenRouter HTTP \(status): \(message)"
            }
        case .transport(let message):
            return "Network error while contacting OpenRouter: \(message)"
        case .decoding(let message):
            return "Could not understand OpenRouter's response: \(message)"
        }
    }
}

// MARK: - Image generation (`POST /images`)

/// One model from `GET /images/models`.
struct ImageGenModel: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let created: Double?
    let architecture: ImageGenArchitecture?
    let supportedParameters: JSONValue?
    let supportsStreaming: Bool?
    let endpoints: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, created, architecture, endpoints
        case supportedParameters = "supported_parameters"
        case supportsStreaming = "supports_streaming"
    }
}

struct ImageGenArchitecture: Codable, Sendable, Hashable {
    let inputModalities: [String]?
    let outputModalities: [String]?

    enum CodingKeys: String, CodingKey {
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
    }

    var takesReferenceImages: Bool { inputModalities?.contains("image") == true }
}

struct ImageGenModelList: Decodable {
    let data: [ImageGenModel]
}

struct ImageGenRequest: Encodable {
    var model: String
    var prompt: String
    var n: Int? = nil
    var aspectRatio: String? = nil
    var resolution: String? = nil
    var quality: String? = nil
    var outputFormat: String? = nil
    var seed: Int? = nil
    var size: String? = nil
    /// Reference images (image-to-image): base64 data URLs or HTTPS URLs.
    var inputReferences: [String]? = nil
    var user: String? = nil

    enum CodingKeys: String, CodingKey {
        case model, prompt, n, seed, size, user
        case aspectRatio = "aspect_ratio"
        case resolution, quality
        case outputFormat = "output_format"
        case inputReferences = "input_references"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(n, forKey: .n)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        try container.encodeIfPresent(quality, forKey: .quality)
        try container.encodeIfPresent(outputFormat, forKey: .outputFormat)
        try container.encodeIfPresent(seed, forKey: .seed)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(inputReferences, forKey: .inputReferences)
        try container.encodeIfPresent(user, forKey: .user)
    }
}

struct ImageGenResponse: Decodable {
    struct Item: Decodable {
        let b64Json: String
        let mediaType: String?

        enum CodingKeys: String, CodingKey {
            case b64Json = "b64_json"
            case mediaType = "media_type"
        }
    }
    let created: Int?
    let data: [Item]
    let usage: ImageGenUsage?
}

struct ImageGenUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case cost
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

@MainActor
final class ImageGenService: ObservableObject {
    @Published var models: [ImageGenModel] = []
    @Published var isLoadingModels = false
    @Published var modelsError: String?
    @Published var isGenerating = false
    @Published var lastUsage: ImageGenUsage?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func fetchModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            let request = try transport.request(path: "images/models")
            let list: ImageGenModelList = try await transport.send(request)
            models = list.data.sorted { $0.name < $1.name }
        } catch is CancellationError {
            // Leave prior models in place; a cancelled refresh is not an error.
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// Generates images. Returns one `ChatImageAttachment` per image, with
    /// the prompt attached for gallery context.
    func generate(_ request: ImageGenRequest) async throws -> [ChatImageAttachment] {
        isGenerating = true
        defer { isGenerating = false }
        let body = try JSONEncoder().encode(request)
        let urlRequest = try transport.request(path: "images", method: "POST", body: body)
        let response: ImageGenResponse = try await transport.send(urlRequest)
        lastUsage = response.usage
        return response.data.map { item in
            let mime = item.mediaType ?? "image/png"
            return ChatImageAttachment(
                dataURL: "data:\(mime);base64,\(item.b64Json)",
                prompt: request.prompt
            )
        }
    }
}

// MARK: - Video generation (`POST /videos` + polling)

/// One model from `GET /videos/models`.
struct VideoGenModel: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let created: Double?
    let generateAudio: Bool?
    let seed: Bool?
    let supportedAspectRatios: [String]?
    let supportedResolutions: [String]?
    let supportedDurations: [Int]?
    let supportedFrameImages: [String]?
    let pricingSkus: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, created, seed
        case generateAudio = "generate_audio"
        case supportedAspectRatios = "supported_aspect_ratios"
        case supportedResolutions = "supported_resolutions"
        case supportedDurations = "supported_durations"
        case supportedFrameImages = "supported_frame_images"
        case pricingSkus = "pricing_skus"
    }
}

struct VideoGenModelList: Decodable {
    let data: [VideoGenModel]
}

struct VideoGenRequest: Encodable {
    var model: String
    var prompt: String?
    var aspectRatio: String? = nil
    var resolution: String? = nil
    var size: String? = nil
    var duration: Int? = nil
    var seed: Int? = nil
    var generateAudio: Bool? = nil
    /// Frame images as base64 data URLs or HTTPS URLs.
    var firstFrameImage: String? = nil
    var lastFrameImage: String? = nil

    enum CodingKeys: String, CodingKey {
        case model, prompt, resolution, size, duration, seed
        case aspectRatio = "aspect_ratio"
        case generateAudio = "generate_audio"
        case frameImages = "frame_images"
    }

    private struct FrameImage: Encodable {
        let frameType: String
        let image: String
        enum CodingKeys: String, CodingKey {
            case image
            case frameType = "frame_type"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(seed, forKey: .seed)
        try container.encodeIfPresent(generateAudio, forKey: .generateAudio)
        var frames: [FrameImage] = []
        if let firstFrameImage { frames.append(.init(frameType: "first_frame", image: firstFrameImage)) }
        if let lastFrameImage { frames.append(.init(frameType: "last_frame", image: lastFrameImage)) }
        if !frames.isEmpty { try container.encode(frames, forKey: .frameImages) }
    }
}

/// A video job: the submit response and every poll share this shape.
struct VideoJob: Decodable, Sendable, Equatable {
    let id: String
    let status: String
    let pollingURL: String?
    let generationId: String?
    let unsignedURLs: [String]?
    let error: String?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case id, status, error
        case pollingURL = "polling_url"
        case generationId = "generation_id"
        case unsignedURLs = "unsigned_urls"
        case usage
    }

    private struct Usage: Decodable { let cost: Double? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        pollingURL = try container.decodeIfPresent(String.self, forKey: .pollingURL)
        generationId = try container.decodeIfPresent(String.self, forKey: .generationId)
        unsignedURLs = try container.decodeIfPresent([String].self, forKey: .unsignedURLs)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        cost = try container.decodeIfPresent(Usage.self, forKey: .usage)?.cost
    }

    var isTerminal: Bool {
        ["completed", "failed", "cancelled", "expired"].contains(status)
    }

    var isSuccess: Bool { status == "completed" }

    /// Direct construction for locally-tracked jobs (submit placeholders,
    /// failure records). Wire decoding uses `init(from:)`.
    init(id: String, status: String, pollingURL: String? = nil, generationId: String? = nil,
         unsignedURLs: [String]? = nil, error: String? = nil, cost: Double? = nil) {
        self.id = id
        self.status = status
        self.pollingURL = pollingURL
        self.generationId = generationId
        self.unsignedURLs = unsignedURLs
        self.error = error
        self.cost = cost
    }
}

@MainActor
final class VideoGenService: ObservableObject {
    @Published var models: [VideoGenModel] = []
    @Published var isLoadingModels = false
    @Published var modelsError: String?
    @Published var activeJob: VideoJob?
    @Published var jobError: String?

    private let transport: MediaTransport
    private var pollTask: Task<Void, Never>?

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func fetchModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            let request = try transport.request(path: "videos/models")
            let list: VideoGenModelList = try await transport.send(request)
            models = list.data.sorted { $0.name < $1.name }
        } catch is CancellationError {
            // Leave prior models in place; a cancelled refresh is not an error.
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// Submits the job, then polls until it reaches a terminal status.
    /// Calls `onUpdate` on every poll so the UI can show progress.
    func submitAndPoll(
        _ request: VideoGenRequest,
        pollInterval: Duration = .seconds(5),
        onUpdate: @escaping @Sendable (VideoJob) -> Void = { _ in }
    ) async throws -> VideoJob {
        stopPolling()
        let body = try JSONEncoder().encode(request)
        let submit = try transport.request(path: "videos", method: "POST", body: body)
        var job: VideoJob = try await transport.send(submit)
        activeJob = job
        onUpdate(job)
        while !job.isTerminal {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
            try Task.checkCancellation()
            // Prefer the absolute polling URL when given, else the job path.
            let path = job.pollingURL?.replacingOccurrences(of: "/api/v1/", with: "") ?? "videos/\(job.id)"
            let poll = try transport.request(path: path)
            job = try await transport.send(poll)
            activeJob = job
            onUpdate(job)
        }
        guard job.isSuccess else {
            throw MediaServiceError.transport(job.error ?? "Video generation \(job.status).")
        }
        return job
    }

    /// Downloads the finished video bytes (first unsigned URL).
    func download(_ job: VideoJob) async throws -> (Data, String?) {
        guard let urlString = job.unsignedURLs?.first, let url = URL(string: urlString) else {
            throw MediaServiceError.decoding("Video job has no download URL yet.")
        }
        var request = URLRequest(url: url, timeoutInterval: NetworkTimeouts.request)
        request.httpMethod = "GET"
        return try await transport.sendRaw(request)
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

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

    /// Multipart body. OpenRouter also accepts a JSON `input_audio` form,
    /// but multipart avoids an extra ~33% base64 overhead on device.
    /// Max 25 MB; larger files must use the JSON form (not implemented).
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

    enum CodingKeys: String, CodingKey { case text, language, duration, task }
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
        return try await transport.sendRaw(urlRequest)
    }

    /// Transcribes audio bytes to text via multipart upload.
    /// Max 25 MB — the API rejects larger multipart files.
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        guard request.audioData.count <= 25_000_000 else {
            throw MediaServiceError.transport("Audio file is larger than the 25 MB transcription limit.")
        }
        isWorking = true
        defer { isWorking = false }
        let boundary = "ORB-\(UUID().uuidString)"
        var urlRequest = try transport.request(path: "audio/transcriptions", method: "POST")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.multipartBody(boundary: boundary)
        return try await transport.send(urlRequest)
    }
}

// MARK: - Embeddings (`POST /embeddings`) + rerank (`POST /rerank`)

struct EmbeddingRequest: Encodable {
    var model: String
    var input: [String]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EmbedKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(input, forKey: .input)
    }

    private enum EmbedKeys: String, CodingKey { case model, input }
}

struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        let index: Int?
        let embedding: [Double]
    }
    let data: [Item]
    let usage: ImageGenUsage?
}

struct RerankRequest: Encodable {
    var model: String
    var query: String
    var documents: [String]
    var topN: Int? = nil

    enum CodingKeys: String, CodingKey {
        case model, query, documents
        case topN = "top_n"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(query, forKey: .query)
        try container.encode(documents, forKey: .documents)
        try container.encodeIfPresent(topN, forKey: .topN)
    }
}

struct RerankResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let relevanceScore: Double?

        enum CodingKeys: String, CodingKey {
            case index
            case relevanceScore = "relevance_score"
        }
    }
    let results: [Item]
}

@MainActor
final class EmbeddingService: ObservableObject {
    @Published var isWorking = false
    @Published var lastError: String?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        isWorking = true
        defer { isWorking = false }
        let body = try JSONEncoder().encode(request)
        let urlRequest = try transport.request(path: "embeddings", method: "POST", body: body)
        return try await transport.send(urlRequest)
    }

    func rerank(_ request: RerankRequest) async throws -> RerankResponse {
        isWorking = true
        defer { isWorking = false }
        let body = try JSONEncoder().encode(request)
        let urlRequest = try transport.request(path: "rerank", method: "POST", body: body)
        return try await transport.send(urlRequest)
    }
}

// MARK: - Files (`/files`)

/// One file in the workspace file list.
struct WorkspaceFile: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let filename: String?
    let mimeType: String?
    let sizeBytes: Int?
    let createdAt: String?
    let downloadable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, filename
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
        case downloadable
    }
}

struct WorkspaceFileList: Decodable {
    let data: [WorkspaceFile]
}

@MainActor
final class FileService: ObservableObject {
    @Published var files: [WorkspaceFile] = []
    @Published var isLoading = false
    @Published var lastError: String?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func fetchFiles() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let request = try transport.request(path: "files")
            let list: WorkspaceFileList = try await transport.send(request)
            files = list.data
        } catch is CancellationError {
            // Leave prior files in place; a cancelled refresh is not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Uploads raw bytes as multipart/form-data. Returns the stored file.
    func upload(filename: String, mimeType: String, data: Data) async throws -> WorkspaceFile {
        let boundary = "ORB-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var request = try transport.request(path: "files", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await transport.send(request)
    }

    func delete(id: String) async throws {
        let request = try transport.request(path: "files/\(id)", method: "DELETE")
        // Delete returns `{id, type: "file_deleted"}` — not a file record.
        struct DeleteConfirmation: Decodable {
            let id: String?
        }
        let _: DeleteConfirmation = try await transport.send(request)
        files.removeAll { $0.id == id }
    }

    /// Downloads raw bytes for server-side files (uploads return 400).
    func downloadContent(id: String) async throws -> (Data, String?) {
        let request = try transport.request(path: "files/\(id)/content")
        return try await transport.sendRaw(request)
    }
}

// MARK: - Generation metadata (`GET /generation`)

/// Per-request metadata for a completed generation (`gen-…` id).
struct GenerationMetadata: Decodable {
    struct Payload: Decodable {
        let id: String?
        let model: String?
        let providerName: String?
        let finishReason: String?
        let totalCost: Double?
        let tokensPrompt: Int?
        let tokensCompletion: Int?
        let latency: Int?
        let streamed: Bool?

        enum CodingKeys: String, CodingKey {
            case id, model, latency, streamed
            case providerName = "provider_name"
            case finishReason = "finish_reason"
            case totalCost = "total_cost"
            case tokensPrompt = "tokens_prompt"
            case tokensCompletion = "tokens_completion"
        }
    }
    let data: Payload
}

@MainActor
final class GenerationService: ObservableObject {
    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func fetch(id: String) async throws -> GenerationMetadata.Payload {
        let request = try transport.request(path: "generation?id=\(id)")
        let response: GenerationMetadata = try await transport.send(request)
        return response.data
    }
}

// MARK: - Providers, key info, usage accounting

/// One row of `GET /providers`.
struct ProviderInfo: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let slug: String

    var id: String { slug }

    enum CodingKeys: String, CodingKey { case name, slug }
}

struct ProviderList: Decodable {
    let data: [ProviderInfo]
}

/// `GET /key` — info about the current API key (limits, usage).
struct KeyInfo: Decodable {
    let label: String?
    let usage: Double?
    let limit: Double?
    let limitRemaining: Double?
    let limitReset: String?
    let usageDaily: Double?
    let usageWeekly: Double?
    let usageMonthly: Double?
    let isFreeTier: Bool?
    let isProvisioningKey: Bool?
    let isManagementKey: Bool?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case label, usage, limit
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
        case isFreeTier = "is_free_tier"
        case isProvisioningKey = "is_provisioning_key"
        case isManagementKey = "is_management_key"
        case expiresAt = "expires_at"
    }
}

@MainActor
final class DirectoryService: ObservableObject {
    @Published var providers: [ProviderInfo] = []
    @Published var keyInfo: KeyInfo?
    @Published var lastError: String?

    private let transport: MediaTransport

    init(transport: MediaTransport = MediaTransport()) { self.transport = transport }

    func fetchProviders() async {
        do {
            // Public endpoint, but MediaTransport requires a key; fall back to
            // an unauthenticated fetch when none is configured.
            if KeychainManager.getAPIKey() == nil {
                let url = URL(string: "https://openrouter.ai/api/v1/providers")!
                let (data, _) = try await URLSession.shared.data(from: url)
                providers = try JSONDecoder().decode(ProviderList.self, from: data).data
            } else {
                let request = try transport.request(path: "providers")
                let list: ProviderList = try await transport.send(request)
                providers = list.data
            }
        } catch is CancellationError {
            // Leave prior providers in place; a cancelled refresh is not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func fetchKeyInfo() async {
        do {
            let request = try transport.request(path: "key")
            struct Envelope: Decodable { let data: KeyInfo }
            keyInfo = try await transport.send(request, as: Envelope.self).data
        } catch is CancellationError {
            // Leave prior key info in place; a cancelled refresh is not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }
}
