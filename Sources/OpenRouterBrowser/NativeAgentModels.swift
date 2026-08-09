import Foundation

// MARK: - Favorite-aware model catalog

struct AgentModelSection: Identifiable {
    let title: String
    let models: [ModelInfo]

    var id: String { title }
}

enum AgentModelCatalog {
    static func sections(
        models: [ModelInfo],
        favoriteIds: Set<String>,
        searchText: String,
        toolCapableOnly: Bool
    ) -> [AgentModelSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = models.filter { model in
            let supportsRequestedMode = !toolCapableOnly || model.supportsTools
            let matchesSearch = query.isEmpty
                || model.name.lowercased().contains(query)
                || model.id.lowercased().contains(query)
                || model.provider.lowercased().contains(query)
            return supportsRequestedMode && matchesSearch
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let favorites = filtered.filter { favoriteIds.contains($0.id) }
        let remaining = filtered.filter { !favoriteIds.contains($0.id) }
        var sections: [AgentModelSection] = []
        if !favorites.isEmpty {
            sections.append(AgentModelSection(title: "Favorites", models: favorites))
        }
        if !remaining.isEmpty {
            sections.append(AgentModelSection(
                title: toolCapableOnly ? "Tool-capable models" : "All models",
                models: remaining
            ))
        }
        return sections
    }
}

// MARK: - OpenRouter function-calling wire models

struct AgentCompletionRequest: Encodable {
    let model: String
    let messages: [AgentAPIMessage]
    let tools: [AgentToolDefinition]?
    let toolChoice: String?
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature
        case toolChoice = "tool_choice"
    }
}

struct AgentCompletionResponse: Decodable {
    let choices: [AgentChoice]
    let usage: ChatUsage?
    let error: ChatAPIError?

    private enum CodingKeys: String, CodingKey {
        case choices, usage, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decodeIfPresent([AgentChoice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(ChatUsage.self, forKey: .usage)
        error = try container.decodeIfPresent(ChatAPIError.self, forKey: .error)
    }
}

struct AgentChoice: Decodable {
    let message: AgentAPIMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

struct AgentAPIMessage: Codable, Sendable {
    let role: String
    let content: String?
    let toolCalls: [AgentToolCall]?
    let toolCallId: String?
    let name: String?

    init(
        role: String,
        content: String? = nil,
        toolCalls: [AgentToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

struct AgentToolCall: Codable, Sendable {
    let id: String
    let type: String
    let function: AgentFunctionCall
}

struct AgentFunctionCall: Codable, Sendable {
    let name: String
    let arguments: String
}

struct AgentToolDefinition: Codable, Sendable {
    let type: String
    let function: AgentToolFunctionDefinition

    init(function: AgentToolFunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

struct AgentToolFunctionDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: AgentToolParameters
}

struct AgentToolParameters: Codable, Sendable {
    let type: String
    let properties: [String: AgentToolProperty]
    let required: [String]

    init(properties: [String: AgentToolProperty], required: [String] = []) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct AgentToolProperty: Codable, Sendable {
    let type: String
    let description: String
}

struct NativeAgentToolResult: Sendable {
    let content: String
    let isError: Bool
}

struct NativeAgentRunResult: Sendable {
    let response: String
    let history: [AgentAPIMessage]
    let usage: ChatUsage?
    let toolNames: [String]
}

enum NativeAgentError: LocalizedError {
    case invalidResponse
    case api(String)
    case exhausted

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenRouter returned an invalid agent response."
        case .api(let message):
            return message
        case .exhausted:
            return "The agent reached its tool-call limit before completing the task."
        }
    }
}
