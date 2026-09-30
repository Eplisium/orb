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
    Preserve the user's intent and every explicit detail; do not add unrelated subjects or text overlays. \
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
        for try await event in try await client.stream(request) {
            switch event {
            case .contentDelta(_, let delta): text += delta
            case .apiError(let error): throw error
            default: break
            }
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !cleaned.isEmpty else { throw PromptEnhancerError.empty }
        return cleaned
    }
}
