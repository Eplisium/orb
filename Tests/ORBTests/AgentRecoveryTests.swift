import Foundation
import Testing
@testable import ORB

/// Client that fails a scripted number of times before answering.
private actor FlakyClient: OpenRouterClientProtocol {
    private var failures: [Error]
    private(set) var requests: [OpenRouterRequest] = []
    init(failures: [Error]) { self.failures = failures }

    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        requests.append(request)
        if !failures.isEmpty { throw failures.removeFirst() }
        return AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta(choiceIndex: 0, text: "done"))
            continuation.yield(.finishReason(choiceIndex: 0, reason: "stop"))
            continuation.finish()
        }
    }
}

private actor SleepLog {
    var delays: [Duration] = []
    func add(_ d: Duration) { delays.append(d) }
}

@Suite("Agent turn recovery")
struct AgentRecoveryTests {
    private let tls = OpenRouterClientError.transport("A TLS error caused the secure connection to fail.")

    private func run(_ client: FlakyClient, history: [AgentAPIMessage] = [], sleeps: SleepLog = SleepLog()) async throws -> NativeAgentRunResult {
        try await NativeAgentRunner.run(
            prompt: "go", modelId: "m", apiKey: "k", workspace: "/tmp", fullComputerAccess: false,
            history: history, client: client, maximumTurns: 3,
            recoverySleep: { await sleeps.add($0) },
            onEvent: { _ in })
    }

    @Test("a TLS failure is retried and the run completes")
    func retriesTLS() async throws {
        let client = FlakyClient(failures: [tls, tls])
        let sleeps = SleepLog()
        let result = try await run(client, sleeps: sleeps)
        #expect(result.response == "done")
        #expect(await client.requests.count == 3)
        #expect(await sleeps.delays.count == 2)
    }

    @Test("gives up after the retry ceiling with the original error")
    func givesUp() async {
        let client = FlakyClient(failures: Array(repeating: tls, count: 20))
        await #expect(throws: OpenRouterClientError.self) { _ = try await run(client) }
        #expect(await client.requests.count == AgentTurnRecovery.maxTransientRetries + 1)
    }

    @Test("HTTP 400 is retried once with replayed reasoning removed")
    func stripsReasoningOn400() async throws {
        let detail = ReasoningDetail(type: "reasoning.text", text: "hmm")
        let history = [AgentAPIMessage(role: "assistant", content: "earlier", reasoningDetails: [detail])]
        let client = FlakyClient(failures: [OpenRouterClientError.http(status: 400, message: "Provider returned error", retryAfter: nil)])
        let result = try await run(client, history: history)
        #expect(result.response == "done")
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages.contains { $0.reasoningDetails != nil })
        #expect(requests[1].messages.allSatisfy { $0.reasoningDetails == nil })
    }

    @Test("a second 400 is not retried forever")
    func secondFourHundredFails() async {
        let bad = OpenRouterClientError.http(status: 400, message: "Provider returned error", retryAfter: nil)
        let detail = ReasoningDetail(type: "reasoning.text", text: "hmm")
        let history = [AgentAPIMessage(role: "assistant", content: "earlier", reasoningDetails: [detail])]
        let client = FlakyClient(failures: [bad, bad, bad])
        await #expect(throws: OpenRouterClientError.self) { _ = try await run(client, history: history) }
        #expect(await client.requests.count == 2)
    }

    @Test("auth and credit errors fail immediately")
    func permanentErrorsFailFast() async {
        for status in [401, 402] {
            let client = FlakyClient(failures: [OpenRouterClientError.http(status: status, message: "no", retryAfter: nil)])
            await #expect(throws: OpenRouterClientError.self) { _ = try await run(client) }
            #expect(await client.requests.count == 1)
        }
    }

    @Test("classification")
    func classification() {
        #expect(AgentTurnRecovery.isTransient(URLError(.secureConnectionFailed)))
        #expect(AgentTurnRecovery.isTransient(OpenRouterClientError.abruptEOF))
        #expect(AgentTurnRecovery.isTransient(OpenRouterClientError.http(status: 503, message: "", retryAfter: nil)))
        #expect(!AgentTurnRecovery.isTransient(OpenRouterClientError.http(status: 401, message: "", retryAfter: nil)))
        #expect(!AgentTurnRecovery.isTransient(CancellationError()))
    }
}
