import Foundation

// MARK: - Browser list pipeline (filter → search → sort → pin)
//
// Pure functions so the view model can cache one result per input change
// and tests can drive them without SwiftUI.

extension SortField {
    /// Natural first direction when the user picks the field: big numbers
    /// and soonest expiry first; names and prices ascending.
    var prefersDescending: Bool {
        switch self {
        case .name, .provider, .promptCost, .completionCost, .expiringSoon: return false
        default: return true
        }
    }
}

enum ModelSorter {
    /// Numeric sort key; nil means "unknown" and always sorts last.
    static func key(_ model: ModelInfo, _ field: SortField) -> Double? {
        switch field {
        case .name, .provider: return nil
        case .contextLength: return model.contextLength.map(Double.init)
        case .promptCost: return sortablePrice(model, \.prompt)
        case .completionCost: return sortablePrice(model, \.completion)
        case .created: return model.created
        case .designElo: return model.bestDesignElo
        case .intelligence: return model.benchmarks?.artificialAnalysis?.intelligenceIndex
        case .coding: return model.benchmarks?.artificialAnalysis?.codingIndex
        case .agentic: return model.benchmarks?.artificialAnalysis?.agenticIndex
        case .maxOutput:
            return (model.topProvider?.maxCompletionTokens ?? model.perRequestLimits?.completionTokens).map(Double.init)
        case .expiringSoon: return model.expirationInstant?.timeIntervalSince1970
        }
    }

    /// Free = 0; variable (negative sentinel) and missing = nil (last).
    static func sortablePrice(_ model: ModelInfo, _ path: KeyPath<Pricing, String?>) -> Double? {
        if model.isFree { return 0 }
        return PriceDisplay.perToken(model.pricing?[keyPath: path])
    }

    /// Unknown values last in both directions; ties broken by id so the
    /// order never shuffles between renders.
    static func sorted(_ models: [ModelInfo], by field: SortField, order: SortOrder) -> [ModelInfo] {
        let ascending = order == .ascending
        switch field {
        case .name, .provider:
            let keyed = models.map { m in (m, field == .name ? m.name.lowercased() : m.provider.lowercased()) }
            return keyed.sorted { a, b in
                if a.1 != b.1 { return ascending ? a.1 < b.1 : a.1 > b.1 }
                return a.0.id < b.0.id
            }.map(\.0)
        default:
            let keyed = models.map { ($0, key($0, field)) }
            return keyed.sorted { a, b in
                switch (a.1, b.1) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.0.id < b.0.id
                }
            }.map(\.0)
        }
    }
}

/// Lower-cased "id name provider description" per model, built once per
/// catalog load.
struct ModelSearchIndex {
    private let blobs: [String: String]

    init(_ models: [ModelInfo]) {
        var map: [String: String] = [:]
        map.reserveCapacity(models.count)
        for m in models {
            map[m.id] = [m.id, m.name, m.provider, m.description ?? ""].joined(separator: "\n").lowercased()
        }
        blobs = map
    }

    /// Every whitespace-separated term must appear.
    func matches(_ model: ModelInfo, terms: [Substring]) -> Bool {
        guard !terms.isEmpty else { return true }
        guard let blob = blobs[model.id] else { return false }
        return terms.allSatisfy { blob.contains($0) }
    }

    static func terms(_ query: String) -> [Substring] {
        query.lowercased().split(whereSeparator: \.isWhitespace)
    }
}

struct BrowserQuery: Equatable {
    var showFavoritesOnly = false
    var showNewThisWeek = false
    var favoriteIds: Set<String> = []
    var filters = BrowserFilterState()
    var searchText = ""
    var sortField: SortField = .created
    var sortOrder: SortOrder = .descending
    var pinFavorites = true

    func run(_ models: [ModelInfo], index: ModelSearchIndex, isNew: (ModelInfo) -> Bool) -> [ModelInfo] {
        let terms = ModelSearchIndex.terms(searchText)
        let filtersActive = filters.isActive
        let kept = models.filter { m in
            if showFavoritesOnly, !favoriteIds.contains(m.id) { return false }
            if showNewThisWeek, !isNew(m) { return false }
            if filtersActive, !filters.matches(m) { return false }
            return index.matches(m, terms: terms)
        }
        var result = ModelSorter.sorted(kept, by: sortField, order: sortOrder)
        if pinFavorites, !favoriteIds.isEmpty {
            // Stable partition: favourites first, chosen order kept inside each half.
            result = result.filter { favoriteIds.contains($0.id) } + result.filter { !favoriteIds.contains($0.id) }
        }
        return result
    }
}
