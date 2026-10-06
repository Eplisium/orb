import Foundation

// MARK: - Model browser logic (Phase 4)
//
// Pure, unit-tested value types behind the redesigned browser: capability
// facets, compound filter state (+ chips), persisted preferences, compare
// selection/columns, list presentation state and row facts. Views only
// consume these.

// MARK: Capabilities

/// One list shared by the Filters popover and the row's icon strip so the two
/// can never drift apart.
enum ModelCapability: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case tools, reasoning, imageInput, imageOutput, videoInput, audio, fileInput, embeddings, free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return "Tools"
        case .reasoning: return "Reasoning"
        case .imageInput: return "Image input"
        case .imageOutput: return "Image output"
        case .videoInput: return "Video input"
        case .audio: return "Audio"
        case .fileInput: return "File input"
        case .embeddings: return "Embeddings"
        case .free: return "Free"
        }
    }

    var icon: String {
        switch self {
        case .tools: return "wrench.and.screwdriver"
        case .reasoning: return "brain"
        case .imageInput: return "photo"
        case .imageOutput: return "paintbrush"
        case .videoInput: return "video"
        case .audio: return "waveform"
        case .fileInput: return "doc"
        case .embeddings: return "chart.dots.scatter"
        case .free: return "gift"
        }
    }

    func matches(_ model: ModelInfo) -> Bool {
        switch self {
        case .tools: return model.supportsTools
        case .reasoning: return model.supportsReasoning
        case .imageInput: return model.supportsImages
        case .imageOutput: return model.supportsImageOutput
        case .videoInput: return model.supportsVideoInput
        case .audio: return model.supportsAudioInput || model.supportsAudioOutput
        case .fileInput: return model.supportsFileInput
        case .embeddings: return model.isEmbeddingModel
        case .free: return model.isFree
        }
    }
}

// MARK: Formatting

enum BrowserFormat {
    /// "$3" for whole dollars, otherwise the shared two-to-four decimal form.
    static func price(_ perMillion: Double) -> String {
        if perMillion == perMillion.rounded() { return "$" + String(format: "%.0f", perMillion) }
        return PriceFormat.perMillion(perMillion)
    }

    static func context(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1000 { return "\(tokens / 1000)K" }
        return "\(tokens)"
    }
}

extension ModelInfo {
    /// Input price in USD per 1M tokens including a genuine zero. nil when
    /// the catalog gives no usable number (variable / negative sentinel).
    var inputPricePer1MIncludingFree: Double? {
        guard let raw = pricing?.prompt, let value = Double(raw), value >= 0 else { return nil }
        return value * 1_000_000
    }

    /// Output price in USD per 1M tokens including a genuine zero.
    var outputPricePer1MIncludingFree: Double? {
        if isFree { return 0 }
        guard let raw = pricing?.completion, let value = Double(raw), value >= 0 else { return nil }
        return value * 1_000_000
    }
}

// MARK: Filter state

struct BrowserFilterState: Equatable, Codable, Sendable {
    var capabilities: Set<ModelCapability>
    /// Maximum input price, USD per 1M tokens. Free models always pass.
    var maxInputPrice: Double?
    /// Maximum output price, USD per 1M tokens. Free models always pass.
    var maxOutputPrice: Double?
    var minContext: Int?
    var providers: Set<String>
    /// `supported_parameters` every result must list (AND).
    var requiredParameters: Set<String>
    var hideExpired: Bool
    var hideAliases: Bool

    init(
        capabilities: Set<ModelCapability> = [],
        maxInputPrice: Double? = nil,
        minContext: Int? = nil,
        providers: Set<String> = [],
        maxOutputPrice: Double? = nil,
        requiredParameters: Set<String> = [],
        hideExpired: Bool = false,
        hideAliases: Bool = false
    ) {
        self.capabilities = capabilities
        self.maxInputPrice = maxInputPrice
        self.maxOutputPrice = maxOutputPrice
        self.minContext = minContext
        self.providers = providers
        self.requiredParameters = requiredParameters
        self.hideExpired = hideExpired
        self.hideAliases = hideAliases
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities, maxInputPrice, maxOutputPrice, minContext, providers
        case requiredParameters, hideExpired, hideAliases
    }

