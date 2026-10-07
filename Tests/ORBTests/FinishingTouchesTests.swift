import Testing
import SwiftUI
import Foundation
@testable import ORB

private func res(_ scenario: String, _ model: String, ok: Bool = true, msg: String? = nil,
                 cost: Double = 0.01, latency: Int = 100, at: TimeInterval = 0) -> TestRunResult {
    TestRunResult(scenarioId: scenario, scenarioTitle: scenario.uppercased(), category: .allCases.first!, modelId: model,
                  response: "", promptTokens: 0, completionTokens: 0, totalTokens: 5, cost: cost, latencyMs: latency,
                  success: ok, errorMessage: msg, timestamp: Date(timeIntervalSince1970: at))
}

// MARK: Side-by-side compare

@Suite("Finishing: compare matrix")
struct CompareMatrixTests {
    @Test("Rows are scenarios, columns are models, each cell holds that pair's latest result")
    func shape() {
        let m = CompareMatrix.make([
            res("s1", "a/x", at: 1), res("s1", "b/y", ok: false, msg: "bad", at: 2),
            res("s2", "a/x", at: 3),
        ])
        #expect(m.models == ["a/x", "b/y"])
        #expect(m.rows.map(\.scenarioTitle) == ["S1", "S2"])
        #expect(m.rows[0].cells["a/x"]?.verdict == .passed)
        #expect(m.rows[0].cells["b/y"]?.verdict == .failed)
        #expect(m.rows[1].cells["b/y"] == nil, "a pair that was never run is empty, not failed")
    }

    @Test("When a pair ran twice only the newest result is shown")
    func latestWins() {
        let m = CompareMatrix.make([res("s1", "a/x", ok: false, msg: "old", at: 1), res("s1", "a/x", ok: true, at: 9)])
        #expect(m.rows[0].cells["a/x"]?.verdict == .passed)
    }

    @Test("Column summaries count verdicts and total spend per model, flagging unreported cost")
    func columns() {
        let m = CompareMatrix.make([
            res("s1", "a/x", cost: 0.10), res("s2", "a/x", ok: false, msg: TestRunner.unverifiedMessage, cost: 0),
            res("s1", "b/y", cost: 0.20), res("s2", "b/y", cost: 0.20),
        ])
        let a = m.summary(for: "a/x"), b = m.summary(for: "b/y")
        #expect(a.passed == 1 && a.unverified == 1 && a.failed == 0)
        #expect(a.costIsLowerBound && !b.costIsLowerBound)
        #expect(abs(b.cost - 0.40) < 0.0001)
    }

    @Test("Fastest and cheapest per row are marked with words, only among passed cells")
    func highlights() {
        let m = CompareMatrix.make([
            res("s1", "a/x", cost: 0.50, latency: 100), res("s1", "b/y", cost: 0.10, latency: 900),
            res("s1", "c/z", ok: false, msg: "bad", cost: 0.01, latency: 10),
        ])
        let row = m.rows[0]
        #expect(row.fastestModel == "a/x")
        #expect(row.cheapestModel == "b/y", "a failed run being cheap or fast is not a win")
    }

    @Test("A single passed cell has no winner to mark")
    func noWinnerAlone() {
        let m = CompareMatrix.make([res("s1", "a/x")])
        #expect(m.rows[0].fastestModel == nil && m.rows[0].cheapestModel == nil)
    }

    @Test("Empty input gives an empty matrix")
    func empty() {
        let m = CompareMatrix.make([])
        #expect(m.models.isEmpty && m.rows.isEmpty)
    }

    @Test("Restricting to a model set keeps only those columns")
    func restrict() {
        let m = CompareMatrix.make([res("s1", "a/x"), res("s1", "b/y")], models: ["b/y"])
        #expect(m.models == ["b/y"])
        #expect(m.rows[0].cells.keys.sorted() == ["b/y"])
    }
}

// MARK: Save feedback

