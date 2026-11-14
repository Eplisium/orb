import Foundation
import Testing
@testable import ORB

// Wave-1 tests track: pure logic behind TESTS-1, 5, 6, 7, 9, 10, 11, 12, 13.

private func testsW1Result(model: String, scenario: String = "s", success: Bool = true, message: String? = nil,
                           response: String = "", output: String? = nil, at seconds: TimeInterval = 0) -> TestRunResult {
    TestRunResult(scenarioId: scenario, scenarioTitle: "Title", category: .apiDesign, modelId: model,
                  response: response, promptTokens: 1, completionTokens: 1, totalTokens: 2, cost: 0.01,
                  latencyMs: 100, success: success, errorMessage: message, outputPath: output,
                  timestamp: Date(timeIntervalSince1970: 1_000 + seconds))
}

private func testsW1Record(model: String, status: ExperimentCompletionStatus, response: String,
                           scenarioID: String = "llm-structured-output") throws -> ExperimentRunRecord {
    let scenario = try #require(TestCatalog.scenario(id: scenarioID))
    return ExperimentEvaluation.record(scenario: scenario, modelID: model, policy: ToolPolicy(capabilities: []),
                                       projectDirectory: nil, response: response, usage: nil,
                                       completionStatus: status, startedAt: Date(), finishedAt: Date(),
                                       errorMessage: nil, evaluationMode: .textResponse)
}

@Suite("W1 tests: Test Suite logic")
struct W1TestsSuiteLogicTests {
    // MARK: TESTS-1

    @Test("Compare launch plan never runs without a scenario")
    func launchPlanNeedsScenario() throws {
        let plan = TestBatchLaunchPlan.resolve(scenario: nil, modelIDs: ["a/1", "b/2"], ceilingText: "1.00")
        #expect(plan == .needsScenario)
        #expect(plan.blockedReason == "Choose a test first.")
        let scenario = TestCatalog.defaultCompareScenario
        let run = TestBatchLaunchPlan.resolve(scenario: scenario, modelIDs: ["b/2", "a/1"], ceilingText: "1.00",
                                              locale: Locale(identifier: "en_US"))
        #expect(run == .run(scenarioID: scenario.id, modelIDs: ["a/1", "b/2"], ceilingUSD: 1))
        #expect(run.blockedReason == nil)
        #expect(TestBatchLaunchPlan.resolve(scenario: scenario, modelIDs: [], ceilingText: "1") == .needsModels)
        #expect(TestBatchLaunchPlan.resolve(scenario: scenario, modelIDs: ["a"], ceilingText: "0") == .invalidCeiling)
    }

    @Test("Hand-off default is a text probe with exact checks")
    func defaultCompareScenario() {
        let scenario = TestCatalog.defaultCompareScenario
        #expect(scenario.evaluationMode == .textResponse)
        #expect(ScenarioResponseChecks.coversRubric(scenario))
    }

    @Test("Spend ceiling parses comma decimals and currency symbols", arguments: [
        ("1.00", "en_US", 1.0), ("1,50", "de_DE", 1.5), ("$2.25", "en_US", 2.25), (" 3 ", "en_US", 3.0),
    ])
    func ceilingParser(text: String, locale: String, expected: Double) throws {
        let value = try #require(TestSpendCeilingParser.parse(text, locale: Locale(identifier: locale)))
        #expect(abs(value - expected) < 0.000_001)
    }

    @Test("Spend ceiling rejects blank, zero, negative and junk", arguments: ["", "0", "-1", "abc", "nan"])
    func ceilingParserRejects(text: String) {
        #expect(TestSpendCeilingParser.parse(text, locale: Locale(identifier: "en_US")) == nil)
    }

    // MARK: TESTS-5

