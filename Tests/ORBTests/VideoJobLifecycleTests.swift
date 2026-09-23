import Foundation
import Testing
@testable import ORB

@Suite("Video job polling lifecycle", .serialized)
@MainActor
struct VideoJobLifecycleTests {
    private static func isUntrustedURLError(_ error: Error) -> Bool {
        if case MediaServiceError.untrustedURL = error { return true }
        return false
    }

    @Test("terminal submit status exits the loop exactly once")
    func terminalSubmitExitsOnce() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-term","status":"completed","usage":{"cost":0.02}}"#)
        ])
        let service = VideoGenService(transport: transport)
        let finished = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil))
        #expect(finished.isSuccess)
        #expect(finished.cost == 0.02)
        // Only the submission went out: no polls, no duplicate submission.
        #expect(transport.sentCount() == 1)
        #expect(transport.submissions().count == 1)
    }

    @Test("polls exactly once per non-terminal status and never re-submits")
    func pollsUntilTerminal() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-poll-1","status":"queued"}"#),
            .json(#"{"id":"job-poll-1","status":"queued"}"#),
            .json(#"{"id":"job-poll-1","status":"completed","usage":{"cost":0.05}}"#)
        ])
        let service = VideoGenService(transport: transport)
        let updates = JobUpdateCollector()
        let finished = try await service.submitAndPoll(
            VideoGenRequest(model: "m", prompt: nil),
            pollInterval: .milliseconds(1)
        ) { updates.append($0) }
        #expect(finished.isSuccess)
        #expect(updates.all.count == 3) // submit + two polls
        let requests = transport.sentRequests()
        #expect(requests.count == 3)
        #expect(transport.submissions().count == 1)
        // Non-terminal polls use the canonical route with the job id.
        for request in requests.dropFirst() {
            #expect(request.url?.path == "/api/v1/videos/job-poll-1")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        }
    }

    @Test("valid absolute polling URL is used with credentials attached")
    func validAbsolutePollingURLUsed() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-abs","status":"queued","polling_url":"https://openrouter.ai/api/v1/videos/job-abs"}"#),
            .json(#"{"id":"job-abs","status":"completed"}"#)
        ])
        let service = VideoGenService(transport: transport)
        _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1))
        let requests = transport.sentRequests()
        #expect(requests.count == 2)
        let poll = try #require(requests.last)
        #expect(poll.url?.absoluteString == "https://openrouter.ai/api/v1/videos/job-abs")
        #expect(poll.httpMethod == "GET")
        #expect(poll.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test("relative polling reference is resolved against the API base")
    func relativePollingReferenceResolved() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-rel","status":"queued","polling_url":"videos/job-rel"}"#),
            .json(#"{"id":"job-rel","status":"completed"}"#)
        ])
        let service = VideoGenService(transport: transport)
        _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1))
        let requests = transport.sentRequests()
        #expect(requests.count == 2)
        let poll = try #require(requests.last)
        #expect(poll.url?.absoluteString == "https://openrouter.ai/api/v1/videos/job-rel")
        #expect(poll.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test("foreign-origin polling URL is rejected before any credential is sent")
    func foreignOriginPollingRejected() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-evil","status":"queued","polling_url":"https://evil.example/api/v1/videos/job-evil"}"#)
        ])
        let service = VideoGenService(transport: transport)
        do {
            _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1))
            Issue.record("Expected the foreign-origin polling URL to be rejected.")
        } catch {
            #expect(Self.isUntrustedURLError(error))
        }
        // Only the submission went out, and it went to the approved origin.
        let requests = transport.sentRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "openrouter.ai")
        // The rejected URL never reached the credential provider again.
        #expect(transport.keyCounter?.current == 1)
    }

    @Test("http polling URL is rejected before any credential is sent")
    func httpPollingRejected() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-http","status":"queued","polling_url":"http://openrouter.ai/api/v1/videos/job-http"}"#)
        ])
        let service = VideoGenService(transport: transport)
        do {
            _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(1))
            Issue.record("Expected the http polling URL to be rejected.")
        } catch {
            #expect(Self.isUntrustedURLError(error))
        }
        #expect(transport.sentCount() == 1)
        #expect(transport.sentRequests().first?.url?.host == "openrouter.ai")
    }

    @Test("stopPolling cancels an in-flight poll loop and preserves the remote job state")
    func stopPollingCancelsInFlightLoop() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-hang","status":"queued"}"#), // submit
            .json(#"{"id":"job-hang","status":"queued"}"#), // poll 1
            .hang                                           // poll 2 hangs in flight
        ])
        let service = VideoGenService(transport: transport)
        let run = Task { try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil), pollInterval: .milliseconds(5)) }
        let progressed = await waitForCondition { transport.sentCount() >= 3 }
        #expect(progressed)
        service.stopPolling()
        do {
            _ = try await run.value
            Issue.record("Expected local cancellation to surface as CancellationError.")
        } catch {
            #expect(error is CancellationError)
            #expect(!(error is MediaServiceError))
        }
        // Polling stopped: no further requests after the cancelled hang.
        let countAfterStop = transport.sentCount()
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.sentCount() == countAfterStop)
        // The service must not claim the remote job was cancelled.
        #expect(service.activeJob?.status == "queued")
    }

    @Test("remote job failure is distinct from local cancellation")
    func remoteFailureIsDistinctFromCancellation() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-fail","status":"failed","error":"Provider quota exceeded"}"#)
        ])
        let service = VideoGenService(transport: transport)
        do {
            _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil))
            Issue.record("Expected the failed job to throw.")
        } catch is CancellationError {
            Issue.record("A remote failure must not surface as local cancellation.")
        } catch {
            #expect(error is MediaServiceError)
            #expect(error.localizedDescription.contains("Provider quota exceeded"))
        }
        #expect(service.activeJob?.status == "failed")
    }

    @Test("repeated submissions each produce exactly one POST /videos")
    func repeatedSubmissionsDoNotDuplicate() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-a","status":"completed"}"#),
            .json(#"{"id":"job-b","status":"completed"}"#)
        ])
        let service = VideoGenService(transport: transport)
        _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil))
        _ = try await service.submitAndPoll(VideoGenRequest(model: "m", prompt: nil))
        #expect(transport.submissions().count == 2)
        #expect(transport.sentCount() == 2)
    }

    @Test("stopPolling with no active job is a safe no-op")
    func stopPollingIdleNoOp() {
        let service = VideoGenService(transport: MockMediaTransport(responses: []))
        service.stopPolling()
        #expect(service.activeJob == nil)
    }
}
