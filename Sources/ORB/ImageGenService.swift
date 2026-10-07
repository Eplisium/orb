import Foundation

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

/// `/images` provider routing uses `provider.only`, not a top-level slug.
struct ImageGenerationProviderPreferences: Encodable {
    var only: [String]? = nil
    var order: [String]? = nil
    var ignore: [String]? = nil
    var allowFallbacks: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case only, order, ignore
        case allowFallbacks = "allow_fallbacks"
    }
}

struct ImageGenRequest: Encodable {
    var model: String
    var prompt: String
    var n: Int? = nil
    var aspectRatio: String? = nil
    var resolution: String? = nil
    var quality: String? = nil
    var outputFormat: String? = nil
    var outputCompression: Int? = nil
    var background: String? = nil
    var provider: ImageGenerationProviderPreferences? = nil
    var seed: Int? = nil
    var size: String? = nil
    /// Reference images (image-to-image): base64 data URLs or HTTPS URLs.
    var inputReferences: [String]? = nil
    var user: String? = nil

    enum CodingKeys: String, CodingKey {
        case model, prompt, n, seed, size, user, background, provider
        case aspectRatio = "aspect_ratio"
        case resolution, quality
        case outputFormat = "output_format"
        case outputCompression = "output_compression"
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
        try container.encodeIfPresent(outputCompression, forKey: .outputCompression)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(seed, forKey: .seed)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(inputReferences?.map { ImageReference(url: $0) }, forKey: .inputReferences)
        try container.encodeIfPresent(user, forKey: .user)
    }
}

/// OpenRouter ContentPartImage for image-to-image references.
struct ImageReference: Encodable {
    let type = "image_url"
    let imageURL: URLValue
    struct URLValue: Encodable { let url: String }
    init(url: String) { imageURL = URLValue(url: url) }
    enum CodingKeys: String, CodingKey { case type; case imageURL = "image_url" }
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
    /// Number of image requests currently in flight (requests may overlap).
    @Published private(set) var inFlight = 0
    var isGenerating: Bool { inFlight > 0 }
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
        try await generateWithUsage(request).images
    }

    /// Same as `generate`, but returns this request's own usage so overlapping
    /// requests can be costed without racing on `lastUsage`.
    func generateWithUsage(_ request: ImageGenRequest) async throws -> (images: [ChatImageAttachment], usage: ImageGenUsage?) {
        guard (1...10).contains(request.n ?? 1),
              (0...100).contains(request.outputCompression ?? 0),
              request.background != "transparent" || request.outputFormat == "png" || request.outputFormat == "webp",
              request.provider?.only?.isEmpty != true else {
            throw MediaServiceError.invalidUpload("Invalid image options: n must be 1–10, compression 0–100, transparent output png/webp, and a provider pin must be nonempty.")
        }
        guard request.inputReferences.map({ $0.count <= 16 }) ?? true else {
            throw MediaServiceError.invalidUpload("Image generation allows at most 16 reference images.")
        }
        inFlight += 1
        defer { inFlight -= 1 }
        let body = try JSONEncoder().encode(request)
        let urlRequest = try transport.request(path: "images", method: "POST", body: body)
        let response: ImageGenResponse = try await transport.send(urlRequest)
        lastUsage = response.usage
        UsageLedger.shared.record(.images, model: request.model, cost: response.usage?.cost,
                                  promptTokens: response.usage?.promptTokens,
                                  completionTokens: response.usage?.completionTokens,
                                  totalTokens: response.usage?.totalTokens)
        let images = response.data.map { item -> ChatImageAttachment in
            let mime = item.mediaType ?? "image/png"
            return ChatImageAttachment(
                dataURL: "data:\(mime);base64,\(item.b64Json)",
                prompt: request.prompt
            )
        }
        return (images, response.usage)
    }
}
