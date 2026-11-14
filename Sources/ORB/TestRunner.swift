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

/// What the Compare picker's Review/Run button would do. Pure so the
/// Browse → Compare hand-off can never be a silent no-op (TESTS-1).
enum TestBatchLaunchPlan: Equatable {
    case run(scenarioID: String, modelIDs: [String], ceilingUSD: Double)
    case needsScenario
    case needsModels
    case invalidCeiling

    static func resolve(scenario: TestScenario?, modelIDs: Set<String>, ceilingText: String,
                        locale: Locale = .current) -> TestBatchLaunchPlan {
        guard let scenario else { return .needsScenario }
        guard !modelIDs.isEmpty else { return .needsModels }
        guard let ceiling = TestSpendCeilingParser.parse(ceilingText, locale: locale) else { return .invalidCeiling }
        return .run(scenarioID: scenario.id, modelIDs: modelIDs.sorted(), ceilingUSD: ceiling)
    }

    /// Why the Review button is disabled, in the user's words; nil when it can run.
    var blockedReason: String? {
        switch self {
        case .run: return nil
        case .needsScenario: return "Choose a test first."
        case .needsModels: return "Select at least one model."
        case .invalidCeiling: return "Enter a positive spend ceiling, like 1.00."
        }
    }
}

/// Parses the ceiling the way the user typed it: "1.00", "1,00" (comma
/// locales), "$1.00". Returns nil for anything non-positive or unparsable.
enum TestSpendCeilingParser {
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let symbol = locale.currencySymbol { cleaned = cleaned.replacingOccurrences(of: symbol, with: "") }
        cleaned = cleaned.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let value = formatter.number(from: cleaned)?.doubleValue
            ?? Double(cleaned)
            ?? Double(cleaned.replacingOccurrences(of: ",", with: "."))
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

extension TestCatalog {
    /// Default for a Compare hand-off that arrives with no test selected: a
    /// cheap text probe whose exact checks give every model a real verdict.
    static var defaultCompareScenario: TestScenario {
        edgeCaseScenarios.first { ScenarioResponseChecks.coversRubric($0) } ?? edgeCaseScenarios[0]
    }
}

extension Notification.Name {
    /// Posted after `CompareHandoff.shared.stage(_:)` so a Test Suite that is
    /// already on screen opens the picker immediately.
    static let testSuiteCompareHandoffStaged = Notification.Name("ORB.testSuiteCompareHandoffStaged")
}

/// What a finished model run is known to have cost, for the batch ceiling.
enum TestRunSpend: Equatable {
    /// Every billed request reported its cost (model + helpers).
    case known(Double)
    /// Nothing was billed: the run failed before any request (no key,
    /// ineligible model) or the provider rejected the request with an HTTP
    /// error before streaming started.
    case noRequest
    /// At least one request's cost is unknown; `knownSubtotal` is a floor.
    case unknown(knownSubtotal: Double)
}

/// Mid-run ceiling decision for agent project runs (TESTS-3): checked after
/// every model turn against the batch's spend before this model plus the
/// run's cumulative usage. Unknown turn cost cannot be capped, so it stops too.
enum ProjectSpendGuard {
    enum Decision: Equatable { case proceed, stopAtCeiling, stopUnknownCost }

    static func decide(spentBefore: Double, cumulative: ChatUsage, ceiling: Double?) -> Decision {
        guard let ceiling else { return .proceed }
        if cumulative.unpricedRequests > 0 { return .stopUnknownCost }
        return spentBefore + cumulative.knownCostSubtotal >= ceiling ? .stopAtCeiling : .proceed
    }
}

/// Streaming speed for text probes (TESTS-12).
enum TestStreamTiming {
    static func ttftMs(requestStarted: Date, firstToken: Date?) -> Int? {
        firstToken.map { max(0, Int(($0.timeIntervalSince(requestStarted) * 1000).rounded())) }
    }

