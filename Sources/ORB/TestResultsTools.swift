import Foundation

// MARK: - Test results: export, rerun grouping, paging, leaderboard, HTML finder
//
// Pure functions so each rule is unit-testable without the view.

enum TestResultsCSV {
    static let header = ["id", "timestamp", "scenario_id", "scenario_title", "category", "model_id",
                         "result", "cost_usd", "latency_ms", "prompt_tokens", "completion_tokens",
                         "total_tokens", "error", "output_path"]

    /// RFC 4180: CRLF line endings; fields containing comma, quote, CR or LF
    /// are quoted with embedded quotes doubled. Unknown cost (stored as 0) is
    /// left blank rather than claiming the run was free.
    static func encode(_ rows: [TestRunResult]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [header.map(field).joined(separator: ",")]
        for r in rows {
            let cost = r.cost > 0 ? String(format: "%.6f", r.cost) : ""
            let values: [String] = [
                r.id.uuidString, iso.string(from: r.timestamp), r.scenarioId, r.scenarioTitle,
                r.category.rawValue, r.modelId, TestVerdictKind.of(r).rawValue, cost,
                String(r.latencyMs), String(r.promptTokens), String(r.completionTokens),
                String(r.totalTokens), r.errorMessage ?? "", r.outputPath ?? ""
            ]
            lines.append(values.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// A rerun batch for one scenario: at most `TestBatchSelection.maximumModels`
/// models (the batch runner's cap). Overflow becomes additional batches.
struct TestRerunBatch: Equatable {
    let scenarioID: String
    let modelIDs: [String]
}

enum TestRerunPlanner {
    /// Rows needing a rerun: failed or unverified.
    static func needsRerun(_ r: TestRunResult) -> Bool { TestVerdictKind.of(r) != .passed }

    /// Groups the latest failed/unverified result per (scenario, model) into
    /// per-scenario batches. A pair whose *latest* result passed is skipped
    /// (it was already rerun successfully). Order: scenarios by most recent
    /// failure, models by first appearance; chunks respect the model cap.
    static func batches(from results: [TestRunResult],
                        cap: Int = TestBatchSelection.maximumModels) -> [TestRerunBatch] {
        let newestFirst = results.sorted { $0.timestamp > $1.timestamp }
        var seenPairs = Set<String>()
        var scenarioOrder: [String] = []
        var models: [String: [String]] = [:]
        for r in newestFirst {
            let pair = r.scenarioId + "\u{1F}" + r.modelId
            guard seenPairs.insert(pair).inserted, needsRerun(r) else { continue }
            if models[r.scenarioId] == nil { scenarioOrder.append(r.scenarioId) }
            models[r.scenarioId, default: []].append(r.modelId)
        }
        let size = max(1, cap)
        return scenarioOrder.flatMap { scenario -> [TestRerunBatch] in
            let ids = models[scenario] ?? []
            return stride(from: 0, to: ids.count, by: size).map {
                TestRerunBatch(scenarioID: scenario, modelIDs: Array(ids[$0..<min($0 + size, ids.count)]))
            }
        }
    }

    static func modelCount(_ batches: [TestRerunBatch]) -> Int { batches.reduce(0) { $0 + $1.modelIDs.count } }
}

enum TestResultsPaging {
    static let pageSize = 200

    /// "Showing newest 200 of 1,234" when truncated; nil when everything is shown.
    static func notice(shown: Int, total: Int) -> String? {
        guard total > shown else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return "Showing newest \(f.string(from: NSNumber(value: shown)) ?? "\(shown)") of \(f.string(from: NSNumber(value: total)) ?? "\(total)") results"
    }
}

struct ModelLeaderboardRow: Equatable, Identifiable {
    var id: String { modelID }
    let modelID: String
    let runs: Int
    let passed: Int
    let unverified: Int
    /// Median wall-clock latency in seconds.
    let medianLatency: Double
    /// Sum of reported costs only.
    let knownCost: Double
    /// Runs with no reported cost (so `knownCost` is a lower bound).
    let unknownCostRuns: Int

    var passRate: Double { runs == 0 ? 0 : Double(passed) / Double(runs) }
}

enum ModelLeaderboard {
    /// Per-model stats from experiment runs, best pass rate first, then more
    /// runs, then lower median latency, then model ID (deterministic).
    static func rows(_ runs: [ExperimentRunSummary]) -> [ModelLeaderboardRow] {
        let grouped: [String: [ExperimentRunSummary]] = Dictionary(grouping: runs, by: \.modelID)
        var rows: [ModelLeaderboardRow] = []
        for (model, items) in grouped {
            let passed = items.filter { $0.verdict == ExperimentVerdict.passed.rawValue }.count
            let unverified = items.filter { $0.verdict == ExperimentVerdict.unverified.rawValue }.count
            let latencies: [Double] = items.map(\.latencySeconds)
            let knownCost: Double = items.compactMap(\.knownCost).reduce(0, +)
            let unknownCostRuns = items.filter { $0.knownCost == nil }.count
            rows.append(ModelLeaderboardRow(
                modelID: model, runs: items.count, passed: passed, unverified: unverified,
                medianLatency: median(latencies), knownCost: knownCost, unknownCostRuns: unknownCostRuns))
        }
        return rows.sorted(by: ranksBefore)
    }

    private static func ranksBefore(_ a: ModelLeaderboardRow, _ b: ModelLeaderboardRow) -> Bool {
        if a.passRate != b.passRate { return a.passRate > b.passRate }
        if a.runs != b.runs { return a.runs > b.runs }
        if a.medianLatency != b.medianLatency { return a.medianLatency < b.medianLatency }
        return a.modelID < b.modelID
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

enum ProjectHTMLFinder {
    static let skippedDirectories: Set<String> = ["node_modules", "build", "dist", ".build", "Pods", "vendor", "target"]
    static let maxDepth = 4
    static let maxResults = 20

    /// HTML files under `root`, skipping hidden entries, package/build
    /// folders and anything deeper than `maxDepth`. Sorted, capped.
    static func find(in root: URL, maxDepth: Int = maxDepth, limit: Int = maxResults) -> [URL] {
        let fm = FileManager.default
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) || enumerator.level >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "html" || ext == "htm" { found.append(url) }
        }
        return Array(found.sorted { $0.path < $1.path }.prefix(limit))
    }
}
