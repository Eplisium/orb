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

/// Builds `/api/v1` endpoint URLs and enforces the exact origin policy for
/// caller-supplied polling references.
///
/// Path components and query items are kept strictly separate. Path segments
/// are percent-encoded individually, and a path containing `?` or `#` is
/// rejected instead of being silently folded into the path (which
/// historically produced `/generation%3Fid=…`). `pollingURL(_:base:)`
/// resolves a supplied polling reference (absolute URL, absolute path, or
/// relative reference) and validates it before any credential may be
/// attached.
enum MediaEndpointURL {
    /// Canonical API base for every authenticated media request.
    static let apiBase = URL(string: "https://openrouter.ai/api/v1")!
    static let allowedHost = "openrouter.ai"
    static let allowedPathPrefix = "/api/v1/"

    static func url(path: String, queryItems: [URLQueryItem] = [], base: URL = apiBase) throws -> URL {
        guard !path.isEmpty, !path.contains("?"), !path.contains("#") else {
            throw MediaServiceError.invalidPath(path)
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment -> String in
                let raw = String(segment).removingPercentEncoding ?? String(segment)
                return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            }
            .joined(separator: "/")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if !encoded.isEmpty {
            components.percentEncodedPath = components.percentEncodedPath + "/" + encoded
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw MediaServiceError.invalidPath(path)
        }
        return url
    }

    /// Resolves a polling reference against the API base and validates the
    /// exact policy before any credential is attached: HTTPS, host
    /// `openrouter.ai`, standard port, no user info, and a path under
    /// `/api/v1/`. Anything else throws `MediaServiceError.untrustedURL`.
    static func pollingURL(_ reference: String, base: URL = apiBase) throws -> URL {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MediaServiceError.untrustedURL(reference)
        }
        if let candidate = URL(string: trimmed), candidate.scheme != nil {
            return try validate(candidate, original: reference)
        }
        let resolutionBase = URL(
            string: base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        )!
        guard let resolved = URL(string: trimmed, relativeTo: resolutionBase) else {
            throw MediaServiceError.untrustedURL(reference)
        }
        return try validate(resolved.absoluteURL, original: reference)
    }

    /// Validates that `url` is an approved API origin. Callers must invoke
    /// this before attaching any bearer credential to a request.
    static func validate(_ url: URL, original: String) throws -> URL {
        func reject() -> MediaServiceError { .untrustedURL(original) }
        guard url.scheme?.lowercased() == "https" else { throw reject() }
        guard url.host?.lowercased() == allowedHost else { throw reject() }
        guard url.port == nil || url.port == 443 else { throw reject() }
        guard url.user == nil, url.password == nil else { throw reject() }
        guard url.path.hasPrefix(allowedPathPrefix), url.path.count > allowedPathPrefix.count else {
            throw reject()
        }
        let segments = url.path.split(separator: "/")
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { throw reject() }
        return url
    }
}

/// Minimal authenticated JSON client shared by every dedicated media API.
/// Every method throws `MediaServiceError` — never a raw URL error — so the
/// UI can show one coherent failure shape.
/// `open` only so tests can inject a recording double that overrides
/// `send`; the request builders themselves stay shared with production.
open class MediaTransport: @unchecked Sendable {
    private let session: URLSession
    private let baseURL = MediaEndpointURL.apiBase
    private let apiKeyProvider: @Sendable () throws -> String