@MainActor
@Suite("Finishing: save feedback")
struct SaveFeedbackTests {
    @Test("A successful save goes saving → saved, toasts once, and fades to idle")
    func success() async {
        let center = ToastCenter()
        let f = SaveFeedback(what: "API key", center: center, displayTime: .milliseconds(20))
        f.begin()
        #expect(f.status == .saving)
        f.succeed()
        #expect(f.status == .saved)
        #expect(center.toasts.map(\.message) == ["API key saved"])
        // Poll instead of one fixed sleep: a loaded machine can delay the 20 ms fade.
        for _ in 0..<200 where f.status != .idle { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(f.status == .idle)
    }

    @Test("A failed save stays visible until the next attempt and toasts the reason")
    func failure() async {
        let center = ToastCenter()
        let f = SaveFeedback(what: "API key", center: center, displayTime: .milliseconds(20))
        f.fail("Keychain locked")
        try? await Task.sleep(for: .milliseconds(120))
        #expect(f.status == .failed("Keychain locked"))
        #expect(center.toasts.last?.kind == .error)
        f.begin()
        #expect(f.status == .saving)
    }

    @Test("run() maps nil to success and an error string to failure")
    func run() {
        let center = ToastCenter()
        let ok = SaveFeedback(what: "Key", center: center)
        #expect(ok.run { nil })
        #expect(ok.status == .saved)
        let bad = SaveFeedback(what: "Key", center: center)
        #expect(!bad.run { "denied" })
        #expect(bad.status == .failed("denied"))
    }
}

// MARK: Job notification policy

@Suite("Finishing: job notifications")
struct JobNotificationPolicyTests {
    @Test("Only finished-with-news states notify, with a clear title and body")
    func content() {
        #expect(JobNotification.content(for: .completed, kind: "video")?.title == "Video ready")
        #expect(JobNotification.content(for: .failed, kind: "video")?.title == "Video failed")
        #expect(JobNotification.content(for: .expired, kind: "video")?.title == "Video expired")
        #expect(JobNotification.content(for: .polling, kind: "video") == nil)
        #expect(JobNotification.content(for: .idle, kind: "video") == nil)
        #expect(JobNotification.content(for: .stoppedLocally, kind: "video") == nil, "the user just did that; no ping")
    }

    @Test("Sound is opt-in and off by default")
    func sound() {
        let name = "orb.tests.notif.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        #expect(!JobNotification.soundEnabled(defaults: d))
        d.set(true, forKey: JobNotification.soundKey)
        #expect(JobNotification.soundEnabled(defaults: d))
    }
}

// MARK: Contrast

@Suite("Finishing: increase contrast")
struct ContrastTests {
    @Test("Subtle fills get stronger and borders thicker under Increase Contrast")
    func values() {
        #expect(ORBContrast.fillAlpha(base: 0.04, increased: true) > ORBContrast.fillAlpha(base: 0.04, increased: false))
        #expect(ORBContrast.fillAlpha(base: 0.04, increased: false) == 0.04)
        #expect(ORBContrast.fillAlpha(base: 0.9, increased: true) <= 1)
        #expect(ORBContrast.borderWidth(increased: true) > ORBContrast.borderWidth(increased: false))
    }
}

// MARK: About

@Suite("Finishing: about info")
struct AboutInfoTests {
    @Test("Version text falls back cleanly when the bundle has no metadata")
    func fallback() {
        let info = AboutInfo(bundleInfo: [:])
        #expect(info.name == "ORB")
        #expect(info.versionText == "Development build")
    }

    @Test("Version and build are combined when present")
    func present() {
        let info = AboutInfo(bundleInfo: ["CFBundleShortVersionString": "1.4", "CFBundleVersion": "27"])
        #expect(info.versionText == "Version 1.4 (27)")
    }

    @Test("The About credits state where keys live and that nothing is sent without a request")
    func privacy() {
        #expect(AboutInfo.privacyNote.localizedCaseInsensitiveContains("keychain"))
    }
}
