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
    let perRequestLimits: PerRequestLimits?
    let defaultParameters: JSONValue?
    /// Set on `~vendor/...-latest` style aliases: the concrete model they
    /// currently route to. Alias `/endpoints` returns nothing — fetch the
    /// target's endpoints instead.
    var aliasTarget: AliasTarget? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, created, description, architecture, pricing, reasoning, benchmarks
        case aliasTarget = "alias_target"
        case canonicalSlug = "canonical_slug"
        case huggingFaceId = "hugging_face_id"
        case contextLength = "context_length"
        case topProvider = "top_provider"
        case supportedParameters = "supported_parameters"
        case knowledgeCutoff = "knowledge_cutoff"
        case expirationDate = "expiration_date"
        case supportedVoices = "supported_voices"
        case perRequestLimits = "per_request_limits"
        case defaultParameters = "default_parameters"
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
        provider.hasPrefix("~") && aliasTarget == nil
    }

    /// `~vendor/...-latest` aliases that route to another model.
    var isAlias: Bool { aliasTarget != nil }

    /// The id whose `/endpoints` actually lists providers.
    var endpointsModelID: String {
        if let slug = aliasTarget?.slug, !slug.isEmpty { return slug }
        return id
    }

    /// Public model page; nil when the id can't form a safe URL.
    var openRouterURL: URL? { ModelInfo.openRouterURL(for: id) }

    static func openRouterURL(for id: String) -> URL? {
        guard !id.isEmpty, !id.contains(".."), id.rangeOfCharacter(from: CharacterSet(charactersIn: "?# ")) == nil else { return nil }
        guard let path = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://openrouter.ai/\(path)")
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

    var supportsAudioOutput: Bool {
        outputModalities.contains("audio")
    }

    /// Models that accept video (`input_modalities` contains "video").
    var supportsVideoInput: Bool {
        inputModalities.contains("video")
    }

    /// Models that accept documents (`input_modalities` contains "file").
    var supportsFileInput: Bool {
        inputModalities.contains("file")
    }

    /// Models that output something other than text (image, audio, …).
    var supportsNonTextOutput: Bool {
        outputModalities.contains { $0 != "text" }
    }

    /// Embedding models (`output_modalities` contains "embeddings").
    var isEmbeddingModel: Bool {
        outputModalities.contains("embeddings")
    }

    /// The full `text->…` / `text+image->text` modality chain from the API.
    var modalityChain: String {
        architecture?.modality ?? "unknown"
    }

    var supportsImageOutput: Bool {
        outputModalities.contains("image")
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

    var hasExpired: Bool { hasExpired(now: Date()) }

    /// The catalog sends a plain `YYYY-MM-DD` (full timestamps also accepted).
    /// A model expires at the end of that UTC day.
    var expirationInstant: Date? {
        guard let raw = expirationDate?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let day = ModelInfo.fullDateFormatter.date(from: String(raw.prefix(10))), raw.count == 10 {
            return day.addingTimeInterval(86_400)
        }
        return ModelInfo.isoFormatter.date(from: raw) ?? ModelInfo.fullDateFormatter.date(from: String(raw.prefix(10)))
    }

    func hasExpired(now: Date) -> Bool {
        guard let end = expirationInstant else { return false }
        return end <= now
    }

    /// Whole days until expiry (0 = expires today), nil if none/expired.
    func daysUntilExpiration(now: Date = Date()) -> Int? {
        guard let end = expirationInstant, end > now else { return nil }
        return Int((end.timeIntervalSince(now) - 1) / 86_400)
    }

    /// "Expires in N days" when expiry is within 30 days.
    func expirationWarning(now: Date = Date()) -> String? {
        guard let days = daysUntilExpiration(now: now), days <= 30 else { return nil }
        switch days {
        case 0: return "Expires today"
        case 1: return "Expires tomorrow"
        default: return "Expires in \(days) days"
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fullDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
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
        guard let cutoff = knowledgeCutoff, !cutoff.isEmpty else { return "N/A" }
        return cutoff
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

/// Model/endpoint pricing. Values are USD strings exactly as the API sends
/// them (per token unless noted). Decoding is tolerant: a field of an
/// unexpected type is dropped instead of failing the whole catalog.
struct Pricing: Codable, Hashable {
    var prompt: String?
    var completion: String?
    var inputCacheRead: String?
    var inputCacheWrite: String? = nil
    var inputCacheWrite1h: String? = nil
    /// USD per web-search request.
    var webSearch: String? = nil
    var internalReasoning: String? = nil
    var image: String? = nil
    var imageOutput: String? = nil
    var audio: String? = nil
    var audioOutput: String? = nil
    var inputAudioCache: String? = nil
    /// USD per request.
    var request: String? = nil
    /// Endpoint discount fraction (0…1); usually 0.
    var discount: Double? = nil
    /// Tiered/time-window prices that replace the base when they apply.
    var overrides: [PricingOverride]? = nil

    init(
        prompt: String?, completion: String?, inputCacheRead: String?,
        inputCacheWrite: String? = nil, inputCacheWrite1h: String? = nil, webSearch: String? = nil,
        internalReasoning: String? = nil, image: String? = nil, imageOutput: String? = nil,
        audio: String? = nil, audioOutput: String? = nil, inputAudioCache: String? = nil,
        request: String? = nil, discount: Double? = nil, overrides: [PricingOverride]? = nil
    ) {
        self.prompt = prompt; self.completion = completion; self.inputCacheRead = inputCacheRead
        self.inputCacheWrite = inputCacheWrite; self.inputCacheWrite1h = inputCacheWrite1h
        self.webSearch = webSearch; self.internalReasoning = internalReasoning
        self.image = image; self.imageOutput = imageOutput; self.audio = audio
        self.audioOutput = audioOutput; self.inputAudioCache = inputAudioCache
        self.request = request; self.discount = discount; self.overrides = overrides
    }

    enum CodingKeys: String, CodingKey {
        case prompt, completion, image, audio, request, discount, overrides
        case inputCacheRead = "input_cache_read"
        case inputCacheWrite = "input_cache_write"
        case inputCacheWrite1h = "input_cache_write_1h"
        case webSearch = "web_search"
        case internalReasoning = "internal_reasoning"
        case imageOutput = "image_output"
        case audioOutput = "audio_output"
        case inputAudioCache = "input_audio_cache"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? { LossyPrice.decode(c, k) }
        prompt = str(.prompt); completion = str(.completion); inputCacheRead = str(.inputCacheRead)
        inputCacheWrite = str(.inputCacheWrite); inputCacheWrite1h = str(.inputCacheWrite1h)
        webSearch = str(.webSearch); internalReasoning = str(.internalReasoning)
        image = str(.image); imageOutput = str(.imageOutput); audio = str(.audio)
        audioOutput = str(.audioOutput); inputAudioCache = str(.inputAudioCache); request = str(.request)
        discount = (try? c.decodeIfPresent(Double.self, forKey: .discount)) ?? str(.discount).flatMap(Double.init)
        overrides = (try? c.decodeIfPresent(LossyArray<PricingOverride>.self, forKey: .overrides))?.elements
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(completion, forKey: .completion)
        try c.encodeIfPresent(inputCacheRead, forKey: .inputCacheRead)
        try c.encodeIfPresent(inputCacheWrite, forKey: .inputCacheWrite)
        try c.encodeIfPresent(inputCacheWrite1h, forKey: .inputCacheWrite1h)
        try c.encodeIfPresent(webSearch, forKey: .webSearch)
        try c.encodeIfPresent(internalReasoning, forKey: .internalReasoning)
        try c.encodeIfPresent(image, forKey: .image)
        try c.encodeIfPresent(imageOutput, forKey: .imageOutput)
        try c.encodeIfPresent(audio, forKey: .audio)
        try c.encodeIfPresent(audioOutput, forKey: .audioOutput)
        try c.encodeIfPresent(inputAudioCache, forKey: .inputAudioCache)
        try c.encodeIfPresent(request, forKey: .request)
        try c.encodeIfPresent(discount, forKey: .discount)
        try c.encodeIfPresent(overrides, forKey: .overrides)
    }
}

/// One `pricing.overrides[]` entry: applies above `min_prompt_tokens`
/// and/or inside a UTC time window (`utc_start`/`utc_end` as HHMM,
/// optional `utc_days`).
struct PricingOverride: Codable, Hashable {
    var minPromptTokens: Int? = nil
    var utcStart: Int? = nil
    var utcEnd: Int? = nil
    var utcDays: [String]? = nil
    var prompt: String? = nil
    var completion: String? = nil
    var inputCacheRead: String? = nil
    var inputCacheWrite: String? = nil

    enum CodingKeys: String, CodingKey {
        case prompt, completion
        case minPromptTokens = "min_prompt_tokens"
        case utcStart = "utc_start"
        case utcEnd = "utc_end"
        case utcDays = "utc_days"
        case inputCacheRead = "input_cache_read"
        case inputCacheWrite = "input_cache_write"
    }

    init(minPromptTokens: Int? = nil, utcStart: Int? = nil, utcEnd: Int? = nil, utcDays: [String]? = nil,
         prompt: String? = nil, completion: String? = nil, inputCacheRead: String? = nil, inputCacheWrite: String? = nil) {
        self.minPromptTokens = minPromptTokens; self.utcStart = utcStart; self.utcEnd = utcEnd; self.utcDays = utcDays
        self.prompt = prompt; self.completion = completion; self.inputCacheRead = inputCacheRead; self.inputCacheWrite = inputCacheWrite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ k: CodingKeys) -> Int? {
            (try? c.decodeIfPresent(Int.self, forKey: k)) ?? LossyPrice.decode(c, k).flatMap { Int($0) }
        }
        minPromptTokens = int(.minPromptTokens); utcStart = int(.utcStart); utcEnd = int(.utcEnd)
        utcDays = try? c.decodeIfPresent([String].self, forKey: .utcDays)
        prompt = LossyPrice.decode(c, .prompt); completion = LossyPrice.decode(c, .completion)
        inputCacheRead = LossyPrice.decode(c, .inputCacheRead); inputCacheWrite = LossyPrice.decode(c, .inputCacheWrite)
    }
}

/// `{name, slug}` of the model an alias currently points at.
struct AliasTarget: Codable, Hashable {
    let name: String?
    let slug: String
}

/// Accepts a JSON string or number and returns its string form.
enum LossyPrice {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        }
        return nil
    }
}

/// Decodes an array, skipping elements that fail to decode.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) { out.append(e) } else { _ = try? c.decode(JSONValue.self) }
        }
        elements = out
    }
}

