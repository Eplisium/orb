import Foundation

// Shared plumbing for the W10 advanced-API adapters (Responses, Messages,
// beta Batches): URL policy, typed errors, and SSE framing. Each adapter
// stays self-contained; only genuinely common mechanics live here.

// MARK: - URL policy

enum AdapterURLError: Error, Equatable, LocalizedError {
    case untrustedURL(String)

    var errorDescription: String? {
        switch self {
        case .untrustedURL(let url): return "Refusing to attach credentials to untrusted URL: \(url)"
        }
    }
}

/// URL policy shared by the advanced API adapters.
///
/// Same security spirit as `MediaEndpointURL` — HTTPS, `openrouter.ai` host
/// only, standard port, no user info, no dot-segment escapes — but the path
/// prefix is a parameter. `MediaEndpointURL` hard-codes the `/api/v1/`
/// prefix, which does not fit the beta batch base path `/api/beta/batches`;
/// adapters must not route their paths through it.
enum AdapterURL {
    static let allowedHost = "openrouter.ai"

    /// Validates an exact adapter endpoint before any credential may be
    /// attached. `allowCollectionRoot` permits the bare collection path
    /// (e.g. POST to `/api/beta/batches` itself); sub-resource requests set
    /// it false so the path must extend past the prefix.
    static func validate(_ url: URL, pathPrefix: String, allowCollectionRoot: Bool = false) throws -> URL {
        func reject() -> AdapterURLError { .untrustedURL(url.absoluteString) }
        guard url.scheme?.lowercased() == "https" else { throw reject() }
        guard url.host?.lowercased() == allowedHost else { throw reject() }
        guard url.port == nil || url.port == 443 else { throw reject() }
        guard url.user == nil, url.password == nil else { throw reject() }
        let path = url.path
        let validLength = allowCollectionRoot
            ? path.count >= pathPrefix.count
            : path.count > pathPrefix.count
        guard validLength, path.hasPrefix(pathPrefix) else { throw reject() }
        let segments = path.split(separator: "/")
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { throw reject() }
        return url
    }

    /// Appends one opaque identifier segment (e.g. a batch ID) to a base
    /// URL, percent-encodes it, and re-validates the result before any
    /// caller can attach credentials.
    static func url(_ base: URL, appendingSegment segment: String, pathPrefix: String) throws -> URL {
        guard !segment.isEmpty,
              segment != ".", segment != "..",
              !segment.contains("/"), !segment.contains("?"), !segment.contains("#")
        else { throw AdapterURLError.untrustedURL(segment) }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
        guard let url = URL(string: base.absoluteString + "/" + encoded) else {
            throw AdapterURLError.untrustedURL(segment)
        }
        return try validate(url, pathPrefix: pathPrefix)
    }
}

// MARK: - Typed service error

/// Typed failure surface for the Responses and Messages adapters. Every
/// error thrown by those adapters is one of these cases — never a raw
/// `URLError` — so feature code presents one coherent failure shape.
enum AdapterServiceError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case invalidRequest(String)
    case untrustedURL(String)
    case http(status: Int, message: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "An OpenRouter API key is required."
        case .invalidRequest(let message):
            return "Could not encode the request: \(message)"
        case .untrustedURL(let url):
            return "Refusing to attach credentials to untrusted URL: \(url)"
        case .http(let status, let message):
            switch status {
            case 401: return "OpenRouter rejected the API key. Check it in Account. \(message)"
            case 402: return "OpenRouter credits are exhausted. \(message)"
            case 429: return "OpenRouter rate limit reached. \(message)"
            case 500...599: return "OpenRouter is temporarily unavailable (HTTP \(status)). \(message)"
            default: return "OpenRouter HTTP \(status): \(message)"
            }
        case .transport(let message):
            return "Network error while contacting OpenRouter: \(message)"
        case .decoding(let message):
            return "Could not decode the OpenRouter response: \(message)"
        }
    }

    static func from(_ error: MediaServiceError) -> AdapterServiceError {
        switch error {
        case .missingAPIKey:
            return .missingAPIKey
        case .invalidPath(let p), .invalidUpload(let p), .deleteNotConfirmed(let p), .resumeUnavailable(let p):
            return .invalidRequest(p)
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

// MARK: - HTTP error envelope

/// Tolerant parser for OpenRouter's documented error envelopes:
/// Responses style `{"error":{"code":"invalid_prompt","message":"…"}}`,
/// Anthropic Messages style `{"type":"error","error":{"type":"invalid_request_error","message":"…"}}`,
/// and the generic `{"error":{"message":"…"}}` shape. Never throws — an
/// unparseable body falls back to the raw prefix so the status is never lost.
struct AdapterHTTPErrorEnvelope: Equatable, Sendable {
    let status: Int
    let code: String?
    let errorType: String?
    let message: String

    static func parse(status: Int, data: Data) -> AdapterHTTPErrorEnvelope {
        let raw = String(decoding: data.prefix(512), as: UTF8.self)
        guard let value = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let object = value.objectValue
        else {
            return .init(status: status, code: nil, errorType: nil, message: raw.isEmpty ? "Unknown error" : raw)
        }
        let error = object["error"]?.objectValue
        let code = error?["code"]?.stringValue
        let errorType = error?["type"]?.stringValue
        let message = error?["message"]?.stringValue ?? raw
        return .init(
            status: status,
            code: code,
            errorType: errorType,
            message: message.isEmpty ? "Unknown error" : message
        )
    }
}

// MARK: - Streaming support

/// Typed failure surface for adapter streaming. `http` carries the parsed
/// error envelope because the streaming path owns the response body.
enum AdapterStreamError: Error, Equatable, LocalizedError {
    case nonHTTPResponse
    case http(status: Int, code: String?, errorType: String?, message: String)
    case malformedEvent(String)
    case eventTooLarge(limit: Int)
    case incompleteEventAtEOF(String)
    case abruptEOF
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "OpenRouter returned a non-HTTP response."
        case .http(let status, _, _, let message):
            return "OpenRouter HTTP \(status): \(message)"
        case .malformedEvent(let raw):
            return "Malformed OpenRouter stream event: \(raw)"
        case .eventTooLarge(let limit):
            return "OpenRouter stream event exceeded \(limit) bytes."
        case .incompleteEventAtEOF(let raw):
            return "OpenRouter stream ended inside an event: \(raw)"
        case .abruptEOF:
            return "OpenRouter stream ended before a terminal event."
        case .transport(let message):
            return "Network error while contacting OpenRouter: \(message)"
        }
    }
}

