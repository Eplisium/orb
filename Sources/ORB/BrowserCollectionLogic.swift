import Foundation

// MARK: - Browser collection consistency
//
// Pure helpers that keep the sidebar counts, the list header and the detail
// pane telling the same story. Everything derives from ONE resolved
// collection (stored IDs matched against the loaded catalog), so a count can
// never silently contradict the list it labels.

/// Stored favorites split into those the current catalog can show and those
/// it no longer contains (retired or renamed models). Unavailable IDs are
/// reported, never deleted.
struct FavoriteSummary: Equatable {
    let available: Int
    let unavailableIDs: [String]

    var unavailable: Int { unavailableIDs.count }
    var stored: Int { available + unavailable }

    /// Before the catalog loads nothing can be resolved; report everything as
    /// available so the badge does not flash to zero during launch.
    static func make(favoriteIds: Set<String>, catalogIds: Set<String>) -> FavoriteSummary {
        guard !catalogIds.isEmpty else {
            return FavoriteSummary(available: favoriteIds.count, unavailableIDs: [])
        }
        let missing = favoriteIds.subtracting(catalogIds).sorted()
        return FavoriteSummary(available: favoriteIds.count - missing.count, unavailableIDs: missing)
    }

    /// Short note for the list header, nil when every favorite resolves.
    var unavailableNote: String? {
        guard unavailable > 0 else { return nil }
        return "\(unavailable) unavailable"
    }

    /// Tooltip / accessibility explanation for the unavailable note.
    var unavailableHelp: String? {
        guard unavailable > 0 else { return nil }
        let noun = unavailable == 1 ? "favorite isn't" : "favorites aren't"
        let list = unavailableIDs.prefix(8).joined(separator: ", ")
        let more = unavailable > 8 ? " and \(unavailable - 8) more" : ""
        return "\(unavailable) \(noun) in the current OpenRouter catalog (retired or renamed): \(list)\(more). They are kept, not deleted, and reappear if the model returns."
    }
}

/// The text of the list header ("12 models", "3 of 12 favorites").
enum BrowserListHeader {
    static func text(shown: Int, showFavoritesOnly: Bool, favorites: FavoriteSummary, refined: Bool) -> String {
        guard showFavoritesOnly else { return "\(shown) model\(shown == 1 ? "" : "s")" }
        if refined, shown != favorites.available {
            return "\(shown) of \(favorites.available) favorites"
        }
        return "\(shown) favorite\(shown == 1 ? "" : "s")"
    }
}

/// What the detail pane should do after the visible collection changes.
enum SelectionReconciliation: Equatable {
    /// The selection is still in the list (or nothing is selected and the
    /// list is empty): leave it alone.
    case keep
    /// Select this visible model instead.
    case select(String)
    /// Clear the detail pane.
    case clear

    /// Switching sidebar collections (All / Favorites / New This Week) never
    /// leaves a model from another collection in detail: an empty selection
    /// or a visible one is kept; a hidden one moves to the first visible row,
    /// or clears when the new collection is empty.
    static func forCollectionChange(selectedID: String?, visibleIDs: [String]) -> SelectionReconciliation {
        guard let selectedID else { return .keep }
        if visibleIDs.contains(selectedID) { return .keep }
        if let first = visibleIDs.first { return .select(first) }
        return .clear
    }
}

// MARK: - Accessibility labels

/// Spoken identity for a model-list row: which model, from which provider,
/// and its favorite/compare state, instead of an unlabeled row.
enum ModelRowAccessibility {
    static func label(_ model: ModelInfo, isFavorite: Bool, isComparing: Bool) -> String {
        let provider = model.provider.trimmingCharacters(in: CharacterSet(charactersIn: "~"))
        var parts = [model.name.isEmpty ? model.id : model.name]
        if !provider.isEmpty { parts.append("by \(provider)") }
        if isFavorite { parts.append("favorite") }
        if isComparing { parts.append("in compare") }
        if model.hasExpired { parts.append("expired") }
        return parts.joined(separator: ", ")
    }

    static func value(_ facts: ModelRowFacts) -> String {
        var parts = ["\(facts.context) context", facts.price]
        if !facts.capabilities.isEmpty {
            parts.append(facts.capabilities.map(\.name).joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

/// Spoken identity for a sidebar destination; the count badge becomes a value.
enum SidebarAccessibility {
    static func value(count: Int, section: SidebarSection) -> String {
        guard count > 0 else { return "" }
        switch section {
        case .favorites: return "\(count) favorite\(count == 1 ? "" : "s")"
        case .newThisWeek: return "\(count) new model\(count == 1 ? "" : "s")"
        default: return "\(count) model\(count == 1 ? "" : "s")"
        }
    }
}
