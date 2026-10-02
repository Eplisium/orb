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
}

// MARK: Filter state

struct BrowserFilterState: Equatable, Codable, Sendable {
    var capabilities: Set<ModelCapability>
    /// Maximum input price, USD per 1M tokens. Free models always pass.
    var maxInputPrice: Double?
    var minContext: Int?
    var providers: Set<String>

    init(
        capabilities: Set<ModelCapability> = [],
        maxInputPrice: Double? = nil,
        minContext: Int? = nil,
        providers: Set<String> = []
    ) {
        self.capabilities = capabilities
        self.maxInputPrice = maxInputPrice
        self.minContext = minContext
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey { case capabilities, maxInputPrice, minContext, providers }

    /// Tolerant: unknown capability names (from a newer/older build) are
    /// dropped rather than failing the whole restore.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        capabilities = Set(names.compactMap(ModelCapability.init(rawValue:)))
        maxInputPrice = try c.decodeIfPresent(Double.self, forKey: .maxInputPrice)
        minContext = try c.decodeIfPresent(Int.self, forKey: .minContext)
        providers = Set(try c.decodeIfPresent([String].self, forKey: .providers) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
        try c.encodeIfPresent(maxInputPrice, forKey: .maxInputPrice)
        try c.encodeIfPresent(minContext, forKey: .minContext)
        try c.encode(providers.sorted(), forKey: .providers)
    }

    var isActive: Bool {
        !capabilities.isEmpty || maxInputPrice != nil || minContext != nil || !providers.isEmpty
    }

    /// Capabilities AND together, providers OR together, facets AND together.
    func matches(_ model: ModelInfo) -> Bool {
        for capability in capabilities where !capability.matches(model) { return false }
        if !providers.isEmpty, !providers.contains(model.provider) { return false }
        if let maxInputPrice {
            guard let price = model.inputPricePer1MIncludingFree, price <= maxInputPrice else { return false }
        }
        if let minContext {
            guard let context = model.contextLength, context >= minContext else { return false }
        }
        return true
    }

    // MARK: Chips

    enum ChipKind: Equatable, Hashable {
        case capability(ModelCapability)
        case maxPrice
        case minContext
        case provider(String)
    }

    struct Chip: Identifiable, Equatable {
        let kind: ChipKind
        let title: String
        var id: String {
            switch kind {
            case .capability(let c): return "cap.\(c.rawValue)"
            case .maxPrice: return "price"
            case .minContext: return "context"
            case .provider(let p): return "provider.\(p)"
            }
        }
    }

    /// Stable order: capabilities (declaration order), price, context, providers (A–Z).
    var chips: [Chip] {
        var result: [Chip] = []
        for capability in ModelCapability.allCases where capabilities.contains(capability) {
            result.append(Chip(kind: .capability(capability), title: capability.title))
        }
        if let maxInputPrice {
            result.append(Chip(kind: .maxPrice, title: "≤ \(BrowserFormat.price(maxInputPrice)) / 1M in"))
        }
        if let minContext {
            result.append(Chip(kind: .minContext, title: "≥ \(BrowserFormat.context(minContext)) ctx"))
        }
        for provider in providers.sorted() {
            result.append(Chip(kind: .provider(provider), title: provider))
        }
        return result
    }

    mutating func remove(_ chip: Chip) {
        switch chip.kind {
        case .capability(let c): capabilities.remove(c)
        case .maxPrice: maxInputPrice = nil
        case .minContext: minContext = nil
        case .provider(let p): providers.remove(p)
        }
    }

    mutating func clear() { self = BrowserFilterState() }

    // MARK: Popover presets

    static let priceSteps: [Double] = [0.5, 1, 2, 5, 10, 25]
    static let contextSteps: [Int] = [8_000, 32_000, 128_000, 200_000, 1_000_000]
}

// MARK: Persistence

struct BrowserPrefs: Codable, Equatable {
    var filters: BrowserFilterState
    var sortField: String
    var ascending: Bool
    var pinFavorites: Bool
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
    let context: String
    let inputModalities: String
    let outputModalities: String
    let latency: String
    let throughput: String
    let inputPriceValue: Double?
    let contextValue: Int?

    static let missing = "—"

    static func make(model: ModelInfo, endpoints: [ModelEndpoint]?) -> ComparisonColumn {
        func priceText(_ perMillion: Double?, free: Bool) -> String {
            if free { return "Free" }
            guard let perMillion else { return "Variable" }
            return "\(BrowserFormat.price(perMillion)) / 1M"
        }
        let inValue = model.inputPricePer1MIncludingFree
        let free = model.isFree
        let outValue = model.pricing?.completion.flatMap(Double.init).flatMap { $0 >= 0 ? $0 * 1_000_000 : nil }
        let latencies = (endpoints ?? []).compactMap(\.latencyLast30m)
        let throughputs = (endpoints ?? []).compactMap(\.throughputLast30m)
        return ComparisonColumn(
            id: model.id,
            name: model.name,
            inputPrice: priceText(inValue, free: free),
            outputPrice: priceText(outValue, free: free),
            context: model.contextLength.map(BrowserFormat.context) ?? "N/A",
            inputModalities: model.inputModalities.joined(separator: ", "),
            outputModalities: model.outputModalities.joined(separator: ", "),
            latency: latencies.min().map { "\($0) ms" } ?? missing,
            throughput: throughputs.max().map { "\($0) tok/s" } ?? missing,
            inputPriceValue: free ? 0 : inValue,
            contextValue: model.contextLength
        )
    }

    struct Highlights: Equatable {
        var cheapestInputID: String?
        var largestContextID: String?
    }

    /// A highlight needs at least two known values that differ; otherwise
    /// there is nothing to beat.
    static func highlights(_ columns: [ComparisonColumn]) -> Highlights {
        let prices = columns.compactMap { c in c.inputPriceValue.map { (c.id, $0) } }
        let contexts = columns.compactMap { c in c.contextValue.map { (c.id, $0) } }
        var result = Highlights()
        if prices.count >= 2, Set(prices.map(\.1)).count > 1 {
            result.cheapestInputID = prices.min { $0.1 < $1.1 }?.0
        }
        if contexts.count >= 2, Set(contexts.map(\.1)).count > 1 {
            result.largestContextID = contexts.max { $0.1 < $1.1 }?.0
        }
        return result
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
        case clearSearch, removeMaxPrice, removeMinContext, clearProviders
        case removeCapability(ModelCapability)
        case clearAll
    }
    let kind: Kind
    let title: String
    var id: String {
        switch kind {
        case .clearSearch: return "search"
        case .removeMaxPrice: return "price"
        case .removeMinContext: return "context"
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
        if filters.minContext != nil {
            list.append(.init(kind: .removeMinContext, title: "Remove the context minimum"))
        }
        if !filters.providers.isEmpty {
            list.append(.init(kind: .clearProviders, title: "Allow any provider"))
        }
        for capability in ModelCapability.allCases where filters.capabilities.contains(capability) {
            list.append(.init(kind: .removeCapability(capability), title: "Stop requiring \(capability.title)"))
        }
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

    static func make(_ model: ModelInfo) -> ModelRowFacts {
        let provider = model.provider.trimmingCharacters(in: CharacterSet(charactersIn: "~"))
        let letter = provider.first.map { String($0).uppercased() } ?? "?"
        let line = model.description?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }

        let price: String
        if model.isFree {
            price = "Free"
        } else if let input = model.promptCostPer1M {
            let output = model.completionCostPer1M.map(BrowserFormat.price) ?? ComparisonColumn.missing
            price = "\(BrowserFormat.price(input)) in · \(output) out"
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