/// Byte-level SSE framer producing raw `data:` payloads for the
/// Responses/Messages event vocabularies.
///
/// Same framing semantics as `ServerSentEventDecoder` (split-UTF-8 safe,
/// CRLF tolerated, comment/keepalive lines skipped, multi-line data joined),
/// but event-type agnostic: `event:` lines carry no payload the adapters
/// need — the JSON `type` field inside `data:` is authoritative per the
/// documented wire format.
struct AdapterSSEFramer {
    private var pending = Data()
    private var dataLines: [Data] = []
    private var eventBytes = 0
    private let maxEventBytes: Int
    private let diagnosticLimit: Int

    init(maxEventBytes: Int = 1_048_576, diagnosticLimit: Int = 512) {
        self.maxEventBytes = maxEventBytes
        self.diagnosticLimit = diagnosticLimit
    }

    mutating func consume<S: DataProtocol>(_ fragment: S) throws -> [Data] {
        pending.append(contentsOf: fragment)
        guard pending.count <= maxEventBytes - eventBytes + 1 else {
            throw AdapterStreamError.eventTooLarge(limit: maxEventBytes)
        }

        var output: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }

            if line.isEmpty {
                if !dataLines.isEmpty {
                    output.append(Data(dataLines.joined(separator: Data([0x0A]))))
                    dataLines.removeAll(keepingCapacity: true)
                    eventBytes = 0
                }
                continue
            }
            if line.first == 0x3A { continue } // comment / keepalive

            let prefix = Data("data:".utf8)
            guard line.starts(with: prefix) else { continue } // `event:`/`id:`/`retry:` lines
            var value = Data(line.dropFirst(prefix.count))
            if value.first == 0x20 { value.removeFirst() }
            eventBytes += value.count + (dataLines.isEmpty ? 0 : 1)
            guard eventBytes <= maxEventBytes else {
                throw AdapterStreamError.eventTooLarge(limit: maxEventBytes)
            }
            dataLines.append(value)
        }
        return output
    }

    mutating func finish() throws -> [Data] {
        guard pending.isEmpty, dataLines.isEmpty else {
            let raw = diagnostic(Data(dataLines.joined(separator: Data([0x0A]))) + pending)
            throw AdapterStreamError.incompleteEventAtEOF(raw)
        }
        return []
    }

    private func diagnostic(_ bytes: Data) -> String {
        String(decoding: bytes.prefix(diagnosticLimit), as: UTF8.self)
    }
}

enum AdapterStreamPump {
    /// Validates the response head, then pumps SSE payloads through `map`,
    /// ending the stream at the first terminal event.
    ///
    /// A body that ends without a terminal event fails with `.abruptEOF` —
    /// a silently truncated stream must never look like success.
    static func run<Event: Sendable>(
        response: URLResponse,
        body: AsyncThrowingStream<Data, Error>,
        map: @escaping @Sendable (Data) throws -> [Event],
        isTerminal: @escaping @Sendable (Event) -> Bool
    ) async throws -> AsyncThrowingStream<Event, Error> {
        guard let http = response as? HTTPURLResponse else {
            throw AdapterStreamError.nonHTTPResponse
        }
        var validatedBody = body
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            let maxErrorBodyBytes = 16_384
            do {
                for try await chunk in body {
                    let remaining = max(0, maxErrorBodyBytes - data.count)
                    if remaining > 0 { data.append(chunk.prefix(remaining)) }
                    if data.count >= maxErrorBodyBytes { break }
                }
            } catch { /* the status remains the primary failure */ }
            let parsed = AdapterHTTPErrorEnvelope.parse(status: http.statusCode, data: data)
            throw AdapterStreamError.http(
                status: http.statusCode,
                code: parsed.code,
                errorType: parsed.errorType,
                message: parsed.message
            )
        }

        return AsyncThrowingStream { continuation in
            let producer = Task {
                var framer = AdapterSSEFramer()
                var terminal = false
                func dispatch(_ events: [Event]) -> Bool {
                    for event in events {
                        if isTerminal(event) {
                            terminal = true
                            continuation.yield(event)
                            return true
                        }
                        continuation.yield(event)
                    }
                    return false
                }
                do {
                    var iterator = validatedBody.makeAsyncIterator()
                    pump: while true {
                        guard let chunk = try await iterator.next() else { break }
                        for payload in try framer.consume(chunk) {
                            if dispatch(try map(payload)) { break pump }
                        }
                    }
                    for payload in try framer.finish() {
                        if dispatch(try map(payload)) { break }
                    }
                    guard terminal else { throw AdapterStreamError.abruptEOF }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

// MARK: - JSON helpers

extension JSONValue {
    /// Decodes a typed value out of a dynamically-shaped JSON subtree,
    /// returning nil when the subtree does not match the target type.
    func decode<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
