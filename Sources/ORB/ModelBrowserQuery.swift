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

/// Lower-cased search fields per model, built once per catalog load.
struct ModelSearchIndex {
    struct Fields {
        let id: String
        let slug: String
        let name: String
        let title: String
        let provider: String
        let author: String
        let description: String
        /// Everything joined, for the every-term-appears filter.
        let blob: String
    }

    private let fields: [String: Fields]

    init(_ models: [ModelInfo]) {
        var map: [String: Fields] = [:]
        map.reserveCapacity(models.count)
        for m in models {
            let description = (m.description ?? "").lowercased()
            let f = Fields(
                id: m.id.lowercased(), slug: m.modelSlug.lowercased(), name: m.name.lowercased(),
                title: m.displayTitle.lowercased(), provider: m.provider.lowercased(),
                author: m.authorName.lowercased(), description: description,
                blob: [m.id, m.name, m.provider, m.description ?? ""].joined(separator: "\n").lowercased()
            )
            map[m.id] = f
        }
        fields = map
    }

    func fields(for model: ModelInfo) -> Fields? { fields[model.id] }

    /// Every whitespace-separated term must appear.
    func matches(_ model: ModelInfo, terms: [Substring]) -> Bool {
        guard !terms.isEmpty else { return true }
        guard let blob = fields[model.id]?.blob else { return false }
        return terms.allSatisfy { blob.contains($0) }
    }

    static func terms(_ query: String) -> [Substring] {
        query.lowercased().split(whereSeparator: \.isWhitespace)
    }
}

/// Relevance for a search hit. Tiers, best first: exact id/slug/name, prefix
/// of slug/name, word-start match in slug/name, substring of slug/name,
/// author/provider-only match, description-only match. Within a tier a
/// shorter, earlier match wins. (Same tiering as `FuzzyMatcher` in the
/// command palette, applied per catalog field.)
enum ModelSearchRanker {
    static let exact = 6, prefix = 5, wordStart = 4, substring = 3, provider = 2, description = 1

    static func score(_ fields: ModelSearchIndex.Fields, query: String) -> Double {
        let phrase = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !phrase.isEmpty else { return 0 }
        let terms = phrase.split(separator: " ").map(String.init)
        let whole = fieldScore(fields, phrase)
        // A phrase found in the id or name (tier 3+) stands as is. Tier N
        // scores lie in (N*1000 - 600, N*1000].
        if terms.count == 1 || whole > Double(provider) * 1000 { return whole }
        // Several words ("gemini flash"): the weakest word decides, so every
        // word has to match well for the model to rank high.
        return terms.map { fieldScore(fields, $0) }.min() ?? 0
    }

    private static func fieldScore(_ f: ModelSearchIndex.Fields, _ q: String) -> Double {
        // The full id only counts as an exact match: its "author/" prefix
        // would otherwise make every model of a provider a prefix hit.
        let primary = [f.slug, f.title, f.name]
        var best = 0.0
        func consider(_ tier: Int, _ text: String, at offset: Int) {
            // Tier dominates; then shorter text, then an earlier match.
            let value = Double(tier) * 1000 - Double(min(text.count, 400)) - Double(min(offset, 400)) * 0.5
            best = max(best, value)
        }
        if f.id == q { consider(exact, f.id, at: 0) }
        // "openai/gpt" is a prefix of the id itself.
        else if q.contains("/"), f.id.hasPrefix(q) { consider(prefix, f.id, at: 0) }
        for text in primary where !text.isEmpty {
            if text == q { consider(exact, text, at: 0); continue }
            if text.hasPrefix(q) { consider(prefix, text, at: 0); continue }
            if let start = firstWordStart(of: q, in: text) {
                consider(wordStart, text, at: start)
            } else if let range = text.range(of: q) {
                consider(substring, text, at: text.distance(from: text.startIndex, to: range.lowerBound))
            }
        }
        if best > 0 { return best }
        if f.provider.contains(q) || f.author.contains(q) { consider(provider, f.provider, at: 0) }
        if best > 0 { return best }
        if let range = f.description.range(of: q) {
            consider(description, "", at: f.description.distance(from: f.description.startIndex, to: range.lowerBound))
        }
        return best
    }

    /// Offset of the first occurrence of `q` that starts a word (after a
    /// non-alphanumeric character or at the start).
    private static func firstWordStart(of q: String, in text: String) -> Int? {
        var searchStart = text.startIndex
        while let range = text.range(of: q, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex {
                return 0
            }
            let before = text[text.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber) {
                return text.distance(from: text.startIndex, to: range.lowerBound)
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    /// Orders `models` (already in the user's sort order) by relevance;
    /// the user's order breaks ties.
    static func ranked(_ models: [ModelInfo], query: String, index: ModelSearchIndex) -> [ModelInfo] {
        let scored = models.enumerated().map { offset, model in
            (model, index.fields(for: model).map { score($0, query: query) } ?? 0, offset)
        }
        return scored.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.2 < b.2 }.map(\.0)
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

    var isSearching: Bool { !ModelSearchIndex.terms(searchText).isEmpty }

    func run(_ models: [ModelInfo], index: ModelSearchIndex, isNew: (ModelInfo) -> Bool) -> [ModelInfo] {
        let terms = ModelSearchIndex.terms(searchText)
        let filtersActive = filters.isActive
        let kept = models.filter { m in
            if showFavoritesOnly, !favoriteIds.contains(m.id) { return false }
            // Batch-only variants are hidden unless asked for; a favorited
            // one still shows in Favorites.
            if !filters.listsBatchVariant(m), !(showFavoritesOnly && favoriteIds.contains(m.id)) { return false }
            if showNewThisWeek, !isNew(m) { return false }
            if filtersActive, !filters.matches(m) { return false }
            return index.matches(m, terms: terms)
        }
        var result = ModelSorter.sorted(kept, by: sortField, order: sortOrder)
        if !terms.isEmpty {
            // While searching, match quality decides the order (pinned
            // favorites included); the chosen sort only breaks ties.
            return ModelSearchRanker.ranked(result, query: searchText, index: index)
        }
        if pinFavorites, !favoriteIds.isEmpty {
            // Stable partition: favourites first, chosen order kept inside each half.
            result = result.filter { favoriteIds.contains($0.id) } + result.filter { !favoriteIds.contains($0.id) }
        }
        return result
    }
}
