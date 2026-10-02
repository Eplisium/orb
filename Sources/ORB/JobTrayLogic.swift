import SwiftUI

// MARK: - Job tray (Phase 6)
//
// Presentation for durable media jobs. The important distinction: stopping
// local polling is not cancelling the remote job, and an unconfirmed
// submission must never be retried automatically (it can bill twice).

struct JobPresentation: Equatable {
    enum Action: Equatable { case resume, stop, open, dismiss }

    let label: String
    let detail: String
    let symbol: String
    let status: ORBStatus
    let actions: [Action]
    let costText: String?

    static func make(_ job: JobRecord) -> JobPresentation {
        let cost = job.usageCost.map { TestResultsTable.costText($0, zeroAsDash: false) }
        let error = job.recoverableError.map { " \($0)" } ?? ""

        if job.submissionState == .outcomeUnknown {
            return JobPresentation(
                label: "Submission unconfirmed",
                detail: "The request may or may not have reached the provider. Submitting again could create a duplicate and bill twice, so ORB never does it for you." + error,
                symbol: "questionmark.diamond", status: .interrupted, actions: [.dismiss], costText: cost)
        }
        if job.submissionState == .failed {
            return JobPresentation(
                label: "Not submitted", detail: "The provider rejected the request, so no job exists and nothing was billed." + error,
                symbol: "xmark.octagon", status: .failed, actions: [.dismiss], costText: cost)
        }

        switch job.pollingState {
        case .polling:
            return JobPresentation(label: "Running", detail: job.lastRemoteStatus.map { "Provider status: \($0)." } ?? "Waiting for the provider.",
                                   symbol: "arrow.triangle.2.circlepath", status: .running, actions: [.stop], costText: cost)
        case .idle:
            return JobPresentation(label: "Queued", detail: "Not being checked right now." + error,
                                   symbol: "clock", status: .queued, actions: job.isResumable ? [.resume] : [.dismiss], costText: cost)
        case .stoppedLocally:
            return JobPresentation(
                label: "Stopped checking",
                detail: "ORB stopped checking, but the job is probably still running at the provider and may still bill. Resume to pick it up." + error,
                symbol: "pause.circle", status: .interrupted, actions: job.isResumable ? [.resume] : [.dismiss], costText: cost)
        case .completed:
            return JobPresentation(label: "Done", detail: "Ready to open.", symbol: "checkmark.circle.fill",
                                   status: .complete, actions: [.open], costText: cost)
        case .failed:
            return JobPresentation(label: "Failed", detail: "The provider reported a failure." + error,
                                   symbol: "xmark.circle.fill", status: .failed, actions: [.dismiss], costText: cost)
        case .cancelled:
            return JobPresentation(label: "Cancelled", detail: "The provider reports this job was cancelled.",
                                   symbol: "slash.circle", status: .failed, actions: [.dismiss], costText: cost)
        case .expired:
            return JobPresentation(label: "Expired", detail: "The result is no longer available from the provider.",
                                   symbol: "hourglass.bottomhalf.filled", status: .failed, actions: [.dismiss], costText: cost)
        }
    }
}

enum JobTray {
    private static func group(_ job: JobRecord) -> Int {
        switch job.pollingState {
        case .polling, .stoppedLocally, .idle: return 0
        case .failed, .cancelled, .expired: return 1
        case .completed: return 2
        }
    }

    /// Active first, then problems, then finished; newest first inside each group.
    static func ordered(_ jobs: [JobRecord]) -> [JobRecord] {
        jobs.sorted { l, r in
            let a = group(l), b = group(r)
            return a == b ? l.createdAt > r.createdAt : a < b
        }
    }

    static func activeCount(_ jobs: [JobRecord]) -> Int { jobs.filter { group($0) == 0 }.count }

    static func badgeText(_ jobs: [JobRecord]) -> String? {
        let n = activeCount(jobs)
        return n > 0 ? "\(n)" : nil
    }

    static func summary(_ jobs: [JobRecord]) -> String {
        guard !jobs.isEmpty else { return "No jobs" }
        let active = activeCount(jobs)
        let attention = jobs.filter { group($0) == 1 }.count
        let finished = jobs.filter { group($0) == 2 }.count
        return "\(active) active, \(finished) finished, \(attention) needs attention"
    }

    static func ageText(from date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}

/// Tray button with an active-count badge; opens a popover list.
struct JobTrayButton: View {
    @State private var jobs: [JobRecord] = []
    @State private var open = false
    let reload: () -> [JobRecord]
    let onResume: (JobRecord) -> Void
    let onStop: (JobRecord) -> Void

    var body: some View {
        Button { jobs = reload(); open.toggle() } label: {
            Label("Jobs", systemImage: "tray.full")
                .overlay(alignment: .topTrailing) {
                    if let badge = JobTray.badgeText(jobs) {
                        Text(badge).font(.system(size: 10, weight: .bold)).padding(3)
                            .background(ORBTheme.accent, in: Circle()).foregroundStyle(.white).offset(x: 8, y: -6)
                    }
                }
        }
        .accessibilityValue(JobTray.summary(jobs))
        .help("Media jobs")
        .onAppear { jobs = reload() }
        .popover(isPresented: $open) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if jobs.isEmpty { Text("No jobs").foregroundStyle(.secondary) }
                    ForEach(JobTray.ordered(jobs)) { job in jobRow(job) }
                }
                .padding(14)
            }
            .frame(width: 380, height: min(420, CGFloat(max(jobs.count, 1)) * 92 + 30))
        }
    }

    private func jobRow(_ job: JobRecord) -> some View {
        let p = JobPresentation.make(job)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                ORBStatusPill(status: p.status)
                Text(p.label).font(ORBFont.footnote.weight(.semibold))
                Spacer()
                Text(JobTray.ageText(from: job.createdAt)).font(ORBFont.caption).foregroundStyle(.secondary)
            }
            Text("\(job.kind.capitalized) · \(job.modelID ?? "unknown model")" + (p.costText.map { " · \($0)" } ?? ""))
                .font(ORBFont.caption).foregroundStyle(.secondary)
            Text(p.detail).font(ORBFont.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(p.actions, id: \.self) { action in
                    switch action {
                    case .resume: Button("Resume") { onResume(job) }
                    case .stop: Button("Stop checking") { onStop(job) }
                    case .open, .dismiss: EmptyView()
                    }
                }
            }.controlSize(.small)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
