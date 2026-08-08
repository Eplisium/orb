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
        guard let d = expirationDate, let dt = ISO8601DateFormatter().date(from: d) else { return false }
        return dt < Date()
    }

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
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: d)
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
    case freeOnly = "Free Only"

    var id: String { rawValue }
}