    /// Tolerant: unknown capability names (from a newer/older build) are
    /// dropped and missing keys (prefs saved by older builds) default,
    /// rather than failing the whole restore.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        capabilities = Set(names.compactMap(ModelCapability.init(rawValue:)))
        maxInputPrice = try c.decodeIfPresent(Double.self, forKey: .maxInputPrice)
        maxOutputPrice = try c.decodeIfPresent(Double.self, forKey: .maxOutputPrice)
        minContext = try c.decodeIfPresent(Int.self, forKey: .minContext)
        providers = Set(try c.decodeIfPresent([String].self, forKey: .providers) ?? [])
        requiredParameters = Set(try c.decodeIfPresent([String].self, forKey: .requiredParameters) ?? [])
        hideExpired = try c.decodeIfPresent(Bool.self, forKey: .hideExpired) ?? false
        hideAliases = try c.decodeIfPresent(Bool.self, forKey: .hideAliases) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
        try c.encodeIfPresent(maxInputPrice, forKey: .maxInputPrice)
        try c.encodeIfPresent(maxOutputPrice, forKey: .maxOutputPrice)
        try c.encodeIfPresent(minContext, forKey: .minContext)
        try c.encode(providers.sorted(), forKey: .providers)
        if !requiredParameters.isEmpty { try c.encode(requiredParameters.sorted(), forKey: .requiredParameters) }
        if hideExpired { try c.encode(true, forKey: .hideExpired) }
        if hideAliases { try c.encode(true, forKey: .hideAliases) }
    }

    var isActive: Bool {
        !capabilities.isEmpty || maxInputPrice != nil || maxOutputPrice != nil || minContext != nil
            || !providers.isEmpty || !requiredParameters.isEmpty || hideExpired || hideAliases
    }

    /// Capabilities AND together, providers OR together, facets AND together.
    func matches(_ model: ModelInfo) -> Bool {
        for capability in capabilities where !capability.matches(model) { return false }
        if !providers.isEmpty, !providers.contains(model.provider) { return false }
        if let maxInputPrice {
            guard let price = model.inputPricePer1MIncludingFree, price <= maxInputPrice else { return false }
        }
        if let maxOutputPrice {
            guard let price = model.outputPricePer1MIncludingFree, price <= maxOutputPrice else { return false }
        }
        if let minContext {
            guard let context = model.contextLength, context >= minContext else { return false }
        }
        if !requiredParameters.isEmpty {
            let params = Set(model.supportedParameters ?? [])
            guard requiredParameters.isSubset(of: params) else { return false }
        }
        if hideExpired, model.hasExpired { return false }
        if hideAliases, model.isAlias { return false }
        return true
    }

    // MARK: Chips

    enum ChipKind: Equatable, Hashable {
        case capability(ModelCapability)
        case maxPrice
        case maxOutputPrice
        case minContext
        case provider(String)
        case parameter(String)
        case hideExpired
        case hideAliases
    }

    struct Chip: Identifiable, Equatable {
        let kind: ChipKind
        let title: String
        var id: String {
            switch kind {
            case .capability(let c): return "cap.\(c.rawValue)"
            case .maxPrice: return "price"
            case .maxOutputPrice: return "outprice"
            case .minContext: return "context"
            case .provider(let p): return "provider.\(p)"
            case .parameter(let p): return "param.\(p)"
            case .hideExpired: return "expired"
            case .hideAliases: return "aliases"
            }
        }
    }

    /// Stable order: capabilities (declaration order), price, context,
    /// parameters (A–Z), providers (A–Z), hide toggles.
    var chips: [Chip] {
        var result: [Chip] = []
        for capability in ModelCapability.allCases where capabilities.contains(capability) {
            result.append(Chip(kind: .capability(capability), title: capability.title))
        }
        if let maxInputPrice {
            result.append(Chip(kind: .maxPrice, title: "≤ \(BrowserFormat.price(maxInputPrice)) / 1M in"))
        }
        if let maxOutputPrice {
            result.append(Chip(kind: .maxOutputPrice, title: "≤ \(BrowserFormat.price(maxOutputPrice)) / 1M out"))
        }
        if let minContext {
            result.append(Chip(kind: .minContext, title: "≥ \(BrowserFormat.context(minContext)) ctx"))
        }
        for parameter in requiredParameters.sorted() {
            result.append(Chip(kind: .parameter(parameter), title: parameter))
        }
        for provider in providers.sorted() {
            result.append(Chip(kind: .provider(provider), title: provider))
        }
        if hideExpired { result.append(Chip(kind: .hideExpired, title: "Hide expired")) }
        if hideAliases { result.append(Chip(kind: .hideAliases, title: "Hide aliases")) }
        return result
    }

    mutating func remove(_ chip: Chip) {
        switch chip.kind {
        case .capability(let c): capabilities.remove(c)
        case .maxPrice: maxInputPrice = nil
        case .maxOutputPrice: maxOutputPrice = nil
        case .minContext: minContext = nil
        case .provider(let p): providers.remove(p)
        case .parameter(let p): requiredParameters.remove(p)
        case .hideExpired: hideExpired = false
        case .hideAliases: hideAliases = false
        }
    }

    mutating func clear() { self = BrowserFilterState() }

    /// Request parameters worth filtering on, in popover order.
    static let filterableParameters: [String] = [
        "structured_outputs", "response_format", "tools", "tool_choice", "seed",
        "logprobs", "top_logprobs", "web_search_options", "reasoning", "include_reasoning",
        "stop", "temperature", "top_k", "min_p", "repetition_penalty", "logit_bias", "verbosity", "prediction",
    ]

    // MARK: Popover presets

    static let priceSteps: [Double] = [0.5, 1, 2, 5, 10, 25]
    static let outputPriceSteps: [Double] = [1, 2, 5, 10, 25, 75]
    static let contextSteps: [Int] = [8_000, 32_000, 128_000, 200_000, 1_000_000]
}

