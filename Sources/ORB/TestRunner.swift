import AppKit
import Foundation
import SwiftUI

// Test Suite execution and model routing.

// MARK: - Test Runner

/// Composes the prompt a test run sends, layering the user's optional
/// run-specific input on top of the scenario's fixed prompt. Pure and
/// side-effect free so the composition rules are unit-testable.
enum TestPromptComposer {
    /// Appends `userInput` to `base` under a clear "user input" heading.
    /// Blank or whitespace-only input leaves `base` untouched — a run with
    /// no input must be byte-identical to the stock scenario prompt.
    static func compose(base: String, userInput: String?) -> String {
        let trimmed = userInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return base }
        return base + "\n\nUser input for this run:\n" + trimmed
    }
}

enum TestModelRoute: Equatable {
    case text, project

    static func resolve(_ model: ModelInfo) -> Self? {
        guard model.inputModalities.contains("text"),
              model.outputModalities.contains("text"), !model.hasExpired else { return nil }
        return model.supportsTools ? .project : .text
    }
}

enum TestBatchSelection {
    static let maximumModels = 5

    static func eligibleIDs(_ ids: [String], catalog: [ModelInfo]) -> [String] {
        let lookup = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ids.filter { id in
            guard seen.insert(id).inserted, let model = lookup[id] else { return false }
            return TestModelRoute.resolve(model) != nil
        }
    }
}

@MainActor
final class TestRunner: ObservableObject {
    static let unverifiedMessage = "Text response received; scenario criteria require review."
    @Published var results: [TestRunResult] = []
    @Published var isRunning = false
    @Published var runningScenarioId: String?
    @Published var activityLabel = ""
    @Published var activityLog: [ActivityEntry] = []
    @Published var runningModelId: String?
    @Published var batchCompleted = 0
    @Published var batchTotal = 0
    /// Known spend and the active ceiling for the current batch, for the progress bar.
    @Published var batchSpent = 0.0
    @Published var batchCeilingUSD: Double?
    @Published var batchUnreportedRuns = 0
    @Published var batchNotice: String?
    /// Total stored results; `results` may hold only the newest page.
    @Published var totalResultCount = 0
    /// True once the user asked for every stored result.
    @Published var showsAllResults = false

    typealias AgentRun = (String, String, String, URL, String, @escaping @MainActor (String) -> Void) async throws -> NativeAgentRunResult
    private let client: any OpenRouterClientProtocol
    private let agentRun: AgentRun
    private let credential: () -> String?
    private let saveResult: (TestRunResult) -> Void
    private let saveExperiment: (ExperimentRunRecord) -> Void
    private let outputRoot: URL
    private var activeTask: Task<Void, Never>?
    private var cancellationRequested = false
    private var reportedCostForLastRun: Double?

