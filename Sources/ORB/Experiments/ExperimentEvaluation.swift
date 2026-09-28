import Foundation

// MARK: - Experiment evaluation (W12 / F10)
//
// Completion status ("the agent loop returned") is NOT evaluation success
// ("the artifacts actually exist and the response is not a refusal"). This
// file keeps those two ideas separate:
//
//   * `ExperimentCompletionStatus` — transport/lifecycle outcome only.
//   * `ArtifactChecker` + `ResponseAssertions` — deterministic, offline
//     checks over the run's project directory and response text.
//   * `ExperimentVerdict` — project builds pass only on completed runs with
//     deterministic evidence; text responses remain unverified on basic checks.
//
// Everything here is deterministic and network-free so it can be exercised
// in `swift test` with synthesized results; no agent loop is ever invoked.

// MARK: Completion status

/// How the run ended at the transport level. Says nothing about quality.
enum ExperimentCompletionStatus: String, Codable, Sendable {
    /// The agent loop returned a final answer on its own.
    case completed
    /// Cancelled by the user before a final answer.
    case cancelled
    /// The run threw (transport, tool, or provider error).
    case failed
    /// The turn budget was spent and the run was force-summarized.
    case exhausted
}

/// Overall deterministic verdict. `passed` establishes only the checks below,
/// never that human-readable scenario criteria were semantically satisfied.
/// Text-only answers are `.unverified` when basic checks succeed.
enum ExperimentVerdict: String, Codable, Sendable {
    case passed
    case failed
    /// Text-response checks passed; the scenario rubric was NOT graded.
    case unverified
}

// MARK: Check results

/// One deterministic check over the run's project directory.
struct ArtifactCheckResult: Codable, Equatable, Sendable {
    /// Stable machine name, e.g. "atLeastOneFileCreated" or
    /// "expectedArtifact:index.html".
    let name: String
    let passed: Bool
    /// Human-readable evidence (what was looked for, what was found).
    let detail: String
}

/// One deterministic check over the response text itself.
struct AssertionResult: Codable, Equatable, Sendable {
    let name: String
    let passed: Bool
    let detail: String
}

// MARK: Policy summary

/// A stable, Codable snapshot of the `ToolPolicy` a run was authorized
/// under. Recorded on EVERY experiment record so a run can never be
/// mistaken for one approved under a different policy.
struct ExperimentPolicySummary: Codable, Equatable, Sendable {
    /// Preset name when the policy matches a known preset ("projectBuild",
    /// "webOnly", …), otherwise "custom".
    let presetName: String
    /// Sorted capability raw values (sorted so encoding is stable).
    let capabilities: [String]
    let constrainsFilesystem: Bool

    init(presetName: String, policy: ToolPolicy) {
        self.presetName = presetName
        self.capabilities = policy.capabilities.map(\.rawValue).sorted()
        self.constrainsFilesystem = policy.constrainsFilesystem
    }

    init(presetName: String, capabilities: [String], constrainsFilesystem: Bool) {
        self.presetName = presetName
        self.capabilities = capabilities
        self.constrainsFilesystem = constrainsFilesystem
    }

    static func presetName(for policy: ToolPolicy) -> String {
        // projectBuild is capability-identical to approvedTerminal, so it is
        // matched FIRST and wins for experiment runs.
        let presets: [(String, ToolPolicy)] = [
            ("projectBuild", .projectBuild),
            ("webOnly", .webOnly),
            ("workspaceRead", .workspaceRead),
            ("workspaceWrite", .workspaceWrite),
            ("approvedTerminal", .approvedTerminal),
            ("computerControl", .computerControl),
        ]
        for (name, preset) in presets where preset == policy {
            return name
        }
        return "custom"
    }
}

// MARK: Spend accounting