    init(session: URLSession = .shared, apiKeyProvider: (@Sendable () throws -> String)? = nil) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider ?? Self.defaultAPIKeyProvider
    }

    private static let defaultAPIKeyProvider: @Sendable () throws -> String = {
        guard let key = KeychainManager.getAPIKey(), !key.isEmpty else {
            throw MediaServiceError.missingAPIKey
        }
        return key
    }

    func apiKey() throws -> String { try apiKeyProvider() }

    /// Builds a request for an already-validated absolute URL. The origin
    /// policy is re-checked here so the bearer token can never be attached
    /// to an unapproved origin; validation happens before the credential is
    /// fetched and attached.
    func request(url: URL, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let approved = try MediaEndpointURL.validate(url, original: url.absoluteString)
        var request = URLRequest(url: approved, timeoutInterval: NetworkTimeouts.request)
        request.httpMethod = method
        request.setValue("Bearer \(try apiKey())", forHTTPHeaderField: "Authorization")
        // F12: no HTTP-Referer is sent — optional URL attribution stays
        // omitted until there is an owner-approved URL. The documented
        // display name is kept.
        request.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Builds a request from a canonical path plus explicit query items.
    /// Path components and query items stay strictly separate: `path` must
    /// not contain `?` or `#`, and query values are percent-encoded.
    func request(path: String, queryItems: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) throws -> URLRequest {
        try request(url: MediaEndpointURL.url(path: path, queryItems: queryItems, base: baseURL), method: method, body: body)
    }

    /// Sends the request and decodes a `Decodable` body, mapping HTTP
    /// failures to typed `MediaServiceError` cases.
    open func send<T: Decodable>(_ request: URLRequest, as type: T.Type = T.self) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // A locally-cancelled request must surface as CancellationError,
            // never as a transport failure.
            throw CancellationError()
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
    /// `open` so tests can capture credential-free download requests.
    open func sendRaw(_ request: URLRequest) async throws -> (Data, String?) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // A locally-cancelled request must surface as CancellationError,
            // never as a transport failure.
            throw CancellationError()
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
    /// A request path contained query/fragment separators (`?`/`#`); paths
    /// and query items must be supplied separately.
    case invalidPath(String)
    /// A caller-supplied polling URL failed the exact origin policy.
    case untrustedURL(String)
    case http(status: Int, message: String)
    case transport(String)
    case decoding(String)
    /// A media/file request was rejected locally (before any request was
    /// sent) — e.g. an empty or oversized file upload.
    case invalidUpload(String)
    /// A destructive operation was invoked without the explicit
    /// confirmation the service layer requires.
    case deleteNotConfirmed(String)
    /// A durable job record cannot be resumed (no remote ID, or already
    /// terminal).
    case resumeUnavailable(String)

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
        case .invalidPath(let path):
            return "Invalid API path \"\(path)\": supply the path and query items separately (paths cannot contain '?' or '#')."
        case .invalidUpload(let message):
            return message
        case .deleteNotConfirmed(let id):
            return "Deleting file \(id) requires explicit confirmation. Deletion is irreversible."
        case .resumeUnavailable(let reason):
            return "This job cannot be resumed: \(reason)"
        case .untrustedURL(let reference):
            return "Refusing to send credentials to an unapproved URL: \(reference). Only HTTPS URLs on openrouter.ai with a path under /api/v1/ are allowed."
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

// MARK: Image endpoint discovery (`GET /images/models/{author}/{slug}/endpoints`)

/// One billable pricing line of an image endpoint (documented
/// `ImagePricingEntry` shape). `billable` values include `output_image`,
/// `input_image`, `input_reference`, …; `unit` is `image`, `megapixel`,
/// `token`, or `request`; `variant` carries resolution-tier pricing (e.g.
/// `2k`, `4k`). Never present these lines as token rates.
struct ImageEndpointPricing: Decodable, Hashable, Sendable {
    let billable: String
    let unit: String
    let costUSD: Double
    let variant: String?

    enum CodingKeys: String, CodingKey {
        case billable, unit, variant
        case costUSD = "cost_usd"
    }
}

/// Typed capability descriptor for one supported parameter of an image
/// endpoint. Documented types: `enum` (discrete value allowlist), `range`
/// (integer `[min, max]`), and `boolean` (present = supported). Unknown
/// descriptor types decode as `.unknown` instead of failing the response.
enum ImageEndpointCapability: Decodable, Hashable, Sendable {
    case enumValues([String])
    case range(min: Double, max: Double)
    case boolean
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type, values, min, max }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "enum":
            if let values = try? container.decode([String].self, forKey: .values) {
                self = .enumValues(values)
                return
            }
        case "range":
            if let min = try? container.decode(Double.self, forKey: .min),
               let max = try? container.decode(Double.self, forKey: .max) {
                self = .range(min: min, max: max)
                return
            }
        case "boolean":
            self = .boolean
            return
        default:
            break
        }
        self = .unknown(type: type)
    }
}

