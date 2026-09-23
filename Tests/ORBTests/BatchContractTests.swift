import Foundation
import Testing
@testable import ORB

// W10 contract tests for the beta Batch adapter.
//
// Shapes verified against https://openrouter.ai/docs/batch-quickstart.md
// (2026-09-16): base path /api/beta/batches (NOT /api/v1), order-sensitive
// top-level envelope (endpoint, model, requests), 202 = validating, inline
// results on the completed record matched by custom_id, DELETE purges
// terminal batches and 409s on in-flight ones, no cancel endpoint exists.

@Suite("Beta batch adapter contract")
struct BatchContractTests {
    private func makeAdapter(
        responses: [MockMediaTransport.MockResponse] = []
    ) -> (BatchAdapter, MockMediaTransport) {
        let mock = MockMediaTransport(responses: responses)
        return (BatchAdapter(transport: mock), mock)
    }

    // MARK: Ordered serializer

    @Test("top-level envelope serializes endpoint, model, requests in documented byte order")
    func orderedSerialization() throws {
        let envelope = BatchEnvelope(
            endpoint: .chatCompletions,
            model: "openai/gpt-4o",
            requests: [
                BatchRequestItem(
                    customID: "req-0001",
                    body: .object(["messages": .array([.object(["role": .string("user"), "content": .string("Summarize OpenRouter in one sentence.")])])])
                ),
                BatchRequestItem(
                    customID: "req-0002",
                    body: .object(["messages": .array([.object(["role": .string("user"), "content": .string("Second request.")])])])
                ),
            ]
        )
        let data = try OrderedBatchEnvelopeSerializer.serialize(envelope)
        let text = String(decoding: data, as: UTF8.self)

        // Provable order: the raw bytes start with the exact documented key
        // sequence, never dictionary/encoder order.
        #expect(text.hasPrefix(#"{"endpoint":"/v1/chat/completions","model":"openai/gpt-4o","requests":[{"custom_id":"req-0001","body":"#))

        let endpointRange = try #require(text.range(of: #""endpoint":"#))
        let modelRange = try #require(text.range(of: #""model":"#))
        let requestsRange = try #require(text.range(of: #""requests":"#))
        #expect(endpointRange.lowerBound < modelRange.lowerBound)
        #expect(modelRange.lowerBound < requestsRange.lowerBound)

        // Item order is preserved; results must never be matched by array
        // order, so submission order must round-trip intact.
        let firstID = try #require(text.range(of: "\"req-0001\""))
        let secondID = try #require(text.range(of: "\"req-0002\""))
        #expect(firstID.lowerBound < secondID.lowerBound)

        // Full-byte equality against the documented example, including the
        // `custom_id` before `body` item shape.
        let expected = #"{"endpoint":"/v1/chat/completions","model":"openai/gpt-4o","requests":[{"custom_id":"req-0001","body":{"messages":[{"content":"Summarize OpenRouter in one sentence.","role":"user"}]}},{"custom_id":"req-0002","body":{"messages":[{"content":"Second request.","role":"user"}]}}]}"#
        #expect(text == expected)
    }

    @Test("JSON string escaping survives serialization")
    func stringEscaping() throws {
        let customID = #"req "1"\x"#
        let bodyInput = #"quote " backslash \ newline"#
        let envelope = BatchEnvelope(
            endpoint: .responses,
            model: "openai/gpt-4o",
            requests: [BatchRequestItem(customID: customID, body: .object(["input": .string(bodyInput)]))]
        )
        let text = String(decoding: try OrderedBatchEnvelopeSerializer.serialize(envelope), as: UTF8.self)
        // The custom_id is reparseable JSON, so the parser never chokes.
        let value = JSONValue.parse(text)
        #expect(value != nil)
        #expect(text.contains(#""custom_id":"req \"1\"\\x""#))
    }

    @Test("envelope validation rejects empty, duplicate, and blank custom_ids before any network call")
    func envelopeValidation() {
        let emptyRequests = BatchEnvelope(endpoint: .messages, model: "m", requests: [])
        #expect(throws: BatchAdapterError.invalidEnvelope("requests must not be empty")) {
            try OrderedBatchEnvelopeSerializer.validate(emptyRequests)
        }