/// Known spend for a run. `nil` fields mean UNKNOWN, never zero: a run whose
/// usage was never reported must not silently read as free.
struct ExperimentSpend: Codable, Equatable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    /// Reported cost in USD. `nil` when the provider reported no cost.
    let knownCostUSD: Double?

    init(usage: ChatUsage?) {
        promptTokens = usage?.promptTokens
        completionTokens = usage?.completionTokens
        totalTokens = usage?.totalTokens
        knownCostUSD = usage?.cost
    }

    init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?, knownCostUSD: Double?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.knownCostUSD = knownCostUSD
    }

    /// True only when a real cost figure was reported.
    var costIsKnown: Bool { knownCostUSD != nil }
    /// True when the provider reported a usage block at all.
    var usageIsKnown: Bool { totalTokens != nil || knownCostUSD != nil }
}

// MARK: Spend ceiling

/// An explicit human approval for spending up to a dollar amount on a batch
/// of experiments. Money is the only unit — a turn count is not a budget.
struct SpendApprovalToken: Codable, Equatable, Sendable {
    let id: UUID
    /// Maximum total KNOWN spend the batch may reach, in USD.
    let ceilingUSD: Double
    let approvedAt: Date
    /// Free-text provenance of the approval (who/why).
    let note: String

    init(ceilingUSD: Double, note: String, id: UUID = UUID(), approvedAt: Date = Date()) {
        self.id = id
        self.ceilingUSD = ceilingUSD
        self.approvedAt = approvedAt
        self.note = note
    }
}

/// Why a run was refused before starting.
struct SpendRefusal: Codable, Equatable, Sendable {
    let id: UUID
    let scenarioID: String
    let modelID: String
    let ceilingUSD: Double
    let knownSpendUSD: Double
    let requestedAt: Date
    let reason: String
}

enum BudgetDecision: Equatable, Sendable {
    case allowed
    case refused(SpendRefusal)
}

/// Gate for a paid batch of experiments. Checks the remaining budget BEFORE
/// each run and refuses (recording the refusal) when the ceiling would be
/// exceeded. Only KNOWN dollar spend accumulates; runs whose cost is unknown
/// cannot move the counter — they are labelled unknown on the record instead.
struct ExperimentBatchRunner: Sendable {
    let approval: SpendApprovalToken
    private(set) var knownSpendUSD: Double = 0
    private(set) var records: [ExperimentRunRecord] = []
    private(set) var refusals: [SpendRefusal] = []

    init(approval: SpendApprovalToken) {
        self.approval = approval
    }

    /// Call BEFORE launching any agent run. Never invokes the agent; a
    /// refusal here means the run must not start at all.
    mutating func beginRun(scenarioID: String, modelID: String, now: Date = Date()) -> BudgetDecision {
        guard knownSpendUSD < approval.ceilingUSD else {
            let refusal = SpendRefusal(
                id: UUID(),
                scenarioID: scenarioID,
                modelID: modelID,
                ceilingUSD: approval.ceilingUSD,
                knownSpendUSD: knownSpendUSD,
                requestedAt: now,
                reason: String(
                    format: "Spend ceiling of $%.2f reached ($%.2f known spent); run refused before any agent invocation.",
                    approval.ceilingUSD, knownSpendUSD
                )
            )
            refusals.append(refusal)
            return .refused(refusal)
        }
        return .allowed
    }

    /// Record a finished run; known cost accrues against the ceiling.
    mutating func record(_ record: ExperimentRunRecord) {
        records.append(record)
        if let cost = record.spend.knownCostUSD {
            knownSpendUSD += cost
        }
    }
}

// MARK: Run record

/// Durable record of one experiment run: what ran, under what policy, what
/// it cost (as far as known), how it ended, and what the deterministic
/// evaluation said. Completion status and evaluation verdict are separate
/// fields on purpose.
struct ExperimentRunRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let scenarioID: String
    let scenarioTitle: String
    /// Version tag of the scenario definition at run time.
    let scenarioVersion: Int
    let categoryRawValue: String
    let modelID: String
    let policy: ExperimentPolicySummary
    let startedAt: Date
    let finishedAt: Date
    let completionStatus: ExperimentCompletionStatus
    let spend: ExperimentSpend
    let artifactChecks: [ArtifactCheckResult]
    let assertions: [AssertionResult]
    let verdict: ExperimentVerdict
    /// Error/cancellation message, when the run did not complete normally.
    let errorMessage: String?
    /// Bounded excerpt of the final response as evidence.
    let responseExcerpt: String?

    var category: TestCategory? { TestCategory(rawValue: categoryRawValue) }

    var artifactChecksPassed: Bool { artifactChecks.allSatisfy(\.passed) }
    var assertionsPassed: Bool { assertions.allSatisfy(\.passed) }
}

