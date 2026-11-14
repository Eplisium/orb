import Foundation

/// Rewrites a rough image/video prompt into a richer one using a text model.
/// It no longer needs a model pinned in Agent: see `PromptEnhancer.resolveModel`.
/// Streams through the shared OpenRouter client.
enum PromptEnhancerError: LocalizedError {
    case noAPIKey, empty
    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Add an API key in Settings first."
        case .empty: return "The model returned an empty prompt."
        }
    }
}

enum PromptEnhancer {
    static let systemPrompt = """
    You improve prompts for AI image generation models. Rewrite the user's prompt to be vivid and specific: \
    subject, setting, composition, lighting, style, colour palette, mood, and lens or medium where it helps. \
    Preserve the user's intent and every explicit detail; do not add unrelated subjects or text overlays.

    Named characters: image models often refuse or mangle prompts that name a specific fictional character, \
    franchise, or celebrity. If the prompt names one (for example a film, game, comic, or cartoon character), \
    do not use the name or franchise. Instead describe them so the result is instantly recognisable from \
    appearance alone: build and silhouette, costume and armour, signature colours, materials, distinctive \
    props, and iconic pose or expression. Use "a character inspired by …" style wording only if the name \
    cannot be avoided. Keep the rest of the scene (action, food, location) exactly as requested. \
    For example, "Darth Vader eating cereal" becomes a tall imposing figure in glossy black armour with a \
    flared domed helmet, angular black mask, and flowing black cape, sitting at a kitchen table eating a \
    bowl of cereal, cinematic lighting.

    Reply with ONLY the improved prompt as plain text — no preamble, quotes, labels, or Markdown.
    """

    /// Known fast, inexpensive text models, in order of preference.
    static let preferredFastModels = [
        "google/gemini-2.5-flash-lite",
        "openai/gpt-4.1-nano",
        "google/gemini-2.0-flash-lite-001",
        "openai/gpt-4o-mini",
        "meta-llama/llama-3.1-8b-instruct",
    ]

    /// Used when nothing is pinned and the catalog is not loaded.
    static let fallbackModel = preferredFastModels[0]

    /// The model to enhance with: the Agent's pinned model, else the Chat
    /// default, else a fast inexpensive text model from the live catalog
    /// (a known one when present, otherwise the cheapest paid text-only
    /// chat model), else `fallbackModel`. A pinned id missing from a loaded
    /// catalog is skipped. Never empty, so Enhance is never disabled for
    /// lack of a model.
    static func resolveModel(pinnedAgent: String, chatDefault: String, catalog: [ModelInfo] = []) -> String {
        let ids = Set(catalog.map(\.id))
        for candidate in [pinnedAgent, chatDefault].map({ $0.trimmingCharacters(in: .whitespaces) })
            where !candidate.isEmpty && (ids.isEmpty || ids.contains(candidate)) {
            return candidate
        }
        guard !catalog.isEmpty else { return fallbackModel }
        if let known = preferredFastModels.first(where: ids.contains) { return known }
        var best: (id: String, price: Double)?
        for model in catalog where isPlainTextChatModel(model) {
            guard let price = model.completionCostPer1M else { continue }
            if let current = best, current.price < price || (current.price == price && current.id <= model.id) { continue }
            best = (model.id, price)
        }
        return best?.id ?? fallbackModel
    }

    /// Text in, text out, paid (free tiers are rate-limited), and not an
    /// embedding, moderation, or search-only model.
    static func isPlainTextChatModel(_ model: ModelInfo) -> Bool {
        if model.isFree { return false }
        let inputs: [String] = model.inputModalities
        let outputs: [String] = model.outputModalities
        let textIn: Bool = inputs.isEmpty || inputs.contains("text")
        let textOut: Bool = outputs.isEmpty ? model.modalityLabel == "text->text" : outputs == ["text"]
        guard textIn, textOut else { return false }
        let id: String = model.id.lowercased()
        let excluded: [String] = ["embed", "guard", "moderation", "rerank", ":online", "search", "deep-research", "router", "auto"]
        return !excluded.contains { id.contains($0) }
    }

    /// Short label for the Enhance row: which model will be used and why.
    static func modelLabel(pinnedAgent: String, chatDefault: String, resolved: String) -> String {
        let name = resolved.split(separator: "/").last.map(String.init) ?? resolved
        if resolved == pinnedAgent { return name }
        if resolved == chatDefault { return "\(name) (Chat default)" }
        return "\(name) (fast default)"
    }

    /// Enhances with the model `resolveModel` picks from the saved defaults.
    static func enhance(_ prompt: String, catalog: [ModelInfo] = [], defaults: UserDefaults = .standard,
                        client: any OpenRouterClientProtocol = OpenRouterClient()) async throws -> String {
        let model = resolveModel(
            pinnedAgent: defaults.string(forKey: PlaygroundModelDefaults.agentKey) ?? "",
            chatDefault: defaults.string(forKey: PlaygroundModelDefaults.chatKey) ?? "",
            catalog: catalog
        )
        return try await enhance(prompt, modelId: model, client: client)
    }

    static func enhance(_ prompt: String, modelId: String,
                        client: any OpenRouterClientProtocol = OpenRouterClient()) async throws -> String {
        guard let key = KeychainManager.getAPIKey(), !key.isEmpty else { throw PromptEnhancerError.noAPIKey }
        let request = OpenRouterRequest(
            apiKey: key, model: modelId,
            messages: [AgentAPIMessage(role: "system", content: systemPrompt),
                       AgentAPIMessage(role: "user", content: prompt)],
            temperature: 0.8, maxTokens: 800)
        var text = ""
        var usage: ChatUsage?
        for try await event in try await client.stream(request) {
            switch event {
            case .contentDelta(_, let delta): text += delta
            case .usage(let value): usage = value
            case .apiError(let error): throw error
            default: break
            }
        }
        await UsageLedger.shared.record(.promptEnhance, model: modelId, usage: usage)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !cleaned.isEmpty else { throw PromptEnhancerError.empty }
        return cleaned
    }
}
