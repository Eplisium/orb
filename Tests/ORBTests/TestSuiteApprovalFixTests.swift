import Foundation
import Testing
@testable import ORB

@Suite("Test Suite approval integration", .serialized)
@MainActor
struct TestSuiteApprovalFixTests {
    @Test("Default project runner prompts and obeys the decision", arguments: ["approve", "deny", "cancel", "navigate", "hidden", "other-window"])
    func projectApproval(action: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orb-approval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = ProjectApprovalCounter()
        let runner = TestRunner(client: ProjectApprovalClient(), agentToolExecutor: { _ in
            await calls.increment()
            return .init(content: "Mock command result; nothing executed", isError: false)
        }, credential: { "fixture" }, saveResult: { _ in }, saveExperiment: { _ in }, outputRoot: directory)
        let hostID = UUID()
        if action != "hidden" { runner.registerApprovalHost(hostID) }
        let model = try JSONDecoder().decode(ModelInfo.self, from: Data(#"{"id":"fixture/tool","name":"Fixture","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["tools"]}"#.utf8))
        let scenario = TestScenario(id: "approval", category: .apiDesign, title: "Fixture",
            subtitle: "", icon: "doc", difficulty: .foundational, estimatedSeconds: 1,
            systemPrompt: "Build", userPrompt: "Create", evaluationCriteria: [])
        runner.start(scenario: scenario, modelIDs: [model.id], models: [model])
        if action != "hidden" {
            for _ in 0..<1000 where runner.approvalPresenter.queue.current == nil {
                try await Task.sleep(for: .milliseconds(2))
            }
            let prompt = try #require(runner.approvalPresenter.queue.current)
            #expect(await calls.value == 0)
            switch action {
            case "approve": runner.approvalPresenter.decide(prompt.id, .approved)
            case "deny": runner.approvalPresenter.decide(prompt.id, .denied)
            case "cancel": runner.cancel()
            case "other-window":
                let secondHost = UUID()
                runner.registerApprovalHost(secondHost)
                runner.unregisterApprovalHost(secondHost)
                #expect(runner.approvalHostID == hostID)
                #expect(runner.approvalPresenter.queue.current?.id == prompt.id)
                runner.approvalPresenter.decide(prompt.id, .approved)
            default: runner.unregisterApprovalHost(hostID)
            }
        }
        for _ in 0..<1000 where runner.isRunning {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!runner.isRunning)
        #expect(runner.approvalPresenter.queue.current == nil)
        #expect(await calls.value == (["approve", "other-window"].contains(action) ? 1 : 0))
    }
}

private actor ProjectApprovalCounter {
    var value = 0
    func increment() { value += 1 }
}
private actor ProjectApprovalClient: OpenRouterClientProtocol {
    private var turn = 0
    func stream(_ request: OpenRouterRequest) async throws -> AsyncThrowingStream<OpenRouterStreamEvent, Error> {
        turn += 1
        let first = turn == 1
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(.toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "fixture", type: "function", name: "run_command", arguments: #"{"command":"never-executed"}"#))
                continuation.yield(.finishReason(choiceIndex: 0, reason: "tool_calls"))
            } else {
                continuation.yield(.contentDelta(choiceIndex: 0, text: "Done."))
            }
            continuation.finish()
        }
    }
}
