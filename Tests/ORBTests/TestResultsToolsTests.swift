import Foundation
import Testing
@testable import ORB

@MainActor
private func result(_ scenario: String, _ model: String, success: Bool, unverified: Bool = false,
                    cost: Double = 0, at seconds: TimeInterval, error: String? = nil) -> TestRunResult {
    TestRunResult(scenarioId: scenario, scenarioTitle: "Title \(scenario)", category: .webDevelopment,
                  modelId: model, response: "", promptTokens: 1, completionTokens: 2, totalTokens: 3,
                  cost: cost, latencyMs: 10, success: success,
                  errorMessage: unverified ? TestRunner.unverifiedMessage : error, outputPath: nil,
                  timestamp: Date(timeIntervalSince1970: seconds))
}

@Suite("Test results CSV")
@MainActor
struct TestResultsCSVTests {
    @Test("RFC 4180 quoting and CRLF")
    func quoting() {
        #expect(TestResultsCSV.field("plain") == "plain")
        #expect(TestResultsCSV.field("a,b") == "\"a,b\"")
        #expect(TestResultsCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(TestResultsCSV.field("line\nbreak") == "\"line\nbreak\"")
        #expect(TestResultsCSV.field("cr\rx") == "\"cr\rx\"")
    }

    @Test("unknown cost is blank; known cost is numeric; verdict column")
    func rows() {
        let csv = TestResultsCSV.encode([
            result("s1", "m/a", success: true, cost: 0.0123, at: 0),
            result("s2", "m/b", success: false, at: 1, error: "Boom, \"bad\""),
            result("s3", "m/c", success: false, unverified: true, at: 2)
        ])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 5 && lines.last == "")
        #expect(lines[0] == TestResultsCSV.header.joined(separator: ","))
        let costIndex = TestResultsCSV.header.firstIndex(of: "cost_usd")!
        #expect(lines[1].components(separatedBy: ",")[costIndex] == "0.012300")
        #expect(lines[1].contains(",passed,"))
        #expect(lines[2].components(separatedBy: ",")[costIndex] == "")
        #expect(lines[2].contains("\"Boom, \"\"bad\"\"\""))
        #expect(lines[3].contains(",unverified,"))
    }

    @Test("experiment JSON export round-trips through the existing encoder")
    func jsonRoundTrip() throws {
        let scenario = try #require(TestCatalog.allScenarios.first)
        let record = ExperimentEvaluation.record(
            scenario: scenario, modelID: "m/a", policy: ToolPolicy(capabilities: []), projectDirectory: nil,
            response: "hello", usage: nil, completionStatus: .completed, startedAt: Date(timeIntervalSince1970: 5),
            finishedAt: Date(timeIntervalSince1970: 7), errorMessage: nil, evaluationMode: .textResponse)
        let json = try ExperimentExport.encodeJSON(records: [record])
        #expect(try ExperimentExport.decodeJSON(json) == [record])
    }
}

@Suite("Rerun planning")
@MainActor
struct TestRerunPlannerTests {
    @Test("groups latest failed/unverified per scenario; skips pairs whose latest run passed")
    func grouping() {
        let rows = [
            result("s1", "a", success: false, at: 10),
            result("s1", "b", success: false, unverified: true, at: 9),
            result("s1", "c", success: true, at: 8),
            result("s2", "a", success: true, at: 20),   // newest s2/a passed …
            result("s2", "a", success: false, at: 5),   // … so this old failure is ignored
            result("s2", "b", success: false, at: 4),
            result("s1", "a", success: false, at: 1)    // duplicate pair, older
        ]
        let batches = TestRerunPlanner.batches(from: rows.shuffled())
        #expect(batches == [
            TestRerunBatch(scenarioID: "s1", modelIDs: ["a", "b"]),
            TestRerunBatch(scenarioID: "s2", modelIDs: ["b"])
        ])
        #expect(TestRerunPlanner.modelCount(batches) == 3)
    }

    @Test("respects the 5-model cap by splitting a scenario into several batches")
    func cap() {
        let rows = (0..<12).map { result("s", "m\($0)", success: false, at: TimeInterval(100 - $0)) }
        let batches = TestRerunPlanner.batches(from: rows)
        #expect(batches.map(\.modelIDs.count) == [5, 5, 2])
        #expect(batches.allSatisfy { $0.modelIDs.count <= TestBatchSelection.maximumModels })
        #expect(batches.flatMap(\.modelIDs) == (0..<12).map { "m\($0)" })
    }

    @Test("nothing to rerun when everything passed")
    func allPassed() {
        #expect(TestRerunPlanner.batches(from: [result("s", "a", success: true, at: 0)]).isEmpty)
    }
}

