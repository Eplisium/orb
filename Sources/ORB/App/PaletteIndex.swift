import Foundation

// MARK: - Fuzzy matching and palette index (Phase 2). Pure and testable.

enum FuzzyMatcher {
    /// Higher is better; nil means no match. Empty query matches with 0.
    /// Tiers: exact > prefix > word-start substring > substring > subsequence.
    static func score(query: String, in text: String) -> Double? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        if q.isEmpty { return 0 }
        guard q.count <= t.count else { return nil }
        let lengthPenalty = Double(t.count) * 0.1

        if q == t { return 1000 }
        if Array(t.prefix(q.count)) == q { return 800 - lengthPenalty }

        if let start = firstSubstring(q, in: t) {
            return (isWordStart(t, start) ? 600 : 400) - Double(start) * 0.5 - lengthPenalty
        }

        // Subsequence with word-start / adjacency bonuses.
        var ti = 0
        var score = 100.0
        var previous = -2
        var first = -1
        for ch in q {
            while ti < t.count, t[ti] != ch { ti += 1 }
            guard ti < t.count else { return nil }
            if first < 0 { first = ti }
            if isWordStart(t, ti) { score += 15 }
            if ti == previous + 1 { score += 8 }
            previous = ti
            ti += 1
        }
        let span = previous - first + 1
        score -= Double(span - q.count) * 0.5
        return score - lengthPenalty
    }

    private static func firstSubstring(_ q: [Character], in t: [Character]) -> Int? {
        guard q.count <= t.count else { return nil }
        for start in 0...(t.count - q.count) where Array(t[start..<(start + q.count)]) == q {
            return start
        }
        return nil
    }

    private static func isWordStart(_ t: [Character], _ i: Int) -> Bool {
        i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber)
    }
}

enum PaletteGroup: String, CaseIterable, Identifiable {
    case sections = "Sections"
    case actions = "Actions"
    case models = "Favourite models"
    case conversations = "Recent conversations"
    var id: String { rawValue }
}

struct PaletteModel: Equatable {
    let id: String
    let name: String
}

struct PaletteConversation: Equatable {
    let id: UUID
    let title: String
    let mode: PlaygroundMode
    let createdAt: Date
}

struct PaletteItem: Identifiable, Equatable {
    let id: String
    let group: PaletteGroup
    let title: String
    let subtitle: String?
    let symbol: String
    let shortcut: String?
    let action: ShellAction
}

struct PaletteGroupResult: Equatable {
    let group: PaletteGroup
    let items: [PaletteItem]
}

struct PaletteIndex {
    static let emptyQueryLimit = 5
    static let queryLimit = 8

    var favoriteModels: [PaletteModel]
    var conversations: [PaletteConversation]

    static let actionItems: [PaletteItem] = [
        PaletteItem(id: "act.newChat", group: .actions, title: "New Chat", subtitle: nil,
                    symbol: "square.and.pencil", shortcut: "⌘N", action: .newChat),
        PaletteItem(id: "act.newAgent", group: .actions, title: "New Agent Session", subtitle: nil,
                    symbol: "wand.and.stars", shortcut: "⇧⌘N", action: .newAgent),
        PaletteItem(id: "act.refresh", group: .actions, title: "Refresh Models", subtitle: nil,
                    symbol: "arrow.clockwise", shortcut: "⌘R", action: .refreshModels),
        PaletteItem(id: "act.sidebar", group: .actions, title: "Toggle Sidebar", subtitle: nil,
                    symbol: "sidebar.leading", shortcut: nil, action: .toggleSidebar),
        PaletteItem(id: "act.settings", group: .actions, title: "Open Settings", subtitle: nil,
                    symbol: "gearshape", shortcut: "⌘,", action: .openSettings),
        PaletteItem(id: "act.shortcuts", group: .actions, title: "Keyboard Shortcuts", subtitle: nil,
                    symbol: "keyboard", shortcut: "⌘/", action: .showShortcuts),
    ]

    static var sectionItems: [PaletteItem] {
        ShellShortcuts.sidebarOrder.map { section in
            PaletteItem(
                id: "sec.\(section.rawValue)", group: .sections, title: section.title, subtitle: nil,
                symbol: section.icon,
                shortcut: ShellShortcuts.shortcutDisplay(for: section),
                action: .section(section)
            )
        }
    }

    func results(query rawQuery: String) -> [PaletteGroupResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = query.isEmpty ? Self.emptyQueryLimit : Self.queryLimit

        let models = favoriteModels.map { model in
            PaletteItem(id: "model.\(model.id)", group: .models, title: model.name, subtitle: model.id,
                        symbol: "star.fill", shortcut: nil, action: .selectModel(model.id))
        }
        let recent = conversations.sorted { $0.createdAt > $1.createdAt }.map { c in
            PaletteItem(id: "conv.\(c.id.uuidString)", group: .conversations, title: c.title,
                        subtitle: c.mode.rawValue,
                        symbol: c.mode == .chat ? "bubble.left" : "wand.and.stars",
                        shortcut: nil, action: .openConversation(c.id, c.mode))
        }

        let candidates: [(PaletteGroup, [PaletteItem], Int?)] = [
            (.sections, Self.sectionItems, nil),
            (.actions, Self.actionItems, nil),
            (.models, models, limit),
            (.conversations, recent, limit),
        ]
        return candidates.compactMap { group, items, cap in
            var ranked: [PaletteItem]
            if query.isEmpty {
                ranked = items
            } else {
                ranked = items.enumerated().compactMap { offset, item -> (Double, Int, PaletteItem)? in
                    let titleScore = FuzzyMatcher.score(query: query, in: item.title)
                    let subScore = item.subtitle.flatMap { FuzzyMatcher.score(query: query, in: $0) }.map { $0 * 0.9 }
                    guard let best = [titleScore, subScore].compactMap({ $0 }).max() else { return nil }
                    return (best, offset, item)
                }
                .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
                .map(\.2)
            }
            if let cap { ranked = Array(ranked.prefix(cap)) }
            return ranked.isEmpty ? nil : PaletteGroupResult(group: group, items: ranked)
        }
    }

    static func flatten(_ groups: [PaletteGroupResult]) -> [PaletteItem] {
        groups.flatMap(\.items)
    }
}