/// One per-provider endpoint of an image model (documented
/// `ImageEndpoint` shape). Every field except `provider_tag` (nullable) is
/// required by the schema; the definitive per-endpoint parameter set lives
/// in `supportedParameters` (a subset of the model-level union).
struct ImageModelEndpoint: Decodable, Hashable, Sendable, Identifiable {
    var id: String { providerSlug }
    let providerName: String
    let providerSlug: String
    /// Pin requests to a specific provider; `nil` when provider-level
    /// routing is unavailable.
    let providerTag: String?
    let supportedParameters: [String: ImageEndpointCapability]
    let allowedPassthroughParameters: [String]
    let supportsStreaming: Bool
    let pricing: [ImageEndpointPricing]

    enum CodingKeys: String, CodingKey {
        case providerName = "provider_name"
        case providerSlug = "provider_slug"
        case providerTag = "provider_tag"
        case supportedParameters = "supported_parameters"
        case allowedPassthroughParameters = "allowed_passthrough_parameters"
        case supportsStreaming = "supports_streaming"
        case pricing
    }
}

/// Documented `ImageModelEndpointsResponse`: top-level `{id, endpoints}` —
/// deliberately not wrapped in a `data` envelope like the model lists.
struct ImageModelEndpointsResponse: Decodable, Sendable {
    let id: String
    let endpoints: [ImageModelEndpoint]
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

    /// Lists the per-provider endpoints for an image model
    /// (`GET /images/models/{author}/{slug}/endpoints`), sorted by provider
    /// slug. The model ID's `author/slug` segments are percent-encoded
    /// individually by `MediaEndpointURL`; a `?`/`#` in the ID is rejected.
    /// No query parameters are documented for this route, so none are sent.
    func fetchImageModelEndpoints(modelID: String) async throws -> [ImageModelEndpoint] {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MediaServiceError.invalidPath(modelID)
        }
        let request = try transport.request(path: "images/models/\(trimmed)/endpoints")
        let response: ImageModelEndpointsResponse = try await transport.send(request)
        return response.endpoints.sorted { $0.providerSlug < $1.providerSlug }
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
    /// Application-owned durable job state (W06). Injectable so tests can
    /// isolate storage; the default view path uses the shared controller so
    /// job records survive navigation and app restarts.
    private let jobController: JobController
    /// The owned polling task, assigned by `submitAndPoll`, so `stopPolling()`
    /// can cancel the in-flight loop.
    private var pollTask: Task<VideoJob, Error>?
    private var pollGeneration = 0
    /// Remote ID of the job the owned poll loop is currently running for, if
    /// any. Distinct from `activeJob`, which deliberately keeps the last known
    /// state after a local stop — a stopped job is not an in-flight run.
    private var inFlightRemoteID: String?

    init(transport: MediaTransport = MediaTransport(), jobController: JobController? = nil) {
        self.transport = transport
        // Resolved on the main actor (VideoGenService is @MainActor): the
        // default view path shares the application-owned controller.
        self.jobController = jobController ?? JobController.shared
    }

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
    ///
    /// The polling loop runs in a task this method owns and assigns to
    /// `pollTask`, so `stopPolling()` cancels the in-flight loop. Local
    /// cancellation surfaces as `CancellationError` and never claims the
    /// remote job was cancelled; remote failures throw `MediaServiceError`.
    func submitAndPoll(
        _ request: VideoGenRequest,
        pollInterval: Duration = .seconds(5),
        onUpdate: @escaping @Sendable (VideoJob) -> Void = { _ in }
    ) async throws -> VideoJob {
        stopPolling()
        let body = try JSONEncoder().encode(request)
        let submit = try transport.request(path: "videos", method: "POST", body: body)
        let job: VideoJob
        do {
            job = try await transport.send(submit)
        } catch {
            // W01/W06 honesty: the POST /videos was SENT, so the outcome is
            // genuinely unknown — a remote (possibly paid) job may or may not
            // exist. Record exactly that durably — never an automatic
            // resubmission candidate — and rethrow unchanged. Failures thrown
            // ABOVE this point (request building, JSON encoding) sent nothing
            // and must not record an unknown outcome. The localized
            // description carries no key material: these errors are built
            // from server messages and URLError descriptions, never from
            // request headers.
            jobController.recordUnknownSubmission(
                modelID: request.model,
                error: error.localizedDescription
            )
            throw error
        }
        activeJob = job
        // Durable record keyed by the remote job ID, persisted before any
        // poll result is relied upon. A failed write never aborts the flow
        // (JobController surfaces it as lastPersistenceError).
        jobController.recordVideoSubmission(
            remoteID: job.id,
            modelID: request.model,
            remoteStatus: job.status,
            error: job.error,
            cost: job.cost
        )
        onUpdate(job)
        return try await runOwnedPollLoop(from: job, pollInterval: pollInterval, onUpdate: onUpdate)
    }

