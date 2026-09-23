import Foundation

// W10 adapter for OpenRouter's Responses API (`POST /api/v1/responses`).
//
// Contract (verified 2026-09-16 against the live docs):
// - https://openrouter.ai/docs/api_reference/responses/overview.md — the API
//   is STATELESS: full conversation history must be sent in `input` every
//   time; `store: true` and a non-null `previous_response_id` are rejected
//   with 400. Only documented operations exist — there is no retrieval or
//   cancellation endpoint, so none is implemented here.
// - https://openrouter.ai/docs/api_reference/responses/basic-usage.md —
//   request/response examples, streaming example, required `id`+`status` on
//   assistant history messages.
// - https://openrouter.ai/openapi.json — `ResponsesRequest`,
//   `OpenResponsesResult`, and the `StreamEvents` discriminator mapping
//   (`response.output_text.delta` and friends).

// MARK: - Request models

enum ResponsesRole: String, Sendable, Equatable {
    case user, system, developer, assistant
}

/// One content part of an input item. `input_text` for caller-written turns,
/// `output_text` for assistant turns replayed from history.
enum ResponsesInputPart: Sendable, Equatable {
    case inputText(String)
    case outputText(text: String, annotations: [JSONValue]?)
}

/// One `input` history item (`{type:"message", role, content}`).
///
/// The documented API requires `id` and `status` on assistant-role history
/// messages; the encoder enforces this instead of letting the request 400.
struct ResponsesInputItem: Sendable, Equatable {
    var role: ResponsesRole
    var content: [ResponsesInputPart]
    /// Required for assistant history items.
    var id: String?
    /// Required for assistant history items (e.g. `"completed"`).
    var status: String?

    init(role: ResponsesRole, content: [ResponsesInputPart], id: String? = nil, status: String? = nil) {
        self.role = role
        self.content = content
        self.id = id
        self.status = status
    }
}

/// `input` accepts a plain string or the full message history.
enum ResponsesInput: Sendable, Equatable {
    case text(String)
    case messages([ResponsesInputItem])
}

/// Typed Responses request. Fields the API rejects (`store`,
/// `previous_response_id`) are deliberately not modelled — the request
/// structurally cannot carry them, and the encoder debug-asserts omission.
struct ResponsesAPIRequest: Sendable, Equatable {
    var model: String
    var input: ResponsesInput
    var instructions: String?
    var maxOutputTokens: Int?
    var temperature: Double?
    var topP: Double?

    init(
        model: String,
        input: ResponsesInput,
        instructions: String? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.model = model
        self.input = input
        self.instructions = instructions
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
    }
}

/// Manual encoder: unset optionals are omitted entirely — "parameter absent"
/// lets the documented default apply and keeps cache keys stable.
enum ResponsesRequestEncoder {
    static func encodeBody(_ request: ResponsesAPIRequest, stream: Bool? = nil) throws -> Data {
        let data = try JSONEncoder().encode(Body(request: request, stream: stream))
        // Stateless guard (debug): this endpoint rejects `store: true` and
        // non-null `previous_response_id` with 400. The request model cannot
        // carry either; this assert catches any regression that reintroduces
        // them (e.g. a future passthrough field).
        if let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            assert(object["store"] == nil, "Responses requests must never send 'store' (stateless endpoint)")
            assert(object["previous_response_id"] == nil, "Responses requests must never send 'previous_response_id' (stateless endpoint)")
        }
        return data
    }

    private struct Body: Encodable {
        let request: ResponsesAPIRequest
        let stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model, input, instructions, temperature, stream
            case maxOutputTokens = "max_output_tokens"
            case topP = "top_p"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(request.model, forKey: .model)
            try container.encode(Input(value: request.input), forKey: .input)
            try container.encodeIfPresent(request.instructions, forKey: .instructions)
            try container.encodeIfPresent(request.maxOutputTokens, forKey: .maxOutputTokens)
            try container.encodeIfPresent(request.temperature, forKey: .temperature)
            try container.encodeIfPresent(request.topP, forKey: .topP)
            try container.encodeIfPresent(stream, forKey: .stream)
        }
    }

    private struct Input: Encodable {
        let value: ResponsesInput

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch value {
            case .text(let text):
                try container.encode(text)
            case .messages(let items):
                try container.encode(items.map(InputItem.init))
            }
        }
    }

    private struct InputItem: Encodable {
        let item: ResponsesInputItem

        enum CodingKeys: String, CodingKey { case type, role, id, status, content }

        func encode(to encoder: Encoder) throws {
            if item.role == .assistant, item.id == nil || item.status == nil {
                // Documented required fields on assistant history messages;
                // catching this locally beats a guaranteed upstream 400.
                throw AdapterServiceError.invalidRequest(
                    "assistant history messages require id and status"
                )
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("message", forKey: .type)
            try container.encode(item.role.rawValue, forKey: .role)
            try container.encodeIfPresent(item.id, forKey: .id)
            try container.encodeIfPresent(item.status, forKey: .status)
            try container.encode(item.content.map(InputPart.init), forKey: .content)
        }
    }

    private struct InputPart: Encodable {
        let part: ResponsesInputPart

        enum CodingKeys: String, CodingKey { case type, text, annotations }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch part {
            case .inputText(let text):
                try container.encode("input_text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .outputText(let text, let annotations):
                try container.encode("output_text", forKey: .type)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(annotations, forKey: .annotations)
            }
        }
    }
}

