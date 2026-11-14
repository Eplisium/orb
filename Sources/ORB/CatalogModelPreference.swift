import Foundation

// MARK: - Default model resolution against the live catalog (V-1)
//
// A default model must always be one the catalog actually lists right now.
// Hard-coded IDs go stale (a first-run Chat used to open on `openai/gpt-4o`
// long after newer models shipped), so the curated list names model
// *families* by prefix and the newest catalog member of the family wins.

enum CatalogModelPreference {
    /// What the default is for.
    enum Requirement: Equatable, Sendable {
        /// Text in, text out over chat completions.
        case textChat
        /// `textChat` plus function calling (Agent, Test Suite projects).
        case toolCalling
    }

    /// The catalog facts the resolver needs. Unknown modalities (an empty
    /// list) are treated as permissive, like the rest of the app does.
    struct Candidate: Equatable, Sendable {
        let id: String
        var inputModalities: [String] = []
        var outputModalities: [String] = []
        var supportsTools = false
        /// Catalog `created` (Unix seconds); newer versions of a family win.
        var created: Double?

        init(id: String, inputModalities: [String] = [], outputModalities: [String] = [],
             supportsTools: Bool = false, created: Double? = nil) {
            self.id = id
            self.inputModalities = inputModalities
            self.outputModalities = outputModalities
            self.supportsTools = supportsTools
            self.created = created
        }

        init(_ model: ModelInfo) {
            self.init(id: model.id, inputModalities: model.inputModalities, outputModalities: model.outputModalities,
                      supportsTools: model.supportsTools, created: model.created)
        }

        /// `:batch` variants are served only through the Batches API, not
        /// chat completions.
        var isBatchOnly: Bool { id.hasSuffix(":batch") }

        func satisfies(_ requirement: Requirement) -> Bool {
            guard !isBatchOnly, !id.isEmpty else { return false }
            if !outputModalities.isEmpty, !outputModalities.contains("text") { return false }
            if !inputModalities.isEmpty, !inputModalities.contains("text") { return false }
            if outputModalities.contains("embeddings") { return false }
            switch requirement {
            case .textChat: return true
            case .toolCalling: return supportsTools
            }
        }
    }

    /// A curated model family: IDs starting with `prefix` (and containing
    /// `contains`, when set). Matches skip variants (`:free`, `:batch`, …)
    /// and specialised builds so a family resolves to its everyday model.
    struct Family: Equatable, Sendable {
        let prefix: String
        var contains: String?

        init(_ prefix: String, contains: String? = nil) {
            self.prefix = prefix
            self.contains = contains
        }

        static let specialisedMarkers = [
            "-pro", "-preview", "-exp", "-image", "-audio", "-search", "-deep-research",
            "-codex", "-realtime", "-vision", "-tts", "-transcribe", "-embed", "-legal",
        ]

        func matches(_ id: String) -> Bool {
            guard id.hasPrefix(prefix), !id.contains(":") else { return false }
            if let contains, !id.dropFirst(prefix.count).contains(contains) { return false }
            let rest = id.dropFirst(prefix.count)
            return !Self.specialisedMarkers.contains { rest.contains($0) }
        }
    }

    /// Popular, broadly capable families, best first. Checked against the
    /// public catalog (GET /api/v1/models, 2026-11): every family has a
    /// tool-capable, text-in/text-out member.
    static let curatedFamilies: [Family] = [
        Family("anthropic/claude-sonnet-"),
        Family("openai/gpt-5"),
        Family("google/gemini-", contains: "-flash"),
        Family("anthropic/claude-haiku-"),
        Family("x-ai/grok-"),
        Family("deepseek/deepseek-"),
        Family("qwen/qwen3"),
        Family("moonshotai/kimi-"),
        Family("z-ai/glm-"),
        Family("mistralai/mistral-medium-"),
    ]

    /// The best default that exists in `catalog` and meets `requirement`:
    /// pinned > most recent > newest member of the first curated family
    /// present > first eligible model in catalog order. Nil only when no
    /// catalog model qualifies (e.g. the catalog has not loaded).
    static func resolve(
        catalog: [Candidate],
        pinned: String? = nil,
        recents: [String] = [],
        requirement: Requirement,
        families: [Family] = curatedFamilies
    ) -> String? {
        let eligible = catalog.filter { $0.satisfies(requirement) }
        guard !eligible.isEmpty else { return nil }
        let eligibleIDs = Set(eligible.map(\.id))
        if let pinned, eligibleIDs.contains(pinned) { return pinned }
        if let recent = recents.first(where: eligibleIDs.contains) { return recent }
        for family in families {
            let members = eligible.filter { family.matches($0.id) }
            if let newest = members.max(by: isOlder) { return newest.id }
        }
        return eligible.first?.id
    }

    /// Ordering inside a family: `created`, then a numeric-aware ID compare
    /// (`claude-sonnet-5.5` after `claude-sonnet-5`) so undated entries still
    /// prefer the higher version.
    private static func isOlder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let l = lhs.created ?? 0, r = rhs.created ?? 0
        if l != r { return l < r }
        return lhs.id.compare(rhs.id, options: .numeric) == .orderedAscending
    }

    static func resolve(
        models: [ModelInfo], pinned: String? = nil, recents: [String] = [], requirement: Requirement
    ) -> String? {
        resolve(catalog: models.map(Candidate.init), pinned: pinned, recents: recents, requirement: requirement)
    }
}