// MARK: Deterministic response assertions

enum ResponseAssertions {
    /// Common refusal phrasings (matched case-insensitively). A response
    /// that says it cannot do the task is a failure even if it is polite,
    /// nonempty, and well-formatted.
    static let refusalPhrases: [String] = [
        "i cannot complete",
        "i can't complete",
        "i cannot create",
        "i can't create",
        "i cannot build",
        "i can't build",
        "i cannot fulfill",
        "i can't fulfill",
        "i cannot help",
        "i can't help",
        "i cannot assist",
        "i can't assist",
        "i'm unable to",
        "i am unable to",
        "unable to complete this",
        "i won't be able to",
        "i will not be able to",
        "sorry, i can't",
        "sorry, i cannot",
    ]

    static func isRefusal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return refusalPhrases.contains { lowered.contains($0) }
    }

    static func evaluate(response: String, allowsRefusal: Bool = false) -> [AssertionResult] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmpty = AssertionResult(
            name: "nonEmptyResponse",
            passed: !trimmed.isEmpty,
            detail: trimmed.isEmpty
                ? "The agent returned an empty response."
                : "Response is nonempty (\(trimmed.count) characters)."
        )
        let refused = isRefusal(response)
        let noRefusal = AssertionResult(
            name: "noRefusalPhrasing",
            passed: allowsRefusal || !refused,
            detail: allowsRefusal ? "Refusal is permitted for this scenario; appropriateness requires human review." : refused
                ? "Response contains a recognized refusal phrasing; text-only success is not acceptance."
                : "No refusal phrasing detected."
        )
        return [nonEmpty, noRefusal]
    }
}

enum ScenarioResponseChecks {
    /// Exact-output probes can be checked without claiming the entire rubric
    /// (or a free-form answer) has been graded.
    static func evaluate(scenario: TestScenario, response: String) -> [AssertionResult] {
        switch scenario.id {
        case "llm-structured-output":
            let object = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any]
            let name = object?["name"] as? String
            let count = object?["count"] as? NSNumber
            let correct = object?.count == 2 && name == "A\"B"
                && count?.intValue == 2 && count?.doubleValue == 2
                && count.map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true
            return [AssertionResult(name: "exactStructuredJSON", passed: correct,
                                    detail: correct ? "Exact JSON keys, escaped name, and numeric count verified."
                                        : "Expected only JSON keys name= A\"B and count=2 (integer).")]
        case "llm-unicode-fidelity":
            let values = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String]
            let correct = values == ["café", "東京", "👩🏽‍💻"]
            return [AssertionResult(name: "exactUnicodeArray", passed: correct,
                                    detail: correct ? "Unicode values and order verified."
                                        : "Expected the exact JSON array [café, 東京, 👩🏽‍💻] in order.")]
        default:
            return []
        }
    }
}

// MARK: Deterministic artifact checker

/// Deterministic, offline checks over a run's project directory. Uses only
/// FileManager — no network, no agent, no judgment calls.
struct ArtifactChecker {
    /// index.html below this size is a stub, not a deliverable.
    static let minimumMeaningfulBytes = 200

    let projectDirectory: URL
    let scenario: TestScenario