    /// Resumes polling for a durable job record (W09): restarts the owned
    /// poll loop for a job that already exists remotely, without any new
    /// submission — a resume never issues `POST /videos`. Use this after an
    /// app restart or a local stop (`JobRecord.stoppedLocally`) so the job
    /// survives the view that started it.
    ///
    /// - Parameter record: a durable record with a remote ID and a
    ///   non-terminal polling state (see `JobRecord.isResumable`).
    /// - Throws: `MediaServiceError.resumeUnavailable` when the record has
    ///   no remote ID to poll or already reached a terminal state — both
    ///   refusals happen before any request is sent.
    func resume(
        _ record: JobRecord,
        pollInterval: Duration = .seconds(5),
        onUpdate: @escaping @Sendable (VideoJob) -> Void = { _ in }
    ) async throws -> VideoJob {
        guard let remoteID = record.remoteID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !remoteID.isEmpty else {
            throw MediaServiceError.resumeUnavailable(
                "the job never received a remote ID, so there is nothing to poll. Resubmitting is a user decision because it can duplicate a paid job."
            )
        }
        guard !record.pollingState.isTerminal else {
            throw MediaServiceError.resumeUnavailable(
                "the job already finished (\(record.pollingState.rawValue))."
            )
        }
        stopPolling()
        // Seed the loop from the last known durable state; the first poll
        // goes to the canonical `videos/<remoteID>` route (or the record's
        // stored polling URL after origin validation) exactly like an
        // uninterrupted poll would.
        let initial = VideoJob(id: remoteID, status: record.lastRemoteStatus ?? "queued")
        onUpdate(initial)
        return try await runOwnedPollLoop(
            from: initial, pollInterval: pollInterval, onUpdate: onUpdate
        )
    }

    /// Starts the owned polling task for `job` and awaits its terminal
    /// result. Shared by submit-then-poll and resume so both flows have the
    /// same cancellation and durability semantics.
    private func runOwnedPollLoop(
        from job: VideoJob,
        pollInterval: Duration,
        onUpdate: @escaping @Sendable (VideoJob) -> Void
    ) async throws -> VideoJob {
        activeJob = job
        pollGeneration += 1
        let generation = pollGeneration
        inFlightRemoteID = job.id
        let loop: Task<VideoJob, Error> = Task {
            try await pollUntilTerminal(job, pollInterval: pollInterval, onUpdate: onUpdate)
        }
        pollTask = loop
        defer {
            if pollGeneration == generation {
                pollTask = nil
                inFlightRemoteID = nil
            }
        }
        return try await loop.value
    }

    /// Polls until a terminal status. Prefers the canonical `videos/<jobId>`
    /// route; a supplied `polling_url` is used only after it resolves and
    /// passes the exact origin policy, before any credential is attached to
    /// the request.
    private func pollUntilTerminal(
        _ initial: VideoJob,
        pollInterval: Duration,
        onUpdate: @escaping @Sendable (VideoJob) -> Void
    ) async throws -> VideoJob {
        var job = initial
        while !job.isTerminal {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
            try Task.checkCancellation()
            job = try await transport.send(pollRequest(for: job))
            activeJob = job
            jobController.recordPollUpdate(
                remoteID: job.id, remoteStatus: job.status, error: job.error, cost: job.cost
            )
            onUpdate(job)
        }
        // Terminal: persist the final state and cost regardless of outcome so
        // a completed job keeps its usage and a failure keeps its error.
        jobController.recordTerminal(
            remoteID: job.id, remoteStatus: job.status, error: job.error, cost: job.cost
        )
        guard job.isSuccess else {
            throw MediaServiceError.transport(job.error ?? "Video generation \(job.status).")
        }
        return job
    }

    private func pollRequest(for job: VideoJob) throws -> URLRequest {
        if let reference = job.pollingURL,
           !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Validate the exact origin policy before attaching credentials.
            let url = try MediaEndpointURL.pollingURL(reference)
            return try transport.request(url: url)
        }
        return try transport.request(path: "videos/\(job.id)")
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