struct PerRequestLimits: Codable, Hashable {
    let promptTokens: Int?
    let completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
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
    var name: String?
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
    /// Unique per endpoint (`deepinfra/fp4`, `deepinfra/turbo`) where the
    /// provider name alone is not.
    var tag: String? = nil
    var supportedParameters: [String]? = nil
    var maxPromptTokens: Int? = nil
    /// Disambiguator assigned by `ModelEndpoint.uniquified` when two
    /// endpoints would otherwise share an id. Never encoded.
    var idSuffix: String? = nil

    /// Stable: tag, else provider + quantization, never random.
    var baseID: String {
        if let tag, !tag.isEmpty { return tag }
        let parts = [providerName ?? name ?? "endpoint", quantization].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: "/")
    }

    var id: String { idSuffix.map { "\(baseID)#\($0)" } ?? baseID }

    /// Gives every endpoint in `list` a distinct `id`, keeping order and
    /// leaving already-unique ids untouched.
    static func uniquified(_ list: [ModelEndpoint]) -> [ModelEndpoint] {
        var seen: [String: Int] = [:]
        return list.map { endpoint in
            var e = endpoint
            e.idSuffix = nil
            let n = seen[e.baseID, default: 0]
            seen[e.baseID] = n + 1
            if n > 0 { e.idSuffix = String(n + 1) }
            return e
        }
    }

    /// Short label shown in provider tables: provider plus the tag's
    /// variant when it adds information ("DeepInfra (turbo)").
    var displayName: String {
        let provider = providerName ?? name ?? "Unknown"
        guard let tag, let slash = tag.firstIndex(of: "/") else { return provider }
        let variant = tag[tag.index(after: slash)...]
        return variant.isEmpty ? provider : "\(provider) (\(variant))"
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

    var isAvailable: Bool { (status ?? 1) == 0 }

    enum CodingKeys: String, CodingKey {
        case name, pricing, quantization, status, tag
        case supportedParameters = "supported_parameters"
        case maxPromptTokens = "max_prompt_tokens"
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

/// Endpoints use the same pricing shape (plus `discount`).
typealias EndpointPricing = Pricing

// MARK: - Sort & Filter

enum SortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case contextLength = "Context Length"
    case promptCost = "Input Cost"
    case completionCost = "Output Cost"
    case created = "Date Added"
    case provider = "Provider"
    case designElo = "Design Elo"
    case intelligence = "Intelligence Index"
    case coding = "Coding Index"
    case agentic = "Agentic Index"
    case maxOutput = "Max Output"
    case expiringSoon = "Expiring Soon"

    var id: String { rawValue }
}

enum SortOrder {
    case ascending, descending
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

enum ChatMessageStatus: String, Codable, Sendable {
    case complete, streaming, failed, interrupted, truncated
}

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let role: String
    var content: String
    /// Multimodal wire content, when this message carries attachments.
    /// UI text lives in `content`; `parts` is what gets sent upstream.
    var parts: [MessageContentPart]?
    /// Images returned by image-output models, rendered inline.
    var images: [ChatImageAttachment]?
    var toolCalls: [ToolCallDisplay]?
    /// For tool result messages: the tool_call_id this answers.
    var toolCallId: String?
    /// For tool result messages: the tool name.
    var toolName: String?
    var status: ChatMessageStatus
    var finishReason: String?
    var errorMessage: String?
    /// Chain-of-thought emitted by reasoning models, shown in a collapsible
    /// section so it never crowds out the answer.
    var reasoning: String?
    /// Start of the current or most recent reasoning segment, taken from its
    /// first stream delta (not the time a SwiftUI row becomes visible).
    var reasoningStartedAt: Date?
    /// Sum of finished reasoning segments; excludes answer and tool time and
    /// survives app relaunch.
    var reasoningDuration: TimeInterval?
    /// Structured reasoning blocks the API returned (`reasoning_details`).
    /// Wire state kept separately from the visible `reasoning` summary so
    /// opaque signature/encrypted payloads survive round trips without ever
    /// being rendered (F07).
    var reasoningDetails: [ReasoningDetail]?
    var transcript: [MessageTranscriptSegment]?
    /// When the message was created. Persisted once; never restamped on save.
    var createdAt: Date
    /// Tokens, cost, and throughput for the reply (assistant rows only).
    var usage: MessageUsage?

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        parts: [MessageContentPart]? = nil,
        images: [ChatImageAttachment]? = nil,
        toolCalls: [ToolCallDisplay]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        status: ChatMessageStatus = .complete,
        finishReason: String? = nil,
        errorMessage: String? = nil,
        reasoning: String? = nil,
        reasoningStartedAt: Date? = nil,
        reasoningDuration: TimeInterval? = nil,
        reasoningDetails: [ReasoningDetail]? = nil,
        transcript: [MessageTranscriptSegment]? = nil,
        createdAt: Date = Date(),
        usage: MessageUsage? = nil
    ) {
        self.createdAt = createdAt
        self.usage = usage
        self.id = id
        self.role = role
        self.content = content
        self.parts = parts
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.status = status
        self.finishReason = finishReason
        self.errorMessage = errorMessage
        self.reasoning = reasoning
        self.reasoningStartedAt = reasoningStartedAt
        self.reasoningDuration = reasoningDuration
        self.reasoningDetails = reasoningDetails
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning, reasoningStartedAt, reasoningDuration, parts, images, transcript, usage
        case createdAt = "created_at"
        case reasoningDetails = "reasoning_details"
        case toolCalls = "tool_calls_display"
        case toolCallId = "tool_call_id"
        case toolName = "tool_name"
        case id, status
        case finishReason = "finish_reason"
        case errorMessage = "error_message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        parts = try c.decodeIfPresent([MessageContentPart].self, forKey: .parts)
        images = try c.decodeIfPresent([ChatImageAttachment].self, forKey: .images)
        toolCalls = try c.decodeIfPresent([ToolCallDisplay].self, forKey: .toolCalls)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        status = try c.decodeIfPresent(ChatMessageStatus.self, forKey: .status) ?? .complete
        finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        reasoningStartedAt = try c.decodeIfPresent(Date.self, forKey: .reasoningStartedAt)
        reasoningDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .reasoningDuration)
        reasoningDetails = try c.decodeIfPresent([ReasoningDetail].self, forKey: .reasoningDetails)
        transcript = try c.decodeIfPresent([MessageTranscriptSegment].self, forKey: .transcript)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        usage = try c.decodeIfPresent(MessageUsage.self, forKey: .usage)
    }

    /// Compares the fields that actually drive rendering. The previous version
    /// only checked `id`/`role`/`content`, so streamed tool calls, status
    /// changes, and reasoning updates could be swallowed by SwiftUI's
    /// equality-based diffing and never redraw.
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.status == rhs.status
            && lhs.reasoning == rhs.reasoning
            && lhs.reasoningStartedAt == rhs.reasoningStartedAt
            && lhs.reasoningDuration == rhs.reasoningDuration
            && lhs.finishReason == rhs.finishReason
            && lhs.errorMessage == rhs.errorMessage
            && lhs.toolCalls == rhs.toolCalls
            && lhs.parts == rhs.parts
            && lhs.images == rhs.images
            && lhs.reasoningDetails == rhs.reasoningDetails
            && lhs.transcript == rhs.transcript
            && lhs.usage == rhs.usage
        // createdAt is set once at creation and never drives a redraw.
    }
}