    func check() -> [ArtifactCheckResult] {
        var results: [ArtifactCheckResult] = []
        let root = projectDirectory.standardizedFileURL
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else {
            return [ArtifactCheckResult(name: "projectDirectoryPresent", passed: false,
                                        detail: "Project directory is missing, not a directory, or is a symlink: \(root.path).")]
        }
        results.append(ArtifactCheckResult(name: "projectDirectoryPresent", passed: true,
                                           detail: "Project directory exists: \(root.path)."))

        // 1. At least one real file created anywhere in the directory.
        let allFiles = Self.files(under: root)
        let meaningful = allFiles.filter { $0.lastPathComponent != ".DS_Store" && Self.nonBlankFile($0, root: root) }
        if meaningful.isEmpty {
            results.append(ArtifactCheckResult(
                name: "atLeastOneFileCreated",
                passed: false,
                detail: "No files were created in \(projectDirectory.path); a text-only response is not a project."
            ))
        } else {
            let names = meaningful.map { $0.lastPathComponent }.sorted().joined(separator: ", ")
            results.append(ArtifactCheckResult(
                name: "atLeastOneFileCreated",
                passed: true,
                detail: "\(meaningful.count) file(s) created: \(names)."
            ))
        }

        // 2. Web-development scenarios must produce a non-trivial index.html.
        if scenario.category == .webDevelopment {
            let indexURL = root.appendingPathComponent("index.html")
            let data = Self.safeRegularFile(indexURL, root: root).flatMap { try? Data(contentsOf: $0) }
            let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let visible = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->|<[^>]*>", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let placeholder = visible.count < 30 || ["hello world", "coming soon", "placeholder", "todo", "under construction"]
                .contains(where: { visible == $0 || visible == "\($0)." })
            let passed = (data?.count ?? 0) >= Self.minimumMeaningfulBytes
                && html.lowercased().contains("<html") && html.lowercased().contains("<body")
                && html.lowercased().contains("</html>") && !placeholder
            results.append(ArtifactCheckResult(name: "webIndexHTMLPresent", passed: passed,
                                               detail: passed ? "Non-trivial index.html found (\(data?.count ?? 0) bytes); functionality not verified."
                                                   : "Missing, unsafe, blank, malformed, or trivial index.html (\(data?.count ?? 0) bytes)."))
        }

        // 3. Every artifact the scenario explicitly declares must exist.
        for relativePath in scenario.expectedArtifacts {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            let validPath = !relativePath.hasPrefix("/") && !components.isEmpty
                && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }
            let url = root.appendingPathComponent(relativePath)
            if validPath && Self.nonBlankFile(url, root: root) {
                results.append(ArtifactCheckResult(
                    name: "expectedArtifact:\(relativePath)",
                    passed: true,
                    detail: "Declared artifact \(relativePath) is a nonblank regular file inside the project."
                ))
            } else {
                results.append(ArtifactCheckResult(
                    name: "expectedArtifact:\(relativePath)",
                    passed: false,
                    detail: "Declared artifact \(relativePath) is missing, blank, or outside the project directory."
                ))
            }
        }

        return results
    }

    private static func safeRegularFile(_ url: URL, root: URL) -> URL? {
        let candidate = url.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        // Check every existing ancestor, including the final component. This
        // catches symlinked directories even when the final target is absent.
        var cursor = candidate
        while cursor.path != root.path {
            let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { return nil }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { return nil }
            cursor = parent
        }
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true ? candidate : nil
    }

    private static func nonBlankFile(_ url: URL, root: URL) -> Bool {
        guard let safe = safeRegularFile(url, root: root), let data = try? Data(contentsOf: safe), !data.isEmpty else { return false }
        if let text = String(data: data, encoding: .utf8) {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true // Nonempty binary artifacts are not judged semantically.
    }

    static func files(under directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true, safeRegularFile(url, root: directory) != nil {
                files.append(url)
            }
        }
        return files
    }
}

// MARK: Evaluation entry point

enum ExperimentEvaluation {
    /// Bounded excerpt kept as durable evidence.
    static let responseExcerptLimit = 2_000

