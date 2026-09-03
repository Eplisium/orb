import Foundation

struct OpenRouterRequest: Sendable {
    let apiKey: String
    let model: String
    let messages: [AgentAPIMessage]
    var tools: [AgentToolDefinition]? = nil
    var toolChoice: String? = nil
    var settings = GenerationSettings()

    /// Convenience for the common case, and source compatibility for the
    /// existing call sites that only ever set temperature and max tokens.
    init(
        apiKey: String,
        model: String,
        messages: [AgentAPIMessage],
        tools: [AgentToolDefinition]? = nil,
        toolChoice: String? = nil,
        temperature: Double = 0.7,
        maxTokens: Int? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        var settings = GenerationSettings()
        settings.temperature = temperature
        settings.maxTokens = maxTokens
        self.settings = settings
    }

    init(
        apiKey: String,
        model: String,
        messages: [AgentAPIMessage],
        tools: [AgentToolDefinition]? = nil,
        toolChoice: String? = nil,
        settings: GenerationSettings
    ) {
        self.apiKey = apiKey
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.settings = settings
    }

    var temperature: Double { settings.temperature ?? 0.7 }
    var maxTokens: Int? { settings.maxTokens }
}

protocol OpenRouterClientProtocol: Sendable {
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error>
}

struct HTTPStreamResponse: @unchecked Sendable {
    let response: URLResponse
    let body: AsyncThrowingStream<Data, Error>
}

protocol HTTPStreamingTransport: Sendable {
    func bytes(for request: URLRequest) async throws -> HTTPStreamResponse
}

struct OpenRouterRetryPolicy: Sendable {
    var maxRetries: Int = 2
    var baseDelay: Duration = .milliseconds(500)
    var maxDelay: Duration = .seconds(8)
    /// Fractional randomization around the exponential delay (0...1).
    var jitter: Double = 0.2
}

enum OpenRouterClientError: Error, Equatable, LocalizedError {
    case invalidRequest(String)
    case nonHTTPResponse
    case http(status: Int, message: String, retryAfter: TimeInterval?)
    case abruptEOF
    case idleTimeout
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return "Could not encode OpenRouter request: \(message)"
        case .nonHTTPResponse: return "OpenRouter returned a non-HTTP response."
        case .http(let status, let message, let retryAfter):
            switch status {
            case 401: return "OpenRouter rejected the API key. Check it in Account. \(message)"
            case 402: return "OpenRouter credits are exhausted. Add credits, then try again. \(message)"
            case 408: return "OpenRouter timed out before streaming began. \(message)"
            case 429:
                let retry = retryAfter.map { " Try again in about \(Int(ceil($0))) seconds." } ?? " Try again shortly."
                return "OpenRouter rate limit reached.\(retry) \(message)"
            case 500...599: return "OpenRouter or the selected provider is temporarily unavailable (HTTP \(status)). \(message)"
            default: return "OpenRouter HTTP \(status): \(message)"
            }
        case .abruptEOF: return "OpenRouter stream ended before a terminal event."
        case .idleTimeout: return "OpenRouter stream became idle."
        case .transport(let message): return "Network error while contacting OpenRouter: \(message)"
        }
    }
}

/// Streams an HTTP body as whole network chunks via `URLSessionDataDelegate`.
///
/// The previous implementation iterated `URLSession.bytes` one `UInt8` at a
/// time and re-buffered into 4 KB blocks. That cost an async suspension per
/// byte and, worse, withheld completed SSE events until 4 KB had accumulated —
/// so short deltas from fast models sat in the buffer instead of rendering.
/// `urlSession(_:dataTask:didReceive:)` hands us each chunk exactly as it
/// arrives off the socket, which is both far cheaper and immediate.
final class URLSessionStreamingTransport: NSObject, HTTPStreamingTransport, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var responders: [Int: CheckedContinuation<URLResponse, Error>] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Long-lived SSE connections must not be killed by the resource timeout.
        configuration.timeoutIntervalForRequest = NetworkTimeouts.request
        configuration.timeoutIntervalForResource = 3_600
        configuration.waitsForConnectivity = true
        // Streaming is latency-critical, so bypass any URL cache entirely.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() { super.init() }

    func bytes(for request: URLRequest) async throws -> HTTPStreamResponse {
        let task = session.dataTask(with: request)
        let identifier = task.taskIdentifier

        let body = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { continuation in
            lock.lock()
            continuations[identifier] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.clear(identifier)
            }
        }

        // Await the response head so a non-2xx status can be surfaced before
        // any body is consumed.
        let response: URLResponse = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            responders[identifier] = continuation
            lock.unlock()
            task.resume()
        }
        return .init(response: response, body: body)
    }

    private func clear(_ identifier: Int) {
        lock.lock()
        continuations[identifier] = nil
        responders[identifier] = nil
        lock.unlock()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let responder = responders.removeValue(forKey: dataTask.taskIdentifier)
        lock.unlock()
        responder?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let continuation = continuations[dataTask.taskIdentifier]
        lock.unlock()
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        let responder = responders.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        // A failure before the response head must fail the awaiting caller.
        if let responder {
            responder.resume(throwing: error ?? OpenRouterClientError.nonHTTPResponse)
        }
        if let error {
            let isCancellation = (error as? URLError)?.code == .cancelled
            continuation?.finish(throwing: isCancellation ? CancellationError() : error)
        } else {
            continuation?.finish()
        }
    }
}

