import SwiftUI

// MARK: - Test Suite results (Phase 6)

enum TestVerdictKind: String, CaseIterable, Sendable {
    case passed, unverified, failed

    static func of(_ result: TestRunResult) -> TestVerdictKind {
        if result.success { return .passed }
        return result.errorMessage == TestRunner.unverifiedMessage ? .unverified : .failed
    }

    var label: String {
        switch self {
        case .passed: return "Passed"
        case .unverified: return "Unverified"
        case .failed: return "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .unverified: return "questionmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tone: Color {
        switch self {
        case .passed: return ORBTheme.success
        case .unverified: return ORBTheme.warning
        case .failed: return ORBTheme.danger
        }
    }

    var explanation: String {
        switch self {
        case .passed: return "Every automatic check for this scenario succeeded (for project builds: the files exist and the build checks pass)."
        case .unverified: return "The model answered, but the scenario's rubric was not graded. Read the response yourself."
        case .failed: return "A check failed, the run errored, or it was cancelled or truncated."
        }
    }

    /// Sort rank: passed first, failed last.
    var rank: Int {
        switch self {
        case .passed: return 0
        case .unverified: return 1
        case .failed: return 2
        }
    }

    static let legendFootnote = "Unverified results are not graded and need your review: a response arrived, but nothing confirmed it is correct."
}

enum TestResultsTable {
    enum Field: String, CaseIterable, Identifiable {
        case scenario, model, verdict, cost, latency, tokens, when
        var id: String { rawValue }
        var title: String {
            switch self {
            case .scenario: return "Scenario"
            case .model: return "Model"
            case .verdict: return "Result"
            case .cost: return "Cost"
            case .latency: return "Latency"
            case .tokens: return "Tokens"
            case .when: return "When"
            }
        }
    }

    /// Stable: rows with equal keys keep their input order in both directions.
    static func sorted(_ rows: [TestRunResult], by field: Field, ascending: Bool) -> [TestRunResult] {
        func key(_ r: TestRunResult) -> Double {
            switch field {
            case .cost: return r.cost
            case .latency: return Double(r.latencyMs)
            case .tokens: return Double(r.totalTokens)
            case .when: return r.timestamp.timeIntervalSince1970
            case .verdict: return Double(TestVerdictKind.of(r).rank)
            case .scenario, .model: return 0
            }
        }
        func text(_ r: TestRunResult) -> String { field == .scenario ? r.scenarioTitle : r.modelId }
        let indexed = rows.enumerated().map { ($0.offset, $0.element) }
        let ordered = indexed.sorted { lhs, rhs in
            let (li, l) = lhs, (ri, r) = rhs
            let cmp: ComparisonResult
            if field == .scenario || field == .model {
                cmp = text(l).localizedCaseInsensitiveCompare(text(r))
            } else {
                let a = key(l), b = key(r)
                cmp = a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
            }
            if cmp == .orderedSame { return li < ri }
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
        return ordered.map(\.1)
    }

    static func counts(_ rows: [TestRunResult]) -> [TestVerdictKind: Int] {
        rows.reduce(into: [:]) { $0[TestVerdictKind.of($1), default: 0] += 1 }
    }

    static func filter(_ rows: [TestRunResult], verdict: TestVerdictKind?) -> [TestRunResult] {
        guard let verdict else { return rows }
        return rows.filter { TestVerdictKind.of($0) == verdict }
    }

    static func summary(_ rows: [TestRunResult]) -> String {
        guard !rows.isEmpty else { return "No results yet" }
        let c = counts(rows)
        return TestVerdictKind.allCases.map { "\(c[$0] ?? 0) \($0.label.lowercased())" }.joined(separator: " · ")
    }

    struct Total: Equatable {
        let amount: Double
        let isLowerBound: Bool
        var text: String { (isLowerBound ? "≥ " : "") + TestResultsTable.costText(amount, zeroAsDash: false) }
    }

    /// A zero cost means "unreported", so any zero makes the total a floor.
    static func totalCost(_ rows: [TestRunResult]) -> Total {
        Total(amount: rows.reduce(0) { $0 + $1.cost }, isLowerBound: rows.contains { $0.cost <= 0 })
    }

    static func costText(_ value: Double, zeroAsDash: Bool = true) -> String {
        if value <= 0 { return zeroAsDash ? "—" : "$0.00" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}

struct TestVerdictPill: View {
    let kind: TestVerdictKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(ORBFont.caption.weight(.medium))
            .foregroundStyle(kind.tone)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(kind.tone.opacity(ORBPalette.subtleFillAlpha), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct TestVerdictLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(TestVerdictKind.allCases, id: \.self) { kind in
                HStack(alignment: .top, spacing: 8) {
                    TestVerdictPill(kind: kind)
                    Text(kind.explanation).font(ORBFont.caption).foregroundStyle(.secondary)
                }
            }
            Text(TestVerdictKind.legendFootnote).font(ORBFont.caption.weight(.medium))
        }
    }
}

/// Sortable results table with a verdict filter. Selecting a row reopens the scenario.
struct TestResultsTableView: View {
    let results: [TestRunResult]
    let onOpen: (TestRunResult) -> Void
    let onDelete: (TestRunResult) -> Void
    @State private var field: TestResultsTable.Field = .when
    @State private var ascending = false
    @State private var verdict: TestVerdictKind?

    private var rows: [TestRunResult] {
        TestResultsTable.sorted(TestResultsTable.filter(results, verdict: verdict), by: field, ascending: ascending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RESULTS").font(ORBFont.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(TestResultsTable.summary(results)).font(ORBFont.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Spend " + TestResultsTable.totalCost(results).text)
                    .font(ORBFont.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("A dash means the provider reported no cost, so the total is a lower bound.")
                Picker("Show", selection: $verdict) {
                    Text("All").tag(TestVerdictKind?.none)
                    ForEach(TestVerdictKind.allCases, id: \.self) { Text($0.label).tag(TestVerdictKind?.some($0)) }
                }
                .pickerStyle(.menu).fixedSize()
            }
            header
            ForEach(rows) { r in
                row(r)
            }
            DisclosureGroup("What do these results mean?") { TestVerdictLegend().padding(.top, 6) }
                .font(ORBFont.footnote)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(TestResultsTable.Field.allCases) { f in
                Button {
                    if field == f { ascending.toggle() } else { field = f; ascending = (f == .scenario || f == .model) }
                } label: {
                    HStack(spacing: 2) {
                        Text(f.title)
                        if field == f { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 11)) }
                    }
                    .font(ORBFont.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(f.title)")
                .accessibilityValue(field == f ? (ascending ? "ascending" : "descending") : "")
            }
        }
        .padding(.horizontal, 10)
        .foregroundStyle(.secondary)
    }

    private func row(_ r: TestRunResult) -> some View {
        Button { onOpen(r) } label: {
            HStack(spacing: 8) {
                Text(r.scenarioTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(shortModelName(r.modelId)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                TestVerdictPill(kind: .of(r)).frame(maxWidth: .infinity, alignment: .leading)
                Text(TestResultsTable.costText(r.cost)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                Text("\(r.latencyMs) ms").monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                Text("\(r.totalTokens)").monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                Text(r.timestamp.formatted(date: .abbreviated, time: .shortened)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(ORBFont.footnote)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(TestVerdictKind.of(r).explanation)
        .contextMenu {
            Button("Delete Result", role: .destructive) { onDelete(r) }
        }
    }
}
