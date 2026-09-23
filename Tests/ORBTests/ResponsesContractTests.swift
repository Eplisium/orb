import Foundation
import Testing
@testable import ORB

// W10 contract tests for the Responses adapter.
//
// Shapes verified against the live docs (2026-09-16):
// - https://openrouter.ai/docs/api_reference/responses/overview.md (stateless-only contract)
// - https://openrouter.ai/docs/api_reference/responses/basic-usage.md (request/response/streaming examples)
// - https://openrouter.ai/openapi.json (ResponsesRequest, OpenResponsesResult, StreamEvents mapping)

/// Fixture transport for adapter streaming tests: records each request and
/// replays scripted chunks. No network, no Keychain. Shared with
/// MessagesContractTests.
actor SSEFixtureTransport: HTTPStreamingTransport {
    struct Reply: Sendable {
        let status: Int
        let chunks: [Data]

        init(status: Int = 200, chunks: [Data]) {
            self.status = status
            self.chunks = chunks
        }
    }

    var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func bytes(for request: URLRequest) async throws -> HTTPStreamResponse {
        requests.append(request)
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return HTTPStreamResponse(
            response: response,
            body: AsyncThrowingStream { continuation in
                for chunk in reply.chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }
}

private func sse(_ payload: String) -> Data {
    Data("data: \(payload)\n\n".utf8)
}

@Suite("Responses adapter contract")
struct ResponsesContractTests {
    private func makeAdapter(
        jsonResponses: [MockMediaTransport.MockResponse] = [],
        streamReplies: [SSEFixtureTransport.Reply] = []
    ) -> (ResponsesAdapter, MockMediaTransport, SSEFixtureTransport) {
        let json = MockMediaTransport(responses: jsonResponses)
        let stream = SSEFixtureTransport(streamReplies)
        return (ResponsesAdapter(transport: json, streamTransport: stream), json, stream)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
    }

    // MARK: Endpoint capture

    @Test("non-streaming send posts to the exact documented URL with bearer auth")
    func nonStreamingSendCapture() async throws {
        let fixture = #"{"id":"resp-abc123","object":"response","status":"completed","model":"gpt-4","output":[]}"#
        let (adapter, json, _) = makeAdapter(jsonResponses: [.json(fixture)])
        _ = try await adapter.send(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hello")))

        let requests = json.sentRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://openrouter.ai/api/v1/responses")
        #expect(url.host == "openrouter.ai")
        #expect(url.path == "/api/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("request body matches the documented stateless shape")
    func requestBodyShape() async throws {
        let fixture = #"{"id":"resp-abc123","status":"completed","output":[]}"#
        let (adapter, json, _) = makeAdapter(jsonResponses: [.json(fixture)])
        let request = ResponsesAPIRequest(
            model: "openai/o4-mini",
            input: .messages([
                ResponsesInputItem(
                    role: .user,
                    content: [.inputText("What is the capital of France?")]
                ),
                ResponsesInputItem(
                    role: .assistant,
                    content: [.outputText(text: "The capital of France is Paris.", annotations: [])],
                    id: "msg_abc123",
                    status: "completed"
                ),
                ResponsesInputItem(
                    role: .user,
                    content: [.inputText("What is the population of that city?")]
                ),
            ]),
            maxOutputTokens: 9000
        )
        _ = try await adapter.send(request)

        let body = try #require(json.sentRequests().first?.httpBody)
        let bodyJSON = try object(body)
        #expect(bodyJSON["model"] as? String == "openai/o4-mini")
        #expect(bodyJSON["max_output_tokens"] as? Int == 9000)
        // Non-streaming: the documented default applies, `stream` is omitted.
        #expect(bodyJSON["stream"] == nil)
        #expect(bodyJSON["temperature"] == nil)
        #expect(bodyJSON["top_p"] == nil)

        let input = try #require(bodyJSON["input"] as? [[String: Any]])
        #expect(input.count == 3)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "user")
        let userContent = try #require(input[0]["content"] as? [[String: Any]])
        #expect(userContent[0]["type"] as? String == "input_text")
        #expect(userContent[0]["text"] as? String == "What is the capital of France?")
        // Documented required fields on assistant history items.
        #expect(input[1]["id"] as? String == "msg_abc123")
        #expect(input[1]["status"] as? String == "completed")
        let assistantContent = try #require(input[1]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "output_text")
        #expect(assistantContent[0]["text"] as? String == "The capital of France is Paris.")
    }

    @Test("assistant history items without id/status are rejected locally")
    func assistantHistoryValidation() {
        let request = ResponsesAPIRequest(
            model: "openai/o4-mini",
            input: .messages([
                ResponsesInputItem(role: .assistant, content: [.outputText(text: "hi", annotations: nil)]),
            ])
        )
        #expect(throws: AdapterServiceError.self) {
            try ResponsesRequestEncoder.encodeBody(request)
        }
    }

    @Test("stateless forbidden fields are never encoded")
    func forbiddenStatefulFieldsOmitted() throws {
        // Every optional field set: `store` and `previous_response_id` are
        // still structurally impossible to emit.
        let request = ResponsesAPIRequest(
            model: "openai/o4-mini",
            input: .text("Hello"),
            instructions: "be brief",
            maxOutputTokens: 64,
            temperature: 0.5,
            topP: 0.9
        )
        for stream in [nil, false, true] {
            let data = try ResponsesRequestEncoder.encodeBody(request, stream: stream)
            let json = try object(data)
            #expect(json["store"] == nil)
            #expect(json["previous_response_id"] == nil)
        }
    }

    // MARK: Fixture decoding

    @Test("documented non-streaming fixture decodes")
    func nonStreamingFixtureDecodes() async throws {
        let fixture = """
        {
          "completed_at": 1704067210,
          "created_at": 1704067200,
          "error": null,
          "id": "resp-abc123",
          "incomplete_details": null,
          "instructions": null,
          "max_output_tokens": null,
          "metadata": null,
          "model": "gpt-4",
          "object": "response",
          "output": [
            {
              "content": [
                {"annotations": [], "text": "Hello! How can I help you today?", "type": "output_text"}
              ],
              "id": "msg-abc123",
              "role": "assistant",
              "status": "completed",
              "type": "message"
            }
          ],
          "parallel_tool_calls": true,
          "presence_penalty": null,
          "status": "completed",
          "temperature": null,
          "tool_choice": "auto",
          "tools": [],
          "top_p": null,
          "usage": {
            "input_tokens": 10,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 25,
            "output_tokens_details": {"reasoning_tokens": 0},
            "total_tokens": 35
          }
        }
        """
        let (adapter, _, _) = makeAdapter(jsonResponses: [.json(fixture)])
        let response = try await adapter.send(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hi")))
        #expect(response.id == "resp-abc123")
        #expect(response.status == "completed")
        #expect(response.model == "gpt-4")
        #expect(response.outputText == "Hello! How can I help you today?")
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 10)
        #expect(usage.outputTokens == 25)
        #expect(usage.totalTokens == 35)
    }

    // MARK: Streaming

    @Test("documented streaming event sequence decodes and terminates on [DONE]")
    func documentedStreamSequence() async throws {
        let created = #"{"type":"response.created","response":{"id":"resp_1234567890","object":"response","status":"in_progress"}}"#
        let itemAdded = #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_abc123","role":"assistant","status":"in_progress","content":[]}}"#
        let partAdded = #"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text","text":""}}"#
        let delta2 = #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"item_id":"msg_abc123","delta":" world"}"#
        let textDone = #"{"type":"response.output_text.done","output_index":0,"content_index":0,"item_id":"msg_abc123","text":"héllo world"}"#
        let itemDone = #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_abc123","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello world"}]}}"#
        let completed = #"{"type":"response.completed","response":{"id":"resp_1234567890","object":"response","status":"completed","usage":{"input_tokens":12,"output_tokens":45,"total_tokens":57}}}"#

        let (adapter, _, stream) = makeAdapter(streamReplies: [
            .init(chunks: [
                sse(created) + sse(itemAdded) + sse(partAdded),
                // One delta split mid-JSON across network chunks, with a
                // multibyte character split across a UTF-8 byte boundary.
                // No trailing newline: the event line is reassembled from
                // four chunks before it becomes a complete SSE event.
                Data("data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"item_id\":\"msg_abc123\",\"delta\":\"h".utf8),
                Data([0xC3]),
                Data([0xA9]) + Data("llo\"}\n\n".utf8),
                sse(delta2) + sse(textDone) + sse(itemDone),
                sse(completed),
                sse("[DONE]"),
            ]),
        ])

        let request = ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hi"))
        let events = try await collect(adapter.stream(request))

        guard case .created(let createdResponse)? = events.first else {
            Issue.record("expected .created first"); return
        }
        #expect(createdResponse?.id == "resp_1234567890")
        #expect(events.contains(.textDelta(outputIndex: 0, contentIndex: 0, itemID: "msg_abc123", text: "héllo")))
        #expect(events.contains(.textDelta(outputIndex: 0, contentIndex: 0, itemID: "msg_abc123", text: " world")))
        #expect(events.contains(.textDone(outputIndex: 0, contentIndex: 0, itemID: "msg_abc123", text: "héllo world")))
        #expect(events.contains { if case .outputItemDone = $0 { return true }; return false })
        // The stream ends at the first terminal event: `response.completed`
        // closes it without waiting for the trailing [DONE] sentinel.
        guard case .completed(let finalResponse)? = events.last else {
            Issue.record("expected .completed to terminate the stream"); return
        }
        #expect(finalResponse?.usage?.totalTokens == 57)

        // The stream request itself captured the streaming wire contract.
        let captured = try #require(await stream.requests.first)
        #expect(captured.url?.absoluteString == "https://openrouter.ai/api/v1/responses")
        #expect(captured.httpMethod == "POST")
        #expect(captured.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try object(#require(captured.httpBody))
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] == nil)
        #expect(body["previous_response_id"] == nil)
    }

    @Test("unknown events are tolerated without crashing and the stream continues")
    func unknownEventsTolerated() async throws {
        // `response.done` appears in the basic-usage streaming example but is
        // not in the live StreamEvents mapping — it must not crash decoding.
        let unknown1 = #"{"type":"response.done","response":{"id":"resp_1","status":"completed"}}"#
        let unknown2 = #"{"type":"response.something.future","sequence_number":9}"#
        let delta = #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hi"}"#
        let completed = #"{"type":"response.completed","response":{"id":"resp_1","status":"completed"}}"#
        let (adapter, _, _) = makeAdapter(streamReplies: [
            .init(chunks: [sse(unknown1), sse(delta), sse(unknown2), sse(completed), sse("[DONE]")]),
        ])
        let events = try await collect(adapter.stream(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hi"))))
        #expect(events.contains(.unknown(type: "response.done")))
        #expect(events.contains(.unknown(type: "response.something.future")))
        #expect(events.contains(.textDelta(outputIndex: 0, contentIndex: 0, itemID: nil, text: "Hi")))
        guard case .completed? = events.last else {
            Issue.record("expected .completed to terminate the stream"); return
        }
    }

    @Test("stream error events surface as typed events and end the stream")
    func streamErrorEvent() async throws {
        let error = #"{"code":"rate_limit_exceeded","message":"Rate limit exceeded. Please try again later.","param":null,"sequence_number":2,"type":"error"}"#
        let (adapter, _, _) = makeAdapter(streamReplies: [
            .init(chunks: [sse(error), sse(#"{"type":"response.completed","response":{}}"#)]),
        ])
        let events = try await collect(adapter.stream(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hi"))))
        #expect(events.first == .streamError(code: "rate_limit_exceeded", message: "Rate limit exceeded. Please try again later."))
        #expect(events.count == 1)
    }

    @Test("non-2xx stream responses map into typed errors with the envelope code")
    func streamHTTPErrorMapping() async {
        let (adapter, _, _) = makeAdapter(streamReplies: [
            .init(status: 400, chunks: [Data(#"{"error":{"code":"invalid_prompt","message":"Missing required parameter: 'model'."},"metadata":null}"#.utf8)]),
        ])
        await #expect {
            _ = try await adapter.stream(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hi")))
        } throws: { error in
            error as? AdapterStreamError == .http(
                status: 400,
                code: "invalid_prompt",
                errorType: nil,
                message: "Missing required parameter: 'model'."
            )
        }
    }

    @Test("a body that ends without a terminal event fails, never fakes success")
    func abruptEOFFails() async {
        let delta = #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"partial"}"#
        let (adapter, _, _) = makeAdapter(streamReplies: [.init(chunks: [sse(delta)])])
        await #expect {
            let stream = try await adapter.stream(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hi")))
            for try await _ in stream {}
        } throws: { error in
            (error as? AdapterStreamError) == .abruptEOF
        }
    }

    // MARK: 4xx on the JSON path

    @Test("non-streaming 4xx maps into a typed service error")
    func jsonHTTPErrorMapping() async {
        let (adapter, _, _) = makeAdapter(jsonResponses: [
            .status(400, #"{"error":{"code":"invalid_prompt","message":"Missing required parameter: 'model'."}}"#),
        ])
        await #expect {
            _ = try await adapter.send(ResponsesAPIRequest(model: "openai/o4-mini", input: .text("Hi")))
        } throws: { error in
            error as? AdapterServiceError
                == .http(status: 400, message: "Missing required parameter: 'model'.")
        }
    }

    private func collect(_ stream: AsyncThrowingStream<ResponsesStreamEvent, Error>) async throws -> [ResponsesStreamEvent] {
        var events: [ResponsesStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
