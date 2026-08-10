import Foundation
import Testing
@testable import ORB

private actor FixtureHTTPTransport: HTTPStreamingTransport {
    struct Reply: Sendable {
        let response: URLResponse
        let chunks: [Result<Data, Error>]
        var chunkDelay: Duration = .milliseconds(2)
    }
    var replies: [Reply]
    private(set) var cancellationObserved = false
    private(set) var requestCount = 0

    init(_ replies: [Reply]) { self.replies = replies }

    func bytes(for request: URLRequest) async throws -> HTTPStreamResponse {
        requestCount += 1
        let reply = replies.removeFirst()
        return HTTPStreamResponse(response: reply.response, body: AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in reply.chunks {
                    try await Task.sleep(for: reply.chunkDelay)
                    switch chunk {
                    case .success(let data): continuation.yield(data)
                    case .failure(let error): continuation.finish(throwing: error); return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.noteCancellation() }
            }
        })
    }

    private func noteCancellation() { cancellationObserved = true }
}

private actor DelayRecorder {
    private(set) var values: [Duration] = []
    func sleep(_ duration: Duration) async throws { values.append(duration) }
}

private struct HangingHTTPTransport: HTTPStreamingTransport {
    let response: URLResponse
    let initialChunk: Data

    func bytes(for request: URLRequest) async throws -> HTTPStreamResponse {
        HTTPStreamResponse(
            response: response,
            body: AsyncThrowingStream { continuation in
                continuation.yield(initialChunk)
            }
        )
    }
}

@Suite("OpenRouter streaming client")
struct OpenRouterClientTests {
    private func request() -> OpenRouterRequest {
        .init(apiKey: "fixture-secret", model: "test/model", messages: [.init(role: "user", content: "hello")])
    }

    private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test("non HTTP responses are rejected")
    func nonHTTP() async throws {
        let transport = FixtureHTTPTransport([.init(response: URLResponse(url: URL(string: "file:///tmp/x")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), chunks: [])])
        let client = OpenRouterClient(transport: transport)
        await #expect(throws: OpenRouterClientError.self) { _ = try await client.stream(self.request()) }
    }

    @Test("important HTTP failures retain typed status", arguments: [401, 402, 408, 429, 500, 502, 503, 504])
    func statuses(status: Int) async throws {
        let data = Data("{\"error\":{\"code\":\(status),\"message\":\"fixture failure\"}}".utf8)
        let transport = FixtureHTTPTransport([.init(response: response(status: status), chunks: [.success(data)])])
        let client = OpenRouterClient(
            transport: transport,
            retryPolicy: .init(maxRetries: 0)
        )
        do {
            _ = try await client.stream(request())
            Issue.record("Expected HTTP failure")
        } catch let error as OpenRouterClientError {
            guard case .http(let actual, let message, _) = error else {
                Issue.record("Wrong error")
                return
            }
            #expect(actual == status)
            #expect(message == "fixture failure")
            #expect(!message.contains("fixture-secret"))
        }
    }

    @Test("error bodies are capped")
    func cappedErrorBody() async throws {
        let transport = FixtureHTTPTransport([.init(response: response(status: 500), chunks: [.success(Data(repeating: 65, count: 10_000))])])
        let client = OpenRouterClient(transport: transport, maxErrorBodyBytes: 64)
        do { _ = try await client.stream(request()) }
        catch let error as OpenRouterClientError {
            guard case .http(_, let message, _) = error else {
                Issue.record("Wrong error")
                return
            }
            #expect(message.utf8.count <= 64)
        }
    }

    @Test("content followed by an SSE error preserves event order")
    func midStreamError() async throws {
        let body = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\ndata: {\"error\":{\"code\":500,\"message\":\"provider died\"}}\n\n".utf8)
        let client = OpenRouterClient(transport: FixtureHTTPTransport([.init(response: response(status: 200), chunks: [.success(body)])]))
        let stream = try await client.stream(request())
        var events: [OpenRouterStreamEvent] = []
        for try await event in stream { events.append(event) }
        #expect(events == [.contentDelta(choiceIndex: 0, text: "partial"), .apiError(.init(code: 500, message: "provider died", errorType: nil, providerName: nil))])
    }

