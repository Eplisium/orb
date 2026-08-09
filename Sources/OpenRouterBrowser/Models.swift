import Foundation

// MARK: - OpenRouter API Response

struct OpenRouterResponse: Codable {
    let data: [ModelInfo]
}

struct ModelInfo: Codable, Identifiable, Hashable {
    let id: String
    let canonicalSlug: String?
    let huggingFaceId: String?
    let name: String
    let created: Double?
    let description: String?
    let contextLength: Int?
    let architecture: Architecture?
    let pricing: Pricing?
    let topProvider: TopProvider?
    let supportedParameters: [String]?
    let reasoning: ReasoningInfo?
    let knowledgeCutoff: String?
    let expirationDate: String?
    let supportedVoices: [String]?
    let benchmarks: Benchmarks?

    enum CodingKeys: String, CodingKey {
        case id, name, created, description, architecture, pricing, reasoning, benchmarks
        case canonicalSlug = "canonical_slug"
        case huggingFaceId = "hugging_face_id"
        case contextLength = "context_length"
        case topProvider = "top_provider"
        case supportedParameters = "supported_parameters"
        case knowledgeCutoff = "knowledge_cutoff"
        case expirationDate = "expiration_date"
        case supportedVoices = "supported_voices"
    }

    // Hashable by id
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ModelInfo, rhs: ModelInfo) -> Bool { lhs.id == rhs.id }

    var provider: String {
        id.split(separator: "/").first.map(String.init) ?? "unknown"
    }

    var modelSlug: String {
        id.split(separator: "/").dropFirst().joined(separator: "/")
    }

    /// Providers with `~` prefix are unofficial mirrors on OpenRouter.
    var isUnofficial: Bool {
        provider.hasPrefix("~")
    }

    var promptCostPer1M: Double? {
        guard let s = pricing?.prompt, let d = Double(s), d > 0 else { return nil }
        return d * 1_000_000
    }

    var completionCostPer1M: Double? {
        guard let s = pricing?.completion, let d = Double(s), d > 0 else { return nil }
        return d * 1_000_000
    }

    var cacheReadCostPer1M: Double? {
        guard let s = pricing?.inputCacheRead, let d = Double(s), d > 0 else { return nil }
        return d * 1_000_000
    }

    var isFree: Bool {
        let p = Double(pricing?.prompt ?? "-1") ?? -1
        let c = Double(pricing?.completion ?? "-1") ?? -1
        return (p == 0 && c == 0) || id.hasSuffix(":free")
    }

    var modalityLabel: String {
        architecture?.modality ?? "unknown"
    }

    var inputModalities: [String] {
        architecture?.inputModalities ?? []
    }

    var outputModalities: [String] {
        architecture?.outputModalities ?? []
    }

    var supportsImages: Bool {
        inputModalities.contains("image")
    }

    var supportsAudioInput: Bool {
        inputModalities.contains("audio")
    }

    var supportsImageOutput: Bool {
        outputModalities.contains("image")
    }

    var supportsAudioOutput: Bool {
        outputModalities.contains("audio")
    }

    var supportsTools: Bool {
        supportedParameters?.contains("tools") ?? false
    }

    var supportsReasoning: Bool {
        reasoning?.defaultEnabled == true || (supportedParameters?.contains("reasoning") ?? false)
    }

    var hasBenchmarks: Bool {
        benchmarks?.designArena?.isEmpty == false || benchmarks?.artificialAnalysis != nil
    }

    var bestDesignElo: Double? {
        benchmarks?.designArena?.map { $0.elo ?? 0 }.max()
    }

    var hasExpired: Bool {
        guard let d = expirationDate else { return false }
        return ModelInfo.isoFormatter.date(from: d).map { $0 < Date() } ?? false
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var contextLengthFormatted: String {
        guard let ctx = contextLength else { return "N/A" }
        if ctx >= 1_000_000 { return String(format: "%.1fM", Double(ctx) / 1_000_000) }
        if ctx >= 1000 { return "\(ctx / 1000)K" }
        return "\(ctx)"
    }

    var createdDate: Date? {
        guard let created = created else { return nil }
        return Date(timeIntervalSince1970: created)
    }

    var createdFormatted: String {
        guard let d = createdDate else { return "N/A" }
        return ModelInfo.dateFormatter.string(from: d)
    }

    var knowledgeCutoffFormatted: String {
        knowledgeCutoff?.isEmpty == false ? knowledgeCutoff! : "N/A"
    }
}

