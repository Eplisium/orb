import SwiftUI
import Foundation

// MARK: - Side-by-side compare (Test Suite)

struct CompareCell: Equatable {
    let verdict: TestVerdictKind
    let cost: Double
    let latencyMs: Int
    let timestamp: Date
}

struct CompareRow: Identifiable, Equatable {
    let scenarioId: String
    let scenarioTitle: String
    let cells: [String: CompareCell]
    var id: String { scenarioId }

    /// Only passed runs compete: a failed run that was quick or cheap is not a win.
    private var contenders: [(String, CompareCell)] {
        let passed = cells.filter { $0.value.verdict == .passed }.sorted { $0.key < $1.key }
        return passed.count >= 2 ? passed.map { ($0.key, $0.value) } : []
    }
    var fastestModel: String? { contenders.min { $0.1.latencyMs < $1.1.latencyMs }?.0 }
    var cheapestModel: String? { contenders.min { $0.1.cost < $1.1.cost }?.0 }
}

struct CompareColumnSummary: Equatable {
    var passed = 0, unverified = 0, failed = 0
    var cost = 0.0
    var costIsLowerBound = false
    var text: String { "\(passed) passed · \(unverified) unverified · \(failed) failed" }
}

struct CompareMatrix: Equatable {
    let models: [String]
    let rows: [CompareRow]

    static func make(_ results: [TestRunResult], models only: [String]? = nil) -> CompareMatrix {
        let kept = only.map { set in results.filter { set.contains($0.modelId) } } ?? results
        // Newest result wins for each (scenario, model) pair.
        var latest: [String: [String: TestRunResult]] = [:]
        var titles: [String: String] = [:]
        var order: [String] = []
        for r in kept.sorted(by: { $0.timestamp < $1.timestamp }) {
            if latest[r.scenarioId] == nil { order.append(r.scenarioId) }
            latest[r.scenarioId, default: [:]][r.modelId] = r
            titles[r.scenarioId] = r.scenarioTitle
        }
        let models = Array(Set(kept.map(\.modelId))).sorted()
        let rows = order.sorted { (titles[$0] ?? $0) < (titles[$1] ?? $1) }.map { id in
            CompareRow(scenarioId: id, scenarioTitle: titles[id] ?? id,
                       cells: (latest[id] ?? [:]).mapValues {
                           CompareCell(verdict: .of($0), cost: $0.cost, latencyMs: $0.latencyMs, timestamp: $0.timestamp)
                       })
        }
        return CompareMatrix(models: models, rows: rows)
    }

    func summary(for model: String) -> CompareColumnSummary {
        var s = CompareColumnSummary()
        for cell in rows.compactMap({ $0.cells[model] }) {
            switch cell.verdict {
            case .passed: s.passed += 1
            case .unverified: s.unverified += 1
            case .failed: s.failed += 1
            }
            s.cost += cell.cost
            if cell.cost <= 0 { s.costIsLowerBound = true }
        }
        return s
    }
}

struct CompareMatrixView: View {
    let results: [TestRunResult]
    var models: [String]?

