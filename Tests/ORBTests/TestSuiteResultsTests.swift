import Testing
import SwiftUI
import Foundation
@testable import ORB

private func result(
    _ title: String, model: String = "a/m", success: Bool = true, message: String? = nil,
    cost: Double = 0, latency: Int = 100, tokens: Int = 10, at seconds: TimeInterval = 0
) -> TestRunResult {
    TestRunResult(
        scenarioId: title, scenarioTitle: title, category: .allCases.first!, modelId: model, response: "",
        promptTokens: 0, completionTokens: 0, totalTokens: tokens, cost: cost, latencyMs: latency,
        success: success, errorMessage: message, timestamp: Date(timeIntervalSince1970: seconds)
    )
}

@Suite("Phase 6: test verdicts")
struct TestVerdictPresentationTests {
    @Test("Verdict derives from success and the unverified marker")
    func verdict() {
        #expect(TestVerdictKind.of(result("a")) == .passed)
        #expect(TestVerdictKind.of(result("a", success: false, message: "boom")) == .failed)
        #expect(TestVerdictKind.of(result("a", success: false, message: TestRunner.unverifiedMessage)) == .unverified)
    }

    @Test("Every verdict has a distinct symbol, a word, and an explanation; none relies on colour")
    func presentation() {
        let all = TestVerdictKind.allCases
        #expect(Set(all.map(\.symbol)).count == all.count)
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(all.allSatisfy { !$0.explanation.isEmpty && !$0.label.isEmpty })
        #expect(TestVerdictKind.unverified.explanation.localizedCaseInsensitiveContains("not graded"))
        #expect(TestVerdictKind.passed.explanation.localizedCaseInsensitiveContains("checks"))
    }

    @Test("Passed is never described as proof the answer is correct for unverified results")
    func honesty() {
        let text = TestVerdictKind.legendFootnote
        #expect(text.localizedCaseInsensitiveContains("unverified"))
        #expect(text.localizedCaseInsensitiveContains("review"))
    }
}

@Suite("Phase 6: results table model")
struct TestResultsTableTests {
    private let rows = [
        result("b", model: "x/zed", success: true, cost: 0.02, latency: 300, tokens: 50, at: 20),
        result("a", model: "x/alpha", success: false, message: "bad", cost: 0.00, latency: 100, tokens: 10, at: 30),
        result("c", model: "x/mid", success: false, message: TestRunner.unverifiedMessage, cost: 0.01, latency: 200, tokens: 30, at: 10),
    ]

    @Test("Sorts by every column in both directions")
    func sorting() {
        func titles(_ f: TestResultsTable.Field, _ asc: Bool) -> [String] {
            TestResultsTable.sorted(rows, by: f, ascending: asc).map(\.scenarioTitle)
        }
        #expect(titles(.scenario, true) == ["a", "b", "c"])
        #expect(titles(.scenario, false) == ["c", "b", "a"])
        #expect(titles(.model, true) == ["a", "c", "b"])
        #expect(titles(.cost, true) == ["a", "c", "b"])
        #expect(titles(.latency, false) == ["b", "c", "a"])
        #expect(titles(.tokens, true) == ["a", "c", "b"])
        #expect(titles(.when, false) == ["a", "b", "c"])
        #expect(titles(.verdict, true) == ["b", "c", "a"], "passed, then unverified, then failed")
    }

    @Test("Equal keys keep their original order (stable sort)")
    func stable() {
        let tied = [result("x", cost: 1, at: 1), result("y", cost: 1, at: 2), result("z", cost: 1, at: 3)]
        #expect(TestResultsTable.sorted(tied, by: .cost, ascending: true).map(\.scenarioTitle) == ["x", "y", "z"])
        #expect(TestResultsTable.sorted(tied, by: .cost, ascending: false).map(\.scenarioTitle) == ["x", "y", "z"])
    }

    @Test("Counts per verdict add up to the total")
    func counts() {
        let c = TestResultsTable.counts(rows)
        #expect(c[.passed] == 1 && c[.unverified] == 1 && c[.failed] == 1)
        #expect(c.values.reduce(0, +) == rows.count)
    }

    @Test("Filtering by verdict and summary line")
    func filtering() {
        #expect(TestResultsTable.filter(rows, verdict: .failed).map(\.scenarioTitle) == ["a"])
        #expect(TestResultsTable.filter(rows, verdict: nil).count == 3)
        #expect(TestResultsTable.summary(rows) == "1 passed · 1 unverified · 1 failed")
        #expect(TestResultsTable.summary([]) == "No results yet")
    }

    @Test("Total cost is a lower bound when any result reported zero cost")
    func lowerBound() {
        let t = TestResultsTable.totalCost(rows)
        #expect(abs(t.amount - 0.03) < 0.0001)
        #expect(t.isLowerBound, "zero-cost rows mean unreported, so the total is a floor")
        let allPriced = [result("a", cost: 0.5), result("b", cost: 0.25)]
        #expect(!TestResultsTable.totalCost(allPriced).isLowerBound)
        #expect(TestResultsTable.totalCost(allPriced).text == "$0.75")
        #expect(t.text.hasPrefix("≥ "))
    }

    @Test("Cost formatting follows the app's small-amount rule")
    func costText() {
        #expect(TestResultsTable.costText(0) == "—")
        #expect(TestResultsTable.costText(0.0042) == "$0.0042")
        #expect(TestResultsTable.costText(1.5) == "$1.50")
    }
}

@MainActor
@Suite("Phase 6: results render", .serialized)
struct TestResultsRenderTests {
    @Test("Legend renders in light and dark")
    func legend() {
        for scheme in [ColorScheme.light, .dark] {
            let r = ImageRenderer(content: TestVerdictLegend().environment(\.colorScheme, scheme).background(scheme == .dark ? Color.black : Color.white).frame(width: 520))
            r.scale = 1
            #expect(r.nsImage != nil)
        }
    }
}