    /// Completion tokens per second measured from the first token to the end.
    static func tokensPerSecond(completionTokens: Int?, firstToken: Date?, finished: Date) -> Double? {
        guard let tokens = completionTokens, tokens > 0, let firstToken else { return nil }
        let seconds = finished.timeIntervalSince(firstToken)
        guard seconds > 0.001 else { return nil }
        return Double(tokens) / seconds
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

    typealias AgentRun = (String, String, String, URL, String, @escaping @MainActor @Sendable (String) -> Void) async throws -> NativeAgentRunResult
    private let client: any OpenRouterClientProtocol
    private let agentRun: AgentRun?
    private let agentToolExecutor: NativeAgentRunner.ToolExecutor?
    let approvalPresenter = ApprovalPresenter()
    @Published private(set) var approvalHostID: UUID?
    private var approvalHosts: [UUID] = []
    private var activeApprovals: ApprovalCoordinator?
    private var activeApprovalRunID: UUID?

    /// The shared runner has one sheet owner even when several windows show
    /// Test Suite. Closing an unrelated window must not deny its requests.
    func registerApprovalHost(_ id: UUID) {
        if !approvalHosts.contains(id) { approvalHosts.append(id) }
        if approvalHostID == nil { approvalHostID = id }
    }

    func unregisterApprovalHost(_ id: UUID) {
        approvalHosts.removeAll { $0 == id }
        guard approvalHostID == id else { return }
        approvalHostID = approvalHosts.first
        approvalPresenter.denyAll()
        if let activeApprovals {
            Task {
                await activeApprovals.revokeSessionApprovals()
                await activeApprovals.cancelPending()
            }
        }
    }

    /// Turn budget for benchmark project runs: generous for a real build,
    /// but far below the interactive agent's 100-turn backstop (TESTS-3).
    static let projectMaximumTurns = 30

    private func runProject(prompt: String, modelID: String, key: String, directory: URL,
                            systemPrompt: String, activity: @escaping @MainActor @Sendable (String) -> Void) async throws -> NativeAgentRunResult {
        // Each model run gets a fresh approval scope. OP Mode is deliberately
        // not honored here: a model-comparison batch is not an unattended Agent run.
        let approvals = ApprovalCoordinator()
        let runID = UUID()
        activeApprovalRunID = runID
        activeApprovals = approvals
        await approvals.setHandler { [weak self] request in
            await self?.presentApproval(request, runID: runID) ?? .denied
        }
        defer {
            approvalPresenter.denyAll()
            activeApprovals = nil
            activeApprovalRunID = nil
        }
        return try await NativeAgentRunner.run(
            prompt: prompt, modelId: modelID, apiKey: key, workspace: directory.path,
            fullComputerAccess: false, history: [], systemPromptOverride: systemPrompt,
            client: client, maximumTurns: Self.projectMaximumTurns, toolExecutor: agentToolExecutor,
            policy: .projectBuild, approvals: approvals,
            onEvent: { [weak self] event in
                await self?.handleProjectEvent(event, activity: activity)
            }
        )
    }

    /// Run-scoped progress of the current project run: the latest
    /// cumulative model usage (kept so failed/cancelled runs still record
    /// what was spent) and the mid-run spend-ceiling guard.
    private func handleProjectEvent(_ event: NativeAgentEvent, activity: @MainActor (String) -> Void) {
        switch event {
        case .modelTurnStarted:
            projectTurnsStarted += 1
            activity("Thinking…")
        case .toolExecutionStarted(let call):
            activity(Self.projectActivityLabel(for: call.name))
        case .usage(_, let cumulative):
            projectUsage = cumulative
            switch ProjectSpendGuard.decide(spentBefore: batchSpent, cumulative: cumulative, ceiling: batchCeilingUSD) {
            case .proceed: break
            case .stopAtCeiling: stopCurrentRun(.spendCeiling)
            case .stopUnknownCost: stopCurrentRun(.unknownCost)
            }
        default:
            break
        }
    }

    enum RunStopReason: Equatable {
        case spendCeiling, unknownCost

        var resultMessage: String {
            switch self {
            case .spendCeiling: return "Stopped at spend ceiling."
            case .unknownCost: return "Stopped: a model turn did not report its cost, so the spend ceiling could not be enforced."
            }
        }

        var batchNotice: String {
            switch self {
            case .spendCeiling: return "Stopped at spend ceiling; remaining models skipped. The turn in flight may exceed it."
            case .unknownCost: return "A model turn did not report its cost; stopped to protect the spend ceiling."
            }
        }
    }

    /// Mirrors the agent's private activity labels for the default project runner.
    static func projectActivityLabel(for tool: String) -> String {
        switch tool {
        case "read_file": "Reading a file…"
        case "list_directory": "Inspecting a folder…"
        case "search_files": "Searching files…"
        case "write_file": "Writing a file…"
        case "run_command": "Running a command…"
        case "fetch_url": "Fetching the web…"
        case "view_image": "Looking at an image…"
        case "web_search": "Searching the web…"
        default: "Using \(tool)…"
        }
    }

    private func stopCurrentRun(_ reason: RunStopReason) {
        guard runStopReason == nil else { return }
        runStopReason = reason
        activeApprovalRunID = nil
        approvalPresenter.denyAll()
        if let activeApprovals { Task { await activeApprovals.cancelPending() } }
        activeTask?.cancel()
    }

    private func presentApproval(_ request: ApprovalCoordinator.Request, runID: UUID) async -> ApprovalCoordinator.Decision {
        guard !Task.isCancelled, approvalHostID != nil, activeApprovalRunID == runID else { return .denied }
        // Time spent waiting on the user is not model latency (TESTS-8).
        let waitStarted = Date()
        let decision = await approvalPresenter.present(request)
        approvalWaitSeconds += Date().timeIntervalSince(waitStarted)
        return decision
    }
    private var projectUsage: ChatUsage?
    private var projectTurnsStarted = 0
    private var runStopReason: RunStopReason?
    private var approvalWaitSeconds: TimeInterval = 0
    /// Spend state of the most recent `execute`, read by the batch loop.
    private(set) var lastRunSpend: TestRunSpend = .noRequest
    private let credential: () -> String?
    private let saveResult: (TestRunResult) -> Void
    private let saveExperiment: (ExperimentRunRecord) -> Void
    private let outputRoot: URL
    private let usageLedger: UsageLedger
    private var activeTask: Task<Void, Never>?
    private var cancellationRequested = false

    init(
        client: any OpenRouterClientProtocol = OpenRouterClient(),
        agentRun: AgentRun? = nil,
        agentToolExecutor: NativeAgentRunner.ToolExecutor? = nil,
        credential: @escaping () -> String? = { KeychainManager.getAPIKey() },
        saveResult: @escaping (TestRunResult) -> Void = { DatabaseManager.shared.saveTestResult($0) },
        saveExperiment: @escaping (ExperimentRunRecord) -> Void = { DatabaseManager.shared.saveExperimentRunRecord($0) },
        outputRoot: URL? = nil,
        usageLedger: UsageLedger? = nil
    ) {
        self.usageLedger = usageLedger ?? .shared
        self.client = client
        self.agentRun = agentRun
        self.agentToolExecutor = agentToolExecutor
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
        runStopReason = nil
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
                        self.batchNotice = "Spend ceiling reached; remaining models skipped. The request in flight may exceed it."
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
                    let spend = self.lastRunSpend
                    if ceilingUSD != nil {
                        switch spend {
                        case .known(let cost): spent += cost
                        case .unknown(let subtotal): spent += subtotal; self.batchUnreportedRuns += 1
                        case .noRequest: break
                        }
                        self.batchSpent = spent
                    }
                    if let reason = self.runStopReason {
                        self.batchNotice = reason.batchNotice
                        break planLoop
                    }
                    if Task.isCancelled || self.cancellationRequested { break planLoop }
                    // A failure before any billed request (no key, ineligible
                    // model, HTTP rejection) costs nothing: keep comparing.
                    if ceilingUSD != nil, case .unknown(let subtotal) = spend {
                        self.batchNotice = subtotal > 0
                            ? "Provider did not report cost for every request (known spend ≥ \(TestResultsTable.costText(subtotal))); remaining models skipped."
                            : "Provider did not report cost; remaining models skipped."
                        break planLoop
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
        activeApprovalRunID = nil
        activeTask?.cancel()
        approvalPresenter.denyAll()
        if let activeApprovals { Task { await activeApprovals.cancelPending() } }
        batchNotice = "Cancelling; unstarted models skipped."
    }

    func run(scenario: TestScenario, modelId: String, models: [ModelInfo], userInput: String? = nil) async {
        guard !isRunning else { return }
        start(scenario: scenario, modelIDs: [modelId], models: models, userInput: userInput)
        await activeTask?.value
    }

    private func execute(scenario: TestScenario, modelID: String, models: [ModelInfo], prompt: String) async -> TestRunResult {
        let started = Date()
        lastRunSpend = .noRequest
        projectUsage = nil
        projectTurnsStarted = 0
        approvalWaitSeconds = 0
        // One stable ledger identity per model run: success and failure paths
        // record under it, so a retry or late write can never double count.
        let runEventID = "test-run:\(UUID().uuidString)"
        guard let route = models.first(where: { $0.id == modelID }).flatMap(TestModelRoute.resolve) else {
            return failure("Model is not eligible for text-output testing.", scenario: scenario, modelID: modelID, started: started)
        }
        let projectBuild = route == .project && scenario.evaluationMode == .projectBuild
        guard let key = credential(), !key.isEmpty else {
            return failure("No API key configured. Add one in Settings → Accounts & Keys.", scenario: scenario, modelID: modelID, started: started)
        }
        var directory: URL?
        var textUsage: ChatUsage?
        var streamStarted = false
        do {
            var response = ""
            var knownCostForDisplay = 0.0
            var status: ExperimentCompletionStatus = .completed
            var ttftMs: Int?
            var tokensPerSec: Double?
            let usage: ChatUsage?
            if projectBuild {
                let root = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                directory = root
                let systemPrompt = """
                \(scenario.systemPrompt)

                Build a complete working project in \(root.path). Use write_file, verify with list_directory,
                and build/test with run_command if applicable. Keep files in the workspace.
                Shell commands require user approval and are NOT sandboxed. If approval is denied,
                continue without executing the command and report what remains unverified.
                For web projects, create an index.html that opens in a browser. Summarize actual work.
                """
                let run: AgentRun = agentRun ?? { [self] prompt, model, key, directory, system, activity in
                    try await runProject(prompt: prompt, modelID: model, key: key, directory: directory,
                                         systemPrompt: system, activity: activity)
                }
                let result = try await run(prompt, modelID, key, root, systemPrompt) { [weak self] label in
                    self?.activityLabel = label
                    self?.activityLog.append(ActivityEntry(text: label, icon: "gearshape"))
                }
                response = result.response
                usage = result.usage
                lastRunSpend = result.reportedTotalCost.map(TestRunSpend.known)
                    ?? .unknown(knownSubtotal: result.knownTotalCostSubtotal)
                knownCostForDisplay = result.knownTotalCostSubtotal
                status = result.hitToolBudget ? .exhausted : .completed
                for name in result.toolNames {
                    activityLog.append(ActivityEntry(text: "Used tool: \(name)", icon: toolIcon(name)))
                }
            } else {
                activityLabel = "Streaming text response…"
                let request = OpenRouterRequest(apiKey: key, model: modelID,
                    messages: [.init(role: "system", content: scenario.systemPrompt), .init(role: "user", content: prompt)],
                    tools: nil, toolChoice: nil, temperature: 0.3)
                let requestStarted = Date()
                var firstTokenAt: Date?
                let stream = try await client.stream(request)
                // Past this point the provider accepted the request: it may bill.
                streamStarted = true
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .contentDelta(let choice, let text) where choice == 0:
                        if firstTokenAt == nil, !text.isEmpty { firstTokenAt = Date() }
                        response += text
                    case .reasoningDelta(let choice, let text) where choice == 0:
                        if firstTokenAt == nil, !text.isEmpty { firstTokenAt = Date() }
                    case .usage(let value): textUsage = value
                    case .apiError(let error): throw TestStreamFailure.message(error.message)
                    case .finishReason(let choice, let reason) where choice == 0 && reason == "length": status = .exhausted
                    default: break
                    }
                }
                let finished = Date()
                ttftMs = TestStreamTiming.ttftMs(requestStarted: requestStarted, firstToken: firstTokenAt)
                tokensPerSec = TestStreamTiming.tokensPerSecond(completionTokens: textUsage?.completionTokens,
                                                                firstToken: firstTokenAt, finished: finished)
                usage = textUsage
                lastRunSpend = textUsage?.cost.flatMap { $0.isFinite && $0 >= 0 ? TestRunSpend.known($0) : nil }
                    ?? .unknown(knownSubtotal: textUsage?.knownCostSubtotal ?? 0)
                knownCostForDisplay = textUsage?.knownCostSubtotal ?? 0
            }
            try Task.checkCancellation()
            usageLedger.record(.testSuite, model: modelID, usage: usage, eventID: runEventID)
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
                totalTokens: usage?.totalTokens ?? 0, cost: knownCostForDisplay,
                latencyMs: modelLatencyMs(since: started), success: passed,
                errorMessage: message, outputPath: directory?.path,
                ttftMs: ttftMs, tokensPerSec: tokensPerSec)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let message = runStopReason?.resultMessage ?? (cancelled ? "Cancelled by user" : error.localizedDescription)
            // Money already spent stays recorded (TESTS-2): the latest
            // cumulative agent usage, or the text stream's attempt.
            let partial = projectBuild ? projectUsage : textUsage
            let httpRejected: Bool = {
                if case OpenRouterClientError.http = error { return true }
                return false
            }()
            if projectBuild {
                let accounted = projectUsage?.accountedRequestCount ?? 0
                // A turn that was in flight when the run ended may have billed
                // without reporting usage; an HTTP rejection did not.
                let inFlightUnpriced = projectTurnsStarted > accounted && !httpRejected
                if let projectUsage {
                    usageLedger.record(.testSuite, model: modelID, usage: projectUsage, eventID: runEventID)
                }
                if inFlightUnpriced {
                    usageLedger.record(.testSuite, model: modelID, cost: nil, eventID: "\(runEventID):in-flight")
                }
                lastRunSpend = projectTurnsStarted == 0 || (projectUsage == nil && !inFlightUnpriced)
                    ? .noRequest : .unknown(knownSubtotal: projectUsage?.knownCostSubtotal ?? 0)
            } else if streamStarted {
                // Usage nil records one explicitly unpriced request, never free.
                usageLedger.record(.testSuite, model: modelID, usage: textUsage, eventID: runEventID)
                lastRunSpend = .unknown(knownSubtotal: textUsage?.knownCostSubtotal ?? 0)
            } else {
                lastRunSpend = .noRequest
            }
            saveExperiment(ExperimentEvaluation.record(scenario: scenario, modelID: modelID,
                policy: projectBuild ? .projectBuild : ToolPolicy(capabilities: []),
                projectDirectory: directory, response: "", usage: partial,
                completionStatus: cancelled ? .cancelled : .failed, startedAt: started,
                finishedAt: Date(), errorMessage: message,
                evaluationMode: projectBuild ? .projectBuild : .textResponse))
            return TestRunResult(scenarioId: scenario.id, scenarioTitle: scenario.title, category: scenario.category,
                modelId: modelID, response: "", promptTokens: partial?.promptTokens ?? 0,
                completionTokens: partial?.completionTokens ?? 0, totalTokens: partial?.totalTokens ?? 0,
                cost: partial?.knownCostSubtotal ?? 0, latencyMs: modelLatencyMs(since: started),
                success: false, errorMessage: message, outputPath: directory?.path)
        }
    }

    /// Wall time minus time spent waiting on approval sheets.
    private func modelLatencyMs(since started: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(started) - approvalWaitSeconds) * 1000))
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