    var body: some View {
        let matrix = CompareMatrix.make(results, models: models)
        if matrix.models.count < 2 {
            Text("Run at least two models on the same scenario to compare them side by side.")
                .font(ORBFont.footnote).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Scenario").font(ORBFont.caption.weight(.bold))
                        ForEach(matrix.models, id: \.self) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortModelName(m)).font(ORBFont.caption.weight(.bold))
                                let s = matrix.summary(for: m)
                                Text(s.text).font(ORBFont.caption).foregroundStyle(.secondary)
                                Text((s.costIsLowerBound ? "≥ " : "") + TestResultsTable.costText(s.cost, zeroAsDash: false))
                                    .font(ORBFont.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    ForEach(matrix.rows) { row in
                        GridRow {
                            Text(row.scenarioTitle).font(ORBFont.footnote).frame(maxWidth: 180, alignment: .leading)
                            ForEach(matrix.models, id: \.self) { m in cell(row, m) }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func cell(_ row: CompareRow, _ model: String) -> some View {
        if let c = row.cells[model] {
            VStack(alignment: .leading, spacing: 2) {
                TestVerdictPill(kind: c.verdict)
                Text("\(c.latencyMs) ms · \(TestResultsTable.costText(c.cost))")
                    .font(ORBFont.caption.monospacedDigit()).foregroundStyle(.secondary)
                if row.fastestModel == model { Label("Fastest", systemImage: "bolt.fill").font(ORBFont.caption) }
                if row.cheapestModel == model { Label("Cheapest", systemImage: "dollarsign.circle").font(ORBFont.caption) }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Not run").font(ORBFont.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Save feedback

@MainActor
final class SaveFeedback: ObservableObject {
    @Published private(set) var status: SaveStatus = .idle
    private let what: String
    private let center: ToastCenter
    private let displayTime: Duration
    private var fade: Task<Void, Never>?

    init(what: String, center: ToastCenter = AppToasts.center, displayTime: Duration = .seconds(2)) {
        self.what = what
        self.center = center
        self.displayTime = displayTime
    }

    func begin() { fade?.cancel(); status = .saving }

    func succeed() {
        status = .saved
        AppToasts.saved(what, center: center)
        fade?.cancel()
        fade = Task { [weak self, displayTime] in
            try? await Task.sleep(for: displayTime)
            guard !Task.isCancelled, let self else { return }
            self.status = self.status.afterDisplayTime
        }
    }

    /// Failures stay until the next attempt.
    func fail(_ reason: String) {
        fade?.cancel()
        status = .failed(reason)
        AppToasts.saveFailed(what, reason: reason, center: center)
    }

    /// Runs a save that reports failure as an error string (nil = success).
    @discardableResult
    func run(_ save: () -> String?) -> Bool {
        begin()
        if let error = save() { fail(error); return false }
        succeed(); return true
    }
}

// MARK: - Job notifications

enum JobNotification {
    struct Content: Equatable { let title: String; let body: String }
    static let soundKey = "orb.notifications.sound"

    /// Only outcomes the user didn't just cause. A local stop is their own action.
    static func content(for state: JobPollingState, kind: String) -> Content? {
        let noun = kind.prefix(1).uppercased() + kind.dropFirst()
        switch state {
        case .completed: return Content(title: "\(noun) ready", body: "Your \(kind) finished and is ready to open.")
        case .failed: return Content(title: "\(noun) failed", body: "The provider reported a failure.")
        case .expired: return Content(title: "\(noun) expired", body: "The result is no longer available.")
        case .cancelled: return Content(title: "\(noun) cancelled", body: "The provider cancelled this job.")
        case .idle, .polling, .stoppedLocally: return nil
        }
    }

    static func soundEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: soundKey) }
}

// MARK: - Increase Contrast

enum ORBContrast {
    static func fillAlpha(base: Double, increased: Bool) -> Double { increased ? min(1, base * 2.5 + 0.04) : base }
    static func borderWidth(increased: Bool) -> CGFloat { increased ? 2 : 1 }
}

// MARK: - About

struct AboutInfo {
    let name: String
    let versionText: String

    init(bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        name = (bundleInfo["CFBundleName"] as? String) ?? "ORB"
        let short = bundleInfo["CFBundleShortVersionString"] as? String
        let build = bundleInfo["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): versionText = "Version \(s) (\(b))"
        case let (s?, nil): versionText = "Version \(s)"
        default: versionText = "Development build"
        }
    }

    static let privacyNote = "Your OpenRouter keys are stored in the macOS Keychain. ORB only contacts OpenRouter and the MCP servers you configure, and only when you make a request."
}

struct AboutPane: View {
    private let info = AboutInfo()

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(info.name).font(ORBFont.title)
            Text(info.versionText).font(ORBFont.footnote).foregroundStyle(.secondary)
            Text(AboutInfo.privacyNote).font(ORBFont.footnote).multilineTextAlignment(.center).frame(maxWidth: 380)
            Link("Source on GitHub", destination: URL(string: "https://github.com/Eplisium/orb")!)
                .font(ORBFont.footnote)
        }
        .padding(24)
    }
}

/// A faint surface fill that strengthens under Increase Contrast.
/// Use instead of `Color.primary.opacity(0.0x)` for card and row backgrounds.
struct ORBSurface: ShapeStyle {
    let base: Double

    func alpha(for contrast: ColorSchemeContrast) -> Double {
        ORBContrast.fillAlpha(base: base, increased: contrast == .increased)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        Color.primary.opacity(alpha(for: environment.colorSchemeContrast))
    }
}

extension ShapeStyle where Self == ORBSurface {
    static func orbSurface(_ base: Double) -> ORBSurface { ORBSurface(base: base) }
}

// MARK: - Text scaling (macOS has no Dynamic Type)

/// `dynamicTypeSize` is a no-op for text on macOS, so ORB scales its own fonts.
/// `ORBScaledFont` reads this from the environment.
private struct ORBTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var orbTextScale: CGFloat {
        get { self[ORBTextScaleKey.self] }
        set { self[ORBTextScaleKey.self] = newValue }
    }
}

extension AppearancePrefs.TextSize {
    var scale: CGFloat {
        switch self {
        case .small: return 0.92
        case .standard: return 1
        case .large: return 1.15
        case .xLarge: return 1.3
        }
    }
}

/// Drop-in for `.font(.system(size: n, ...))` that follows the Text size setting.
struct ORBScaledFont: ViewModifier {
    @Environment(\.orbTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    static func points(_ size: CGFloat, scale: CGFloat) -> CGFloat { max(ORBFont.minimumPointSize, (size * scale).rounded()) }

    func body(content: Content) -> some View {
        content.font(.system(size: Self.points(size, scale: scale), weight: weight, design: design))
    }
}

extension View {
    func orbFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ORBScaledFont(size: size, weight: weight, design: design))
    }
}

/// A small standalone window for About; the standard panel can't show the privacy note.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: AboutPane().orbAppearance())
        let w = NSWindow(contentViewController: host)
        w.title = "About ORB"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
