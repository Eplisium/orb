import Foundation
import Testing
@testable import ORB

// F12 — request attribution. The previous code sent `HTTP-Referer: ORB`
// everywhere; the attribution guide identifies an app by a URL and uses
// `X-OpenRouter-Title` as the display name. ORB has no owner-approved URL,
// so the optional HTTP-Referer attribution is deliberately OMITTED (never
// invented) while the documented display-name header stays.
//
// Restoring HTTP-Referer requires an owner-approved URL — see the F12 plan
// item; it must never be a fabricated domain.

/// Captures the request OpenRouterClient builds, then fails (non-transiently
/// so no retry/backoff machinery runs).
private final class CapturingStreamTransport: HTTPStreamingTransport, @unchecked Sendable {
    private struct NonTransient: Error {}

    private let lock = NSLock()
    private var request: URLRequest?

    func bytes(for request: URLRequest) async throws -> HTTPStreamResponse {
        lock.lock()
        self.request = request
        lock.unlock()
        throw NonTransient()
    }

    var capturedRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

@Suite("F12 attribution headers")
@MainActor
struct AttributionHeaderTests {
    private func assertAttribution(_ request: URLRequest, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil,
                "HTTP-Referer is omitted until an owner-approved URL exists", sourceLocation: sourceLocation)
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "ORB",
                "the documented display-name header is kept", sourceLocation: sourceLocation)
    }

    @Test("media transport requests omit HTTP-Referer and keep X-OpenRouter-Title")
    func mediaTransportHeaders() throws {
        let transport = MockMediaTransport(responses: [])
        let request = try transport.request(path: "videos/models")
        assertAttribution(request)
    }

    @Test("messages adapter requests omit HTTP-Referer")
    func messagesAdapterHeaders() async throws {
        let fixture = #"{"id":"msg_1","type":"message","role":"assistant","model":"anthropic/claude-sonnet-4","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
        let json = MockMediaTransport(responses: [.json(fixture)])
        let adapter = MessagesAdapter(transport: json, streamTransport: SSEFixtureTransport([]))
        _ = try await adapter.send(MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [.init(role: .user, content: .text("Hello"))],
            maxTokens: 1024
        ))
        let request = try #require(json.sentRequests().first)
        assertAttribution(request)
    }

    @Test("responses adapter requests omit HTTP-Referer")
    func responsesAdapterHeaders() async throws {
        let fixture = #"{"id":"resp-1","object":"response","status":"completed","model":"gpt-4","output":[]}"#
        let json = MockMediaTransport(responses: [.json(fixture)])
        let adapter = ResponsesAdapter(transport: json, streamTransport: SSEFixtureTransport([]))
        _ = try await adapter.send(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hello")))
        let request = try #require(json.sentRequests().first)
        assertAttribution(request)
    }

    @Test("beta batch adapter requests omit HTTP-Referer")
    func batchAdapterHeaders() async throws {
        let fixture = """
        {
          "id": "batch_1",
          "object": "batch",
          "endpoint": "/v1/chat/completions",
          "model": "openai/gpt-4o",
          "completion_window": "24h",
          "status": "validating",
          "created_at": 1782097200,
          "finalized_at": null,
          "request_counts": {"total": 1, "completed": 0, "failed": 0},
          "usage": null,
          "results": null,
          "error": null
        }
        """
        let mock = MockMediaTransport(responses: [.json(fixture)])
        let adapter = BatchAdapter(transport: mock)
        let envelope = BatchEnvelope(
            endpoint: .chatCompletions,
            model: "openai/gpt-4o",
            requests: [BatchRequestItem(customID: "req-0001", body: .object(["input": .string("Hi")]))]
        )
        _ = try await adapter.submit(envelope)
        let request = try #require(mock.sentRequests().first)
        assertAttribution(request)
    }

    @Test("account service requests omit HTTP-Referer")
    func accountServiceHeaders() async throws {
        let store = InMemoryCredentialStore()
        store.saveSecret("test-management-key", forReference: CredentialRole.management.keychainAccount)
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        let service = AccountService(profile: profile, secretStore: store) { request in
            box.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        await service.fetchCredits()
        let request = try #require(box.request)
        assertAttribution(request)
    }

    @Test("management service requests omit HTTP-Referer")
    func managementServiceHeaders() async throws {
        let store = InMemoryCredentialStore()
        store.saveSecret("test-management-key", forReference: CredentialRole.management.keychainAccount)
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        let profile = CredentialProfile(managementKeyReference: CredentialRole.management.keychainAccount)
        let service = ManagementService(profile: profile, secretStore: store) { request in
            box.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":[]}"#.utf8), response)
        }
        _ = try await service.getKeys()
        let request = try #require(box.request)
        assertAttribution(request)
    }

    @Test("chat streaming client requests omit HTTP-Referer")
    func chatClientHeaders() async throws {
        let transport = CapturingStreamTransport()
        let client = OpenRouterClient(transport: transport)
        let request = OpenRouterRequest(
            apiKey: "test-key",
            model: "openai/gpt-4o-mini",
            messages: [AgentAPIMessage(role: "user", content: "hi")]
        )
        do {
            _ = try await client.stream(request)
            Issue.record("Expected the capturing transport to fail the stream setup.")
        } catch {
            // The request is built (and captured) before the failure.
        }
        let captured = try #require(transport.capturedRequest)
        assertAttribution(captured)
    }
}
