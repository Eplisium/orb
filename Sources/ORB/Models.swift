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
    case videoIn = "Video In"
    case audio = "Audio"
    case files = "Files"
    case tools = "Tools"
    case reasoning = "Reasoning"
    case embeddings = "Embeddings"
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
    /// Structured reasoning blocks the API returned (`reasoning_details`).
    /// Wire state kept separately from the visible `reasoning` summary so
    /// opaque signature/encrypted payloads survive round trips without ever
    /// being rendered (F07).
    var reasoningDetails: [ReasoningDetail]?

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
        reasoningDetails: [ReasoningDetail]? = nil
    ) {
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
        self.reasoningDetails = reasoningDetails
    }

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning, parts, images
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
        reasoningDetails = try c.decodeIfPresent([ReasoningDetail].self, forKey: .reasoningDetails)
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
            && lhs.finishReason == rhs.finishReason
            && lhs.errorMessage == rhs.errorMessage
            && lhs.toolCalls == rhs.toolCalls
            && lhs.parts == rhs.parts
            && lhs.images == rhs.images
            && lhs.reasoningDetails == rhs.reasoningDetails
    }
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
