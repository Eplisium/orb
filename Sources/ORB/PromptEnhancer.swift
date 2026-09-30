import Foundation

/// Rewrites a rough image/video prompt into a richer one using a text model
/// (the model pinned in Agent). Streams through the shared OpenRouter client.
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
