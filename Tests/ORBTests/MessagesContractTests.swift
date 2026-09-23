import Foundation
import Testing
@testable import ORB

// W10 contract tests for the Anthropic-compatible Messages adapter.
//
// Shapes verified against the live docs (2026-09-16):
// - https://openrouter.ai/openapi.json (MessagesRequest, MessagesResult,
//   MessagesStreamEvents discriminator: message_start, content_block_start,
//   content_block_delta {text_delta|input_json_delta|thinking_delta|
//   signature_delta|citations_delta|compaction_delta}, content_block_stop,
//   message_delta, message_stop, ping, error)
// - https://openrouter.ai/docs/api/api-reference/anthropic-messages/create-a-message.md
//   (endpoint, request example, typed error envelopes, [DONE] sentinel)

private func mSSE(_ payload: String) -> Data {
    Data("data: \(payload)\n\n".utf8)
}

@Suite("Messages adapter contract")
struct MessagesContractTests {
    private func makeAdapter(
        jsonResponses: [MockMediaTransport.MockResponse] = [],
        streamReplies: [SSEFixtureTransport.Reply] = []
    ) -> (MessagesAdapter, MockMediaTransport, SSEFixtureTransport) {
        let json = MockMediaTransport(responses: jsonResponses)
        let stream = SSEFixtureTransport(streamReplies)
        return (MessagesAdapter(transport: json, streamTransport: stream), json, stream)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
    }

    // MARK: Endpoint capture

    @Test("non-streaming send posts to the exact documented URL with bearer auth")
    func nonStreamingSendCapture() async throws {
        let fixture = #"{"id":"msg_abc123","type":"message","role":"assistant","model":"anthropic/claude-sonnet-4","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
        let (adapter, json, _) = makeAdapter(jsonResponses: [.json(fixture)])
        _ = try await adapter.send(MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [.init(role: .user, content: .text("Hello"))],
            maxTokens: 1024
        ))

        let requests = json.sentRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://openrouter.ai/api/v1/messages")
        #expect(url.host == "openrouter.ai")
        #expect(url.path == "/api/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("request body matches the documented Anthropic-compatible shape")
    func requestBodyShape() async throws {
        let fixture = #"{"id":"msg_abc123","content":[]}"#
        let (adapter, json, _) = makeAdapter(jsonResponses: [.json(fixture)])
        _ = try await adapter.send(MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [
                .init(role: .user, content: .text("Summarize this file.")),
                .init(role: .assistant, content: .blocks([
                    .thinking(thinking: "Reading the request.", signature: "sig-abc"),
                    .toolUse(id: "toolu_1", name: "read_file", input: .object(["path": .string("a.txt")])),
                ])),
                .init(role: .user, content: .blocks([
                    .toolResult(toolUseID: "toolu_1", content: .string("file contents"), isError: false),
                ])),
            ],
            maxTokens: 1024,
            system: .text("You are helpful."),
            temperature: 0.3,
            stopSequences: ["END"]
        ))

