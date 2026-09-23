import Foundation

// W10 adapter for OpenRouter's beta Batch API.
//
// Contract (verified 2026-09-16 against https://openrouter.ai/docs/batch-quickstart.md):
// - Base path is `/api/beta/batches`, NOT the normal `/api/v1` prefix.
// - Submit is inline JSON: top-level `endpoint`, `model`, `requests`. The
//   documented parser is order-sensitive and stream-parses the body, so
//   `endpoint` and `model` MUST precede `requests` (a 400 otherwise). The
//   ordered serializer below hand-assembles the top-level object — it never
//   relies on Swift dictionary or JSONEncoder key ordering.
// - `custom_id` must be unique within the batch and non-empty; `requests`
//   must be non-empty.
// - A successful submission returns 202 with `status: "validating"` — that
//   is queued/validating, NOT completed. Statuses progress
//   validating → in_progress → finalizing → completed; terminal statuses
//   are completed/failed/expired/cancelled.
// - Results arrive INLINE on the completed batch record's `results` array.
//   There is no separate results-download endpoint, so none exists here.
//   Results are matched by `custom_id`, never by array order.
// - DELETE purges a terminal batch and its artifacts. Deleting an in-flight
//   batch returns 409. DELETION IS NOT CANCELLATION: the documented API has
//   no cancel endpoint (despite the `cancelled` status), and this adapter
//   deliberately exposes no cancel operation.

// MARK: - Envelope models

/// The documented API shapes selectable via the top-level `endpoint` field.
enum BatchEndpoint: String, Sendable, Equatable, CaseIterable {
    case chatCompletions = "/v1/chat/completions"
    case responses = "/v1/responses"
    case messages = "/v1/messages"
    case embeddings = "/v1/embeddings"
}

struct BatchRequestItem: Sendable, Equatable {
    /// Unique, non-empty per-batch identity a result is matched back by.
    let customID: String
    /// The endpoint-shaped request body, carried verbatim.
    let body: JSONValue

    init(customID: String, body: JSONValue) {
        self.customID = customID
        self.body = body
    }
}

struct BatchEnvelope: Sendable, Equatable {
    let endpoint: BatchEndpoint
    let model: String
    let requests: [BatchRequestItem]

    init(endpoint: BatchEndpoint, model: String, requests: [BatchRequestItem]) {
        self.endpoint = endpoint
        self.model = model
        self.requests = requests
    }
}

/// Ordered serializer for the beta batch envelope.
///
/// The documented parser is order-sensitive (`endpoint` and `model` must
/// precede `requests`), so the top-level object is assembled byte-by-byte
/// in documented order. Request item bodies are spliced as pre-encoded JSON
/// (`JSONValue.jsonText`); key order *inside* a body is not contractual —
/// only the top-level envelope order is.
enum OrderedBatchEnvelopeSerializer {
    static func serialize(_ envelope: BatchEnvelope) throws -> Data {
        try validate(envelope)

        var out = Data()
        out.append(Data("{".utf8))
        appendKey("endpoint", to: &out)
        out.append(Data(OrderedBatchEnvelopeSerializer.quoted(envelope.endpoint.rawValue).utf8))
        out.append(Data(",".utf8))
        appendKey("model", to: &out)
        out.append(Data(quoted(envelope.model).utf8))
        out.append(Data(",".utf8))
        appendKey("requests", to: &out)
        out.append(Data("[".utf8))
        for (index, item) in envelope.requests.enumerated() {
            if index > 0 { out.append(Data(",".utf8)) }
            out.append(Data("{".utf8))
            appendKey("custom_id", to: &out)
            out.append(Data(quoted(item.customID).utf8))
            out.append(Data(",".utf8))
            appendKey("body", to: &out)
            out.append(Data(item.body.jsonText.utf8))
            out.append(Data("}".utf8))
        }
        out.append(Data("]".utf8))
        out.append(Data("}".utf8))
        return out
    }