struct Architecture: Codable, Hashable {
    let modality: String?
    let inputModalities: [String]?
    let outputModalities: [String]?
    let tokenizer: String?
    let instructType: String?

    enum CodingKeys: String, CodingKey {
        case modality, tokenizer
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
        case instructType = "instruct_type"
    }
}

struct Pricing: Codable, Hashable {
    let prompt: String?
    let completion: String?
    let inputCacheRead: String?

    enum CodingKeys: String, CodingKey {
        case prompt, completion
        case inputCacheRead = "input_cache_read"
    }
}

struct TopProvider: Codable, Hashable {
    let contextLength: Int?
    let maxCompletionTokens: Int?
    let isModerated: Bool?

    enum CodingKeys: String, CodingKey {
        case contextLength = "context_length"
        case maxCompletionTokens = "max_completion_tokens"
        case isModerated = "is_moderated"
    }
}

struct ReasoningInfo: Codable, Hashable {
    let mandatory: Bool?
    let defaultEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case mandatory
        case defaultEnabled = "default_enabled"
    }
}

// MARK: - Benchmarks

struct Benchmarks: Codable, Hashable {
    let designArena: [DesignArenaEntry]?
    let artificialAnalysis: ArtificialAnalysis?

    enum CodingKeys: String, CodingKey {
        case designArena = "design_arena"
        case artificialAnalysis = "artificial_analysis"
    }
}

struct DesignArenaEntry: Codable, Hashable, Identifiable {
    let arena: String?
    let category: String?
    let elo: Double?
    let winRate: Double?
    let rank: Int?

    var id: String { "\(arena ?? "")-\(category ?? "")" }

    enum CodingKeys: String, CodingKey {
        case arena, category, elo, rank
        case winRate = "win_rate"
    }
}

struct ArtificialAnalysis: Codable, Hashable {
    let intelligenceIndex: Double?
    let codingIndex: Double?
    let agenticIndex: Double?

    enum CodingKeys: String, CodingKey {
        case intelligenceIndex = "intelligence_index"
        case codingIndex = "coding_index"
        case agenticIndex = "agentic_index"
    }
}

// MARK: - Per-provider endpoints

struct EndpointResponse: Codable {
    let data: EndpointDetail
}

struct EndpointDetail: Codable, Hashable {
    let id: String
    let name: String?
    let endpoints: [ModelEndpoint]
}

struct ModelEndpoint: Codable, Hashable, Identifiable {
    let name: String?
    let modelId: String?
    let providerName: String?
    let contextLength: Int?
    let maxCompletionTokens: Int?
    let pricing: EndpointPricing?
    let quantization: String?
    let latencyLast30m: Int?
    let throughputLast30m: Int?
    let uptimeLast5m: Double?
    let uptimeLast30m: Double?
    let uptimeLast1d: Double?
    let supportsImplicitCaching: Bool?
    let status: Int?

    var id: String { providerName ?? name ?? UUID().uuidString }

    var promptCostPer1M: Double? {
        guard let s = pricing?.prompt, let d = Double(s), d > 0 else { return nil }
        return d * 1_000_000
    }

    var completionCostPer1M: Double? {
        guard let s = pricing?.completion, let d = Double(s), d > 0 else { return nil }
        return d * 1_000_000
    }

    var cacheReadCostPer1M: Double? {
        guard let s = pricing?.inputCacheRead, let d = Double(s), d > 0 else { return nil }
        return d * 1_000_000
    }

    var isAvailable: Bool { (status ?? 1) == 0 }

