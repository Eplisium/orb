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
    /// Plain-text content. Mutually exclusive with `parts` on the wire: when
    /// attachments are present the message encodes as a content-part array.
    let content: String?
    /// Multimodal content parts. Encodes as `content: [...]` when non-nil.
    let parts: [MessageContentPart]?
    let toolCalls: [AgentToolCall]?
    let toolCallId: String?
    let name: String?
    /// Generated images attached to an assistant message (`images: [...]`).
    let images: [AssistantImagePart]?
    /// Structured reasoning blocks the API returned for this assistant
    /// message. OpenRouter requires the consecutive sequence to be passed
    /// back unmodified on the following tool turn, so this is encoded to the
    /// wire verbatim (F07).
    let reasoningDetails: [ReasoningDetail]?

    init(
        role: String,
        content: String? = nil,
        parts: [MessageContentPart]? = nil,
        toolCalls: [AgentToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        images: [AssistantImagePart]? = nil,
        reasoningDetails: [ReasoningDetail]? = nil
    ) {
        self.role = role
        self.content = content
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
        self.images = images
        self.reasoningDetails = reasoningDetails
    }

    /// Convenience for a multimodal user turn: text plus attachment parts.
    /// A nil/empty text produces a parts-only message with no empty text part.
    static func multimodal(role: String = "user", text: String?, parts: [MessageContentPart]) -> AgentAPIMessage {
        var all: [MessageContentPart] = []
        if let text, !text.isEmpty { all.append(.textPart(text)) }
        all += parts
        return .init(role: role, parts: all)
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name, images
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case reasoningDetails = "reasoning_details"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        // `content` is polymorphic: a string, a part array, or null.
        // Try the string form first; the part array only when that fails.
        if let text = try? container.decode(String.self, forKey: .content) {
            content = text
            parts = nil
        } else if let decoded = try? container.decode([MessageContentPart].self, forKey: .content) {
            parts = decoded
            content = nil
        } else if (try? container.decodeNil(forKey: .content)) == true {
            content = nil
            parts = nil
        } else {
            content = try container.decodeIfPresent(String.self, forKey: .content)
            parts = nil
        }
        toolCalls = try container.decodeIfPresent([AgentToolCall].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        images = try container.decodeIfPresent([AssistantImagePart].self, forKey: .images)
        reasoningDetails = try container.decodeIfPresent([ReasoningDetail].self, forKey: .reasoningDetails)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let parts {
            try container.encode(parts, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(images, forKey: .images)
        // Omitted when absent so messages without reasoning details keep the
        // exact wire shape they always had.
        try container.encodeIfPresent(reasoningDetails, forKey: .reasoningDetails)
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
    let parameters: AgentToolSchema
}

/// A tool's parameter schema. Native ORB tools use the flat `.native` form;
/// MCP-provided tools carry arbitrary JSON Schema through `.raw` so nested
/// objects, arrays, and enums survive the trip to OpenRouter intact.
enum AgentToolSchema: Codable, Sendable {
    case native(AgentToolParameters)
    case raw(JSONValue)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let native = try? container.decode(AgentToolParameters.self) {
            self = .native(native)
        } else {
            self = .raw(try container.decode(JSONValue.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .native(let value): try container.encode(value)
        case .raw(let value): try container.encode(value)
        }
    }
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

struct NativeAgentToolResult: Sendable, Equatable {
    let content: String
    let isError: Bool
}

struct AssembledAgentToolCall: Sendable, Equatable {
    let index: Int
    let id: String
    let type: String
    let name: String
    let arguments: String
}

enum NativeAgentEvent: Sendable, Equatable {
    case modelTurnStarted(Int)
    case textDelta(String)
    case reasoningDelta(String)
    /// Structured reasoning blocks streamed for the current turn, forwarded
    /// so the UI/persistence layer can store the same wire state the agent
    /// keeps in its history (pitfall 28: both streaming paths stay in sync).
    case reasoningDetails([ReasoningDetail])
    case toolCallUpdated(AssembledAgentToolCall)
    case toolExecutionStarted(AssembledAgentToolCall)
    case toolResult(AssembledAgentToolCall, NativeAgentToolResult)
    case usage(turn: Int, cumulative: ChatUsage)
    case turnFinished(reason: String?)
    /// The turn budget is spent; the agent is composing a final tool-free answer.
    case finalizing
    case runCompleted
}

struct NativeAgentRunResult: Sendable {
    let response: String
    let history: [AgentAPIMessage]
    let usage: ChatUsage?
    let toolNames: [String]
    /// Tool call display summaries for UI rendering.
    let toolCallDisplays: [ToolCallDisplay]
    /// Tool result messages for insertion into the conversation.
    let toolMessages: [ChatMessage]
    /// True when the run exhausted its turn budget and was force-summarized,
    /// so the UI can say the answer may be incomplete.
    let hitToolBudget: Bool

    init(
        response: String,
        history: [AgentAPIMessage],
        usage: ChatUsage?,
        toolNames: [String],
        toolCallDisplays: [ToolCallDisplay],
        toolMessages: [ChatMessage],
        hitToolBudget: Bool = false
    ) {
        self.response = response
        self.history = history
        self.usage = usage
        self.toolNames = toolNames
        self.toolCallDisplays = toolCallDisplays
        self.toolMessages = toolMessages
        self.hitToolBudget = hitToolBudget
    }
}

enum NativeAgentError: LocalizedError {
    case invalidResponse
    case api(String)
    case exhausted
    case invalidToolCall(String)
    case truncatedToolCall
    case duplicateToolCallID(String)
    case reasoningOnly

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenRouter returned an invalid agent response."
        case .api(let message):
            return message
        case .exhausted:
            return "The agent reached its tool-call limit before completing the task."
        case .invalidToolCall(let message):
            return "Invalid streamed tool call: \(message)"
        case .truncatedToolCall:
            return "The model's tool call was truncated before completion and was not executed."
        case .duplicateToolCallID(let id):
            return "OpenRouter returned duplicate tool-call ID \(id)."
        case .reasoningOnly:
            return "The model returned only reasoning and never produced a final answer."
        }
    }
}