/// Per-reply usage stored on the assistant message.
struct MessageUsage: Codable, Equatable, Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var reasoningTokens: Int?
    var cost: Double?
    /// Completion tokens per second of wall time for the run.
    var tokensPerSecond: Double?

    init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil,
         reasoningTokens: Int? = nil, cost: Double? = nil, tokensPerSecond: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.tokensPerSecond = tokensPerSecond
    }

    init(_ usage: ChatUsage, elapsed: TimeInterval?) {
        self.init(
            promptTokens: usage.promptTokens, completionTokens: usage.completionTokens,
            totalTokens: usage.totalTokens, reasoningTokens: usage.reasoningTokens, cost: usage.cost,
            tokensPerSecond: zip(usage.completionTokens, elapsed).flatMap { tokens, seconds in
                seconds > 0 ? Double(tokens) / seconds : nil
            }
        )
    }

    /// Compact footer text, e.g. "1,204 tokens · $0.0031 · 42 tok/s".
    var summary: String {
        var parts: [String] = []
        if let totalTokens { parts.append("\(totalTokens.formatted()) tokens") }
        else if let completionTokens { parts.append("\(completionTokens.formatted()) out") }
        if let cost, cost > 0 { parts.append(cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)) }
        if let tokensPerSecond { parts.append("\(Int(tokensPerSecond.rounded())) tok/s") }
        return parts.joined(separator: " · ")
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Lightweight tool-call summary stored alongside ChatMessage for display.
struct ToolCallDisplay: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    var name: String
    var argumentsSummary: String
    var arguments: String?
    var result: String?
    var isError: Bool
    var isExecuting: Bool

    init(
        id: String,
        name: String,
        argumentsSummary: String,
        arguments: String? = nil,
        result: String? = nil,
        isError: Bool = false,
        isExecuting: Bool = false
    ) {
        self.id = id
        self.name = name
        self.argumentsSummary = argumentsSummary
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.isExecuting = isExecuting
    }

    enum CodingKeys: String, CodingKey {
        case id, name, arguments, result, isError, isExecuting
        case argumentsSummary = "arguments_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        argumentsSummary = try container.decode(String.self, forKey: .argumentsSummary)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        isExecuting = try container.decodeIfPresent(Bool.self, forKey: .isExecuting) ?? false
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

struct ChatUsage: Codable, Equatable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?
    /// Prompt tokens served from the provider's cache. These bill at a reduced
    /// rate, so showing them explains cost gaps on long conversations.
    var cachedTokens: Int?
    /// Completion tokens spent on reasoning rather than visible output.
    var reasoningTokens: Int?
    /// Tokens spent on audio input/output detail (STT/TTS models).
    var audioTokens: Int?
    /// Tokens spent on video input detail.
    var videoTokens: Int?
    /// Server-side tool executions (OpenRouter server tools, not ORB tools).
    var serverToolCallsExecuted: Int?
    var serverToolCallsRequested: Int?
    /// Whether the request was served via Bring-Your-Own-Key.
    var isBYOK: Bool?

    enum CodingKeys: String, CodingKey {
        case cost
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case cachedTokens = "cached_tokens"
        case reasoningTokens = "reasoning_tokens"
        case audioTokens = "audio_tokens"
        case videoTokens = "video_tokens"
        case serverToolUseDetails = "server_tool_use_details"
        case isBYOK = "is_byok"
    }

    private struct PromptDetails: Codable {
        let cachedTokens: Int?
        let audioTokens: Int?
        let videoTokens: Int?
        let cacheWriteTokens: Int?
        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case audioTokens = "audio_tokens"
            case videoTokens = "video_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }
    }

    private struct CompletionDetails: Codable {
        let reasoningTokens: Int?
        let audioTokens: Int?
        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
            case audioTokens = "audio_tokens"
        }
    }

    private struct ServerToolDetails: Codable {
        let executed: Int?
        let requested: Int?
        enum CodingKeys: String, CodingKey {
            case executed = "tool_calls_executed"
            case requested = "tool_calls_requested"
        }
    }

    init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?, cost: Double?,
         cachedTokens: Int? = nil, reasoningTokens: Int? = nil,
         audioTokens: Int? = nil, videoTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.audioTokens = audioTokens
        self.videoTokens = videoTokens
        self.serverToolCallsExecuted = nil
        self.serverToolCallsRequested = nil
        self.isBYOK = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        // Nested detail objects are optional and provider-specific.
        let promptDetails = try c.decodeIfPresent(PromptDetails.self, forKey: .promptTokensDetails)
        let completionDetails = try c.decodeIfPresent(CompletionDetails.self, forKey: .completionTokensDetails)
        // …but some providers also send the flat keys top-level.
        cachedTokens = try c.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? promptDetails?.cachedTokens
        reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? completionDetails?.reasoningTokens
        audioTokens = try c.decodeIfPresent(Int.self, forKey: .audioTokens)
            ?? promptDetails?.audioTokens ?? completionDetails?.audioTokens
        videoTokens = try c.decodeIfPresent(Int.self, forKey: .videoTokens) ?? promptDetails?.videoTokens
        let serverDetails = try c.decodeIfPresent(ServerToolDetails.self, forKey: .serverToolUseDetails)
        serverToolCallsExecuted = serverDetails?.executed
        serverToolCallsRequested = serverDetails?.requested
        isBYOK = try c.decodeIfPresent(Bool.self, forKey: .isBYOK)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(promptTokens, forKey: .promptTokens)
        try c.encodeIfPresent(completionTokens, forKey: .completionTokens)
        try c.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encodeIfPresent(cachedTokens, forKey: .cachedTokens)
        try c.encodeIfPresent(reasoningTokens, forKey: .reasoningTokens)
        try c.encodeIfPresent(audioTokens, forKey: .audioTokens)
        try c.encodeIfPresent(videoTokens, forKey: .videoTokens)
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

// MARK: - Chat Conversation

struct ChatConversation: Identifiable, Equatable {
    let id: UUID
    var title: String
    var modelId: String
    var mode: PlaygroundMode
    var messages: [ChatMessage]
    var systemPrompt: String
    var createdAt: Date
    var totalCost: Double
    var totalTokens: Int

    init(
        id: UUID = UUID(),
        title: String? = nil,
        modelId: String,
        mode: PlaygroundMode = .agent,
        messages: [ChatMessage] = [],
        systemPrompt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title ?? (mode == .agent ? "New Agent Session" : "New Chat")
        self.modelId = modelId
        self.mode = mode
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
        self.totalCost = 0
        self.totalTokens = 0
    }

    static func == (lhs: ChatConversation, rhs: ChatConversation) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.modelId == rhs.modelId
            && lhs.messages == rhs.messages
            && lhs.systemPrompt == rhs.systemPrompt
            && lhs.totalCost == rhs.totalCost
            && lhs.totalTokens == rhs.totalTokens
    }
}
