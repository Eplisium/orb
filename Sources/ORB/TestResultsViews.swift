import AppKit
import SwiftUI

/// "Open in browser" buttons for a test project's HTML files. The folder is
/// scanned once per path, off the main actor (bounded depth, hidden and
/// package/build folders skipped) — never in the view body.
struct ProjectHTMLButtons: View {
    let projectPath: String
    let accent: Color
    let controlRadius: CGFloat
    @State private var files: [URL] = []

    var body: some View {
        Group {
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OPEN IN BROWSER")
                        .orbFont(size: 11, weight: .bold)
                        .foregroundStyle(.secondary)
                    ForEach(files, id: \.self) { file in
                        Button { NSWorkspace.shared.open(file) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "safari.fill")
                                Text(relativeName(file)).lineLimit(1)
                            }
                            .orbFont(size: 11, weight: .medium)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(accent.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: controlRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: projectPath) {
            let root = URL(fileURLWithPath: projectPath, isDirectory: true)
            files = await Task.detached(priority: .utility) { ProjectHTMLFinder.find(in: root) }.value
        }
    }

    private func relativeName(_ url: URL) -> String {
        let base = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }
}

/// Per-model leaderboard from recorded experiment runs.
struct ModelLeaderboardView: View {
    let rows: [ModelLeaderboardRow]

    var body: some View {
        if rows.isEmpty {
            Text("No recorded runs yet.").font(ORBFont.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Pass rate").frame(width: 90, alignment: .trailing)
                    Text("Runs").frame(width: 50, alignment: .trailing)
                    Text("Median").frame(width: 70, alignment: .trailing)
                    Text("Known cost").frame(width: 90, alignment: .trailing)
                }
                .font(ORBFont.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack {
                        Text(shortModelName(row.modelID)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.modelID)
                        Text("\(Int((row.passRate * 100).rounded()))%").frame(width: 90, alignment: .trailing)
                            .help("\(row.passed) passed, \(row.unverified) unverified, \(row.runs - row.passed - row.unverified) failed")
                        Text("\(row.runs)").frame(width: 50, alignment: .trailing)
                        Text(String(format: "%.1fs", row.medianLatency)).frame(width: 70, alignment: .trailing)
                        Text((row.unknownCostRuns > 0 ? "≥ " : "") + TestResultsTable.costText(row.knownCost, zeroAsDash: false))
                            .frame(width: 90, alignment: .trailing)
                            .help(row.unknownCostRuns > 0 ? "\(row.unknownCostRuns) run(s) reported no cost." : "")
                    }
                    .font(ORBFont.footnote.monospacedDigit())
                }
                Text("Pass rate counts only verified passes; unverified text responses are not passes and cancelled runs are left out. Ranked by a confidence-adjusted pass rate, so a single lucky run does not top many reliable ones.")
                    .font(ORBFont.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Side-by-side outputs (TESTS-11)

/// The latest output of each model on one scenario, as scrolling columns.
struct ScenarioComparisonView: View {
    let results: [TestRunResult]
    var accent: Color = ORBTheme.accent
    @State private var copiedID: UUID?

    var body: some View {
        if results.count < 2 {
            Text("Run this test on at least two models (Compare Models…) to read their answers side by side.")
                .font(ORBFont.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(results) { column($0) }
                }
                .padding(2)
            }
        }
    }

    private func column(_ r: TestRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(shortModelName(r.modelId)).font(ORBFont.footnote.weight(.semibold)).lineLimit(1)
                    .help(r.modelId)
                Spacer(minLength: 4)
                TestVerdictPill(kind: .of(r))
            }
            Text([TestResultsTable.costText(r.cost), TestResultsTable.latencyText(r.latencyMs),
                  "\(r.totalTokens.formatted(.number.notation(.compactName))) tok",
                  r.ttftMs.map { "TTFT " + TestResultsTable.ttftText($0) },
                  r.tokensPerSec.map { TestResultsTable.throughputText($0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(ORBFont.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                Group {
                    if r.response.isEmpty {
                        Text(r.errorMessage ?? "No response.").font(ORBFont.footnote).foregroundStyle(.secondary)
                    } else {
                        MarkdownText(content: r.response, accent: accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(height: 320)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(r.response, forType: .string)
                copiedID = r.id
            } label: {
                Label(copiedID == r.id ? "Copied" : "Copy", systemImage: copiedID == r.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless).font(ORBFont.caption)
            .disabled(r.response.isEmpty)
        }
        .padding(10)
        .frame(width: 300, alignment: .topLeading)
        .background(.orbSurface(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.orbSurface(0.06), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(shortModelName(r.modelId)), \(TestVerdictKind.of(r).label)")
    }
}