final class OpenRouterClient: OpenRouterClientProtocol, @unchecked Sendable {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let transport: any HTTPStreamingTransport
    private let maxErrorBodyBytes: Int
    private let retryPolicy: OpenRouterRetryPolicy
    private let sleeper: Sleeper
    private let idleTimeout: Duration?
    private let finishGraceTimeout: Duration?

    init(
        transport: any HTTPStreamingTransport = URLSessionStreamingTransport(),
        maxErrorBodyBytes: Int = 16_384,
        retryPolicy: OpenRouterRetryPolicy = .init(),
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        idleTimeout: Duration? = .seconds(60),
        finishGraceTimeout: Duration? = .seconds(1)
    ) {
        self.transport = transport
        self.maxErrorBodyBytes = maxErrorBodyBytes
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.idleTimeout = idleTimeout
        self.finishGraceTimeout = finishGraceTimeout
    }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: min(60, NetworkTimeouts.request))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("ORB", forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue("ORB", forHTTPHeaderField: "X-OpenRouter-Title")
        do {
            urlRequest.httpBody = try OpenRouterRequestEncoder.encodeBody(request, stream: true)
        } catch {
            throw OpenRouterClientError.invalidRequest(error.localizedDescription)
        }

        let raw = try await initialResponse(for: urlRequest, apiKey: request.apiKey)

        return AsyncThrowingStream { continuation in
            let producer = Task {
                var decoder = ServerSentEventDecoder()
                var terminal = false
                var sawPrimaryFinish = false
                var finishDeadline: ContinuousClock.Instant?
                do {
                    let iterator = StreamBodyIterator(raw.body)
                    streamLoop: while true {
                        let timeout: Duration?
                        if let finishDeadline {
                            let remaining = ContinuousClock.now.duration(to: finishDeadline)
                            guard remaining > .zero else { break streamLoop }
                            timeout = remaining
                        } else {
                            timeout = sawPrimaryFinish ? finishGraceTimeout : idleTimeout
                        }
                        let fragment: Data?
                        do {
                            fragment = try await nextFragment(
                                from: iterator,
                                timeout: timeout
                            )
                        } catch OpenRouterClientError.idleTimeout where sawPrimaryFinish {
                            break streamLoop
                        }
                        guard let fragment else { break }
                        try Task.checkCancellation()
                        for decodedEvent in try decoder.consume(fragment) {
                            let event = sanitized(decodedEvent, secret: request.apiKey)
                            if case .done = event { terminal = true }
                            if case .finishReason(let choice, _) = event, choice == 0 {
                                sawPrimaryFinish = true
                                if finishDeadline == nil, let finishGraceTimeout {
                                    finishDeadline = ContinuousClock.now.advanced(by: finishGraceTimeout)
                                }
                            }
                            if case .apiError = event { terminal = true }
                            continuation.yield(event)
                        }
                        if terminal { break streamLoop }
                    }
                    if terminal {
                        continuation.finish()
                    } else if sawPrimaryFinish {
                        _ = try decoder.finish()
                        continuation.finish()
                    } else {
                        _ = try decoder.finish()
                        continuation.finish(throwing: OpenRouterClientError.abruptEOF)
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: sanitized(error, secret: request.apiKey))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func nextFragment(from iterator: StreamBodyIterator, timeout: Duration?) async throws -> Data? {
        guard let timeout else { return try await iterator.next() }
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await iterator.next() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw OpenRouterClientError.idleTimeout
            }
            guard let result = try await group.next() else { return nil }
            group.cancelAll()
            return result
        }
    }

    private func redacted(_ text: String, secret: String) -> String {
        secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[REDACTED]")
    }

    private func sanitized(_ event: OpenRouterStreamEvent, secret: String) -> OpenRouterStreamEvent {
        guard case .apiError(let error) = event else { return event }
        return .apiError(.init(
            code: error.code,
            message: redacted(error.message, secret: secret),
            errorType: error.errorType.map { redacted($0, secret: secret) },
            providerName: error.providerName.map { redacted($0, secret: secret) }
        ))
    }

    private func sanitized(_ error: Error, secret: String) -> Error {
        switch error {
        case OpenRouterStreamError.malformedEvent(let raw):
            return OpenRouterStreamError.malformedEvent(redacted(raw, secret: secret))
        case OpenRouterStreamError.incompleteEventAtEOF(let raw):
            return OpenRouterStreamError.incompleteEventAtEOF(redacted(raw, secret: secret))
        case let typed as OpenRouterStreamError:
            return typed
        case let typed as OpenRouterClientError:
            return typed
        default:
            return OpenRouterClientError.transport(redacted(error.localizedDescription, secret: secret))
        }
    }

    private func initialResponse(for request: URLRequest, apiKey: String) async throws -> HTTPStreamResponse {
        var retry = 0
        while true {
            try Task.checkCancellation()
            let raw: HTTPStreamResponse
            do {
                raw = try await transport.bytes(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if retry < retryPolicy.maxRetries, isTransientTransport(error) {
                    try await sleeper(backoff(for: retry, retryAfter: nil))
                    retry += 1
                    continue
                }
                throw OpenRouterClientError.transport(redacted(error.localizedDescription, secret: apiKey))
            }

            guard let response = raw.response as? HTTPURLResponse else {
                throw OpenRouterClientError.nonHTTPResponse
            }
            guard !(200..<300).contains(response.statusCode) else { return raw }

            var body = Data()
            do {
                for try await chunk in raw.body {
                    let remaining = max(0, maxErrorBodyBytes - body.count)
                    if remaining > 0 { body.append(chunk.prefix(remaining)) }
                    if body.count >= maxErrorBodyBytes { break }
                }
            } catch { /* the status remains the primary failure */ }
            let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
            let fallback = String(decoding: body, as: UTF8.self)
            let message = redacted(decoded?.error.message ?? fallback, secret: apiKey)
            let retryAfter = parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
            let failure = OpenRouterClientError.http(
                status: response.statusCode,
                message: String(message.prefix(maxErrorBodyBytes)),
                retryAfter: retryAfter
            )
            if retry < retryPolicy.maxRetries, isTransientStatus(response.statusCode) {
                try await sleeper(backoff(for: retry, retryAfter: retryAfter))
                retry += 1
                continue
            }
            throw failure
        }
    }

    private func isTransientStatus(_ status: Int) -> Bool {
        [408, 429, 502, 503, 504].contains(status)
    }

    private func isTransientTransport(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet
        ].contains(urlError.code)
    }

    private func backoff(for retry: Int, retryAfter: TimeInterval?) -> Duration {
        if let retryAfter { return .seconds(max(0, retryAfter)) }
        let base = retryPolicy.baseDelay.timeInterval * pow(2, Double(retry))
        let capped = min(base, retryPolicy.maxDelay.timeInterval)
        let spread = capped * min(max(retryPolicy.jitter, 0), 1)
        let randomized = spread == 0 ? capped : Double.random(in: (capped - spread)...(capped + spread))
        return .seconds(max(0, randomized))
    }

    private func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

private actor StreamBodyIterator {
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator

    init(_ body: AsyncThrowingStream<Data, Error>) {
        iterator = body.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        var local = iterator
        let value = try await local.next()
        iterator = local
        return value
    }
}

/// Testable seam over the private body type so the exact wire format can be
/// asserted without performing a network request.
enum OpenRouterRequestEncoder {
    static func encodeBody(_ request: OpenRouterRequest, stream: Bool) throws -> Data {
        try JSONEncoder().encode(RequestBody(request, stream: stream))
    }
}

/// Encodes the OpenRouter chat-completions body.
///
/// Written as a manual `encode(to:)` because the API distinguishes "parameter
/// omitted" from "parameter sent with a default value" — omitted lets the
/// provider apply its own default and keeps provider-side cache keys stable.
/// A synthesized encoder with optional properties would be close, but the
/// nested `reasoning`/`provider`/`plugins` objects need conditional shaping.
private struct RequestBody: Encodable {
    let request: OpenRouterRequest
    let stream: Bool

    init(_ request: OpenRouterRequest, stream: Bool = true) {
        self.request = request
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature, stream, seed, stop, models
        case reasoning, provider, transforms, plugins, logprobs, usage
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case streamOptions = "stream_options"
        case topP = "top_p"
        case topK = "top_k"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case repetitionPenalty = "repetition_penalty"
        case minP = "min_p"
        case topA = "top_a"
        case logitBias = "logit_bias"
        case topLogprobs = "top_logprobs"
        case parallelToolCalls = "parallel_tool_calls"
    }

    func encode(to encoder: Encoder) throws {
        let settings = request.settings.validated()
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(request.model, forKey: .model)
        try container.encode(request.messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(request.tools, forKey: .tools)
        try container.encodeIfPresent(request.toolChoice, forKey: .toolChoice)

        if settings.includeUsageAccounting {
            // Two distinct mechanisms: `stream_options` makes the final SSE
            // chunk carry a usage block, while `usage.include` is what actually
            // enables OpenRouter's cost accounting. Without the latter, `cost`
            // comes back nil and the UI can only show token counts.
            if stream {
                try container.encode(StreamOptions(includeUsage: true), forKey: .streamOptions)
            }
            try container.encode(UsageAccounting(include: true), forKey: .usage)
        }

        try container.encodeIfPresent(settings.temperature, forKey: .temperature)
        try container.encodeIfPresent(settings.topP, forKey: .topP)
        try container.encodeIfPresent(settings.topK, forKey: .topK)
        try container.encodeIfPresent(settings.frequencyPenalty, forKey: .frequencyPenalty)
        try container.encodeIfPresent(settings.presencePenalty, forKey: .presencePenalty)
        try container.encodeIfPresent(settings.repetitionPenalty, forKey: .repetitionPenalty)
        try container.encodeIfPresent(settings.minP, forKey: .minP)
        try container.encodeIfPresent(settings.topA, forKey: .topA)
        try container.encodeIfPresent(settings.seed, forKey: .seed)
        try container.encodeIfPresent(settings.maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(settings.parallelToolCalls, forKey: .parallelToolCalls)

        if !settings.stop.isEmpty { try container.encode(settings.stop, forKey: .stop) }
        if !settings.logitBias.isEmpty { try container.encode(settings.logitBias, forKey: .logitBias) }
        if settings.logprobs {
            try container.encode(true, forKey: .logprobs)
            try container.encodeIfPresent(settings.topLogprobs, forKey: .topLogprobs)
        }
        if !settings.transforms.isEmpty { try container.encode(settings.transforms, forKey: .transforms) }
        if !settings.fallbackModels.isEmpty {
            // OpenRouter expects the primary model first in `models`.
            try container.encode([request.model] + settings.fallbackModels, forKey: .models)
        }

        if settings.reasoning.isConfigured {
            var reasoning = container.nestedContainer(keyedBy: ReasoningKeys.self, forKey: .reasoning)
            if let effort = settings.reasoning.effort {
                try reasoning.encode(effort.rawValue, forKey: .effort)
            } else if let budget = settings.reasoning.maxTokens {
                try reasoning.encode(budget, forKey: .maxTokens)
            } else if settings.reasoning.enabled {
                try reasoning.encode(true, forKey: .enabled)
            }
            if settings.reasoning.exclude { try reasoning.encode(true, forKey: .exclude) }
        }

        if settings.provider.isConfigured {
            var provider = container.nestedContainer(keyedBy: ProviderKeys.self, forKey: .provider)
            let routing = settings.provider
            if !routing.order.isEmpty { try provider.encode(routing.order, forKey: .order) }
            if !routing.only.isEmpty { try provider.encode(routing.only, forKey: .only) }
            if !routing.ignore.isEmpty { try provider.encode(routing.ignore, forKey: .ignore) }
            if routing.sort != .none { try provider.encode(routing.sort.rawValue, forKey: .sort) }
            if !routing.allowFallbacks { try provider.encode(false, forKey: .allowFallbacks) }
            if routing.requireParameters { try provider.encode(true, forKey: .requireParameters) }
            if routing.dataCollection != .allow {
                try provider.encode(routing.dataCollection.rawValue, forKey: .dataCollection)
            }
            if routing.zeroDataRetention { try provider.encode(true, forKey: .zdr) }
        }

        if settings.webSearch {
            try container.encode([WebPlugin(maxResults: settings.webSearchMaxResults)], forKey: .plugins)
        }
    }

    private enum ReasoningKeys: String, CodingKey {
        case effort, exclude, enabled
        case maxTokens = "max_tokens"
    }

    private enum ProviderKeys: String, CodingKey {
        case order, only, ignore, sort, zdr
        case allowFallbacks = "allow_fallbacks"
        case requireParameters = "require_parameters"
        case dataCollection = "data_collection"
    }

    private struct WebPlugin: Encodable {
        let id = "web"
        let maxResults: Int?
        enum CodingKeys: String, CodingKey {
            case id
            case maxResults = "max_results"
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(maxResults, forKey: .maxResults)
        }
    }
}

private struct StreamOptions: Encodable { let includeUsage: Bool
    enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
}

/// Opts the request into OpenRouter's usage/cost accounting.
private struct UsageAccounting: Encodable { let include: Bool }

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}