// MARK: Persistence

struct BrowserPrefs: Codable, Equatable {
    var filters: BrowserFilterState
    var sortField: String
    var ascending: Bool
    var pinFavorites: Bool
    /// Compare selection, pick order kept. Optional so older prefs decode.
    var compareIDs: [String]? = nil
}

enum BrowserPrefsStore {
    static let key = "orb.browser.prefs"

    static func load(from defaults: UserDefaults) -> BrowserPrefs? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BrowserPrefs.self, from: data)
    }

    static func save(_ prefs: BrowserPrefs, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: Compare

/// Staged model IDs for the Test Suite "Compare Models" picker. Single use.
final class CompareHandoff: @unchecked Sendable {
    static let shared = CompareHandoff()
    private let lock = NSLock()
    private var staged: [String]?

    func stage(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        staged = ids.isEmpty ? nil : ids
    }

    func take() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        defer { staged = nil }
        return staged
    }

    /// Only models the Test Suite can actually run, de-duplicated and capped.
    static func batchIDs(from ids: [String], catalog: [ModelInfo]) -> [String] {
        Array(TestBatchSelection.eligibleIDs(ids, catalog: catalog).prefix(TestBatchSelection.maximumModels))
    }
}

struct ComparisonColumn: Identifiable, Equatable {
    let id: String
    let name: String
    let inputPrice: String
    let outputPrice: String
    let cachePrice: String
    let context: String
    let maxOutput: String
    let inputModalities: String
    let outputModalities: String
    let latency: String
    let throughput: String
    let intelligence: String
    let knowledgeCutoff: String
    let parameters: String
    let inputPriceValue: Double?
    let contextValue: Int?
    let maxOutputValue: Int?
    let intelligenceValue: Double?

    static let missing = "—"

    /// `endpoints == nil` means "not loaded yet / failed" — shown as "—".
    static func make(model: ModelInfo, endpoints: [ModelEndpoint]?, unit: PriceUnit = .perMillion) -> ComparisonColumn {
        func priceText(_ raw: String?, free: Bool) -> String {
            if free { return "Free" }
            return PriceDisplay.text(raw, unit: unit) ?? "Variable"
        }
        let free = model.isFree
        let inValue = model.inputPricePer1MIncludingFree
        let latencies = (endpoints ?? []).compactMap(\.latencyLast30m)
        let throughputs = (endpoints ?? []).compactMap(\.throughputLast30m)
        let maxOut = model.topProvider?.maxCompletionTokens
        let intelligence = model.benchmarks?.artificialAnalysis?.intelligenceIndex
        let cache = PriceDisplay.perToken(model.pricing?.inputCacheRead).flatMap { $0 > 0 ? $0 : nil }
        return ComparisonColumn(
            id: model.id,
            name: model.name,
            inputPrice: priceText(model.pricing?.prompt, free: free),
            outputPrice: priceText(model.pricing?.completion, free: free),
            cachePrice: cache.map { PriceDisplay.text(perToken: $0, unit: unit) } ?? missing,
            context: model.contextLength.map(BrowserFormat.context) ?? "N/A",
            maxOutput: maxOut.map(BrowserFormat.context) ?? missing,
            inputModalities: model.inputModalities.joined(separator: ", "),
            outputModalities: model.outputModalities.joined(separator: ", "),
            latency: latencies.min().map { "\($0) ms" } ?? missing,
            throughput: throughputs.max().map { "\($0) tok/s" } ?? missing,
            intelligence: intelligence.map { String(format: "%.1f", $0) } ?? missing,
            knowledgeCutoff: model.knowledgeCutoff.flatMap { $0.isEmpty ? nil : $0 } ?? missing,
            parameters: (model.supportedParameters ?? []).sorted().joined(separator: ", ").nonEmpty ?? missing,
            inputPriceValue: free ? 0 : inValue,
            contextValue: model.contextLength,
            maxOutputValue: maxOut,
            intelligenceValue: intelligence
        )
    }

