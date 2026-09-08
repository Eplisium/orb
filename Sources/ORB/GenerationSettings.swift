import Foundation

/// Reasoning ("thinking") controls, per OpenRouter's `reasoning` parameter.
///
/// `effort` and `maxTokens` are mutually exclusive upstream, so the encoder
/// emits at most one of them.
struct ReasoningSettings: Codable, Equatable, Sendable, Hashable {
    enum Effort: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, minimal, low, medium, high, xhigh, max
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// OpenAI-style effort level.
    var effort: Effort?
    /// Anthropic-style explicit token budget. Ignored when `effort` is set.
    var maxTokens: Int?
    /// Hide reasoning from the response while still letting the model think.
    var exclude: Bool = false
    /// Turn reasoning on with provider defaults.
    var enabled: Bool = false

    var isConfigured: Bool {
        effort != nil || maxTokens != nil || exclude || enabled
    }
}

/// Provider routing preferences, per OpenRouter's `provider` object.
struct ProviderSettings: Codable, Equatable, Sendable, Hashable {
    static let maxPriceCap: Double = 10_000
    enum Sort: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, price, throughput, latency
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Balanced (default)"
            case .price: return "Cheapest"
            case .throughput: return "Fastest throughput"
            case .latency: return "Lowest latency"
            }
        }
    }

    enum DataCollection: String, Codable, CaseIterable, Sendable, Identifiable {
        case allow, deny
        var id: String { rawValue }
        var label: String { self == .allow ? "Allow" : "Deny (no training/storage)" }
    }

    /// Ordered provider slugs to try first.
    var order: [String] = []
    /// Providers to exclude entirely.
    var ignore: [String] = []
    /// Restrict routing to only these providers.
    var only: [String] = []
    var sort: Sort = .none
    var allowFallbacks: Bool = true
    /// Only route to providers supporting every parameter in the request.
    var requireParameters: Bool = false
    var dataCollection: DataCollection = .allow
    /// Enforce zero-data-retention providers.
    var zeroDataRetention: Bool = false
    /// Maximum USD per 1M prompt tokens. Nil omits the cap.
    var maxPromptPrice: Double?
    /// Maximum USD per 1M completion tokens. Nil omits the cap.
    var maxCompletionPrice: Double?
    /// Maximum USD per image (image-output models). Nil omits the cap.
    var maxImagePrice: Double?
    /// Maximum USD per audio unit. Nil omits the cap.
    var maxAudioPrice: Double?
    /// Maximum USD per request. Nil omits the cap.
    var maxRequestPrice: Double?

    var isConfigured: Bool {
        !order.isEmpty || !ignore.isEmpty || !only.isEmpty
            || sort != .none || !allowFallbacks || requireParameters
            || dataCollection != .allow || zeroDataRetention
            || maxPromptPrice != nil || maxCompletionPrice != nil
            || maxImagePrice != nil || maxAudioPrice != nil || maxRequestPrice != nil
    }
}

/// Constrain the assistant's reply shape (`response_format`).
///
/// `.off` omits the parameter. `.jsonObject` requires the prompt to ask for
/// JSON. `.jsonSchema` sends a named schema (structured outputs on providers
/// that support it).
enum ResponseFormatSettings: Codable, Equatable, Sendable, Hashable {
    case off
    case jsonObject
    case jsonSchema(name: String, schema: JSONValue, strict: Bool = true)

    var isConfigured: Bool {
        if case .off = self { return false }
        return true
    }

    // MARK: Codable

    private enum Keys: String, CodingKey { case type, jsonSchema = "json_schema" }
    private enum SchemaKeys: String, CodingKey { case name, schema, strict }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "json_object": self = .jsonObject
        case "json_schema":
            let nested = try container.nestedContainer(keyedBy: SchemaKeys.self, forKey: .jsonSchema)
            self = .jsonSchema(
                name: try nested.decode(String.self, forKey: .name),
                schema: try nested.decode(JSONValue.self, forKey: .schema),
                strict: try nested.decodeIfPresent(Bool.self, forKey: .strict) ?? true
            )
        default: self = .off
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .off:
            // Encoded only when isConfigured; keep the shape valid anyway.
            try container.encode("text", forKey: .type)
        case .jsonObject:
            try container.encode("json_object", forKey: .type)
        case .jsonSchema(let name, let schema, let strict):
            try container.encode("json_schema", forKey: .type)
            var nested = container.nestedContainer(keyedBy: SchemaKeys.self, forKey: .jsonSchema)
            try nested.encode(name, forKey: .name)
            try nested.encode(schema, forKey: .schema)
            try nested.encode(strict, forKey: .strict)
        }
    }
}

