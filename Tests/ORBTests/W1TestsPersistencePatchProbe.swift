import Foundation
import Testing
@testable import ORB

// Verifies the DB patch proposed for the core/studio owners (not committed by tests track).
@Suite("W1 tests: persistence patch round trip", .serialized)
struct W1TestsPersistencePatchProbe {
    @Test("ttft, throughput and custom-test options survive a reload; legacy rows read nil")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w1tests-db-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = DatabaseManager(path: dir.appendingPathComponent("db.sqlite3").path)
        var r = TestRunResult(scenarioId: "s", scenarioTitle: "S", category: .apiDesign, modelId: "m", response: "x",
                              promptTokens: 1, completionTokens: 2, totalTokens: 3, cost: 0.1, latencyMs: 9,
                              success: true, errorMessage: nil, outputPath: nil)
        r.ttftMs = 321; r.tokensPerSec = 12.5
        db.saveTestResult(r)
        let legacy = TestRunResult(scenarioId: "s2", scenarioTitle: "S", category: .apiDesign, modelId: "m", response: "",
                                   promptTokens: 0, completionTokens: 0, totalTokens: 0, cost: 0, latencyMs: 1,
                                   success: false, errorMessage: nil, outputPath: nil)
        db.saveTestResult(legacy)
        let loaded = db.loadTestResults()
        #expect(loaded.first { $0.id == r.id }?.ttftMs == 321)
        #expect(loaded.first { $0.id == r.id }?.tokensPerSec == 12.5)
        #expect(loaded.first { $0.id == legacy.id }?.ttftMs == nil)
        #expect(db.loadAllTestResults().first { $0.id == r.id }?.ttftMs == 321)
        let test = CustomTest(title: "T", userPrompt: "P", mode: .textResponse,
                              expectation: .init(kind: .regex, value: "^ok$"))
        db.saveCustomTest(test)
        let back = try #require(db.loadCustomTests().first { $0.id == test.id })
        #expect(back.mode == .textResponse && back.expectation == test.expectation)
    }
}
