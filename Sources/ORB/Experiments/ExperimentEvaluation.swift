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
//   * `ExperimentVerdict` — passes only when the run completed AND every
//     deterministic check passed. A nonempty answer alone is never proof.
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

/// Overall deterministic verdict. `passed` requires completion AND artifacts
/// AND assertions; every individual failure must be explainable from the
/// recorded check results.
enum ExperimentVerdict: String, Codable, Sendable {
    case passed
    case failed
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

    static func evaluate(response: String) -> [AssertionResult] {
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
            passed: !refused,
            detail: refused
                ? "Response contains a recognized refusal phrasing; text-only success is not acceptance."
                : "No refusal phrasing detected."
        )
        return [nonEmpty, noRefusal]
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
        let fm = FileManager.default

        // 1. At least one real file created anywhere in the directory.
        let allFiles = Self.files(under: projectDirectory)
        let meaningful = allFiles.filter { $0.lastPathComponent != ".DS_Store" }
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
            let indexURL = projectDirectory.appendingPathComponent("index.html")
            let byteCount = (try? Data(contentsOf: indexURL))?.count ?? 0
            if !fm.fileExists(atPath: indexURL.path) {
                results.append(ArtifactCheckResult(
                    name: "webIndexHTMLPresent",
                    passed: false,
                    detail: "Web scenario did not create an index.html in the project directory."
                ))
            } else if byteCount < Self.minimumMeaningfulBytes {
                results.append(ArtifactCheckResult(
                    name: "webIndexHTMLPresent",
                    passed: false,
                    detail: "index.html exists but is only \(byteCount) bytes (minimum \(Self.minimumMeaningfulBytes)); too trivial to count as a deliverable."
                ))
            } else {
                results.append(ArtifactCheckResult(
                    name: "webIndexHTMLPresent",
                    passed: true,
                    detail: "index.html exists (\(byteCount) bytes)."
                ))
            }
        }

        // 3. Every artifact the scenario explicitly declares must exist.
        for relativePath in scenario.expectedArtifacts {
            let url = projectDirectory.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: url.path) {
                results.append(ArtifactCheckResult(
                    name: "expectedArtifact:\(relativePath)",
                    passed: true,
                    detail: "Declared artifact \(relativePath) exists."
                ))
            } else {
                results.append(ArtifactCheckResult(
                    name: "expectedArtifact:\(relativePath)",
                    passed: false,
                    detail: "Declared artifact \(relativePath) is missing from the project directory."
                ))
            }
        }

        return results
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
               values.isRegularFile == true {
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
        errorMessage: String?
    ) -> ExperimentRunRecord {
        let checker = projectDirectory.map {
            ArtifactChecker(projectDirectory: $0, scenario: scenario)
        }
        let artifactChecks = checker?.check() ?? []
        let assertions = ResponseAssertions.evaluate(response: response)
        let verdict = overallVerdict(
            completionStatus: completionStatus,
            artifactChecks: artifactChecks,
            assertions: assertions
        )
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