/// Upstream service tier (`service_tier`). `fast` is an alias for `priority`.
enum ServiceTier: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case auto, `default`, priority, fast, flex, scale
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .default: return "Default"
        case .priority: return "Priority"
        case .fast: return "Fast (priority alias)"
        case .flex: return "Flex (cheaper, slower)"
        case .scale: return "Scale"
        }
    }
}

/// Extra OpenRouter plugins beyond web search: file-parser, moderation,
/// response-healing. Each encodes as `{id, …options}`.
struct ExtraPlugin: Codable, Equatable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        case fileParser = "file-parser"
        case moderation
        case responseHealing = "response-healing"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fileParser: return "File Parser (PDF engine)"
            case .moderation: return "Moderation"
            case .responseHealing: return "Response Healing"
            }
        }
    }

    var kind: Kind
    /// PDF engine for the file-parser plugin (e.g. "native", "mistral-ocr").
    /// Nil sends no engine preference.
    var pdfEngine: String?
    var id: String { kind.rawValue }

    enum CodingKeys: String, CodingKey { case id, pdf }

    private enum PDFKeys: String, CodingKey { case engine }

    init(kind: Kind, pdfEngine: String? = nil) {
        self.kind = kind
        self.pdfEngine = pdfEngine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: try container.decode(String.self, forKey: .id)) ?? .moderation
        if container.contains(.pdf) {
            let nested = try container.nestedContainer(keyedBy: PDFKeys.self, forKey: .pdf)
            pdfEngine = try nested.decodeIfPresent(String.self, forKey: .engine)
        } else {
            pdfEngine = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .id)
        if kind == .fileParser, let pdfEngine, !pdfEngine.isEmpty {
            var nested = container.nestedContainer(keyedBy: PDFKeys.self, forKey: .pdf)
            try nested.encode(pdfEngine, forKey: .engine)
        }
    }
}
///
/// Optionals are meaningful: a `nil` field is omitted from the JSON body so
/// OpenRouter forwards the provider's own default rather than a value ORB
/// invented. This matters because explicitly sending a parameter can change
/// provider-side cache keys even when it matches the default.
struct GenerationSettings: Codable, Equatable, Sendable, Hashable {
    var temperature: Double? = 0.7
    var topP: Double?
    var topK: Int?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var repetitionPenalty: Double?
    var minP: Double?
    var topA: Double?
    var seed: Int?
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var stop: [String] = []
    var logitBias: [String: Double] = [:]
    var logprobs: Bool = false
    var topLogprobs: Int?
    var parallelToolCalls: Bool?
    var reasoning = ReasoningSettings()
    var provider = ProviderSettings()
    /// Message transforms such as `middle-out` compression for long contexts.
    var transforms: [String] = []
    /// Ordered fallback models, per OpenRouter's `models` array.
    var fallbackModels: [String] = []
    /// Enable the `:online` web-search plugin for this request.
    var webSearch: Bool = false
    /// Maximum web results when `webSearch` is enabled.
    var webSearchMaxResults: Int?
    /// Ask OpenRouter to return usage accounting (cost, token counts).
    var includeUsageAccounting: Bool = true
    /// Constrain the reply shape: off, `json_object`, or a JSON Schema.
    /// `json_object` requires the prompt to ask for JSON.
    var responseFormat: ResponseFormatSettings = .off
    /// Upstream service tier: auto, default, priority/fast, flex, or scale.
    var serviceTier: ServiceTier? = nil
    /// Stable per-end-user identifier for abuse isolation. Hashed upstream,
    /// never sent to providers verbatim.
    var endUserId: String?
    /// Identifier grouping related requests (conversation/agent workflow).
    /// Also used as the sticky-routing key.
    var sessionId: String?
    /// `image_config` knobs for chat requests to image-output models.
    var imageConfig = ChatImageConfig()
    /// Output modalities to request instead of plain text (image/audio out).
    var modalities: [OutputModality] = []
    /// Extra OpenRouter plugins beyond web search (file-parser, …).
    var extraPlugins: [ExtraPlugin] = []

    static let `default` = GenerationSettings()

    // MARK: Validation