    init(
        client: any OpenRouterClientProtocol = OpenRouterClient(),
        agentRun: @escaping AgentRun = { prompt, modelID, key, directory, systemPrompt, activity in
            try await NativeAgentRunner.run(
                prompt: prompt, modelId: modelID, apiKey: key,
                workspace: directory.path, fullComputerAccess: false, history: [],
                systemPromptOverride: systemPrompt, policy: .projectBuild, onActivity: activity
            )
        },
        credential: @escaping () -> String? = { KeychainManager.getAPIKey() },
        saveResult: @escaping (TestRunResult) -> Void = { DatabaseManager.shared.saveTestResult($0) },
        saveExperiment: @escaping (ExperimentRunRecord) -> Void = { DatabaseManager.shared.saveExperimentRunRecord($0) },
        outputRoot: URL? = nil
    ) {
        self.client = client
        self.agentRun = agentRun
        self.credential = credential
        self.saveResult = saveResult
        self.saveExperiment = saveExperiment
        self.outputRoot = outputRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ORB/TestProjects", isDirectory: true)
    }

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let text: String
        let icon: String
    }

    /// Loads the newest page of results (or all, after "Load all").
    func loadSavedResults() {
        let db = DatabaseManager.shared
        results = showsAllResults ? db.loadAllTestResults() : db.loadTestResults()
        totalResultCount = max(db.countTestResults(), results.count)
    }

    func loadAllResults() {
        showsAllResults = true
        loadSavedResults()
    }

    func clearResults() {
        results.removeAll()
        totalResultCount = 0
    }

    /// Synchronous ownership prevents duplicate starts across UI Tasks.
    func start(scenario: TestScenario, modelIDs: [String], models: [ModelInfo], userInput: String? = nil,
               ceilingUSD: Double? = nil) {
        start(plan: [(scenario, modelIDs)], models: models, userInput: userInput, ceilingUSD: ceilingUSD)
    }

    /// Runs several (scenario, models) batches back to back — used by
    /// "Rerun failed/unverified". Each batch obeys the model cap; the spend
    /// ceiling and unknown-cost stop apply across the whole plan.
    func start(plan rawPlan: [(scenario: TestScenario, modelIDs: [String])], models: [ModelInfo],
               userInput: String? = nil, ceilingUSD: Double? = nil) {
        guard !isRunning else { return }
        let plan = rawPlan.map { ($0.scenario, TestBatchSelection.eligibleIDs($0.modelIDs, catalog: models)) }
            .filter { !$0.1.isEmpty }
        guard !plan.isEmpty else { batchNotice = "No eligible text-output models selected."; return }
        guard plan.allSatisfy({ $0.1.count <= TestBatchSelection.maximumModels }) else {
            batchNotice = "Select at most \(TestBatchSelection.maximumModels) models."; return
        }
        if let ceilingUSD, (!ceilingUSD.isFinite || ceilingUSD <= 0) {
            batchNotice = "Enter a positive spend ceiling."; return
        }
        let requested = rawPlan.reduce(0) { $0 + $1.modelIDs.count }
        let total = plan.reduce(0) { $0 + $1.1.count }
        batchNotice = total == requested ? nil : "Duplicate or unsupported models were omitted."
        isRunning = true
        cancellationRequested = false
        runningScenarioId = plan[0].0.id
        batchCompleted = 0
        batchTotal = total
        batchSpent = 0
        batchUnreportedRuns = 0
        batchCeilingUSD = ceilingUSD
        activeTask = Task { [weak self] in
            guard let self else { return }
            var spent = 0.0
            planLoop: for (scenario, ids) in plan {
                self.runningScenarioId = scenario.id
                let prompt = TestPromptComposer.compose(base: scenario.userPrompt, userInput: userInput)
                for id in ids {
                    if Task.isCancelled || self.cancellationRequested { break planLoop }
                    if let ceilingUSD, spent >= ceilingUSD {
                        self.batchNotice = "Spend ceiling reached; remaining models skipped. One request may exceed the ceiling."
                        break planLoop
                    }
                    self.runningModelId = id
                    self.activityLabel = "Starting \(id)…"
                    self.activityLog.removeAll()
                    let result = await self.execute(scenario: scenario, modelID: id, models: models, prompt: prompt)
                    self.results.insert(result, at: 0)
                    self.totalResultCount += 1
                    self.saveResult(result)
                    self.batchCompleted += 1
                    if Task.isCancelled || self.cancellationRequested { break planLoop }
                    if ceilingUSD != nil {
                        guard let cost = self.reportedCostForLastRun else {
                            self.batchUnreportedRuns += 1
                            self.batchNotice = "Provider did not report cost; remaining models skipped."
                            break planLoop
                        }
                        spent += cost
                        self.batchSpent = spent
                    }
                }
            }
            self.runningModelId = nil
            self.runningScenarioId = nil
            self.activityLabel = ""
            self.isRunning = false
            self.activeTask = nil
            StudioNotifier.shared.finished(section: SidebarSection.testSuite.rawValue, title: "Test run finished", body: "\(self.batchCompleted) of \(self.batchTotal) model run\(self.batchTotal == 1 ? "" : "s") completed.")
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        activeTask?.cancel()
        batchNotice = "Cancelling; unstarted models skipped."
    }

    func run(scenario: TestScenario, modelId: String, models: [ModelInfo], userInput: String? = nil) async {
        guard !isRunning else { return }
        start(scenario: scenario, modelIDs: [modelId], models: models, userInput: userInput)
        await activeTask?.value
    }

    private func execute(scenario: TestScenario, modelID: String, models: [ModelInfo], prompt: String) async -> TestRunResult {
        let started = Date()
        reportedCostForLastRun = nil
        guard let route = models.first(where: { $0.id == modelID }).flatMap(TestModelRoute.resolve) else {
            return failure("Model is not eligible for text-output testing.", scenario: scenario, modelID: modelID, started: started)
        }
        let projectBuild = route == .project && scenario.evaluationMode == .projectBuild
        guard let key = credential(), !key.isEmpty else {
            return failure("No API key configured. Add one in Settings → Accounts & Keys.", scenario: scenario, modelID: modelID, started: started)
        }
        var directory: URL?
        do {
            var response = ""
            var usage: ChatUsage?
            var status: ExperimentCompletionStatus = .completed
            if projectBuild {
                let root = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                directory = root
                let systemPrompt = """
                \(scenario.systemPrompt)

                Build a complete working project in \(root.path). Use write_file, verify with list_directory,
                and build/test with run_command if applicable. Keep files in the workspace.
                For web projects, create an index.html that opens in a browser. Summarize actual work.
                """
                let result = try await agentRun(prompt, modelID, key, root, systemPrompt) { [weak self] label in
                    self?.activityLabel = label
                    self?.activityLog.append(ActivityEntry(text: label, icon: "gearshape"))
                }
                response = result.response
                usage = result.usage
                status = result.hitToolBudget ? .exhausted : .completed
                for name in result.toolNames {
                    activityLog.append(ActivityEntry(text: "Used tool: \(name)", icon: toolIcon(name)))
                }
            } else {
                activityLabel = "Streaming text response…"
                let request = OpenRouterRequest(apiKey: key, model: modelID,
                    messages: [.init(role: "system", content: scenario.systemPrompt), .init(role: "user", content: prompt)],
                    tools: nil, toolChoice: nil, temperature: 0.3)
                for try await event in try await client.stream(request) {
                    try Task.checkCancellation()
                    switch event {
                    case .contentDelta(let choice, let text) where choice == 0: response += text
                    case .usage(let value): usage = value
                    case .apiError(let error): throw TestStreamFailure.message(error.message)
                    case .finishReason(let choice, let reason) where choice == 0 && reason == "length": status = .exhausted
                    default: break
                    }
                }
            }
            try Task.checkCancellation()
            reportedCostForLastRun = usage?.cost
            UsageLedger.shared.record(.testSuite, model: modelID, usage: usage)
            let evaluationMode: TestEvaluationMode = projectBuild ? .projectBuild : .textResponse
            let policy: ToolPolicy = projectBuild ? .projectBuild : ToolPolicy(capabilities: [])
            let record = ExperimentEvaluation.record(
                scenario: scenario, modelID: modelID, policy: policy, projectDirectory: directory,
                response: response, usage: usage, completionStatus: status,
                startedAt: started, finishedAt: Date(), errorMessage: nil,
                evaluationMode: evaluationMode)
            saveExperiment(record)
            let passed = record.verdict == .passed
            let message: String? = passed ? nil : (record.verdict == .unverified
                ? Self.unverifiedMessage
                : status == .exhausted ? "Response truncated or tool budget exhausted."
                : record.artifactChecks.first(where: { !$0.passed })?.detail ??
                  record.assertions.first(where: { !$0.passed })?.detail ?? "Evaluation failed.")
            return TestRunResult(scenarioId: scenario.id, scenarioTitle: scenario.title,
                category: scenario.category, modelId: modelID, response: response,
                promptTokens: usage?.promptTokens ?? 0, completionTokens: usage?.completionTokens ?? 0,
                totalTokens: usage?.totalTokens ?? 0, cost: usage?.cost ?? 0,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000), success: passed,
                errorMessage: message, outputPath: directory?.path)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let message = cancelled ? "Cancelled by user" : error.localizedDescription
            saveExperiment(ExperimentEvaluation.record(scenario: scenario, modelID: modelID,
                policy: projectBuild ? .projectBuild : ToolPolicy(capabilities: []),
                projectDirectory: directory, response: "", usage: nil,
                completionStatus: cancelled ? .cancelled : .failed, startedAt: started,
                finishedAt: Date(), errorMessage: message,
                evaluationMode: projectBuild ? .projectBuild : .textResponse))
            return failure(message, scenario: scenario, modelID: modelID, started: started, outputPath: directory?.path)
        }
    }

    private func failure(_ message: String, scenario: TestScenario, modelID: String, started: Date,
                         outputPath: String? = nil) -> TestRunResult {
        TestRunResult(scenarioId: scenario.id, scenarioTitle: scenario.title, category: scenario.category,
            modelId: modelID, response: "", promptTokens: 0, completionTokens: 0,
            totalTokens: 0, cost: 0, latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            success: false, errorMessage: message, outputPath: outputPath)
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "write_file": return "doc.text"
        case "read_file": return "book"
        case "list_directory": return "folder"
        case "search_files": return "magnifyingglass"
        case "run_command": return "terminal"
        case "fetch_url": return "globe"
        case "run_applescript": return "app"
        case "open_application": return "macwindow"
        case "open_url": return "safari"
        case "capture_screen": return "camera"
        case "computer_action": return "macbook"
        default: return "gearshape"
        }
    }

    var formattedTotalCost: String {
        let total = results.reduce(0.0) { $0 + $1.cost }
        let amount = total < 0.01 ? String(format: "$%.4f", total) : String(format: "$%.2f", total)
        // The legacy result schema stores missing provider cost as zero. This
        // is a lower bound, not a claim that every run was free.
        return "≥" + amount
    }

    func formattedCost(_ cost: Double) -> String {
        // Zero is ambiguous in persisted legacy results: truly free or absent usage.
        guard cost != 0 else { return "—" }
        return cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }
}

// MARK: - NSWorkspace Helpers

private enum TestStreamFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

extension NSWorkspace {
    func openFolder(atPath path: String) {
        open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func selectFile(_ fullPath: String?, inDirectory dir: String) {
        activateFileViewerSelecting([URL(fileURLWithPath: fullPath ?? dir, isDirectory: fullPath == nil)])
    }
}