    @Test("EOF without DONE or finish reason is abrupt")
    func abruptEOF() async throws {
        let body = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8)
        let client = OpenRouterClient(transport: FixtureHTTPTransport([.init(response: response(status: 200), chunks: [.success(body)])]))
        let stream = try await client.stream(request())
        await #expect(throws: OpenRouterClientError.self) {
            for try await _ in stream {}
        }
    }

    @Test("a non-primary choice finish reason does not complete choice zero")
    func nonPrimaryFinishIsNotTerminal() async throws {
        let payload =
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n" +
            "data: {\"choices\":[{\"index\":1,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        let body = Data(payload.utf8)
        let client = OpenRouterClient(
            transport: FixtureHTTPTransport([.init(response: response(status: 200), chunks: [.success(body)])])
        )
        let stream = try await client.stream(request())

        await #expect(throws: OpenRouterClientError.self) {
            for try await _ in stream {}
        }
    }

    @Test("consumer cancellation reaches byte source")
    func cancellation() async throws {
        let chunks = (0..<100).map { _ in Result<Data, Error>.success(Data(": ping\n\n".utf8)) }
        let transport = FixtureHTTPTransport([.init(response: response(status: 200), chunks: chunks)])
        let client = OpenRouterClient(transport: transport)
        let stream = try await client.stream(request())
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = await consumer.result
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.cancellationObserved)
    }

    @Test("transient HTTP failure retries before any stream content")
    func retriesTransientHTTPFailure() async throws {
        let error = Data("{\"error\":{\"message\":\"busy\"}}".utf8)
        let success = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8)
        let transport = FixtureHTTPTransport([
            .init(response: response(status: 429, headers: ["Retry-After": "2"]), chunks: [.success(error)]),
            .init(response: response(status: 200), chunks: [.success(success)])
        ])
        let delays = DelayRecorder()
        let client = OpenRouterClient(
            transport: transport,
            retryPolicy: .init(maxRetries: 2, baseDelay: .milliseconds(10), maxDelay: .seconds(5), jitter: 0),
            sleeper: { try await delays.sleep($0) }
        )

        let stream = try await client.stream(request())
        var events: [OpenRouterStreamEvent] = []
        for try await event in stream { events.append(event) }

        #expect(events.contains(.contentDelta(choiceIndex: 0, text: "ok")))
        #expect(await transport.requestCount == 2)
        #expect(await delays.values == [.seconds(2)])
    }

    @Test("non-transient HTTP failures do not retry")
    func doesNotRetryAuthenticationFailure() async throws {
        let error = Data("{\"error\":{\"message\":\"bad key\"}}".utf8)
        let transport = FixtureHTTPTransport([
            .init(response: response(status: 401), chunks: [.success(error)])
        ])
        let client = OpenRouterClient(
            transport: transport,
            retryPolicy: .init(maxRetries: 3, baseDelay: .milliseconds(1), maxDelay: .seconds(1), jitter: 0)
        )

        await #expect(throws: OpenRouterClientError.self) { _ = try await client.stream(self.request()) }
        #expect(await transport.requestCount == 1)
    }

    @Test("idle streams fail with a typed timeout")
    func idleTimeout() async throws {
        let transport = FixtureHTTPTransport([
            .init(
                response: response(status: 200),
                chunks: [.success(Data(": delayed keepalive\n\n".utf8))],
                chunkDelay: .milliseconds(100)
            )
        ])
        let client = OpenRouterClient(
            transport: transport,
            retryPolicy: .init(maxRetries: 0),
            idleTimeout: .milliseconds(5)
        )
        let stream = try await client.stream(request())

        await #expect(throws: OpenRouterClientError.self) {
            for try await _ in stream {}
        }
    }

    @Test("DONE completes without waiting for the HTTP body to close")
    func doneCompletesOpenBody() async throws {
        let body = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8)
        let client = OpenRouterClient(
            transport: HangingHTTPTransport(response: response(status: 200), initialChunk: body),
            retryPolicy: .init(maxRetries: 0),
            idleTimeout: .milliseconds(10)
        )
        let stream = try await client.stream(request())
        var events: [OpenRouterStreamEvent] = []

        for try await event in stream { events.append(event) }

        #expect(events.contains(.contentDelta(choiceIndex: 0, text: "ok")))
        #expect(events.contains(.done))
    }

    @Test("usage after choice-zero finish is not dropped across chunks")
    func usageAfterFinishIsPreserved() async throws {
        let finish = Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8)
        let usage = Data("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5,\"cost\":0.01}}\n\n".utf8)
        let done = Data("data: [DONE]\n\n".utf8)
        let transport = FixtureHTTPTransport([
            .init(response: response(status: 200), chunks: [.success(finish), .success(usage), .success(done)])
        ])
        let client = OpenRouterClient(transport: transport)
        let stream = try await client.stream(request())
        var events: [OpenRouterStreamEvent] = []
        for try await event in stream { events.append(event) }

        #expect(events.contains(.finishReason(choiceIndex: 0, reason: "stop")))
        #expect(events.contains(.usage(.init(promptTokens: 2, completionTokens: 3, totalTokens: 5, cost: 0.01))))
        #expect(events.last == .done)
    }

    @Test("choice-zero finish has a bounded grace period when the body hangs")
    func finishReasonHasBoundedGrace() async throws {
        let finish = Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8)
        let client = OpenRouterClient(
            transport: HangingHTTPTransport(response: response(status: 200), initialChunk: finish),
            retryPolicy: .init(maxRetries: 0),
            idleTimeout: .seconds(1),
            finishGraceTimeout: .milliseconds(5)
        )
        let stream = try await client.stream(request())
        var events: [OpenRouterStreamEvent] = []
        for try await event in stream { events.append(event) }

        #expect(events == [.finishReason(choiceIndex: 0, reason: "stop")])
    }

    @Test("choice-zero finish grace is absolute despite keepalives")
    func finishGraceIsAbsoluteDespiteKeepalives() async throws {
        let finish = Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8)
        let keepalive = Data(": keepalive\n\n".utf8)
        let transport = FixtureHTTPTransport([
            .init(
                response: response(status: 200),
                chunks: [.success(finish)] + Array(repeating: .success(keepalive), count: 100),
                chunkDelay: .milliseconds(2)
            )
        ])
        let client = OpenRouterClient(
            transport: transport,
            retryPolicy: .init(maxRetries: 0),
            idleTimeout: .seconds(1),
            finishGraceTimeout: .milliseconds(15)
        )
        let started = ContinuousClock.now
        let stream = try await client.stream(request())
        for try await _ in stream {}

        #expect(started.duration(to: .now) < .milliseconds(100))
        for _ in 0..<50 where await !transport.cancellationObserved {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await transport.cancellationObserved)
    }

    @Test("provider diagnostics never echo the API key")
    func redactsProviderDiagnostics() async throws {
        let key = "fixture-super-secret"
        let payload = Data("data: {\"error\":{\"code\":500,\"message\":\"failed for fixture-super-secret\"}}\n\n".utf8)
        let transport = FixtureHTTPTransport([
            .init(response: response(status: 200), chunks: [.success(payload)])
        ])
        let client = OpenRouterClient(transport: transport, retryPolicy: .init(maxRetries: 0))
        let stream = try await client.stream(.init(apiKey: key, model: "test/model", messages: [.init(role: "user", content: "hi")]))

        for try await event in stream {
            if case .apiError(let error) = event {
                #expect(!error.message.contains(key))
                #expect(error.message.contains("[REDACTED]"))
            }
        }
    }

    @Test("cancelling retry backoff prevents another request")
    func cancellationDuringBackoff() async throws {
        let error = Data("{\"error\":{\"message\":\"busy\"}}".utf8)
        let transport = FixtureHTTPTransport([
            .init(response: response(status: 503), chunks: [.success(error)])
        ])
        let client = OpenRouterClient(
            transport: transport,
            retryPolicy: .init(maxRetries: 2, baseDelay: .seconds(30), maxDelay: .seconds(30), jitter: 0)
        )
        let task = Task { try await client.stream(request()) }
        for _ in 0..<100 where await transport.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.requestCount == 1)
    }
}