    /// Clamps every value into the range OpenRouter documents, so a bad preset
    /// can't produce a 400 that looks like a network failure to the user.
    func validated() -> GenerationSettings {
        var copy = self
        copy.temperature = temperature.map { min(max($0, 0), 2) }
        copy.topP = topP.map { min(max($0, 0), 1) }
        copy.topK = topK.map { max($0, 0) }
        copy.frequencyPenalty = frequencyPenalty.map { min(max($0, -2), 2) }
        copy.presencePenalty = presencePenalty.map { min(max($0, -2), 2) }
        copy.repetitionPenalty = repetitionPenalty.map { min(max($0, 0.01), 2) }
        copy.minP = minP.map { min(max($0, 0), 1) }
        copy.topA = topA.map { min(max($0, 0), 1) }
        copy.maxTokens = maxTokens.map { max($0, 1) }
        copy.maxCompletionTokens = maxCompletionTokens.map { max($0, 1) }
        copy.topLogprobs = topLogprobs.map { min(max($0, 0), 20) }
        copy.webSearchMaxResults = webSearchMaxResults.map { min(max($0, 1), 10) }
        copy.provider.maxPromptPrice = copy.provider.maxPromptPrice.map {
            min(max($0, 0), ProviderSettings.maxPriceCap)
        }
        copy.provider.maxCompletionPrice = copy.provider.maxCompletionPrice.map {
            min(max($0, 0), ProviderSettings.maxPriceCap)
        }
        copy.provider.maxImagePrice = copy.provider.maxImagePrice.map {
            min(max($0, 0), ProviderSettings.maxPriceCap)
        }
        copy.provider.maxAudioPrice = copy.provider.maxAudioPrice.map {
            min(max($0, 0), ProviderSettings.maxPriceCap)
        }
        copy.provider.maxRequestPrice = copy.provider.maxRequestPrice.map {
            min(max($0, 0), ProviderSettings.maxPriceCap)
        }
        if copy.reasoning.effort != nil { copy.reasoning.maxTokens = nil }
        copy.reasoning.maxTokens = copy.reasoning.maxTokens.map { max($0, 1) }
        // Empty strings would silently truncate generation at every token.
        copy.stop = stop.filter { !$0.isEmpty }
        copy.endUserId = endUserId.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        copy.sessionId = sessionId.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if case .jsonSchema(let name, let schema, let strict) = copy.responseFormat {
            // A blank name or non-object schema is rejected upstream; drop the
            // constraint rather than sending a request that must 400.
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, schema.objectValue != nil else {
                copy.responseFormat = .off
                return copy.validatedResponseFormatTrimmed()
            }
            copy.responseFormat = .jsonSchema(name: trimmed, schema: schema, strict: strict)
        }
        copy.imageConfig.aspectRatio = copy.imageConfig.aspectRatio?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? copy.imageConfig.aspectRatio : nil
        copy.imageConfig.quality = copy.imageConfig.quality?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? copy.imageConfig.quality : nil
        return copy
    }

    /// Tail of `validated()` after a degenerate JSON Schema was dropped.
    /// Split out so the guard above can return a fully-trimmed copy without
    /// recursing into `validated()`.
    private func validatedResponseFormatTrimmed() -> GenerationSettings {
        var copy = self
        copy.imageConfig.aspectRatio = copy.imageConfig.aspectRatio?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? copy.imageConfig.aspectRatio : nil
        copy.imageConfig.quality = copy.imageConfig.quality?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false ? copy.imageConfig.quality : nil
        return copy
    }

    /// Human-readable summary of everything diverging from defaults, for the
    /// settings UI badge.
    var activeSummary: [String] {
        var parts: [String] = []
        if let temperature, temperature != 0.7 { parts.append("temp \(format(temperature))") }
        if let topP { parts.append("top_p \(format(topP))") }
        if let topK { parts.append("top_k \(topK)") }
        if let frequencyPenalty { parts.append("freq \(format(frequencyPenalty))") }
        if let presencePenalty { parts.append("pres \(format(presencePenalty))") }
        if let repetitionPenalty { parts.append("rep \(format(repetitionPenalty))") }
        if let minP { parts.append("min_p \(format(minP))") }
        if let topA { parts.append("top_a \(format(topA))") }
        if let seed { parts.append("seed \(seed)") }
        if let maxTokens { parts.append("max \(maxTokens)") }
        if !stop.isEmpty { parts.append("\(stop.count) stop") }
        if reasoning.isConfigured { parts.append("reasoning") }
        if provider.isConfigured { parts.append("routing") }
        if webSearch { parts.append("web") }
        if !fallbackModels.isEmpty { parts.append("\(fallbackModels.count) fallback") }
        if !transforms.isEmpty { parts.append("transforms") }
        if responseFormat.isConfigured { parts.append("format") }
        if serviceTier != nil { parts.append("tier") }
        if !modalities.isEmpty { parts.append("modalities") }
        if imageConfig.isConfigured { parts.append("imgcfg") }
        if endUserId != nil || sessionId != nil { parts.append("identity") }
        if !extraPlugins.isEmpty { parts.append("\(extraPlugins.count) plugin") }
        return parts
    }

    private func format(_ value: Double) -> String {
        String(format: value == value.rounded() ? "%.0f" : "%.2f", value)
    }
}
