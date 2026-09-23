import Foundation

// W10 adapter for OpenRouter's Anthropic-compatible Messages API
// (`POST /api/v1/messages`).
//
// Contract (verified 2026-09-16 against the live docs):
// - https://openrouter.ai/openapi.json — `MessagesRequest` (required:
//   `model`, `messages`), `MessagesResult`, and `MessagesStreamEvents`
//   (message_start / content_block_start / content_block_delta /
//   content_block_stop / message_delta / message_stop / ping / error).
// - https://openrouter.ai/docs/api/api-reference/anthropic-messages/create-a-message.md
//   — endpoint, request example, typed 4xx error envelopes
//   (`{"type":"error","error":{"type":…,"message":…}}`), `[DONE]` sentinel.

// MARK: - Request models

enum MessagesRole: String, Sendable, Equatable {
    case user, assistant
}

enum MessagesContent: Sendable, Equatable {
    case text(String)
    case blocks([MessagesContentBlock])
}

/// Anthropic-compatible content block. Unknown block types are preserved
/// verbatim (dynamic-key pattern, like `ReasoningDetail`) so provider
/// extensions survive an encode/decode round trip.
enum MessagesContentBlock: Sendable, Equatable {
    case text(text: String, citations: [JSONValue]?)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: JSONValue?, isError: Bool?)
    case thinking(thinking: String, signature: String?)
    case redactedThinking(data: String?)
    case unknown(JSONValue)
}

/// Codec shared by the request encoder and the response/stream decoders.
enum MessagesContentBlockCodec {
    static func encode(_ block: MessagesContentBlock) -> JSONValue {
        switch block {
        case .text(let text, let citations):
            var object: [String: JSONValue] = ["type": .string("text"), "text": .string(text)]
            if let citations { object["citations"] = .array(citations) }
            return .object(object)
        case .toolUse(let id, let name, let input):
            return .object([
                "type": .string("tool_use"),
                "id": .string(id),
                "name": .string(name),
                "input": input,
            ])
        case .toolResult(let toolUseID, let content, let isError):
            var object: [String: JSONValue] = [
                "type": .string("tool_result"),
                "tool_use_id": .string(toolUseID),
            ]
            if let content { object["content"] = content }
            if let isError { object["is_error"] = .bool(isError) }
            return .object(object)
        case .thinking(let thinking, let signature):
            var object: [String: JSONValue] = [
                "type": .string("thinking"),
                "thinking": .string(thinking),
            ]
            if let signature { object["signature"] = .string(signature) }
            return .object(object)
        case .redactedThinking(let data):
            var object: [String: JSONValue] = ["type": .string("redacted_thinking")]
            if let data { object["data"] = .string(data) }
            return .object(object)
        case .unknown(let value):
            return value
        }
    }

    static func decode(_ value: JSONValue?) -> MessagesContentBlock {
        guard let object = value?.objectValue else { return .unknown(value ?? .null) }
        switch object["type"]?.stringValue {
        case "text":
            return .text(text: object["text"]?.stringValue ?? "", citations: object["citations"]?.arrayValue)
        case "tool_use":
            return .toolUse(
                id: object["id"]?.stringValue ?? "",
                name: object["name"]?.stringValue ?? "",
                input: object["input"] ?? .null
            )
        case "tool_result":
            return .toolResult(
                toolUseID: object["tool_use_id"]?.stringValue ?? "",
                content: object["content"],
                isError: object["is_error"]?.boolValue
            )
        case "thinking":
            return .thinking(
                thinking: object["thinking"]?.stringValue ?? "",
                signature: object["signature"]?.stringValue
            )
        case "redacted_thinking":
            return .redactedThinking(data: object["data"]?.stringValue)
        default:
            return .unknown(value ?? .null)
        }
    }
}

struct MessagesAPIMessage: Sendable, Equatable {
    var role: MessagesRole
    var content: MessagesContent

    init(role: MessagesRole, content: MessagesContent) {
        self.role = role
        self.content = content
    }
}

/// Typed Anthropic-compatible Messages request. Per the documented schema
/// only `model` and `messages` are required; `max_tokens` stays optional and
/// is never defaulted — omitted means the documented provider behavior, not
/// an ORB-invented default.
struct MessagesAPIRequest: Sendable, Equatable {
    var model: String
    var messages: [MessagesAPIMessage]
    var maxTokens: Int?
    var system: MessagesContent?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var stopSequences: [String]?

    init(
        model: String,
        messages: [MessagesAPIMessage],
        maxTokens: Int? = nil,
        system: MessagesContent? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        stopSequences: [String]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.system = system
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.stopSequences = stopSequences
    }
}