    struct Highlights: Equatable {
        var cheapestInputID: String?
        var largestContextID: String?
        var largestOutputID: String?
        var smartestID: String?
    }

    /// A highlight needs at least two known values that differ; otherwise
    /// there is nothing to beat.
    static func highlights(_ columns: [ComparisonColumn]) -> Highlights {
        func best<T: Comparable & Hashable>(_ values: [(String, T)], lowest: Bool) -> String? {
            guard values.count >= 2, Set(values.map(\.1)).count > 1 else { return nil }
            return (lowest ? values.min { $0.1 < $1.1 } : values.max { $0.1 < $1.1 })?.0
        }
        var result = Highlights()
        result.cheapestInputID = best(columns.compactMap { c in c.inputPriceValue.map { (c.id, $0) } }, lowest: true)
        result.largestContextID = best(columns.compactMap { c in c.contextValue.map { (c.id, $0) } }, lowest: false)
        result.largestOutputID = best(columns.compactMap { c in c.maxOutputValue.map { (c.id, $0) } }, lowest: false)
        result.smartestID = best(columns.compactMap { c in c.intelligenceValue.map { (c.id, $0) } }, lowest: false)
        return result
    }

    /// Row order shared by the panel and the exports.
    static let rows: [(title: String, value: (ComparisonColumn) -> String)] = [
        ("Model ID", { $0.id }),
        ("Input price", { $0.inputPrice }),
        ("Output price", { $0.outputPrice }),
        ("Cache read", { $0.cachePrice }),
        ("Context", { $0.context }),
        ("Max output", { $0.maxOutput }),
        ("Intelligence", { $0.intelligence }),
        ("Knowledge cutoff", { $0.knowledgeCutoff }),
        ("Inputs", { $0.inputModalities }),
        ("Outputs", { $0.outputModalities }),
        ("Latency", { $0.latency }),
        ("Throughput", { $0.throughput }),
        ("Parameters", { $0.parameters }),
    ]

