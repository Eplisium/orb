import Testing
import SwiftUI
import Foundation
@testable import ORB

private func job(
    _ poll: JobPollingState, submission: JobSubmissionState = .submitted, remote: String? = "r1",
    status: String? = nil, cost: Double? = nil, error: String? = nil, age: TimeInterval = 0, kind: String = "video"
) -> JobRecord {
    JobRecord(id: UUID(), remoteID: remote, kind: kind, submissionState: submission, pollingState: poll,
              lastRemoteStatus: status, conversationID: nil, messageID: nil, modelID: "g/video",
              usageCost: cost, recoverableError: error,
              createdAt: Date(timeIntervalSince1970: 1_000_000 - age), updatedAt: Date(timeIntervalSince1970: 1_000_000 - age))
}

@Suite("Phase 6: job tray presentation")
struct JobTrayPresentationTests {
    @Test("Each polling state has its own label; stopped locally never reads as cancelled or failed")
    func labels() {
        let polling = JobPresentation.make(job(.polling, status: "in_progress"))
        let stopped = JobPresentation.make(job(.stoppedLocally, status: "in_progress"))
        let cancelled = JobPresentation.make(job(.cancelled))
        let failed = JobPresentation.make(job(.failed))
        let done = JobPresentation.make(job(.completed))
        let expired = JobPresentation.make(job(.expired))
        let labels = [polling, stopped, cancelled, failed, done, expired].map(\.label)
        #expect(Set(labels).count == labels.count, "every state is distinguishable by words")
        #expect(stopped.label == "Stopped checking")
        #expect(stopped.detail.localizedCaseInsensitiveContains("still running"), "the remote job may continue and bill")
        #expect(cancelled.label == "Cancelled")
    }

    @Test("Symbols differ per state so colour is never the only cue")
    func symbols() {
        let states: [JobPollingState] = [.polling, .stoppedLocally, .completed, .failed, .cancelled, .expired]
        let symbols = states.map { JobPresentation.make(job($0)).symbol }
        #expect(Set(symbols).count == states.count)
    }

    @Test("Only resumable jobs offer Resume; only active ones offer Stop")
    func actions() {
        #expect(JobPresentation.make(job(.stoppedLocally)).actions == [.resume])
        #expect(JobPresentation.make(job(.polling)).actions == [.stop])
        #expect(JobPresentation.make(job(.idle)).actions == [.resume])
        // A finished job is only "open"-able once its output is saved in ORB;
        // otherwise the tray must offer Download (the bytes are remote-only).
        #expect(JobPresentation.make(job(.completed)).actions == [.download])
        var savedJob = job(.completed)
        savedJob.savedCreationID = UUID()
        #expect(JobPresentation.make(savedJob).actions == [.open])
        #expect(JobPresentation.make(job(.failed)).actions == [.dismiss])
        #expect(JobPresentation.make(job(.stoppedLocally, remote: nil)).actions == [.dismiss], "nothing to poll without a remote ID")
    }

    @Test("An unknown submission outcome warns that re-submitting may bill twice and never auto-retries")
    func unknownOutcome() {
        let p = JobPresentation.make(job(.idle, submission: .outcomeUnknown, remote: nil))
        #expect(p.label == "Submission unconfirmed")
        #expect(p.detail.localizedCaseInsensitiveContains("twice") || p.detail.localizedCaseInsensitiveContains("duplicate"))
        #expect(!p.actions.contains(.resume))
    }

    @Test("Recoverable error text is shown; cost is shown only when reported")
    func detail() {
        let p = JobPresentation.make(job(.failed, cost: nil, error: "Provider timed out"))
        #expect(p.detail.contains("Provider timed out"))
        #expect(p.costText == nil)
        #expect(JobPresentation.make(job(.completed, cost: 0.4)).costText == "$0.40")
    }

    @Test("Status maps to the shared status pills")
    func status() {
        #expect(JobPresentation.make(job(.polling)).status == .running)
        #expect(JobPresentation.make(job(.completed)).status == .complete)
        #expect(JobPresentation.make(job(.failed)).status == .failed)
        #expect(JobPresentation.make(job(.stoppedLocally)).status == .interrupted)
    }
}

@Suite("Phase 6: job tray list")
struct JobTrayListTests {
    @Test("Active jobs come first, newest first within each group")
    func order() {
        let rows = [
            job(.completed, age: 10), job(.polling, age: 50), job(.stoppedLocally, age: 5), job(.failed, age: 1),
        ]
        let sorted = JobTray.ordered(rows)
        #expect(sorted.map(\.pollingState) == [.stoppedLocally, .polling, .failed, .completed])
    }

    @Test("Badge counts active jobs only")
    func badge() {
        let rows = [job(.polling), job(.stoppedLocally), job(.completed), job(.idle)]
        #expect(JobTray.activeCount(rows) == 3)
        #expect(JobTray.badgeText(rows) == "3")
        #expect(JobTray.badgeText([job(.completed)]) == nil)
    }

    @Test("Accessibility summary reads the counts")
    func summary() {
        #expect(JobTray.summary([]) == "No jobs")
        #expect(JobTray.summary([job(.polling), job(.completed), job(.failed)]) == "1 active, 1 finished, 1 needs attention")
    }

    @Test("Age text is relative and never negative")
    func age() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(JobTray.ageText(from: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(JobTray.ageText(from: now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(JobTray.ageText(from: now.addingTimeInterval(-7200), now: now) == "2 h ago")
        #expect(JobTray.ageText(from: now.addingTimeInterval(500), now: now) == "just now")
    }
}