        let body = try #require(json.sentRequests().first?.httpBody)
        let bodyJSON = try object(body)
        #expect(bodyJSON["model"] as? String == "anthropic/claude-sonnet-4")
        #expect(bodyJSON["max_tokens"] as? Int == 1024)
        #expect(bodyJSON["system"] as? String == "You are helpful.")
        #expect(bodyJSON["temperature"] as? Double == 0.3)
        #expect(bodyJSON["stop_sequences"] as? [String] == ["END"])
        #expect(bodyJSON["stream"] == nil)
        #expect(bodyJSON["top_p"] == nil)
        #expect(bodyJSON["top_k"] == nil)

        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "Summarize this file.")
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks[0]["type"] as? String == "thinking")
        #expect(assistantBlocks[0]["thinking"] as? String == "Reading the request.")
        #expect(assistantBlocks[0]["signature"] as? String == "sig-abc")
        #expect(assistantBlocks[1]["type"] as? String == "tool_use")
        #expect(assistantBlocks[1]["id"] as? String == "toolu_1")
        #expect(assistantBlocks[1]["name"] as? String == "read_file")
        let toolInput = try #require(assistantBlocks[1]["input"] as? [String: Any])
        #expect(toolInput["path"] as? String == "a.txt")
        let resultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(resultBlocks[0]["type"] as? String == "tool_result")
        #expect(resultBlocks[0]["tool_use_id"] as? String == "toolu_1")
        #expect(resultBlocks[0]["is_error"] as? Bool == false)
    }

    @Test("unset options stay omitted from the request body")
    func omittedOptionsStayOmitted() throws {
        let data = try MessagesRequestEncoder.encodeBody(MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [.init(role: .user, content: .text("Hi"))]
        ))
        let json = try object(data)
        #expect(json["max_tokens"] == nil)
        #expect(json["system"] == nil)
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["top_k"] == nil)
        #expect(json["stop_sequences"] == nil)
        #expect(json["stream"] == nil)
    }

    // MARK: Fixture decoding

    @Test("documented non-streaming fixture decodes")
    func nonStreamingFixtureDecodes() async throws {
        let fixture = """
        {
          "container": null,
          "content": [
            {"citations": [], "text": "Hello! I'm doing well, thank you for asking.", "type": "text"}
          ],
          "id": "msg_01XFDUDYJgAACzvnptvVoYEL",
          "model": "claude-sonnet-4-5-20250929",
          "role": "assistant",
          "stop_details": null,
          "stop_reason": "end_turn",
          "stop_sequence": null,
          "type": "message",
          "usage": {
            "cache_creation": null,
            "cache_creation_input_tokens": null,
            "cache_read_input_tokens": null,
            "inference_geo": null,
            "input_tokens": 12,
            "output_tokens": 15,
            "output_tokens_details": null,
            "server_tool_use": null,
            "service_tier": "standard"
          }
        }
        """
        let (adapter, _, _) = makeAdapter(jsonResponses: [.json(fixture)])
        let response = try await adapter.send(MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [.init(role: .user, content: .text("Hi"))]
        ))
        #expect(response.id == "msg_01XFDUDYJgAACzvnptvVoYEL")
        #expect(response.type == "message")
        #expect(response.stopReason == "end_turn")
        #expect(response.text == "Hello! I'm doing well, thank you for asking.")
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 12)
        #expect(usage.outputTokens == 15)
    }

    // MARK: Streaming

    @Test("documented streaming event sequence decodes and terminates")
    func documentedStreamSequence() async throws {
        let messageStart = #"{"type":"message_start","message":{"id":"msg_01XFDUDYJgAACzvnptvVoYEL","type":"message","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":0}}}"#
        let blockStart = #"{"type":"content_block_start","index":0,"content_block":{"citations":[],"text":"","type":"text"}}"#
        let thinkingDelta = #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"First, "}}"#
        let textDelta = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        let jsonDelta = #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}"#
        let signatureDelta = #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}"#
        let blockStop = #"{"type":"content_block_stop","index":0}"#
        let messageDelta = #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}"#
        let ping = #"{"type":"ping"}"#
        let messageStop = #"{"type":"message_stop"}"#

        let (adapter, _, stream) = makeAdapter(streamReplies: [
            .init(chunks: [
                // The documented SSE framing also carries `event:` lines;
                // the data payload's `type` field is authoritative.
                Data("event: message_start\n".utf8) + mSSE(messageStart),
                mSSE(blockStart) + mSSE(thinkingDelta),
                mSSE(signatureDelta) + mSSE(blockStop),
                mSSE(#"{"type":"content_block_start","index":1,"content_block":{"id":"toolu_1","input":{},"name":"get_weather","type":"tool_use"}}"#),
                mSSE(jsonDelta) + mSSE(textDelta),
                mSSE(#"{"type":"content_block_stop","index":1}"#) + mSSE(ping),
                mSSE(messageDelta) + mSSE(messageStop),
                mSSE("[DONE]"),
            ]),
        ])

        let request = MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [.init(role: .user, content: .text("Hi"))],
            maxTokens: 256
        )
        let events = try await collect(adapter.stream(request))

        guard case .messageStart(let startMessage)? = events.first else {
            Issue.record("expected .messageStart first"); return
        }
        #expect(startMessage?.id == "msg_01XFDUDYJgAACzvnptvVoYEL")
        #expect(startMessage?.usage?.inputTokens == 12)
        #expect(events.contains(.contentBlockStart(index: 0, block: .text(text: "", citations: []))))
        #expect(events.contains(.contentBlockDelta(index: 0, delta: .thinking("First, "))))
        #expect(events.contains(.contentBlockDelta(index: 0, delta: .signature("sig-1"))))
        #expect(events.contains(.contentBlockDelta(index: 1, delta: .inputJSON("{\"location\":"))))
        #expect(events.contains(.contentBlockDelta(index: 0, delta: .text("Hello"))))
        #expect(events.contains(.contentBlockStart(index: 1, block: .toolUse(id: "toolu_1", name: "get_weather", input: .object([:])))))
        #expect(events.contains(.contentBlockStop(index: 0)))
        #expect(events.contains(.contentBlockStop(index: 1)))
        #expect(events.contains(.ping))
        #expect(events.contains(.messageDelta(stopReason: "end_turn", stopSequence: nil, usage: MessagesUsage(inputTokens: nil, outputTokens: 15, cacheCreationInputTokens: nil, cacheReadInputTokens: nil))))
        #expect(events.last == .messageStop(metadata: nil))

        let captured = try #require(await stream.requests.first)
        #expect(captured.url?.absoluteString == "https://openrouter.ai/api/v1/messages")
        #expect(captured.httpMethod == "POST")
        #expect(captured.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try object(#require(captured.httpBody))
        #expect(body["stream"] as? Bool == true)
    }

    @Test("unknown event types are tolerated without crashing")
    func unknownEventsTolerated() async throws {
        let unknown = #"{"type":"container_upload_delta","index":0,"delta":{}}"#
        let stop = #"{"type":"message_stop"}"#
        let (adapter, _, _) = makeAdapter(streamReplies: [
            .init(chunks: [mSSE(unknown), mSSE(stop), mSSE("[DONE]")]),
        ])
        let events = try await collect(adapter.stream(MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [.init(role: .user, content: .text("Hi"))]
        )))
        #expect(events.contains(.unknown(type: "container_upload_delta")))
        #expect(events.last == .messageStop(metadata: nil))
    }

    @Test("stream error events surface as typed events and end the stream")
    func streamErrorEvent() async throws {
        let error = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let (adapter, _, _) = makeAdapter(streamReplies: [.init(chunks: [mSSE(error)])])
        let events = try await collect(adapter.stream(MessagesAPIRequest(
            model: "anthropic/claude-sonnet-4",
            messages: [.init(role: .user, content: .text("Hi"))]
        )))
        #expect(events.first == .streamError(type: "overloaded_error", errorType: nil, message: "Overloaded"))
    }

    @Test("non-2xx stream responses map into typed errors with the envelope type")
    func streamHTTPErrorMapping() async {
        let (adapter, _, _) = makeAdapter(streamReplies: [
            .init(status: 400, chunks: [Data(#"{"error":{"type":"invalid_request_error","message":"Invalid request: messages is required"},"request_id":null,"type":"error"}"#.utf8)]),
        ])
        await #expect {
            _ = try await adapter.stream(MessagesAPIRequest(
                model: "anthropic/claude-sonnet-4",
                messages: [.init(role: .user, content: .text("Hi"))]
            ))
        } throws: { error in
            error as? AdapterStreamError == .http(
                status: 400,
                code: nil,
                errorType: "invalid_request_error",
                message: "Invalid request: messages is required"
            )
        }
    }

    @Test("a body that ends without message_stop fails, never fakes success")
    func abruptEOFFails() async {
        let delta = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#
        let (adapter, _, _) = makeAdapter(streamReplies: [.init(chunks: [mSSE(delta)])])
        await #expect {
            let stream = try await adapter.stream(MessagesAPIRequest(
                model: "anthropic/claude-sonnet-4",
                messages: [.init(role: .user, content: .text("Hi"))]
            ))
            for try await _ in stream {}
        } throws: { error in
            (error as? AdapterStreamError) == .abruptEOF
        }
    }

    // MARK: 4xx on the JSON path

    @Test("non-streaming 4xx maps into a typed service error")
    func jsonHTTPErrorMapping() async {
        let (adapter, _, _) = makeAdapter(jsonResponses: [
            .status(400, #"{"error":{"type":"invalid_request_error","message":"Invalid request: messages is required"},"type":"error"}"#),
        ])
        await #expect {
            _ = try await adapter.send(MessagesAPIRequest(
                model: "anthropic/claude-sonnet-4",
                messages: [.init(role: .user, content: .text("Hi"))]
            ))
        } throws: { error in
            error as? AdapterServiceError
                == .http(status: 400, message: "Invalid request: messages is required")
        }
    }

    private func collect(_ stream: AsyncThrowingStream<MessagesStreamEvent, Error>) async throws -> [MessagesStreamEvent] {
        var events: [MessagesStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