    static func markdown(_ columns: [ComparisonColumn]) -> String {
        func cell(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| | " + columns.map { cell($0.name) }.joined(separator: " | ") + " |"]
        lines.append("|---|" + columns.map { _ in "---|" }.joined())
        for row in rows {
            lines.append("| \(row.title) | " + columns.map { cell(row.value($0)) }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csv(_ columns: [ComparisonColumn]) -> String {
        var lines = [([""] + columns.map(\.name)).map(ModelExport.csvField).joined(separator: ",")]
        for row in rows {
            lines.append(([row.title] + columns.map(row.value)).map(ModelExport.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Loads every compared model's endpoints concurrently. Each result is
/// independent: one failure never hides another model's data, and the
/// shared `APIService.endpointsError` is never touched.
enum CompareEndpointLoader {
    typealias Loader = @Sendable (String) async -> Result<[ModelEndpoint], EndpointLoadError>

    static func load(_ models: [(id: String, endpointsID: String)], loader: @escaping Loader) async -> [String: Result<[ModelEndpoint], EndpointLoadError>] {
        await withTaskGroup(of: (String, Result<[ModelEndpoint], EndpointLoadError>).self) { group in
            for model in models {
                group.addTask { (model.id, await loader(model.endpointsID)) }
            }
            var out: [String: Result<[ModelEndpoint], EndpointLoadError>] = [:]
            for await (id, result) in group { out[id] = result }
            return out
        }
    }
}

// MARK: List presentation

enum BrowserListState: Equatable {
    case skeleton
    case error(String)
    case emptySection
    case noResults
    case list(offlineSince: Date?)

    /// `error` is any failure to refresh (with or without cached models);
    /// the caller supplies `lastUpdated` for the offline banner.
    static func resolve(
        isLoading: Bool,
        hasModels: Bool,
        error: String?,
        resultCount: Int,
        hasRefinements: Bool,
        lastUpdated: Date?
    ) -> BrowserListState {
        if !hasModels {
            if isLoading { return .skeleton }
            if let error { return .error(error) }
            return .emptySection
        }
        if resultCount == 0 { return hasRefinements ? .noResults : .emptySection }
        return .list(offlineSince: error != nil ? lastUpdated : nil)
    }

    static func offlineBannerText(since: Date?) -> String {
        guard let since else { return "Offline: showing cached models" }
        return "Offline: showing cached models from \(since.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct NoResultsSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case clearSearch, removeMaxPrice, removeMaxOutputPrice, removeMinContext, clearProviders
        case clearParameters, showExpired, showAliases
        case removeCapability(ModelCapability)
        case clearAll
    }
    let kind: Kind
    let title: String
    var id: String {
        switch kind {
        case .clearSearch: return "search"
        case .removeMaxPrice: return "price"
        case .removeMaxOutputPrice: return "outprice"
        case .removeMinContext: return "context"
        case .clearParameters: return "params"
        case .showExpired: return "expired"
        case .showAliases: return "aliases"
        case .clearProviders: return "providers"
        case .removeCapability(let c): return "cap.\(c.rawValue)"
        case .clearAll: return "all"
        }
    }
}

enum NoResultsSuggestions {
    /// Narrowest, most-likely-culprit facets first; "clear all" always last.
    static func make(search: String, filters: BrowserFilterState) -> [NoResultsSuggestion] {
        var list: [NoResultsSuggestion] = []
        if filters.maxInputPrice != nil {
            list.append(.init(kind: .removeMaxPrice, title: "Remove the price limit"))
        }
        if filters.maxOutputPrice != nil {
            list.append(.init(kind: .removeMaxOutputPrice, title: "Remove the output price limit"))
        }
        if filters.minContext != nil {
            list.append(.init(kind: .removeMinContext, title: "Remove the context minimum"))
        }
        if !filters.requiredParameters.isEmpty {
            list.append(.init(kind: .clearParameters, title: "Stop requiring parameters"))
        }
        if !filters.providers.isEmpty {
            list.append(.init(kind: .clearProviders, title: "Allow any provider"))
        }
        for capability in ModelCapability.allCases where filters.capabilities.contains(capability) {
            list.append(.init(kind: .removeCapability(capability), title: "Stop requiring \(capability.title)"))
        }
        if filters.hideExpired { list.append(.init(kind: .showExpired, title: "Show expired models")) }
        if filters.hideAliases { list.append(.init(kind: .showAliases, title: "Show aliases")) }
        if !search.isEmpty {
            list.append(.init(kind: .clearSearch, title: "Clear the search"))
        }
        if !list.isEmpty { list.append(.init(kind: .clearAll, title: "Clear all filters")) }
        return list
    }
}

// MARK: Row facts

struct ModelRowFacts: Equatable {
    struct Badge: Equatable { let icon: String; let name: String }

    let avatarLetter: String
    let oneLiner: String?
    let context: String
    let price: String
    let capabilities: [Badge]

    static func make(_ model: ModelInfo, unit: PriceUnit = .perMillion) -> ModelRowFacts {
        let provider = model.provider.trimmingCharacters(in: CharacterSet(charactersIn: "~"))
        let letter = provider.first.map { String($0).uppercased() } ?? "?"
        let line = model.description?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        let price: String
        if model.isFree {
            price = "Free"
        } else if let input = PriceDisplay.perToken(model.pricing?.prompt), input > 0 {
            let output = PriceDisplay.perToken(model.pricing?.completion)
                .map { PriceDisplay.amount(perToken: $0, unit: unit) } ?? ComparisonColumn.missing
            let suffix = unit == .perMillion ? "" : " /1K"
            price = "\(PriceDisplay.amount(perToken: input, unit: unit)) in · \(output) out\(suffix)"
        } else {
            price = "Variable price"
        }

        let badges = ModelCapability.allCases
            .filter { $0 != .free && $0.matches(model) }
            .map { Badge(icon: $0.icon, name: $0.title) }

        return ModelRowFacts(
            avatarLetter: letter,
            oneLiner: line,
            context: model.contextLength.map(BrowserFormat.context) ?? "N/A",
            price: price,
            capabilities: badges
        )
    }
}