    /// Builds a complete record from a finished (or cancelled/failed) run.
    /// Callers must pass `.textResponse` explicitly for text-only runs;
    /// scenario.evaluationMode is catalog metadata, not an implicit override.
    /// Deterministic: same inputs → same record (aside from id/timestamps).
    static func record(
        id: UUID = UUID(),
        scenario: TestScenario,
        modelID: String,
        policy: ToolPolicy,
        projectDirectory: URL?,
        response: String,
        usage: ChatUsage?,
        completionStatus: ExperimentCompletionStatus,
        startedAt: Date,
        finishedAt: Date,
        errorMessage: String?,
        evaluationMode: TestEvaluationMode = .projectBuild
    ) -> ExperimentRunRecord {
        let artifactChecks: [ArtifactCheckResult]
        switch evaluationMode {
        case .projectBuild:
            artifactChecks = projectDirectory.map { ArtifactChecker(projectDirectory: $0, scenario: scenario).check() }
                ?? [ArtifactCheckResult(name: "projectDirectoryPresent", passed: false,
                                        detail: "Project-build run has no project directory.")]
        case .textResponse:
            artifactChecks = [ArtifactCheckResult(name: "textResponseMode", passed: true,
                                                  detail: "No artifacts required; scenario criteria have not been graded.")]
        }
        let assertions = ResponseAssertions.evaluate(response: response, allowsRefusal: scenario.allowsRefusal)
            + ScenarioResponseChecks.evaluate(scenario: scenario, response: response)
        let basicVerdict = overallVerdict(
            completionStatus: completionStatus,
            artifactChecks: artifactChecks,
            assertions: assertions
        )
        let verdict: ExperimentVerdict = basicVerdict == .passed && evaluationMode == .textResponse
            ? .unverified : basicVerdict
        let excerpt: String? = {
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(responseExcerptLimit))
        }()
        return ExperimentRunRecord(
            id: id,
            scenarioID: scenario.id,
            scenarioTitle: scenario.title,
            scenarioVersion: scenario.version,
            categoryRawValue: scenario.category.rawValue,
            modelID: modelID,
            policy: ExperimentPolicySummary(
                presetName: ExperimentPolicySummary.presetName(for: policy),
                policy: policy
            ),
            startedAt: startedAt,
            finishedAt: finishedAt,
            completionStatus: completionStatus,
            spend: ExperimentSpend(usage: usage),
            artifactChecks: artifactChecks,
            assertions: assertions,
            verdict: verdict,
            errorMessage: errorMessage,
            responseExcerpt: excerpt
        )
    }

    /// A run only passes when it completed AND every deterministic check
    /// passed. Cancelled/failed/exhausted runs can never pass, no matter
    /// what artifacts happen to exist.
    static func overallVerdict(
        completionStatus: ExperimentCompletionStatus,
        artifactChecks: [ArtifactCheckResult],
        assertions: [AssertionResult]
    ) -> ExperimentVerdict {
        guard completionStatus == .completed else { return .failed }
        guard !artifactChecks.isEmpty, !assertions.isEmpty else { return .failed }
        let artifactsOK = artifactChecks.allSatisfy(\.passed)
        let assertionsOK = assertions.allSatisfy(\.passed)
        return (artifactsOK && assertionsOK) ? .passed : .failed
    }
}

// MARK: Structured export

enum ExperimentExport {
    /// Stable, ordered JSON export of a batch of records (and any budget
    /// refusals). Records are sorted by (startedAt, id) so input order never
    /// changes the output, keys are sorted, and dates are ISO-8601. The
    /// result is byte-identical for the same logical batch.
    static func encodeJSON(
        records: [ExperimentRunRecord],
        refusals: [SpendRefusal] = [],
        approval: SpendApprovalToken? = nil
    ) throws -> String {
        let sortedRecords = records.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let sortedRefusals = refusals.sorted {
            if $0.requestedAt != $1.requestedAt { return $0.requestedAt < $1.requestedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let envelope = ExportEnvelope(
            format: "orb.experiment-runs",
            version: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            approval: approval,
            refusals: sortedRefusals,
            records: sortedRecords
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decodeJSON(_ json: String) throws -> [ExperimentRunRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ExportEnvelope.self, from: Data(json.utf8))
        return envelope.records
    }

    private struct ExportEnvelope: Codable {
        let format: String
        let version: Int
        let exportedAt: String
        let approval: SpendApprovalToken?
        let refusals: [SpendRefusal]
        let records: [ExperimentRunRecord]
    }
}