// MARK: - Response models

/// Non-streaming response (`OpenResponsesResult`). Every field is optional
/// so unknown forward-compatible shapes decode instead of failing; output
/// items keep their raw JSON for fields ORB does not model yet.
struct ResponsesAPIResponse: Decodable, Equatable, Sendable {
    let id: String?
    let object: String?
    let createdAt: Int?
    let status: String?
    let model: String?
    let output: [ResponsesOutputItem]?
    let usage: ResponsesUsage?
    let error: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, object, status, model, output, usage, error
        case createdAt = "created_at"
    }

    /// Concatenated `output_text` from message output items — the visible
    /// answer. Structured blocks stay available on `output`.
    var outputText: String {
        (output ?? []).compactMap(\.messageText).joined()
    }
}

struct ResponsesOutputItem: Decodable, Equatable, Sendable {
    let type: String?
    let id: String?
    let role: String?
    let status: String?
    let content: [ResponsesOutputPart]?
    /// Full wire item, preserving fields ORB does not model yet.
    let raw: JSONValue?

    init(from decoder: Decoder) throws {
        raw = try? JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        if let parts = try? container.decodeIfPresent([JSONValue].self, forKey: .content) {
            content = parts.map { part in
                if let object = part.objectValue,
                   object["type"]?.stringValue == "output_text" {
                    return .outputText(
                        text: object["text"]?.stringValue ?? "",
                        annotations: object["annotations"]?.arrayValue
                    )
                }
                return .unknown(part)
            }
        } else {
            content = nil
        }
    }

    enum CodingKeys: String, CodingKey { case type, id, role, status, content }

    var messageText: String? {
        guard type == "message" || type == nil else { return nil }
        return (content ?? []).compactMap { part in
            if case .outputText(let text, _) = part { return text }
            return nil
        }.joined()
    }
}

enum ResponsesOutputPart: Equatable, Sendable {
    case outputText(text: String, annotations: [JSONValue]?)
    case unknown(JSONValue)
}

struct ResponsesUsage: Decodable, Equatable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}

// MARK: - Stream events

/// Typed Responses stream events, decoded by the `type` field per the live
/// `StreamEvents` mapping. Unknown event types are tolerated as `.unknown`
/// and never crash the stream.
enum ResponsesStreamEvent: Equatable, Sendable {
    case created(ResponsesAPIResponse?)
    case inProgress(ResponsesAPIResponse?)
    case outputItemAdded(outputIndex: Int?, item: ResponsesAPIResponseItem?)
    case outputItemDone(outputIndex: Int?, item: ResponsesAPIResponseItem?)
    case contentPartAdded(outputIndex: Int?, contentIndex: Int?, part: JSONValue?)
    case contentPartDone(outputIndex: Int?, contentIndex: Int?, part: JSONValue?)
    case textDelta(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String)
    case textDone(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String?)
    case reasoningDelta(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String)
    case reasoningDone(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String?)
    case reasoningSummaryDelta(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String)
    case reasoningSummaryDone(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String?)
    case refusalDelta(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String)
    case refusalDone(outputIndex: Int?, contentIndex: Int?, itemID: String?, text: String?)
    case functionCallArgumentsDelta(itemID: String?, delta: String)
    case functionCallArgumentsDone(itemID: String?, arguments: String?)
    case annotationAdded(outputIndex: Int?, contentIndex: Int?, annotation: JSONValue?)
    case completed(ResponsesAPIResponse?)
    case incomplete(ResponsesAPIResponse?)
    case failed(ResponsesAPIResponse?)
    case streamError(code: String?, message: String?)
    case unknown(type: String)
    case done
}

/// Alias used by the event enum so the output item type reads consistently.
typealias ResponsesAPIResponseItem = ResponsesOutputItem