/// Manual encoder: unset optionals are omitted entirely.
enum MessagesRequestEncoder {
    static func encodeBody(_ request: MessagesAPIRequest, stream: Bool? = nil) throws -> Data {
        try JSONEncoder().encode(Body(request: request, stream: stream))
    }

    private struct Body: Encodable {
        let request: MessagesAPIRequest
        let stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model, messages, system, temperature, stream
            case maxTokens = "max_tokens"
            case topP = "top_p"
            case topK = "top_k"
            case stopSequences = "stop_sequences"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(request.model, forKey: .model)
            try container.encodeIfPresent(request.maxTokens, forKey: .maxTokens)
            if let system = request.system {
                try container.encode(Content(value: system), forKey: .system)
            }
            try container.encode(request.messages.map(MessageParam.init), forKey: .messages)
            try container.encodeIfPresent(request.temperature, forKey: .temperature)
            try container.encodeIfPresent(request.topP, forKey: .topP)
            try container.encodeIfPresent(request.topK, forKey: .topK)
            try container.encodeIfPresent(request.stopSequences, forKey: .stopSequences)
            try container.encodeIfPresent(stream, forKey: .stream)
        }
    }

    private struct Content: Encodable {
        let value: MessagesContent?

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch value {
            case .text(let text):
                try container.encode(text)
            case .blocks(let blocks):
                try container.encode(blocks.map(MessagesContentBlockCodec.encode))
            case nil:
                try container.encodeNil()
            }
        }
    }

    private struct MessageParam: Encodable {
        let message: MessagesAPIMessage

        enum CodingKeys: String, CodingKey { case role, content }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message.role.rawValue, forKey: .role)
            switch message.content {
            case .text(let text):
                try container.encode(text, forKey: .content)
            case .blocks(let blocks):
                try container.encode(blocks.map(MessagesContentBlockCodec.encode), forKey: .content)
            }
        }
    }
}

// MARK: - Response model

/// Non-streaming response (`MessagesResult`). Fields ORB does not model are
/// tolerated (unknown keys are ignored by the decoder).
struct MessagesAPIResponse: Decodable, Equatable, Sendable {
    let id: String?
    let type: String?
    let role: String?
    let model: String?
    let content: [MessagesContentBlock]?
    let stopReason: String?
    let stopSequence: String?
    let usage: MessagesUsage?

    enum CodingKeys: String, CodingKey {
        case id, type, role, model, content, usage
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        if let rawContent = try? container.decodeIfPresent([JSONValue].self, forKey: .content) {
            content = rawContent.map(MessagesContentBlockCodec.decode)
        } else {
            content = nil
        }
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        stopSequence = try container.decodeIfPresent(String.self, forKey: .stopSequence)
        usage = try container.decodeIfPresent(MessagesUsage.self, forKey: .usage)
    }

    var text: String {
        (content ?? []).compactMap { block in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined()
    }
}

struct MessagesUsage: Decodable, Equatable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

// MARK: - Stream events

/// One `content_block_delta` payload, typed by its `delta.type`.
enum MessagesContentDelta: Equatable, Sendable {
    case text(String)
    case inputJSON(String)
    case thinking(String)
    case signature(String)
    case citations(JSONValue?)
    case compaction(JSONValue)
    case unknown(String)
}

/// Typed Messages stream events. Unknown event types are tolerated as
/// `.unknown` and never crash the stream.
enum MessagesStreamEvent: Equatable, Sendable {
    case messageStart(MessagesAPIResponse?)
    case contentBlockStart(index: Int, block: MessagesContentBlock)
    case contentBlockDelta(index: Int, delta: MessagesContentDelta)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, stopSequence: String?, usage: MessagesUsage?)
    case messageStop(metadata: JSONValue?)
    case ping
    case streamError(type: String?, errorType: String?, message: String?)
    case unknown(type: String)
    case done
}

