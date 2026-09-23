import Foundation
import Testing

@testable import ORB

// MARK: - W12: Experiment evaluation tests
//
// All tests are deterministic and offline: they synthesize responses and
// artifact directories, and never invoke the agent loop, the network, or any
// paid inference. Databases are isolated temp databases (`DatabaseManager()`).

@Suite("Experiment evaluation (W12)")
struct ExperimentEvaluationTests {

    // MARK: Helpers

    private func makeProjectDirectory(
        files: [String: String] = [:]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ORB-experiment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A large-enough index.html body.
    private var indexHTMLBody: String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><title>Nimbus</title>
        <style>:root { --accent: #6366f1; } body { margin: 0; font-family: system-ui; }
        header { position: sticky; top: 0; background: var(--accent); color: white; }
        .hero { background: linear-gradient(135deg, #6366f1, #8b5cf6); padding: 4rem; }
        .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; }
        @media (max-width: 768px) { .grid { grid-template-columns: 1fr; } }
        </style></head>
        <body><header><nav aria-label="Primary">Nimbus</nav></header>
        <section class="hero"><h1>Nimbus</h1><a href="#signup" class="cta">Get started</a></section>
        <section class="grid" id="features"><div>Fast</div><div>Simple</div><div>Secure</div></section>
        <footer><a href="https://example.com/social">Social</a></footer></body></html>
        """
    }

    private var webScenario: TestScenario {
        TestCatalog.scenario(id: "web-responsive-landing")!
    }

    // MARK: (a) Empty response fails checks

    @Test("empty response fails assertions and verdict")
    func emptyResponseFailsChecks() throws {
        let dir = try makeProjectDirectory() // nothing created at all
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "",
            usage: nil,
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )

        #expect(record.verdict == .failed)
        #expect(record.assertions.first(where: { $0.name == "nonEmptyResponse" })?.passed == false)
        #expect(record.artifactChecks.first(where: { $0.name == "atLeastOneFileCreated" })?.passed == false)
        // Completion status stays distinct from evaluation: the run DID complete.
        #expect(record.completionStatus == .completed)
    }

    // MARK: (b) Refusal phrasing fails checks

    @Test("refusal phrasing fails checks even when artifacts exist")
    func refusalFailsChecks() throws {
        let dir = try makeProjectDirectory(files: ["index.html": indexHTMLBody])
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "I'm unable to complete this task. I cannot complete a landing page for you.",
            usage: nil,
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )

        // Artifacts alone never outweigh a refusal.
        #expect(record.artifactChecksPassed)
        #expect(record.assertions.first(where: { $0.name == "noRefusalPhrasing" })?.passed == false)
        #expect(record.verdict == .failed)
        #expect(ResponseAssertions.isRefusal("Sorry, I can't help with that request."))
        #expect(!ResponseAssertions.isRefusal(indexHTMLBody))
    }

    // MARK: (c) Real artifacts pass

    @Test("response with real web artifacts passes")
    func realArtifactsPass() throws {
        let dir = try makeProjectDirectory(files: ["index.html": indexHTMLBody])
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "Created a responsive landing page with sticky nav, hero, feature grid, and footer.",
            usage: ChatUsage(promptTokens: 900, completionTokens: 3_500, totalTokens: 4_400, cost: 0.021),
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )

        #expect(record.verdict == .passed)
        #expect(record.artifactChecksPassed)
        #expect(record.assertionsPassed)
        #expect(record.spend.knownCostUSD == 0.021)
        #expect(record.spend.costIsKnown)
    }

    @Test("trivial stub index.html does not count as a web deliverable")
    func stubIndexHTMLFails() throws {
        let dir = try makeProjectDirectory(files: ["index.html": "<p>hi</p>"])
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "done",
            usage: nil,
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )

        #expect(record.artifactChecks.first(where: { $0.name == "webIndexHTMLPresent" })?.passed == false)
        #expect(record.verdict == .failed)
    }

    @Test("text-only success with no artifacts fails")
    func textOnlyResponseFails() throws {
        let dir = try makeProjectDirectory() // agent explained everything in text, created nothing
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "Here is the complete landing page code you asked for: <html>…</html>",
            usage: nil,
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )

        #expect(record.verdict == .failed)
        #expect(record.artifactChecksPassed == false)
    }

    // MARK: (d) Missing expected artifact fails

    @Test("missing declared expected artifact fails the checks")
    func missingExpectedArtifactFails() throws {
        let scenario = TestScenario(
            id: "test-game",
            category: .gameDevelopment,
            title: "Test Game",
            subtitle: "",
            icon: "gamecontroller",
            difficulty: .intermediate,
            estimatedSeconds: 30,
            systemPrompt: "s",
            userPrompt: "u",
            evaluationCriteria: [],
            expectedArtifacts: ["index.html", "game.js"]
        )
        let dir = try makeProjectDirectory(files: ["index.html": indexHTMLBody]) // game.js missing
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: scenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "Created the game.",
            usage: nil,
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )

        let missing = record.artifactChecks.first(where: { $0.name == "expectedArtifact:game.js" })
        #expect(missing?.passed == false)
        #expect(record.artifactChecks.first(where: { $0.name == "expectedArtifact:index.html" })?.passed == true)
        #expect(record.verdict == .failed)
    }

    // MARK: (e) Spend ceiling blocks the next run and records the refusal

    @Test("spend ceiling refuses the next run before any agent invocation")
    func spendCeilingBlocksNextRun() {
        var runner = ExperimentBatchRunner(
            approval: SpendApprovalToken(ceilingUSD: 0.50, note: "W12 test batch")
        )

        #expect(runner.beginRun(scenarioID: "s1", modelID: "m") == .allowed)

        let spentRun = ExperimentRunRecord(
            id: UUID(),
            scenarioID: "s1",
            scenarioTitle: "Scenario One",
            scenarioVersion: 1,
            categoryRawValue: TestCategory.webDevelopment.rawValue,
            modelID: "m",
            policy: ExperimentPolicySummary(
                presetName: "projectBuild",
                capabilities: ["approvedTerminal", "planning", "web", "workspaceRead", "workspaceWrite"],
                constrainsFilesystem: true
            ),
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            completionStatus: .completed,
            spend: ExperimentSpend(promptTokens: 1_000, completionTokens: 2_000, totalTokens: 3_000, knownCostUSD: 0.50),
            artifactChecks: [],
            assertions: [],
            verdict: .passed,
            errorMessage: nil,
            responseExcerpt: nil
        )
        runner.record(spentRun)

        // Ceiling reached: the next run is refused before it starts. No agent
        // invocation happens anywhere in this path — the gate is checked
        // before a run could ever be launched.
        let decision = runner.beginRun(scenarioID: "s2", modelID: "m")
        guard case .refused(let refusal) = decision else {
            Issue.record("Expected .refused, got \(decision)")
            return
        }
        #expect(refusal.scenarioID == "s2")
        #expect(refusal.ceilingUSD == 0.50)
        #expect(refusal.knownSpendUSD == 0.50)
        #expect(runner.refusals.count == 1)
        #expect(runner.records.count == 1) // no new run was recorded
    }

    // MARK: (f) Ceiling is money-based, not turn-based

    @Test("ceiling is money-based: huge token counts with zero known spend still run")
    func ceilingIsMoneyNotTurns() {
        var runner = ExperimentBatchRunner(
            approval: SpendApprovalToken(ceilingUSD: 1.00, note: "W12 test batch")
        )

        let expensiveInTurns = ExperimentRunRecord(
            id: UUID(),
            scenarioID: "s1",
            scenarioTitle: "Scenario One",
            scenarioVersion: 1,
            categoryRawValue: TestCategory.webDevelopment.rawValue,
            modelID: "m",
            policy: ExperimentPolicySummary(
                presetName: "projectBuild",
                capabilities: ["web"],
                constrainsFilesystem: true
            ),
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            completionStatus: .completed,
            // One million tokens across many turns, but zero reported cost.
            spend: ExperimentSpend(promptTokens: 400_000, completionTokens: 600_000, totalTokens: 1_000_000, knownCostUSD: 0.0),
            artifactChecks: [],
            assertions: [],
            verdict: .passed,
            errorMessage: nil,
            responseExcerpt: nil
        )
        runner.record(expensiveInTurns)

        #expect(runner.knownSpendUSD == 0.0)
        #expect(runner.beginRun(scenarioID: "s2", modelID: "m") == .allowed)
        #expect(runner.refusals.isEmpty)

        // A reported $0.00 cost is a KNOWN zero, not unknown.
        #expect(expensiveInTurns.spend.costIsKnown == true)

        // Unknown cost also cannot move a money counter; it is labelled
        // unknown on the record instead of zero, and never blocks a run.
        let unknownCost = ExperimentRunRecord(
            id: UUID(),
            scenarioID: "s3",
            scenarioTitle: "Scenario Three",
            scenarioVersion: 1,
            categoryRawValue: TestCategory.webDevelopment.rawValue,
            modelID: "m",
            policy: ExperimentPolicySummary(presetName: "projectBuild", capabilities: ["web"], constrainsFilesystem: true),
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 400),
            completionStatus: .completed,
            spend: ExperimentSpend(promptTokens: nil, completionTokens: nil, totalTokens: nil, knownCostUSD: nil),
            artifactChecks: [],
            assertions: [],
            verdict: .failed,
            errorMessage: nil,
            responseExcerpt: nil
        )
        runner.record(unknownCost)
        #expect(unknownCost.spend.costIsKnown == false)
        #expect(runner.beginRun(scenarioID: "s4", modelID: "m") == .allowed)
    }

    // MARK: (g) Cancelled/failed runs persist with spend + evidence

    @Test("cancelled run with reported usage keeps known spend; unknown spend stays unknown")
    func cancelledAndFailedRecordsKeepSpendLabels() throws {
        let db = DatabaseManager()

        // Cancelled with a usage block: spend is known.
        let usage = ChatUsage(promptTokens: 120, completionTokens: 40, totalTokens: 160, cost: 0.0023)
        let cancelled = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: nil,
            response: "",
            usage: usage,
            completionStatus: .cancelled,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 150),
            errorMessage: "Cancelled by user"
        )
        try db.saveExperimentRunRecordChecked(cancelled)

        // Failed with no usage block: spend must read unknown, not zero.
        let failed = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: nil,
            response: "",
            usage: nil,
            completionStatus: .failed,
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 310),
            errorMessage: "The network connection was lost."
        )
        try db.saveExperimentRunRecordChecked(failed)

        let loaded = db.loadExperimentRunRecords()
        #expect(loaded.count == 2)

        let loadedCancelled = loaded.first(where: { $0.completionStatus == .cancelled })
        #expect(loadedCancelled?.spend.knownCostUSD == 0.0023)
        #expect(loadedCancelled?.spend.totalTokens == 160)
        #expect(loadedCancelled?.spend.costIsKnown == true)
        #expect(loadedCancelled?.verdict == .failed) // cancelled never passes
        #expect(loadedCancelled?.errorMessage == "Cancelled by user")

        let loadedFailed = loaded.first(where: { $0.completionStatus == .failed })
        #expect(loadedFailed?.spend.knownCostUSD == nil) // unknown, NOT zero
        #expect(loadedFailed?.spend.costIsKnown == false)
        #expect(loadedFailed?.verdict == .failed)
        #expect(loadedFailed?.errorMessage == "The network connection was lost.")
    }

    // MARK: (h) DB round-trip

    @Test("experiment run record round-trips through the database")
    func databaseRoundTrip() throws {
        let db = DatabaseManager()
        let dir = try makeProjectDirectory(files: ["index.html": indexHTMLBody])
        defer { cleanup(dir) }

        let original = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "openai/gpt-test",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "Built the landing page.",
            usage: ChatUsage(promptTokens: 900, completionTokens: 3_500, totalTokens: 4_400, cost: 0.021),
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_120),
            errorMessage: nil
        )
        try db.saveExperimentRunRecordChecked(original)

        // A second, older record checks ordering (newest first).
        let older = ExperimentRunRecord(
            id: UUID(),
            scenarioID: "api-rest-pagination",
            scenarioTitle: "RESTful Pagination Design",
            scenarioVersion: 1,
            categoryRawValue: TestCategory.apiDesign.rawValue,
            modelID: "anthropic/test",
            policy: original.policy,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_600_000_050),
            completionStatus: .exhausted,
            spend: ExperimentSpend(promptTokens: nil, completionTokens: nil, totalTokens: 5_000, knownCostUSD: nil),
            artifactChecks: [ArtifactCheckResult(name: "atLeastOneFileCreated", passed: true, detail: "1 file(s).")],
            assertions: [AssertionResult(name: "nonEmptyResponse", passed: true, detail: "ok")],
            verdict: .failed,
            errorMessage: "Turn budget spent",
            responseExcerpt: "partial…"
        )
        try db.saveExperimentRunRecordChecked(older)

        let loaded = db.loadExperimentRunRecords()
        #expect(loaded.count == 2)
        #expect(loaded.first?.id == original.id) // newest started_at first
        #expect(loaded.first == original)
        #expect(loaded.dropFirst().first == older)
    }

    // MARK: (i) Export JSON is stable/ordered

    @Test("export JSON is deterministic, ordered, and round-trips")
    func exportJSONIsStableAndOrdered() throws {
        func makeRecord(id: UUID, scenarioID: String, startedAt: TimeInterval) -> ExperimentRunRecord {
            ExperimentRunRecord(
                id: id,
                scenarioID: scenarioID,
                scenarioTitle: "Title \(scenarioID)",
                scenarioVersion: 1,
                categoryRawValue: TestCategory.webDevelopment.rawValue,
                modelID: "test/model",
                policy: ExperimentPolicySummary(
                    presetName: "projectBuild",
                    capabilities: ["approvedTerminal", "planning", "web"],
                    constrainsFilesystem: true
                ),
                startedAt: Date(timeIntervalSince1970: startedAt),
                finishedAt: Date(timeIntervalSince1970: startedAt + 10),
                completionStatus: .completed,
                spend: ExperimentSpend(promptTokens: 10, completionTokens: 20, totalTokens: 30, knownCostUSD: 0.001),
                artifactChecks: [
                    ArtifactCheckResult(name: "atLeastOneFileCreated", passed: true, detail: "1 file(s)."),
                    ArtifactCheckResult(name: "webIndexHTMLPresent", passed: true, detail: "index.html exists."),
                ],
                assertions: [
                    AssertionResult(name: "nonEmptyResponse", passed: true, detail: "ok"),
                    AssertionResult(name: "noRefusalPhrasing", passed: true, detail: "clean"),
                ],
                verdict: .passed,
                errorMessage: nil,
                responseExcerpt: "Built it."
            )
        }

        let a = makeRecord(id: UUID(), scenarioID: "alpha", startedAt: 100)
        let b = makeRecord(id: UUID(), scenarioID: "beta", startedAt: 200)
        let refusal = SpendRefusal(
            id: UUID(),
            scenarioID: "gamma",
            modelID: "test/model",
            ceilingUSD: 0.50,
            knownSpendUSD: 0.50,
            requestedAt: Date(timeIntervalSince1970: 300),
            reason: "ceiling reached"
        )

        func canonical(_ json: String) throws -> Data {
            // Drop exportedAt so two encodes a second apart still compare equal.
            let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            var mutable = object
            mutable["exportedAt"] = nil
            return try JSONSerialization.data(withJSONObject: mutable, options: [.sortedKeys])
        }

        // Same logical batch in different input order → same canonical export.
        let forward = try ExperimentExport.encodeJSON(records: [a, b], refusals: [refusal])
        let backward = try ExperimentExport.encodeJSON(records: [b, a], refusals: [refusal])
        #expect(try canonical(forward) == canonical(backward))

        // Records come out sorted by startedAt regardless of input order.
        #expect(forward.contains("alpha") && forward.contains("beta"))
        let alphaRange = try #require(forward.range(of: "\"scenarioID\" : \"alpha\"")?.lowerBound)
        let betaRange = try #require(forward.range(of: "\"scenarioID\" : \"beta\"")?.lowerBound)
        #expect(alphaRange < betaRange)

        // Decoding the export returns the same records.
        let decoded = try ExperimentExport.decodeJSON(forward)
        #expect(decoded == [a, b])
    }

    // MARK: (j) Scenario version + policy recorded on every record

    @Test("scenario version and policy summary are recorded on every record")
    func versionAndPolicyRecordedEverywhere() throws {
        let dir = try makeProjectDirectory(files: ["index.html": indexHTMLBody])
        defer { cleanup(dir) }

        let completed = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "Built it.",
            usage: nil,
            completionStatus: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )
        let cancelled = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: nil,
            response: "",
            usage: nil,
            completionStatus: .cancelled,
            startedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 350),
            errorMessage: "Cancelled by user"
        )

        for record in [completed, cancelled] {
            #expect(record.scenarioVersion == webScenario.version)
            #expect(record.scenarioID == webScenario.id)
            #expect(record.policy.presetName == "projectBuild")
            #expect(record.policy.constrainsFilesystem == true)
            #expect(record.policy.capabilities == record.policy.capabilities.sorted())
            #expect(record.policy.capabilities.contains("approvedTerminal"))
            #expect(!record.policy.capabilities.contains("computerControl"))
        }

        // Every catalog scenario carries a version tag and the custom-test
        // conversion path preserves the additive defaults.
        #expect(TestCatalog.allScenarios.allSatisfy { $0.version >= 1 })
        #expect(TestCatalog.allScenarios.count == 22)
    }

    // MARK: Verdict independence from completion status

    @Test("cancelled run with perfect artifacts still fails the verdict")
    func cancelledNeverPasses() throws {
        let dir = try makeProjectDirectory(files: ["index.html": indexHTMLBody])
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "Partially built…",
            usage: ChatUsage(promptTokens: 500, completionTokens: 1_000, totalTokens: 1_500, cost: 0.01),
            completionStatus: .cancelled,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 150),
            errorMessage: "Cancelled by user"
        )

        #expect(record.artifactChecksPassed) // artifacts exist
        #expect(record.verdict == .failed) // but the run did not complete
    }

    @Test("exhausted (budget-spent) run that produced artifacts is still not a pass")
    func exhaustedRunIsNotAPass() throws {
        let dir = try makeProjectDirectory(files: ["index.html": indexHTMLBody])
        defer { cleanup(dir) }

        let record = ExperimentEvaluation.record(
            scenario: webScenario,
            modelID: "test/model",
            policy: .projectBuild,
            projectDirectory: dir,
            response: "Summary of partial work…",
            usage: ChatUsage(promptTokens: 5_000, completionTokens: 9_000, totalTokens: 14_000, cost: 0.12),
            completionStatus: .exhausted,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            errorMessage: "Turn budget spent"
        )

        #expect(record.completionStatus == .exhausted)
        #expect(record.verdict == .failed)
        #expect(record.spend.knownCostUSD == 0.12)
    }
}