enum ResponsesStreamDecoder {
    static func decode(_ payload: Data) throws -> [ResponsesStreamEvent] {
        if payload == Data("[DONE]".utf8) { return [.done] }
        let diagnostic = String(decoding: payload.prefix(512), as: UTF8.self)
        guard let value = JSONValue.parse(String(decoding: payload, as: UTF8.self)),
              var object = value.objectValue
        else {
            throw AdapterStreamError.malformedEvent(diagnostic)
        }
        // The OpenAPI `ResponsesStreamingResponse` schema wraps each event in
        // `{"data": {…}}`; the documented SSE examples emit the event object
        // directly. Accept both shapes.
        if object["type"] == nil, let inner = object["data"]?.objectValue, inner["type"] != nil {
            object = inner
        }
        guard let type = object["type"]?.stringValue else {
            throw AdapterStreamError.malformedEvent(diagnostic)
        }
        let outputIndex = intValue(object["output_index"])
        let contentIndex = intValue(object["content_index"])
        let itemID = object["item_id"]?.stringValue
        let delta = object["delta"]?.stringValue ?? ""
        let response = object["response"]?.decode(as: ResponsesAPIResponse.self)

        switch type {
        case "response.created": return [.created(response)]
        case "response.in_progress": return [.inProgress(response)]
        case "response.output_item.added":
            return [.outputItemAdded(outputIndex: outputIndex, item: object["item"]?.decode(as: ResponsesOutputItem.self))]
        case "response.output_item.done":
            return [.outputItemDone(outputIndex: outputIndex, item: object["item"]?.decode(as: ResponsesOutputItem.self))]
        case "response.content_part.added":
            return [.contentPartAdded(outputIndex: outputIndex, contentIndex: contentIndex, part: object["part"])]
        case "response.content_part.done":
            return [.contentPartDone(outputIndex: outputIndex, contentIndex: contentIndex, part: object["part"])]
        case "response.output_text.delta":
            return [.textDelta(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: delta)]
        case "response.output_text.done":
            return [.textDone(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: object["text"]?.stringValue)]
        case "response.reasoning_text.delta":
            return [.reasoningDelta(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: delta)]
        case "response.reasoning_text.done":
            return [.reasoningDone(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: object["text"]?.stringValue)]
        case "response.reasoning_summary_text.delta":
            return [.reasoningSummaryDelta(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: delta)]
        case "response.reasoning_summary_text.done":
            return [.reasoningSummaryDone(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: object["text"]?.stringValue)]
        case "response.refusal.delta":
            return [.refusalDelta(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: delta)]
        case "response.refusal.done":
            return [.refusalDone(outputIndex: outputIndex, contentIndex: contentIndex, itemID: itemID, text: object["text"]?.stringValue)]
        case "response.function_call_arguments.delta":
            return [.functionCallArgumentsDelta(itemID: itemID, delta: delta)]
        case "response.function_call_arguments.done":
            return [.functionCallArgumentsDone(itemID: itemID, arguments: object["arguments"]?.stringValue)]
        case "response.output_text.annotation.added":
            return [.annotationAdded(outputIndex: outputIndex, contentIndex: contentIndex, annotation: object["annotation"])]
        case "response.completed": return [.completed(response)]
        case "response.incomplete": return [.incomplete(response)]
        case "response.failed": return [.failed(response)]
        case "error":
            return [.streamError(code: object["code"]?.stringValue, message: object["message"]?.stringValue)]
        default:
            // Unknown forward-compatible events must not crash streaming.
            return [.unknown(type: type)]
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

/// Adapter for OpenRouter's stateless Responses API.
///
/// Only the documented operations exist: create (streaming and
/// non-streaming). There is no retrieval or cancellation endpoint — none is
/// implemented, and none may be invented here.
struct ResponsesAdapter: Sendable {
    /// Documented base URL.
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/responses")!
    static let pathPrefix = "/api/v1/responses"

    private let transport: MediaTransport
    private let streamTransport: any HTTPStreamingTransport

    init(transport: MediaTransport, streamTransport: any HTTPStreamingTransport = URLSessionStreamingTransport()) {
        self.transport = transport
        self.streamTransport = streamTransport
    }

    /// Sends a non-streaming request. `stream` is omitted so the documented
    /// default (`false`) applies.
    func send(_ request: ResponsesAPIRequest) async throws -> ResponsesAPIResponse {
        let urlRequest = try self.request(for: request, stream: nil, accept: "application/json")
        do {
            return try await transport.send(urlRequest, as: ResponsesAPIResponse.self)
        } catch let error as MediaServiceError {
            throw AdapterServiceError.from(error)
        }
    }

    /// Streams a response as typed events. Terminal events are
    /// `response.completed` / `response.incomplete` / `response.failed`, the
    /// `error` event, and the `[DONE]` sentinel.
    func stream(_ request: ResponsesAPIRequest) async throws -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
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
            map: ResponsesStreamDecoder.decode,
            isTerminal: { event in
                switch event {
                case .done, .completed, .incomplete, .failed, .streamError: return true
                default: return false
                }
            }
        )
    }

    private func request(for request: ResponsesAPIRequest, stream: Bool?, accept: String) throws -> URLRequest {
        // Validate the exact documented endpoint BEFORE any credential work,
        // so the key can never be attached to an unapproved origin.
        let validated = try AdapterURL.validate(Self.endpoint, pathPrefix: Self.pathPrefix, allowCollectionRoot: true)
        var urlRequest = URLRequest(url: validated, timeoutInterval: NetworkTimeouts.request)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // F12: no HTTP-Referer until an owner-approved URL exists; the
        // documented display-name header stays.
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
        urlRequest.httpBody = try ResponsesRequestEncoder.encodeBody(request, stream: stream)
        return urlRequest
    }
}