enum MessagesStreamDecoder {
    static func decode(_ payload: Data) throws -> [MessagesStreamEvent] {
        if payload == Data("[DONE]".utf8) { return [.done] }
        let diagnostic = String(decoding: payload.prefix(512), as: UTF8.self)
        guard let value = JSONValue.parse(String(decoding: payload, as: UTF8.self)),
              let object = value.objectValue
        else {
            throw AdapterStreamError.malformedEvent(diagnostic)
        }
        guard let type = object["type"]?.stringValue else {
            throw AdapterStreamError.malformedEvent(diagnostic)
        }
        let index = intValue(object["index"])

        switch type {
        case "message_start":
            return [.messageStart(object["message"]?.decode(as: MessagesAPIResponse.self))]
        case "content_block_start":
            return [.contentBlockStart(index: index ?? 0, block: MessagesContentBlockCodec.decode(object["content_block"]))]
        case "content_block_delta":
            return [.contentBlockDelta(index: index ?? 0, delta: decodeDelta(object["delta"]))]
        case "content_block_stop":
            return [.contentBlockStop(index: index ?? 0)]
        case "message_delta":
            let delta = object["delta"]?.objectValue
            return [.messageDelta(
                stopReason: delta?["stop_reason"]?.stringValue,
                stopSequence: delta?["stop_sequence"]?.stringValue,
                usage: object["usage"]?.decode(as: MessagesUsage.self)
            )]
        case "message_stop":
            return [.messageStop(metadata: object["openrouter_metadata"])]
        case "ping":
            return [.ping]
        case "error":
            let error = object["error"]?.objectValue
            return [.streamError(
                type: error?["type"]?.stringValue,
                errorType: error?["error_type"]?.stringValue,
                message: error?["message"]?.stringValue
            )]
        default:
            // Unknown forward-compatible events must not crash streaming.
            return [.unknown(type: type)]
        }
    }

    private static func decodeDelta(_ value: JSONValue?) -> MessagesContentDelta {
        guard let object = value?.objectValue else { return .unknown("missing") }
        switch object["type"]?.stringValue {
        case "text_delta": return .text(object["text"]?.stringValue ?? "")
        case "input_json_delta": return .inputJSON(object["partial_json"]?.stringValue ?? "")
        case "thinking_delta": return .thinking(object["thinking"]?.stringValue ?? "")
        case "signature_delta": return .signature(object["signature"]?.stringValue ?? "")
        case "citations_delta": return .citations(object["citation"])
        case "compaction_delta": return .compaction(value ?? .null)
        default: return .unknown(object["type"]?.stringValue ?? "unknown")
        }
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        guard let double = value?.doubleValue,
              double.rounded() == double,
              double >= 0, double <= Double(Int.max)
        else { return nil }
        return Int(double)
    }
}

// MARK: - Adapter

/// Adapter for OpenRouter's Anthropic-compatible Messages API.
struct MessagesAdapter: Sendable {
    /// Documented base URL.
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/messages")!
    static let pathPrefix = "/api/v1/messages"

    private let transport: MediaTransport
    private let streamTransport: any HTTPStreamingTransport

    init(transport: MediaTransport, streamTransport: any HTTPStreamingTransport = URLSessionStreamingTransport()) {
        self.transport = transport
        self.streamTransport = streamTransport
    }

    /// Sends a non-streaming request. `stream` is omitted so the documented
    /// default applies.
    func send(_ request: MessagesAPIRequest) async throws -> MessagesAPIResponse {
        let urlRequest = try self.request(for: request, stream: nil, accept: "application/json")
        do {
            return try await transport.send(urlRequest, as: MessagesAPIResponse.self)
        } catch let error as MediaServiceError {
            throw AdapterServiceError.from(error)
        }
    }

    /// Streams a message as typed events. Terminal events are
    /// `message_stop`, the `error` event, and the `[DONE]` sentinel.
    func stream(_ request: MessagesAPIRequest) async throws -> AsyncThrowingStream<MessagesStreamEvent, Error> {
        let urlRequest = try self.request(for: request, stream: true, accept: "text/event-stream")
        let raw: HTTPStreamResponse
        do {
            raw = try await streamTransport.bytes(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AdapterStreamError.transport(error.localizedDescription)
        }
        return try await AdapterStreamPump.run(
            response: raw.response,
            body: raw.body,
            map: MessagesStreamDecoder.decode,
            isTerminal: { event in
                switch event {
                case .done, .messageStop, .streamError: return true
                default: return false
                }
            }
        )
    }

    private func request(for request: MessagesAPIRequest, stream: Bool?, accept: String) throws -> URLRequest {
        // Validate the exact documented endpoint BEFORE any credential work.
        let validated = try AdapterURL.validate(Self.endpoint, pathPrefix: Self.pathPrefix, allowCollectionRoot: true)
        var urlRequest = URLRequest(url: validated, timeoutInterval: NetworkTimeouts.request)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // F12: no HTTP-Referer until an owner-approved URL exists.
        urlRequest.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        let key: String
        do {
            key = try transport.apiKey()
        } catch let error as MediaServiceError {
            throw AdapterServiceError.from(error)
        } catch {
            throw AdapterServiceError.missingAPIKey
        }
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try MessagesRequestEncoder.encodeBody(request, stream: stream)
        return urlRequest
    }
}