    /// Cancels the owned polling task, if any. Local stopping only ends the
    /// polling loop; the remote job keeps running and its last known state
    /// stays in `activeJob`. The durable record is marked `.stoppedLocally` —
    /// explicitly distinct from remote failure/cancellation and still
    /// resumable.
    func stopPolling() {
        if let active = activeJob, !active.isTerminal {
            jobController.recordStoppedLocally(remoteID: active.id)
        }
        pollTask?.cancel()
        pollTask = nil
        inFlightRemoteID = nil
    }

    // MARK: Durable resume affordance (W09 step 3 wiring)

    /// Durable records that can still be resumed (remote ID present, polling
    /// not terminal), read from this service's own JobController. Views use
    /// this passthrough instead of reaching into `JobController.shared`, so
    /// tests and alternate hosts stay isolated from shared state.
    var resumableRecords: [JobRecord] { jobController.resumableJobs() }

    /// Last persistence failure from the durable store, surfaced beside the
    /// resume affordance so a failed write is visible, never silent.
    var durablePersistenceError: String? { jobController.lastPersistenceError }

    /// True while this service's owned poll loop is running for the record's
    /// remote job. The resume affordance disables the control for such records
    /// so a run cannot be double-started; matching is by remote ID because a
    /// resumed run and its durable record share it. Deliberately reads the
    /// in-flight marker rather than `activeJob`: after a local stop
    /// `activeJob` still holds the last known (non-terminal) state, but no run
    /// is in flight and the job stays resumable.
    func isRunInFlight(for record: JobRecord) -> Bool {
        guard let remoteID = record.remoteID else { return false }
        return inFlightRemoteID == remoteID
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

/// Confirmation returned by `DELETE /api/v1/files/{file_id}`. The live
/// OpenAPI schema (`FileDeleteResponse`) is a oneOf discriminated by
/// `_shape`: OpenRouter/Anthropic return `{_shape, id, type:
/// "file_deleted"}`, OpenAI returns `{_shape, id, object: "file", deleted:
/// true}`. All documented fields are decoded tolerantly; `fileDeleted`
/// normalizes the three shapes.
struct FileDeleteConfirmation: Decodable, Equatable, Sendable {
    let id: String
    let shape: String?
    let type: String?
    let object: String?
    let deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, type, object, deleted
        case shape = "_shape"
    }

    var fileDeleted: Bool {
        deleted ?? (type == "file_deleted")
    }
}

@MainActor
final class FileService: ObservableObject {
    /// Documented Files API upload maximum: 100 MiB (104,857,600 bytes).
    /// A larger file is rejected with HTTP 413, so ORB refuses it locally
    /// before any request is sent.
    static let maxUploadBytes = 104_857_600

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
    /// Uploads are validated client-side before any request: the Files API
    /// rejects empty files with 400 and files over 100 MiB with 413, so ORB
    /// refuses both locally with a clear message.
    func upload(filename: String, mimeType: String, data: Data) async throws -> WorkspaceFile {
        guard !data.isEmpty else {
            throw MediaServiceError.invalidUpload(
                "\"\(filename)\" is empty; the Files API rejects empty files."
            )
        }
        guard data.count <= Self.maxUploadBytes else {
            throw MediaServiceError.invalidUpload(
                "\"\(filename)\" is \(data.count) bytes and exceeds the 100 MiB upload limit (104,857,600 bytes)."
            )
        }
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

    /// Deletes a workspace file (`DELETE /api/v1/files/{file_id}`).
    /// Deletion is irreversible, so the service refuses to act without an
    /// explicit `confirming: true` — the view layer must only pass it after
    /// the user confirmed the exact target. The local list is updated only
    /// after the confirmed request succeeds.
    @discardableResult
    func delete(id: String, confirming: Bool) async throws -> FileDeleteConfirmation {
        guard confirming else {
            throw MediaServiceError.deleteNotConfirmed(id)
        }
        let request = try transport.request(path: "files/\(id)", method: "DELETE")
        let confirmation: FileDeleteConfirmation = try await transport.send(request)
        files.removeAll { $0.id == id }
        return confirmation
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
        let request = try transport.request(
            path: "generation",
            queryItems: [URLQueryItem(name: "id", value: id)]
        )
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
