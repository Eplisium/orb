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
    /// Show the `:batch` variants (Batch API only, can't chat). Off by
    /// default: 90+ near-duplicate rows are noise for most browsing. A
    /// display preference, not a refinement: it never counts as an active
    /// filter, never shows a chip, and Clear keeps it.
    var showBatchVariants: Bool

    init(
        capabilities: Set<ModelCapability> = [],
        maxInputPrice: Double? = nil,
        minContext: Int? = nil,
        providers: Set<String> = [],
        maxOutputPrice: Double? = nil,
        requiredParameters: Set<String> = [],
        hideExpired: Bool = false,
        hideAliases: Bool = false,
        showBatchVariants: Bool = false
    ) {
        self.capabilities = capabilities
        self.maxInputPrice = maxInputPrice
        self.maxOutputPrice = maxOutputPrice
        self.minContext = minContext
        self.providers = providers
        self.requiredParameters = requiredParameters
        self.hideExpired = hideExpired
        self.hideAliases = hideAliases
        self.showBatchVariants = showBatchVariants
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities, maxInputPrice, maxOutputPrice, minContext, providers
        case requiredParameters, hideExpired, hideAliases, showBatchVariants
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
        showBatchVariants = (try? c.decodeIfPresent(Bool.self, forKey: .showBatchVariants)) ?? false
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
        if showBatchVariants { try c.encode(true, forKey: .showBatchVariants) }
    }

    /// Whether a model is listed at all under the batch preference. Explicit
    /// favorites are always listed in Favorites (see `BrowserQuery`).
    func listsBatchVariant(_ model: ModelInfo) -> Bool {
        showBatchVariants || !model.isBatchOnly
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

    /// Clears every refinement; the batch display preference is kept.
    mutating func clear() { self = BrowserFilterState(showBatchVariants: showBatchVariants) }

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
    /// Override tiers / extra prices ("Above 272K prompt tokens: …"), or "—".
    let pricingTiers: String
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
        let latencies = (endpoints ?? []).compactMap { $0.latencyLast30m?.typical }
        let throughputs = (endpoints ?? []).compactMap { $0.throughputLast30m?.typical }
        let maxOut = model.topProvider?.maxCompletionTokens
        let intelligence = model.benchmarks?.artificialAnalysis?.intelligenceIndex
        let cache = PriceDisplay.perToken(model.pricing?.inputCacheRead).flatMap { $0 > 0 ? $0 : nil }
        return ComparisonColumn(
            id: model.id,
            name: model.name,
            inputPrice: priceText(model.pricing?.prompt, free: free),
            outputPrice: priceText(model.pricing?.completion, free: free),
            cachePrice: cache.map { PriceDisplay.text(perToken: $0, unit: unit) } ?? missing,
            pricingTiers: model.pricing.map { p in
                (p.tierLines(unit: unit) + p.extraLines(unit: unit).filter { $0.title != "Cache read" })
                    .map { "\($0.title): \($0.value)" }.joined(separator: "\n")
            }.flatMap(\.nonEmpty) ?? missing,
            context: model.contextLength.map(BrowserFormat.context) ?? "N/A",
            maxOutput: maxOut.map(BrowserFormat.context) ?? missing,
            inputModalities: model.inputModalities.joined(separator: ", "),
            outputModalities: model.outputModalities.joined(separator: ", "),
            latency: latencies.min().map(EndpointPerformance.milliseconds) ?? missing,
            throughput: throughputs.max().map(EndpointPerformance.tokensPerSecond) ?? missing,
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
        ("Other pricing", { $0.pricingTiers }),
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
    /// Human display name without the redundant "Author: " prefix.
    var title: String = ""
    /// The id after the author ("gpt-4o-mini"), shown as secondary text.
    var slug: String = ""
    /// Author shown by the avatar ("Google", else the id's provider).
    var author: String = ""
    let oneLiner: String?
    let context: String
    let price: String
    /// Short price for narrow rows ("$2/$10", "Free", "Varies"); the row falls back to it before truncating.
    var compactPrice: String = ""
    let capabilities: [Badge]

    static func make(_ model: ModelInfo, unit: PriceUnit = .perMillion) -> ModelRowFacts {
        let provider = model.provider.trimmingCharacters(in: CharacterSet(charactersIn: "~"))
        let letter = provider.first.map { String($0).uppercased() } ?? "?"
        let line = firstLine(of: model.description)

        let price: String
        let compactPrice: String
        if model.isFree {
            price = "Free"; compactPrice = "Free"
        } else if let input = PriceDisplay.perToken(model.pricing?.prompt), input > 0 {
            let output = PriceDisplay.perToken(model.pricing?.completion)
                .map { PriceDisplay.amount(perToken: $0, unit: unit) } ?? ComparisonColumn.missing
            let suffix = unit == .perMillion ? "" : " /1K"
            let inputText = PriceDisplay.amount(perToken: input, unit: unit)
            price = "\(inputText) in · \(output) out\(suffix)"
            compactPrice = "\(inputText)/\(output)"
        } else {
            price = "Variable price"; compactPrice = "Varies"
        }

        let badges = ModelCapability.allCases
            .filter { $0 != .free && $0.matches(model) }
            .map { Badge(icon: $0.icon, name: $0.title) }

        return ModelRowFacts(
            avatarLetter: letter,
            title: model.displayTitle,
            slug: model.modelSlug.isEmpty ? model.id : model.modelSlug,
            author: model.authorName,
            oneLiner: line,
            context: model.contextLength.map(BrowserFormat.context) ?? "N/A",
            price: price,
            compactPrice: compactPrice,
            capabilities: badges
        )
    }

    /// First line with visible text once Markdown is stripped. Lazy: cleaning
    /// is several regex passes, so it stops at the first line that has text
    /// instead of cleaning the whole description for every row.
    static func firstLine(of description: String?) -> String? {
        description?
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { CatalogDescriptionText.plain(String($0)) }
            .first { !$0.isEmpty }
    }
}

// MARK: Endpoint facts

extension ModelEndpoint {
    /// Per-token input price used to rank providers. A real $0 is 0, so a
    /// free endpoint is the cheapest; variable ("-1") and missing prices are
    /// nil and rank last. (`promptCostPer1M` is nil for $0 as well.)
    var rankingInputPrice: Double? { PriceDisplay.perToken(pricing?.prompt) }

    /// The lowest input price in `endpoints`, for the "Cheapest input" seal.
    static func cheapestInputPrice(in endpoints: [ModelEndpoint]) -> Double? {
        endpoints.compactMap(\.rankingInputPrice).min()
    }
}

enum EndpointUptime {
    /// Uptime as a percentage in 0...100. The API documents a percentage
    /// (99.89), so a value of 1 is a real 1% outage, never a fraction.
    static func percent(_ raw: Double) -> Double? {
        guard raw.isFinite, raw >= 0 else { return nil }
        return min(raw, 100)
    }

    /// "Uptime 99.9%". One decimal place, and never rounded up to 100:
    /// 99.997 reads "99.9%", not "100%" (and not the truncated "99%").
    static func label(_ raw: Double) -> String? {
        guard let percent = percent(raw) else { return nil }
        if percent >= 100 { return "Uptime 100%" }
        let shown = min((percent * 10).rounded() / 10, 99.9)
        return "Uptime " + String(format: "%.1f", shown) + "%"
    }
}

// MARK: Catalog routes and names

extension ModelInfo {
    /// API routes from the catalog's top-level `endpoints`; nil when the
    /// field is missing (caches written by older builds).
    var apiRoutes: [String]? {
        guard let values = apiEndpoints?.values, !values.isEmpty else { return nil }
        return values
    }

    /// `:batch` variants: callable only through `/api/v1/batches`.
    var isBatchOnly: Bool {
        if let routes = apiRoutes { return routes.allSatisfy { $0.hasSuffix("/batches") } }
        return id.hasSuffix(":batch")
    }

    /// Whether `/chat/completions` accepts this model. Without route data
    /// (older caches) everything but a `:batch` id is assumed to.
    var supportsChatCompletions: Bool {
        if let routes = apiRoutes { return routes.contains { $0.hasSuffix("/chat/completions") } }
        return !id.hasSuffix(":batch")
    }

    /// Text comes out (or the catalog doesn't say).
    var producesText: Bool {
        outputModalities.isEmpty || outputModalities.contains("text")
    }

    /// Usable by Chat, Agent and Test Suite: a chat-completions model that
    /// answers in text.
    var isChatCapable: Bool { supportsChatCompletions && producesText }

    /// Callable on `/api/v1/embeddings`.
    var supportsEmbeddingsAPI: Bool {
        if let routes = apiRoutes { return routes.contains { $0.hasSuffix("/embeddings") } }
        return isEmbeddingModel
    }

    /// "Gemini 4 Hydrogen (batch)" for "Google: Gemini 4 Hydrogen (batch)".
    var displayTitle: String {
        ModelDisplayName.title(name: name, fallback: modelSlug.isEmpty ? id : modelSlug)
    }

    /// "Google" from the name's prefix, else the id's provider.
    var authorName: String {
        ModelDisplayName.author(name: name) ?? provider.trimmingCharacters(in: CharacterSet(charactersIn: "~"))
    }
}

/// Catalog names read "Author: Model". Rows show the author by the avatar,
/// so the title drops the prefix instead of repeating it on every row.
enum ModelDisplayName {
    private static let maxAuthorLength = 40

    private static func split(_ name: String) -> (author: Substring, rest: Substring)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ": ") else { return nil }
        let author = trimmed[..<range.lowerBound]
        let rest = trimmed[range.upperBound...].drop { $0.isWhitespace }
        guard !author.isEmpty, author.count <= maxAuthorLength, !rest.isEmpty,
              !author.contains("("), !author.contains("[") else { return nil }
        return (author, rest)
    }

    static func title(name: String, fallback: String) -> String {
        if let parts = split(name) { return String(parts.rest) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func author(name: String) -> String? {
        split(name).map { String($0.author) }
    }
}

// MARK: Hand-off availability

/// Which playgrounds can run a model, and why not. One source of truth for
/// the row menu, hover buttons, accessibility actions and the detail header.
enum ModelHandoff {
    enum Destination: Hashable, CaseIterable { case chat, agent }

    static func available(for model: ModelInfo) -> Set<Destination> {
        Set(Destination.allCases.filter { unavailableReason($0, for: model) == nil })
    }

    static func unavailableReason(_ destination: Destination, for model: ModelInfo) -> String? {
        if model.isBatchOnly {
            return "Batch API only: this variant runs through /api/v1/batches, not chat"
        }
        if !model.supportsChatCompletions {
            return "This model isn't served on chat completions"
        }
        if !model.producesText {
            return "This model doesn't produce text, so it can't chat"
        }
        if destination == .agent, !model.supportsTools {
            return "This model doesn't support tool calling, which the Agent needs"
        }
        return nil
    }
}

// MARK: API snippets

/// Ready-to-paste request examples for a model. The key is always the
/// `OPENROUTER_API_KEY` environment variable, never a real credential.
enum ModelSnippet {
    enum Language: String, CaseIterable, Identifiable {
        case curl, python, typescript
        var id: String { rawValue }
        var title: String {
            switch self {
            case .curl: return "curl"
            case .python: return "Python (OpenAI SDK)"
            case .typescript: return "TypeScript (fetch)"
            }
        }
    }

    enum Kind: Equatable { case chat, embeddings }

    static let keyVariable = "OPENROUTER_API_KEY"
    static let baseURL = "https://openrouter.ai/api/v1"

    /// nil for models with no request ORB can describe (batch-only,
    /// image/video/speech generation).
    static func kind(for model: ModelInfo) -> Kind? {
        if model.isChatCapable { return .chat }
        if model.supportsEmbeddingsAPI, !model.isBatchOnly { return .embeddings }
        return nil
    }

    static func render(model: ModelInfo, language: Language) -> String? {
        guard let kind = kind(for: model) else { return nil }
        let reasoning = kind == .chat && (model.supportedParameters?.contains("reasoning") ?? false)
        let tools = kind == .chat && model.supportsTools
        switch (kind, language) {
        case (.chat, .curl): return chatCurl(model.id, reasoning: reasoning, tools: tools)
        case (.chat, .python): return chatPython(model.id, reasoning: reasoning, tools: tools)
        case (.chat, .typescript): return chatTypeScript(model.id, reasoning: reasoning, tools: tools)
        case (.embeddings, .curl): return embeddingsCurl(model.id)
        case (.embeddings, .python): return embeddingsPython(model.id)
        case (.embeddings, .typescript): return embeddingsTypeScript(model.id)
        }
    }

    /// A JSON (and Python / TypeScript) string literal.
    static func literal(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let s = String(data: data, encoding: .utf8) else { return "\"\"" }
        return s
    }

    /// Escapes for the inside of a single-quoted shell string.
    private static func shellSingleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let toolJSON = """
    [
        {
          "type": "function",
          "function": {
            "name": "get_weather",
            "description": "Get the current weather for a city",
            "parameters": {
              "type": "object",
              "properties": {"city": {"type": "string"}},
              "required": ["city"]
            }
          }
        }
      ]
    """

    private static func chatCurl(_ id: String, reasoning: Bool, tools: Bool) -> String {
        var fields = [
            "  \"model\": \(literal(id))",
            "  \"messages\": [\n    {\"role\": \"user\", \"content\": \"Hello!\"}\n  ]",
        ]
        if reasoning { fields.append("  \"reasoning\": {\"effort\": \"medium\"}") }
        if tools { fields.append("  \"tools\": " + toolJSON) }
        let body = "{\n" + fields.joined(separator: ",\n") + "\n}"
        return """
        curl \(baseURL)/chat/completions \\
          -H "Authorization: Bearer $\(keyVariable)" \\
          -H "Content-Type: application/json" \\
          -d \(shellSingleQuoted(body))
        """
    }

    private static func pythonClient() -> String {
        """
        import os
        from openai import OpenAI

        client = OpenAI(
            base_url="\(baseURL)",
            api_key=os.environ["\(keyVariable)"],
        )
        """
    }

    private static func chatPython(_ id: String, reasoning: Bool, tools: Bool) -> String {
        var args = [
            "    model=\(literal(id)),",
            "    messages=[{\"role\": \"user\", \"content\": \"Hello!\"}],",
        ]
        if tools {
            args.append("""
                tools=[{
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "description": "Get the current weather for a city",
                        "parameters": {
                            "type": "object",
                            "properties": {"city": {"type": "string"}},
                            "required": ["city"],
                        },
                    },
                }],
            """)
        }
        if reasoning { args.append("    extra_body={\"reasoning\": {\"effort\": \"medium\"}},") }
        return pythonClient() + "\n\ncompletion = client.chat.completions.create(\n" + args.joined(separator: "\n")
            + "\n)\nprint(completion.choices[0].message)\n"
    }

    private static func typeScriptRequest(path: String, body: [String]) -> String {
        """
        const response = await fetch("\(baseURL)/\(path)", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${process.env.\(keyVariable)}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
        \(body.joined(separator: "\n"))
          }),
        });
        const data = await response.json();
        """
    }

    private static func chatTypeScript(_ id: String, reasoning: Bool, tools: Bool) -> String {
        var body = [
            "    model: \(literal(id)),",
            "    messages: [{ role: \"user\", content: \"Hello!\" }],",
        ]
        if reasoning { body.append("    reasoning: { effort: \"medium\" },") }
        if tools {
            body.append("""
                tools: [{
                  type: "function",
                  function: {
                    name: "get_weather",
                    description: "Get the current weather for a city",
                    parameters: {
                      type: "object",
                      properties: { city: { type: "string" } },
                      required: ["city"],
                    },
                  },
                }],
            """)
        }
        return typeScriptRequest(path: "chat/completions", body: body) + "\nconsole.log(data.choices[0].message);\n"
    }

    private static func embeddingsCurl(_ id: String) -> String {
        let body = "{\n  \"model\": \(literal(id)),\n  \"input\": \"The quick brown fox\"\n}"
        return """
        curl \(baseURL)/embeddings \\
          -H "Authorization: Bearer $\(keyVariable)" \\
          -H "Content-Type: application/json" \\
          -d \(shellSingleQuoted(body))
        """
    }

    private static func embeddingsPython(_ id: String) -> String {
        pythonClient() + "\n\nresult = client.embeddings.create(\n    model=\(literal(id)),\n    input=\"The quick brown fox\",\n)\nprint(len(result.data[0].embedding))\n"
    }

    private static func embeddingsTypeScript(_ id: String) -> String {
        typeScriptRequest(path: "embeddings", body: [
            "    model: \(literal(id)),",
            "    input: \"The quick brown fox\",",
        ]) + "\nconsole.log(data.data[0].embedding.length);\n"
    }
}

// MARK: Endpoint performance and status

enum EndpointPerformance {
    static func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
    static func tokensPerSecond(_ value: Double) -> String { String(format: "%.0f tok/s", value) }

    /// Median latency, e.g. "26 ms"; nil when unknown.
    static func latencyText(_ stats: PercentileStats?) -> String? { stats?.typical.map(milliseconds) }
    static func throughputText(_ stats: PercentileStats?) -> String? { stats?.typical.map(tokensPerSecond) }

    /// Tooltip with every known percentile.
    static func help(_ stats: PercentileStats?, unit: String, what: String) -> String {
        guard let stats, !stats.isEmpty else { return unavailableHelp }
        func f(_ v: Double) -> String { String(format: v < 10 ? "%.1f" : "%.0f", v) }
        let parts = [("p50", stats.p50), ("p75", stats.p75), ("p90", stats.p90), ("p99", stats.p99)]
            .compactMap { label, value in value.map { "\(label) \(f($0))" } }
        return "\(what) over the last 30 minutes (\(unit)): " + parts.joined(separator: " · ")
    }

    static let unavailableHelp =
        "OpenRouter publishes provider latency and throughput only to signed-in requests. ORB loads provider data anonymously, so these values aren't available."

    /// Whether any endpoint reports latency or throughput.
    static func hasStats(_ endpoints: [ModelEndpoint]) -> Bool {
        endpoints.contains { $0.latencyLast30m?.isEmpty == false || $0.throughputLast30m?.isEmpty == false }
    }
}

/// What the provider status dot says, in words as well as color.
enum EndpointStatusPresentation: Equatable {
    case available
    case degraded(Int)
    case unknown

    init(status: Int?) {
        switch status {
        case nil: self = .unknown
        case 0?: self = .available
        case let value?: self = .degraded(value)
        }
    }

    var label: String {
        switch self {
        case .available: return "Available"
        case .degraded(let code): return "Degraded (status \(code))"
        case .unknown: return "Status not reported"
        }
    }
}

// MARK: Keyboard and navigation decisions

/// Search field keys: ↓ moves into the results, Return opens the top hit,
/// Esc clears a query.
enum BrowserSearchKeys {
    enum Key: Equatable { case down, submit, escape }
    enum Action: Equatable {
        /// Focus the list; select the first row unless the selection is
        /// already visible.
        case focusList(selectFirst: Bool)
        /// Select the first result and focus the list.
        case openFirst
        case clear
        case ignored
    }

    static func action(for key: Key, hasQuery: Bool, resultCount: Int, selectionVisible: Bool = false) -> Action {
        switch key {
        case .down: return resultCount > 0 ? .focusList(selectFirst: !selectionVisible) : .ignored
        case .submit: return resultCount > 0 ? .openFirst : .ignored
        case .escape: return hasQuery ? .clear : .ignored
        }
    }
}

enum BrowserFind {
    /// ⌘F searches the collection on screen; from a non-browser section it
    /// opens All Models.
    static func target(current: SidebarSection) -> SidebarSection {
        current.isBrowser ? current : .allModels
    }
}

enum BrowserReveal {
    /// The section to show a model in ("Alias of X →", palette, deep link):
    /// the current collection when it can contain the model, else All Models.
    static func section(current: SidebarSection, isFavorite: Bool, isNew: Bool) -> SidebarSection {
        switch current {
        case .favorites: return isFavorite ? .favorites : .allModels
        case .newThisWeek: return isNew ? .newThisWeek : .allModels
        default: return .allModels
        }
    }
}

/// Stable palette slot for a provider without a hand-picked color. FNV-1a,
/// not `hashValue`, so the color is the same on every launch.
enum ProviderPalette {
    static func slot(for provider: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in provider.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}