    /// Documented envelope constraints, checked before any credential work:
    /// non-empty model, non-empty `requests`, unique non-empty `custom_id`s.
    static func validate(_ envelope: BatchEnvelope) throws {
        guard !envelope.model.isEmpty else {
            throw BatchAdapterError.invalidEnvelope("model must not be empty")
        }
        guard !envelope.requests.isEmpty else {
            throw BatchAdapterError.invalidEnvelope("requests must not be empty")
        }
        var seen = Set<String>()
        for item in envelope.requests {
            guard !item.customID.isEmpty else {
                throw BatchAdapterError.invalidEnvelope("custom_id must not be empty")
            }
            guard seen.insert(item.customID).inserted else {
                throw BatchAdapterError.invalidEnvelope("duplicate custom_id: \(item.customID)")
            }
        }
    }

    private static func appendKey(_ key: String, to out: inout Data) {
        out.append(Data(quoted(key).utf8))
        out.append(Data(":".utf8))
    }

    /// A spec-correct quoted JSON string literal. Escapes only what JSON
    /// requires (quote, backslash, control characters) — forward slashes are
    /// left unescaped so the wire bytes match the documented examples.
    private static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - Record models

/// Batch status. The transient `finalizing`/`cancelling` statuses are not
/// accepted as list filters (`listFilterValue` returns nil for them) but are
/// still representable when polling.
enum BatchStatus: Equatable, Sendable {
    case validating
    case inProgress
    case finalizing
    case completed
    case failed
    case expired
    case cancelling
    case cancelled
    case other(String)

    init(string: String) {
        switch string {
        case "validating": self = .validating
        case "in_progress": self = .inProgress
        case "finalizing": self = .finalizing
        case "completed": self = .completed
        case "failed": self = .failed
        case "expired": self = .expired
        case "cancelling": self = .cancelling
        case "cancelled": self = .cancelled
        default: self = .other(string)
        }
    }

    /// The four documented terminal statuses. `202`-shaped records
    /// (`validating`) are pending, not completed.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .expired, .cancelled: return true
        default: return false
        }
    }

    /// Public statuses accepted by the list endpoint's repeatable
    /// `status` filter; nil for transient/unrecognized statuses.
    var listFilterValue: String? {
        switch self {
        case .validating: return "validating"
        case .inProgress: return "in_progress"
        case .completed: return "completed"
        case .failed: return "failed"
        case .expired: return "expired"
        case .cancelled: return "cancelled"
        case .finalizing, .cancelling, .other: return nil
        }
    }
}

struct BatchRequestCounts: Decodable, Equatable, Sendable {
    let total: Int?
    let completed: Int?
    let failed: Int?
}

struct BatchUsage: Decodable, Equatable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cost: Double?
    let isByok: Bool?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cost
        case isByok = "is_byok"
    }
}

struct BatchResultResponse: Decodable, Equatable, Sendable {
    let statusCode: Int?
    let requestID: String?
    /// The endpoint-shaped response body, kept verbatim.
    let body: JSONValue?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case requestID = "request_id"
        case body
    }
}

/// One per-request result. The documented contract: exactly one of
/// `response` or `error` is populated, and `custom_id` — never array
/// position — maps the result back to its input.
struct BatchResultItem: Decodable, Equatable, Sendable {
    let id: String?
    let customID: String
    let response: BatchResultResponse?
    let error: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, response, error
        case customID = "custom_id"
    }

    var succeeded: Bool { response != nil && error == nil }
}

