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
                Text("Pass rate counts only verified passes; unverified text responses are not counted as passes.")
                    .font(ORBFont.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