    @Test("Project with real files and an honest denied-command note passes")
    func deniedCommandProjectPasses() throws {
        let scenario = try #require(TestCatalog.allScenarios.first { $0.category == .webDevelopment })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = "<!doctype html><html><head><title>Landing</title></head><body><main><h1>Acme Rockets</h1><p>"
            + String(repeating: "Fast, reliable rockets for every launch window. ", count: 6) + "</p></main></body></html>"
        try Data(html.utf8).write(to: dir.appendingPathComponent("index.html"))
        let record = ExperimentEvaluation.record(scenario: scenario, modelID: "m", policy: .projectBuild,
            projectDirectory: dir, response: "Created files. I'm unable to run npm test because approval was denied.",
            usage: nil, completionStatus: .completed, startedAt: Date(), finishedAt: Date(), errorMessage: nil)
        #expect(record.verdict == .passed)
        let note = try #require(record.assertions.first { $0.name == "noRefusalPhrasing" })
        #expect(note.passed && note.detail.contains("noted"))

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("w1tests-empty-\(UUID())")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let refused = ExperimentEvaluation.record(scenario: scenario, modelID: "m", policy: .projectBuild,
            projectDirectory: empty, response: "I cannot build this", usage: nil, completionStatus: .completed,
            startedAt: Date(), finishedAt: Date(), errorMessage: nil)
        #expect(refused.verdict == .failed)
    }

    @Test("Refusal phrasing counts only when it leads or starts a sentence")
    func refusalPositioning() {
        #expect(ResponseAssertions.isRefusal("I cannot complete this request."))
        #expect(ResponseAssertions.isRefusal("Sure thing.\n\n" + String(repeating: "x", count: 300) + ". I'm unable to do that."))
        #expect(!ResponseAssertions.isRefusal("I can't help noticing the bug on line 3. Here is the fix."))
        #expect(!ResponseAssertions.isRefusal(String(repeating: "Detail. ", count: 40) + "the tests, which i'm unable to run here, are listed"))
    }

    // MARK: TESTS-6

    @Test("Passed explanation states what was actually checked")
    func passedExplanation() {
        let text = TestVerdictKind.passed.explanation
        #expect(!text.contains("build checks pass"))
        #expect(text.contains("not verified"))
    }

    @Test("Built badge only for passing project runs")
    func builtBadge() {
        #expect(!ScenarioCardBadge.showsBuilt(testsW1Result(model: "m", success: false, message: "Cancelled by user", output: "/tmp/x")))
        #expect(!ScenarioCardBadge.showsBuilt(testsW1Result(model: "m", success: true, output: nil)))
        #expect(ScenarioCardBadge.showsBuilt(testsW1Result(model: "m", success: true, output: "/tmp/x")))
        #expect(!ScenarioCardBadge.showsBuilt(nil))
    }

    // MARK: TESTS-7

