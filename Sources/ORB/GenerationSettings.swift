import Foundation

/// Reasoning ("thinking") controls, per OpenRouter's `reasoning` parameter.
///
/// `effort` and `maxTokens` are mutually exclusive upstream, so the encoder
/// emits at most one of them.
struct ReasoningSettings: Codable, Equatable, Sendable {
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
struct ProviderSettings: Codable, Equatable, Sendable {
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

    var isConfigured: Bool {
        !order.isEmpty || !ignore.isEmpty || !only.isEmpty
            || sort != .none || !allowFallbacks || requireParameters
            || dataCollection != .allow || zeroDataRetention
    }
}

/// Every sampling and routing knob ORB exposes for a request.
///
/// Optionals are meaningful: a `nil` field is omitted from the JSON body so
/// OpenRouter forwards the provider's own default rather than a value ORB
/// invented. This matters because explicitly sending a parameter can change
/// provider-side cache keys even when it matches the default.
struct GenerationSettings: Codable, Equatable, Sendable {
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
        copy.topLogprobs = topLogprobs.map { min(max($0, 0), 20) }
        copy.webSearchMaxResults = webSearchMaxResults.map { min(max($0, 1), 10) }
        if copy.reasoning.effort != nil { copy.reasoning.maxTokens = nil }
        copy.reasoning.maxTokens = copy.reasoning.maxTokens.map { max($0, 1) }
        // Empty strings would silently truncate generation at every token.
        copy.stop = stop.filter { !$0.isEmpty }
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
        return parts
    }

    private func format(_ value: Double) -> String {
        String(format: value == value.rounded() ? "%.0f" : "%.2f", value)
    }
}