/// A batch record. On a completed batch, `results` arrives inline — there
/// is no separate results-download endpoint.
struct BatchRecord: Decodable, Equatable, Sendable {
    let id: String?
    let object: String?
    let endpoint: String?
    let model: String?
    let completionWindow: String?
    let status: String?
    let createdAt: Int?
    let finalizedAt: Int?
    let requestCounts: BatchRequestCounts?
    let usage: BatchUsage?
    let results: [BatchResultItem]?
    let error: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, object, endpoint, model, status, usage, results, error
        case completionWindow = "completion_window"
        case createdAt = "created_at"
        case finalizedAt = "finalized_at"
        case requestCounts = "request_counts"
    }

    var batchStatus: BatchStatus? { status.map(BatchStatus.init(string:)) }

    /// Results indexed by `custom_id`. Array order is never used for
    /// matching.
    var resultsByCustomID: [String: BatchResultItem] {
        Dictionary(
            (results ?? []).map { ($0.customID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func result(for customID: String) -> BatchResultItem? {
        resultsByCustomID[customID]
    }
}

struct BatchList: Decodable, Equatable, Sendable {
    let object: String?
    let data: [BatchRecord]?
    let firstID: String?
    let lastID: String?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case object, data
        case firstID = "first_id"
        case lastID = "last_id"
        case hasMore = "has_more"
    }
}

struct BatchDeletionResponse: Decodable, Equatable, Sendable {
    struct Upstream: Decodable, Equatable, Sendable {
        let provider: String?
        let status: String?
    }

    struct Detail: Decodable, Equatable, Sendable {
        let openrouter: String?
        let upstream: Upstream?
    }

    let id: String?
    let object: String?
    let deletion: Detail?
}

// MARK: - Errors

enum BatchAdapterError: Error, Equatable, LocalizedError {
    /// Envelope constraint violations caught before any network call.
    case invalidEnvelope(String)
    case untrustedURL(String)
    case missingAPIKey
    case http(status: Int, message: String)
    /// Documented 409: the batch is in flight. Deletion is not
    /// cancellation — there is no cancel operation to fall back to.
    case inFlightBatchDeletion(batchID: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope(let message):
            return "Invalid batch envelope: \(message)"
        case .untrustedURL(let url):
            return "Refusing to attach credentials to untrusted URL: \(url)"
        case .missingAPIKey:
            return "An OpenRouter API key is required."
        case .http(let status, let message):
            switch status {
            case 401: return "OpenRouter rejected the API key. Check it in Account. \(message)"
            case 402: return "OpenRouter credits are exhausted. \(message)"
            case 429: return "OpenRouter rate limit reached. \(message)"
            case 500...599: return "OpenRouter is temporarily unavailable (HTTP \(status)). \(message)"
            default: return "OpenRouter HTTP \(status): \(message)"
            }
        case .inFlightBatchDeletion(let batchID):
            return "Batch \(batchID) is still in flight and cannot be deleted. Deletion is not cancellation; wait for a terminal status."
        case .transport(let message):
            return "Network error while contacting OpenRouter: \(message)"
        case .decoding(let message):
            return "Could not decode the OpenRouter batch response: \(message)"
        }
    }
}

// MARK: - Adapter

/// Adapter for OpenRouter's beta Batch API.
///
/// Documented operations only: submit, list, get (results inline on the
/// completed record), and delete (purges a terminal batch). There is no
/// results-download endpoint and no cancel endpoint — neither is implemented
/// and neither may be invented here.
struct BatchAdapter: Sendable {
    /// Documented beta base path — deliberately NOT under `/api/v1`.
    static let base = URL(string: "https://openrouter.ai/api/beta/batches")!
    static let pathPrefix = "/api/beta/batches"

    private let transport: MediaTransport

    init(transport: MediaTransport) {
        self.transport = transport
    }

    /// Submits a batch. Envelope constraints are validated before any
    /// credential work; a successful submission returns the 202-shaped
    /// record (`status` validating) — that is queued, not completed.
    func submit(_ envelope: BatchEnvelope) async throws -> BatchRecord {
        try OrderedBatchEnvelopeSerializer.validate(envelope)
        let body = try OrderedBatchEnvelopeSerializer.serialize(envelope)
        let urlRequest = try request(method: "POST", segment: nil, body: body)
        return try await execute(urlRequest)
    }

    /// Retrieves one batch. On a completed batch the `results` array arrives
    /// inline on the returned record.
    func batch(id: String) async throws -> BatchRecord {
        try await execute(try request(method: "GET", segment: id, body: nil))
    }

    /// Lists the workspace's batches, newest first. `statuses` repeats the
    /// documented `status` filter; transient statuses are rejected locally
    /// rather than sent. Pagination uses `after` (the previous page's
    /// `last_id`) — there are no offsets. List items carry metadata only and
    /// always set `results` to null.
    func list(
        limit: Int? = nil,
        after: String? = nil,
        statuses: [BatchStatus] = [],
        createdAfter: String? = nil,
        createdBefore: String? = nil
    ) async throws -> BatchList {
        var components = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let after { items.append(URLQueryItem(name: "after", value: after)) }
        for status in statuses {
            guard let value = status.listFilterValue else {
                throw BatchAdapterError.invalidEnvelope(
                    "status \(String(describing: status)) is transient or unrecognized and cannot filter a list"
                )
            }
            items.append(URLQueryItem(name: "status", value: value))
        }
        // Timestamps pass through verbatim: Unix seconds or ISO-8601.
        if let createdAfter { items.append(URLQueryItem(name: "created_after", value: createdAfter)) }
        if let createdBefore { items.append(URLQueryItem(name: "created_before", value: createdBefore)) }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else {
            throw BatchAdapterError.untrustedURL(Self.base.absoluteString)
        }
        return try await executeList(try buildRequest(url: url, method: "GET", body: nil))
    }

    /// Deletes a terminal batch, purging its request and result artifacts.
    /// In-flight batches return the documented 409, mapped to
    /// `inFlightBatchDeletion`. This is NOT cancellation — the API documents
    /// no cancel endpoint, and none is exposed here.
    func delete(id: String) async throws -> BatchDeletionResponse {
        let urlRequest = try request(method: "DELETE", segment: id, body: nil)
        do {
            return try await transport.send(urlRequest, as: BatchDeletionResponse.self)
        } catch let error as MediaServiceError {
            if case .http(let status, _) = error, status == 409 {
                throw BatchAdapterError.inFlightBatchDeletion(batchID: id)
            }
            throw Self.map(error)
        }
    }

    // MARK: Plumbing

    private func request(method: String, segment: String?, body: Data?) throws -> URLRequest {
        let url: URL
        if let segment {
            url = try AdapterURL.url(Self.base, appendingSegment: segment, pathPrefix: Self.pathPrefix)
        } else {
            url = try AdapterURL.validate(Self.base, pathPrefix: Self.pathPrefix, allowCollectionRoot: true)
        }
        return try buildRequest(url: url, method: method, body: body)
    }

    private func buildRequest(url: URL, method: String, body: Data?) throws -> URLRequest {
        var urlRequest = URLRequest(url: url, timeoutInterval: NetworkTimeouts.request)
        urlRequest.httpMethod = method
        // The URL builders validated the origin before the credential is read,
        // so the bearer token can never be attached to an unapproved origin.
        let key: String
        do {
            key = try transport.apiKey()
        } catch {
            throw BatchAdapterError.missingAPIKey
        }
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // F12: no HTTP-Referer until an owner-approved URL exists.
        urlRequest.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        if let body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    private func execute(_ urlRequest: URLRequest) async throws -> BatchRecord {
        do {
            return try await transport.send(urlRequest, as: BatchRecord.self)
        } catch let error as MediaServiceError {
            throw Self.map(error)
        }
    }

    private func executeList(_ urlRequest: URLRequest) async throws -> BatchList {
        do {
            return try await transport.send(urlRequest, as: BatchList.self)
        } catch let error as MediaServiceError {
            throw Self.map(error)
        }
    }

    static func map(_ error: MediaServiceError) -> BatchAdapterError {
        switch error {
        case .missingAPIKey:
            return .missingAPIKey
        case .invalidPath(let p), .invalidUpload(let p), .deleteNotConfirmed(let p), .resumeUnavailable(let p):
            return .invalidEnvelope(p)
        case .untrustedURL(let u):
            return .untrustedURL(u)
        case .http(let status, let message):
            return .http(status: status, message: message)
        case .transport(let m):
            return .transport(m)
        case .decoding(let m):
            return .decoding(m)
        }
    }
}