@Suite("Results paging and leaderboard")
@MainActor
struct TestResultsPagingTests {
    @Test("notice only when truncated")
    func notice() {
        #expect(TestResultsPaging.notice(shown: 10, total: 10) == nil)
        #expect(TestResultsPaging.notice(shown: 200, total: 1234) == "Showing newest 200 of 1,234 results")
    }

    @Test("count and load-all see past the 200-row page")
    @MainActor
    func dbPaging() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-results-\(UUID()).sqlite3").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let db = DatabaseManager(path: path)
        for i in 0..<205 { db.saveTestResult(result("s", "m", success: i % 2 == 0, at: TimeInterval(i))) }
        #expect(db.loadTestResults().count == 200)
        #expect(db.countTestResults() == 205)
        let all = db.loadAllTestResults()
        #expect(all.count == 205)
        #expect(all.first?.timestamp == Date(timeIntervalSince1970: 204))
    }

    @Test("leaderboard: pass rate, median latency, known cost floor, deterministic order")
    func leaderboard() {
        let runs = [
            ExperimentRunSummary(modelID: "b", verdict: "passed", latencySeconds: 4, knownCost: 0.1),
            ExperimentRunSummary(modelID: "b", verdict: "failed", latencySeconds: 2, knownCost: nil),
            ExperimentRunSummary(modelID: "a", verdict: "passed", latencySeconds: 1, knownCost: 0.2),
            ExperimentRunSummary(modelID: "a", verdict: "passed", latencySeconds: 3, knownCost: 0.3),
            ExperimentRunSummary(modelID: "a", verdict: "unverified", latencySeconds: 9, knownCost: 0.1),
            ExperimentRunSummary(modelID: "c", verdict: "unverified", latencySeconds: 1, knownCost: nil)
        ]
        let rows = ModelLeaderboard.rows(runs)
        #expect(rows.map(\.modelID) == ["a", "b", "c"])
        #expect(rows[0].passed == 2 && rows[0].unverified == 1 && rows[0].runs == 3)
        #expect(rows[0].medianLatency == 3)
        #expect(abs(rows[0].knownCost - 0.6) < 1e-9 && rows[0].unknownCostRuns == 0)
        #expect(rows[1].medianLatency == 3)
        #expect(rows[1].unknownCostRuns == 1)
        #expect(rows[2].passRate == 0)
        #expect(ModelLeaderboard.median([]) == 0)
    }

    @Test("leaderboard rows load from experiment_runs")
    @MainActor
    func leaderboardFromDB() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-lb-\(UUID()).sqlite3").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let db = DatabaseManager(path: path)
        let scenario = try #require(TestCatalog.allScenarios.first)
        let record = ExperimentEvaluation.record(
            scenario: scenario, modelID: "m/x", policy: ToolPolicy(capabilities: []), projectDirectory: nil,
            response: "", usage: nil, completionStatus: .failed, startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 12.5), errorMessage: "x", evaluationMode: .textResponse)
        try db.saveExperimentRunRecordChecked(record)
        let rows = db.loadExperimentRunSummaries()
        #expect(rows == [ExperimentRunSummary(modelID: "m/x", verdict: record.verdict.rawValue, latencySeconds: 2.5, knownCost: nil)])
    }
}

@Suite("Project HTML finder")
struct ProjectHTMLFinderTests {
    @Test("skips hidden, node_modules, symlinks and over-deep files; sorted")
    func finds() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orb-html-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func touch(_ rel: String) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<html>".utf8).write(to: url)
        }
        try touch("index.html")
        try touch("pages/about.HTM")
        try touch("node_modules/pkg/readme.html")
        try touch(".git/hidden.html")
        try touch("a/b/c/d/e/deep.html")
        try touch("a/b/ok.html")
        try touch("style.css")
        let outside = fm.temporaryDirectory.appendingPathComponent("orb-html-out-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("leak.html"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let names = ProjectHTMLFinder.find(in: root).map(\.lastPathComponent)
        #expect(names == ["ok.html", "index.html", "about.HTM"])
        #expect(ProjectHTMLFinder.find(in: root, limit: 1).count == 1)
        #expect(ProjectHTMLFinder.find(in: root.appendingPathComponent("missing")).isEmpty)
    }
}