        let duplicate = BatchEnvelope(endpoint: .messages, model: "m", requests: [
            BatchRequestItem(customID: "req-1", body: .object([:])),
            BatchRequestItem(customID: "req-1", body: .object([:])),
        ])
        #expect(throws: BatchAdapterError.invalidEnvelope("duplicate custom_id: req-1")) {
            try OrderedBatchEnvelopeSerializer.validate(duplicate)
        }

        let blank = BatchEnvelope(endpoint: .messages, model: "m", requests: [
            BatchRequestItem(customID: "", body: .object([:])),
        ])
        #expect(throws: BatchAdapterError.invalidEnvelope("custom_id must not be empty")) {
            try OrderedBatchEnvelopeSerializer.validate(blank)
        }

        let noModel = BatchEnvelope(endpoint: .messages, model: "", requests: [
            BatchRequestItem(customID: "req-1", body: .object([:])),
        ])
        #expect(throws: BatchAdapterError.invalidEnvelope("model must not be empty")) {
            try OrderedBatchEnvelopeSerializer.validate(noModel)
        }
    }

    // MARK: Submit

    @Test("submit posts the ordered envelope to the beta base path and returns the 202-shaped record")
    func submitCapture() async throws {
        let fixture = """
        {
          "id": "batch_123",
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
        let (adapter, mock) = makeAdapter(responses: [.json(fixture)])
        let envelope = BatchEnvelope(
            endpoint: .chatCompletions,
            model: "openai/gpt-4o",
            requests: [BatchRequestItem(customID: "req-0001", body: .object(["input": .string("Hi")]))]
        )
        let record = try await adapter.submit(envelope)

        // 202 means queued/validating — NOT completed.
        #expect(record.batchStatus == .validating)
        #expect(record.batchStatus?.isTerminal == false)
        #expect(record.id == "batch_123")
        #expect(record.completionWindow == "24h")
        #expect(record.requestCounts?.total == 1)
        #expect(record.results == nil)

        let request = try #require(mock.sentRequests().first)
        let url = try #require(request.url)
        #expect(url.host == "openrouter.ai")
        // The beta base path sits OUTSIDE the /api/v1 policy.
        #expect(url.path == "/api/beta/batches")
        #expect(url.absoluteString.hasPrefix("https://openrouter.ai/api/beta/"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // The wire body is exactly the ordered serializer's bytes.
        let expectedBody = try OrderedBatchEnvelopeSerializer.serialize(envelope)
        #expect(request.httpBody == expectedBody)
        // The credential never leaks into the URL or the body.
        #expect(!url.absoluteString.contains("test-key"))
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("test-key"))
    }

    // MARK: Get (results inline)

    @Test("completed batch results arrive inline and match by custom_id, not array order")
    func resultsMatchByCustomID() async throws {
        // Results deliberately listed out of submission order (req-0003,
        // req-0001, req-0002) with one error-populated item.
        let fixture = """
        {
          "id": "batch_123",
          "object": "batch",
          "endpoint": "/v1/messages",
          "model": "anthropic/claude-3.5-sonnet",
          "completion_window": "24h",
          "status": "completed",
          "created_at": 1782097200,
          "finalized_at": 1782100800,
          "request_counts": {"total": 3, "completed": 2, "failed": 1},
          "usage": {"prompt_tokens": 20, "completion_tokens": 40, "total_tokens": 60, "cost": 0.000225, "is_byok": false},
          "results": [
            {
              "id": "batch_req_3",
              "custom_id": "req-0003",
              "response": null,
              "error": {"code": "invalid_request", "message": "per-item failure"}
            },
            {
              "id": "batch_req_1",
              "custom_id": "req-0001",
              "response": {"status_code": 200, "request_id": "request_1", "body": {"answer": "first"}},
              "error": null
            },
            {
              "id": "batch_req_2",
              "custom_id": "req-0002",
              "response": {"status_code": 200, "request_id": "request_2", "body": {"answer": "second"}},
              "error": null
            }
          ],
          "error": null
        }
        """
        let (adapter, mock) = makeAdapter(responses: [.json(fixture)])
        let record = try await adapter.batch(id: "batch_123")

        #expect(record.batchStatus == .completed)
        #expect(record.batchStatus?.isTerminal == true)

        // Results are read from the completed record itself — there is no
        // separate results-download endpoint, and none exists on the adapter.
        let results = try #require(record.results)
        #expect(results.count == 3)

        // Matched by custom_id, never by array position.
        let first = try #require(record.result(for: "req-0001"))
        #expect(first.id == "batch_req_1")
        #expect(first.succeeded)
        #expect(first.response?.body?.objectValue?["answer"]?.stringValue == "first")
        #expect(first.response?.requestID == "request_1")
        #expect(first.response?.statusCode == 200)

        let second = try #require(record.result(for: "req-0002"))
        #expect(second.response?.body?.objectValue?["answer"]?.stringValue == "second")

        // Per-item failure: exactly the error case is populated.
        let third = try #require(record.result(for: "req-0003"))
        #expect(!third.succeeded)
        #expect(third.response == nil)
        #expect(third.error?.objectValue?["message"]?.stringValue == "per-item failure")

        #expect(record.resultsByCustomID.count == 3)
        #expect(record.result(for: "missing") == nil)

        let request = try #require(mock.sentRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/beta/batches/batch_123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    // MARK: List

    @Test("list applies the documented query parameters, including repeated status filters")
    func listCapture() async throws {
        let fixture = """
        {
          "object": "list",
          "data": [
            {
              "id": "batch_9f2c1e",
              "object": "batch",
              "endpoint": "/v1/chat/completions",
              "model": "openai/gpt-4o",
              "completion_window": "24h",
              "status": "completed",
              "created_at": 1787836000,
              "finalized_at": 1787837000,
              "request_counts": {"total": 100, "completed": 100, "failed": 0},
              "usage": {"prompt_tokens": 51200, "completion_tokens": 20480, "total_tokens": 71680},
              "results": null,
              "error": null
            }
          ],
          "first_id": "batch_9f2c1e",
          "last_id": "batch_9f2c1e",
          "has_more": true
        }
        """
        let (adapter, mock) = makeAdapter(responses: [.json(fixture)])
        let list = try await adapter.list(
            limit: 2,
            after: "batch_9f2c1e",
            statuses: [.completed, .failed],
            createdAfter: "1787184000",
            createdBefore: "2026-08-20T00:00:00Z"
        )

        #expect(list.hasMore == true)
        #expect(list.firstID == "batch_9f2c1e")
        // List items carry metadata only — results always null.
        #expect(list.data?.first?.results == nil)
        #expect(list.data?.first?.usage?.totalTokens == 71680)

        let url = try #require(mock.sentRequests().first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        let values = { (name: String) in queryItems.filter { $0.name == name }.compactMap { $0.value } }
        #expect(values("limit") == ["2"])
        #expect(values("after") == ["batch_9f2c1e"])
        #expect(values("status") == ["completed", "failed"])
        #expect(values("created_after") == ["1787184000"])
        #expect(values("created_before") == ["2026-08-20T00:00:00Z"])
        #expect(components.percentEncodedQuery?.contains("%3D") == false)
    }

    @Test("transient statuses are rejected as list filters instead of being sent")
    func transientStatusFilterRejected() async {
        let (adapter, mock) = makeAdapter()
        await #expect {
            _ = try await adapter.list(statuses: [.finalizing])
        } throws: { error in
            if case BatchAdapterError.invalidEnvelope = error { return true }
            return false
        }
        #expect(mock.sentRequests().isEmpty)
    }

    // MARK: Delete

    @Test("deleting a terminal batch purges it and reports the documented outcome")
    func terminalDelete() async throws {
        let fixture = """
        {
          "id": "batch_123",
          "object": "batch",
          "deletion": {
            "openrouter": "deleted",
            "upstream": {"provider": "Anthropic", "status": "deleted"}
          }
        }
        """
        let (adapter, mock) = makeAdapter(responses: [.json(fixture)])
        let deletion = try await adapter.delete(id: "batch_123")
        #expect(deletion.deletion?.openrouter == "deleted")
        #expect(deletion.deletion?.upstream?.provider == "Anthropic")
        #expect(deletion.deletion?.upstream?.status == "deleted")

        let request = try #require(mock.sentRequests().first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/beta/batches/batch_123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test("deleting an in-flight batch maps the documented 409 into a typed error")
    func inFlightDeleteIs409() async {
        let (adapter, _) = makeAdapter(responses: [
            .status(409, #"{"error":{"message":"Batch is still in flight"}}"#),
        ])
        await #expect {
            _ = try await adapter.delete(id: "batch_inflight")
        } throws: { error in
            error as? BatchAdapterError == .inFlightBatchDeletion(batchID: "batch_inflight")
        }
    }

    @Test("batch IDs are percent-encoded path segments")
    func segmentEncoding() async throws {
        let fixture = #"{"id":"batch x","status":"completed"}"#
        let (adapter, mock) = makeAdapter(responses: [.json(fixture)])
        _ = try await adapter.batch(id: "batch 1&x")
        let url = try #require(mock.sentRequests().first?.url)
        #expect(url.path == "/api/beta/batches/batch 1&x")
        #expect(url.absoluteString == "https://openrouter.ai/api/beta/batches/batch%201%26x")
    }

    // MARK: Invariants

    @Test("batch IDs and filters never carry credentials; URLs stay on the beta path")
    func credentialNeverLeaksIntoURL() async throws {
        let (adapter, mock) = makeAdapter(responses: [
            .json(#"{"id":"batch_1","status":"completed","results":null}"#),
            .json(#"{"object":"list","data":[],"has_more":false}"#),
        ])
        _ = try await adapter.batch(id: "batch_1")
        _ = try await adapter.list(limit: 5)
        for request in mock.sentRequests() {
            let url = try #require(request.url)
            #expect(url.host == "openrouter.ai")
            #expect(url.path.hasPrefix("/api/beta/batches"))
            #expect(url.query?.contains("Bearer") != true)
            #expect(!url.absoluteString.contains("test-key"))
        }
    }
}