    enum CodingKeys: String, CodingKey {
        case name, pricing, quantization, status
        case modelId = "model_id"
        case providerName = "provider_name"
        case contextLength = "context_length"
        case maxCompletionTokens = "max_completion_tokens"
        case latencyLast30m = "latency_last_30m"
        case throughputLast30m = "throughput_last_30m"
        case uptimeLast5m = "uptime_last_5m"
        case uptimeLast30m = "uptime_last_30m"
        case uptimeLast1d = "uptime_last_1d"
        case supportsImplicitCaching = "supports_implicit_caching"
    }
}

struct EndpointPricing: Codable, Hashable {
    let prompt: String?
    let completion: String?
    let inputCacheRead: String?

    enum CodingKeys: String, CodingKey {
        case prompt, completion
        case inputCacheRead = "input_cache_read"
    }
}

// MARK: - Sort & Filter

enum SortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case contextLength = "Context Length"
    case promptCost = "Input Cost"
    case completionCost = "Output Cost"
    case created = "Date Added"
    case provider = "Provider"
    case designElo = "Design Elo"

    var id: String { rawValue }
}

enum SortOrder {
    case ascending, descending
}

enum ModalityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case textOnly = "Text Only"
    case multimodal = "Multimodal"
    case imageOut = "Image Out"
    case tools = "Tools"
    case reasoning = "Reasoning"
    case freeOnly = "Free Only"

    var id: String { rawValue }
}

// MARK: - Credits

struct CreditsResponse: Codable {
    let data: CreditsData
}

struct CreditsData: Codable {
    let totalCredits: Double
    let totalUsage: Double

    var remaining: Double { totalCredits - totalUsage }

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

// MARK: - Activity

struct ActivityResponse: Codable {
    let data: [ActivityItem]
}

struct ActivityItem: Codable, Identifiable {
    let date: String
    let model: String
    let modelPermaslug: String?
    let endpointId: String?
    let providerName: String?
    let usage: Double
    let byokUsageInference: Double?
    let requests: Int
    let promptTokens: Int
    let completionTokens: Int
    let reasoningTokens: Int

    var id: String { "\(date)-\(model)-\(endpointId ?? "")" }

    enum CodingKeys: String, CodingKey {
        case date, model, usage, requests
        case modelPermaslug = "model_permaslug"
        case endpointId = "endpoint_id"
        case providerName = "provider_name"
        case byokUsageInference = "byok_usage_inference"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case reasoningTokens = "reasoning_tokens"
    }
}

// MARK: - Chat Completions

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool?
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
    let seed: Int?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, seed, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
    }
}

struct ResponseFormat: Codable {
    let type: String
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let role: String
    var content: String

    enum CodingKeys: String, CodingKey {
        case role, content
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role && lhs.content == rhs.content
    }
}

struct ChatCompletionResponse: Codable {
    let id: String?
    let choices: [ChatChoice]?
    let usage: ChatUsage?
    let model: String?
    let error: ChatAPIError?
}

struct ChatChoice: Codable {
    let index: Int?
    let message: ChatMessage?
    let delta: ChatDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, message, delta
        case finishReason = "finish_reason"
    }
}

struct ChatDelta: Codable {
    let role: String?
    let content: String?
}

struct ChatUsage: Codable {
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

struct ChatAPIError: Codable {
    let code: Int?
    let message: String?
    let metadata: ChatErrorMetadata?
}

struct ChatErrorMetadata: Codable {
    let providerName: String?
    let raw: String?

    enum CodingKeys: String, CodingKey {
        case raw
        case providerName = "provider_name"
    }
}

// MARK: - Chat Conversation (in-memory)

struct ChatConversation: Identifiable, Equatable {
    let id: UUID
    var title: String
    var modelId: String
    var messages: [ChatMessage]
    var createdAt: Date
    var totalCost: Double
    var totalTokens: Int

    init(
        id: UUID = UUID(),
        title: String = "New Agent Session",
        modelId: String,
        messages: [ChatMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.modelId = modelId
        self.messages = messages
        self.createdAt = createdAt
        self.totalCost = 0
        self.totalTokens = 0
    }

    static func == (lhs: ChatConversation, rhs: ChatConversation) -> Bool {
        lhs.id == rhs.id
    }
}
