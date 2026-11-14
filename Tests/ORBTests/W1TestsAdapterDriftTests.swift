import Foundation
import Testing
@testable import ORB

// TESTS-14: the advanced adapters follow the live public OpenAPI
// (https://openrouter.ai/openapi.json, fetched 2026-11-14): `/batches` sits
// under the production server `https://openrouter.ai/api/v1`, the batch
// endpoint enum includes `/v1/audio/speech`, batch records carry `provider`,
// `expires_at` and `output`, GET can return 402 with results withheld, and
// Messages/Responses usage report `cost`, `is_byok` and `cost_details`.

@Suite("W1 tests: adapter drift from live OpenAPI")
struct W1TestsAdapterDriftTests {
    @Test("Batch base path is /api/v1/batches for submit and get")
    func batchPath() async throws {
        #expect(BatchAdapter.base.absoluteString == "https://openrouter.ai/api/v1/batches")
        let mock = MockMediaTransport(responses: [
            .json(#"{"id":"batch_1","status":"validating"}"#),
            .json(#"{"id":"batch_1","status":"completed"}"#),
        ])
        let adapter = BatchAdapter(transport: mock)
        _ = try await adapter.submit(BatchEnvelope(endpoint: .chatCompletions, model: "m",
            requests: [BatchRequestItem(customID: "a", body: .object([:]))]))
        _ = try await adapter.batch(id: "batch_1")
        let paths = mock.sentRequests().compactMap { $0.url?.path }
        #expect(paths == ["/api/v1/batches", "/api/v1/batches/batch_1"])
    }

    @Test("Batch endpoint enum includes audio speech")
    func speechEndpoint() throws {
        #expect(BatchEndpoint.allCases.map(\.rawValue).contains("/v1/audio/speech"))
        let data = try OrderedBatchEnvelopeSerializer.serialize(BatchEnvelope(endpoint: .audioSpeech, model: "tts",
            requests: [BatchRequestItem(customID: "s", body: .object(["input": .string("hi")]))]))
        #expect(String(decoding: data, as: UTF8.self).hasPrefix(#"{"endpoint":"/v1/audio/speech","model":"tts""#))
    }

    @Test("Batch record decodes provider, expires_at and output")
    func recordFields() throws {
        let json = #"{"id":"b","object":"batch","status":"completed","provider":"Google Vertex","expires_at":1767225600,"output":{"uri":"gs://bucket/out"},"results":null}"#
        let record = try JSONDecoder().decode(BatchRecord.self, from: Data(json.utf8))
        #expect(record.provider == "Google Vertex")
        #expect(record.expiresAt == 1_767_225_600)
        #expect(record.output?.uri == "gs://bucket/out")
        let nullExpiry = try JSONDecoder().decode(BatchRecord.self, from: Data(#"{"id":"b","expires_at":null}"#.utf8))
        #expect(nullExpiry.expiresAt == nil)
    }

    @Test("402 on GET maps to payment-required with withheld-results copy")
    func paymentRequired() async throws {
        let mock = MockMediaTransport(responses: [.status(402, #"{"error":{"code":402,"message":"Insufficient credits"}}"#)])
        let adapter = BatchAdapter(transport: mock)
        do {
            _ = try await adapter.batch(id: "batch_9")
            Issue.record("Expected payment-required")
        } catch let error as BatchAdapterError {
            guard case .paymentRequired(let id, _) = error else {
                Issue.record("Unexpected \(error)"); return
            }
            #expect(id == "batch_9")
            #expect(error.localizedDescription.contains("withheld"))
            #expect(error.localizedDescription.contains("will not run again"))
        }
    }

    @Test("Messages usage decodes cost, BYOK and cost details; missing cost stays nil")
    func messagesUsageCost() throws {
        let json = #"{"id":"msg","type":"message","role":"assistant","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":3,"output_tokens":4,"cost":0.0012,"is_byok":false,"cost_details":{"upstream_inference_prompt_cost":0.0008,"upstream_inference_completions_cost":0.0004,"upstream_inference_cost":null}}}"#
        let response = try JSONDecoder().decode(MessagesAPIResponse.self, from: Data(json.utf8))
        let usage = try #require(response.usage)
        #expect(usage.cost == 0.0012)
        #expect(usage.isByok == false)
        #expect(usage.costDetails?.upstreamInferencePromptCost == 0.0008)
        #expect(usage.costDetails?.upstreamInferenceCost == nil)
        let bare = try JSONDecoder().decode(MessagesUsage.self, from: Data(#"{"input_tokens":1,"output_tokens":1}"#.utf8))
        #expect(bare.cost == nil)
    }

    @Test("Responses usage decodes cost and cost details")
    func responsesUsageCost() throws {
        let json = #"{"input_tokens":10,"output_tokens":25,"total_tokens":35,"cost":0.0012,"is_byok":true,"cost_details":{"upstream_inference_input_cost":0.0008,"upstream_inference_output_cost":0.0004}}"#
        let usage = try JSONDecoder().decode(ResponsesUsage.self, from: Data(json.utf8))
        #expect(usage.cost == 0.0012)
        #expect(usage.isByok == true)
        #expect(usage.costDetails?.upstreamInferenceOutputCost == 0.0004)
        let bare = try JSONDecoder().decode(ResponsesUsage.self, from: Data(#"{"input_tokens":1}"#.utf8))
        #expect(bare.cost == nil)
    }
}