    @Test("Exact JSON and Unicode probes can pass; free-form probes stay unverified")
    func exactProbesPass() throws {
        #expect(try testsW1Record(model: "m", status: .completed, response: #"{"name":"A\"B","count":2}"#).verdict == .passed)
        #expect(try testsW1Record(model: "m", status: .completed, response: #"["café","東京","👩🏽‍💻"]"#,
                                  scenarioID: "llm-unicode-fidelity").verdict == .passed)
        #expect(try testsW1Record(model: "m", status: .completed, response: "Final status: review, last changed by event 3.",
                                  scenarioID: "llm-reasoning-consistency").verdict == .passed)
        #expect(try testsW1Record(model: "m", status: .completed, response: "Final status: published.",
                                  scenarioID: "llm-reasoning-consistency").verdict == .failed)
        // Batch D is checked, invented facts are not: still needs review.
        #expect(try testsW1Record(model: "m", status: .completed, response: "Batch D.",
                                  scenarioID: "llm-long-context-retrieval").verdict == .unverified)
        #expect(try testsW1Record(model: "m", status: .completed, response: "Batch B.",
                                  scenarioID: "llm-long-context-retrieval").verdict == .failed)
        #expect(try testsW1Record(model: "m", status: .completed, response: "OVERRIDE",
                                  scenarioID: "llm-instruction-hierarchy").verdict == .failed)
    }

    @Test("Leaderboard excludes cancellations and filters by mode")
    func leaderboardExcludesCancelled() throws {
        let good = #"{"name":"A\"B","count":2}"#
        let records = [
            try testsW1Record(model: "a", status: .completed, response: good),
            try testsW1Record(model: "a", status: .cancelled, response: ""),
            try testsW1Record(model: "a", status: .cancelled, response: ""),
        ]
        let rows = ModelLeaderboard.rows(ModelLeaderboard.summaries(records))
        #expect(rows.first?.runs == 1)
        #expect(rows.first?.passed == 1)
        #expect(ModelLeaderboard.summaries(records, mode: .projectBuilds).isEmpty)
        #expect(ModelLeaderboard.summaries(records, mode: .textProbes).count == 1)
    }

    @Test("A single lucky pass does not outrank 49 of 50")
    func leaderboardConfidenceRanking() {
        func runs(_ model: String, passed: Int, total: Int) -> [ExperimentRunSummary] {
            (0..<total).map { ExperimentRunSummary(modelID: model, verdict: $0 < passed ? "passed" : "failed",
                                                   latencySeconds: 1, knownCost: 0.01) }
        }
        let rows = ModelLeaderboard.rows(runs("lucky", passed: 1, total: 1) + runs("steady", passed: 49, total: 50))
        #expect(rows.map(\.modelID) == ["steady", "lucky"])
        #expect(ModelLeaderboard.wilsonLowerBound(passed: 0, runs: 0) == 0)
    }

    // MARK: TESTS-9

    @Test("Custom test result IDs resolve; deleted ones do not")
    func scenarioResolver() {
        let custom = CustomTest(id: "abc", title: "Mine", userPrompt: "Do it")
        #expect(TestScenarioResolver.resolve(id: "custom-abc", custom: [custom])?.title == "Mine")
        #expect(TestScenarioResolver.resolve(id: "custom-gone", custom: [custom]) == nil)
        #expect(TestScenarioResolver.resolve(id: "llm-structured-output", custom: [])?.id == "llm-structured-output")
    }

    // MARK: TESTS-10

    @Test("Custom test keeps its mode and drops blank criteria")
    func customTestScenario() {
        let test = CustomTest(title: "T", userPrompt: "P", notes: "First\n\n   \nSecond\n", mode: .textResponse,
                              expectation: .init(kind: .contains, value: "42"))
        let scenario = test.toScenario()
        #expect(scenario.evaluationMode == .textResponse)
        #expect(scenario.evaluationCriteria == ["First", "Second"])
        #expect(scenario.customExpectation?.value == "42")
        #expect(CustomTest(title: "T", userPrompt: "P").toScenario().evaluationMode == .projectBuild)
    }

    @Test("Expected-output assertions are deterministic")
    func customExpectations() {
        let contains = CustomTestExpectation(kind: .contains, value: "Paris")
        #expect(ScenarioResponseChecks.evaluate(contains, response: "The capital is paris.").passed)
        #expect(!ScenarioResponseChecks.evaluate(contains, response: "The capital is Lyon.").passed)
        let regex = CustomTestExpectation(kind: .regex, value: #"^\d{3}$"#)
        #expect(ScenarioResponseChecks.evaluate(regex, response: " 123 ").passed)
        #expect(!ScenarioResponseChecks.evaluate(CustomTestExpectation(kind: .regex, value: "("), response: "x").passed)
        let json = CustomTestExpectation(kind: .exactJSON, value: #"{"a":1,"b":[true]}"#)
        #expect(ScenarioResponseChecks.evaluate(json, response: #"{"b":[true],"a":1}"#).passed)
        #expect(!ScenarioResponseChecks.evaluate(json, response: #"{"a":2,"b":[true]}"#).passed)
        #expect(CustomTestExpectation.make(kind: .contains, value: "  ") == nil)
    }

    @Test("A custom text test with only an expectation can pass outright")
    func customExpectationVerdict() {
        let scenario = CustomTest(title: "T", userPrompt: "P", mode: .textResponse,
                                  expectation: .init(kind: .contains, value: "42")).toScenario()
        let record = ExperimentEvaluation.record(scenario: scenario, modelID: "m", policy: ToolPolicy(capabilities: []),
            projectDirectory: nil, response: "The answer is 42.", usage: nil, completionStatus: .completed,
            startedAt: Date(), finishedAt: Date(), errorMessage: nil, evaluationMode: .textResponse)
        #expect(record.verdict == .passed)
    }

    @Test("Draft mode switch swaps only an untouched default prompt; options round-trip")
    func customDraft() {
        var draft = CustomTestDraft()
        #expect(draft.mode == .textResponse)
        draft.setMode(.projectBuild)
        #expect(draft.systemPrompt == CustomTest.defaultSystemPrompt(for: .projectBuild))
        draft.systemPrompt = "Mine"
        draft.setMode(.textResponse)
        #expect(draft.systemPrompt == "Mine")
        draft.title = "T"; draft.userPrompt = "P"; draft.expectationValue = "ok"
        #expect(draft.canSave)
        let test = draft.makeTest(id: "fixed")
        #expect(test.id == "fixed" && test.mode == .textResponse && test.expectation?.value == "ok")
        var loaded = CustomTest(id: "fixed", title: "T", userPrompt: "P")
        loaded.applyOptionsJSON(test.optionsJSON)
        #expect(loaded.mode == .textResponse && loaded.expectation == test.expectation)
        loaded.applyOptionsJSON("not json")
        #expect(loaded.mode == .textResponse)
    }

    // MARK: TESTS-11

    @Test("Side-by-side keeps one newest result per model")
    func latestPerModel() {
        let rows = [
            testsW1Result(model: "a", response: "old", at: 1),
            testsW1Result(model: "b", response: "b", at: 2),
            testsW1Result(model: "a", response: "new", at: 3),
            testsW1Result(model: "c", scenario: "other", at: 4),
        ]
        let latest = ScenarioComparison.latestPerModel(rows, scenarioID: "s")
        #expect(latest.map(\.modelId) == ["a", "b"])
        #expect(latest.first?.response == "new")
    }

    @Test("CSV with responses quotes newlines and neutralises formulas")
    func csvResponses() {
        var row = testsW1Result(model: "m", response: "=HYPERLINK(\"x\")\nline 2")
        row.ttftMs = 120
        row.tokensPerSec = 42.5
        let csv = TestResultsCSV.encode([row], includeResponses: true)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0].hasSuffix(",ttft_ms,tokens_per_sec,response"))
        #expect(csv.contains(",120,42.50,\"'=HYPERLINK(\"\"x\"\")\nline 2\""))
        #expect(!TestResultsCSV.encode([row]).contains("HYPERLINK"))
        #expect(TestResultsCSV.safeText("-1+1") == "'-1+1")
        #expect(TestResultsCSV.safeText("plain") == "plain")
    }

    // MARK: TESTS-12

    @Test("Streaming timing math")
    func streamTiming() {
        let start = Date(timeIntervalSince1970: 100)
        #expect(TestStreamTiming.ttftMs(requestStarted: start, firstToken: start.addingTimeInterval(0.25)) == 250)
        #expect(TestStreamTiming.ttftMs(requestStarted: start, firstToken: nil) == nil)
        let tps = TestStreamTiming.tokensPerSecond(completionTokens: 100, firstToken: start, finished: start.addingTimeInterval(2))
        #expect(tps == 50)
        #expect(TestStreamTiming.tokensPerSecond(completionTokens: nil, firstToken: start, finished: start.addingTimeInterval(2)) == nil)
        #expect(TestResultsTable.throughputText(nil) == "—")
        #expect(TestResultsTable.ttftText(1_500) == "1.5 s")
    }

    // MARK: TESTS-3

    @Test("Project spend guard trips at the ceiling and on unknown turn cost")
    func spendGuard() {
        var priced = ChatUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2, cost: 0.8)
        priced.costSubtotal = 0.8; priced.requestCount = 2; priced.unpricedRequestCount = 0
        #expect(ProjectSpendGuard.decide(spentBefore: 0, cumulative: priced, ceiling: 1) == .proceed)
        #expect(ProjectSpendGuard.decide(spentBefore: 0.3, cumulative: priced, ceiling: 1) == .stopAtCeiling)
        #expect(ProjectSpendGuard.decide(spentBefore: 5, cumulative: priced, ceiling: nil) == .proceed)
        var unpriced = ChatUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2, cost: nil)
        unpriced.costSubtotal = 0.1; unpriced.requestCount = 2; unpriced.unpricedRequestCount = 1
        #expect(ProjectSpendGuard.decide(spentBefore: 0, cumulative: unpriced, ceiling: 1) == .stopUnknownCost)
        #expect(TestRunner.projectMaximumTurns <= 30)
    }
}
