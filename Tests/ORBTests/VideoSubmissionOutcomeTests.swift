import Foundation
import Testing
@testable import ORB

// Honest submission-outcome recording for video submissions (W01 gate "no
// duplicate paid submission" + W06 durability):
//
//   - Once `POST /videos` has been SENT, any failure (transport error,
//     cancellation, non-2xx, undecodable body) leaves the outcome genuinely
//     unknown — a remote job may or may not exist. The durable record must
//     capture exactly that: ONE `outcomeUnknown` record, never an automatic
//     resubmission candidate, and the original error rethrown unchanged.
//   - Failures BEFORE anything was sent (request building, JSON encoding)
//     must record nothing — there is no ambiguity to be honest about.
//   - The happy path keeps its existing `.submitted` record.
//
// No network: every flow uses injected transports and a test-isolated
// DatabaseManager-backed JobController.

/// Transport whose `send` always throws the scripted error (the submit POST
/// has been handed off, so the outcome is unknown).
private final class ThrowingSendMediaTransport: MediaTransport, @unchecked Sendable {
    private let error: Error
    private let lock = NSLock()
    private var sent: [URLRequest] = []

    init(error: Error) {
        self.error = error
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: { "test-key" })
    }

    var sentRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    override func send<T: Decodable>(_ request: URLRequest, as type: T.Type = T.self) async throws -> T {
        lock.lock()
        sent.append(request)
        lock.unlock()
        throw error
    }
}

/// Transport that fails while BUILDING the request (no key → no request):
/// `transport.request` throws before anything is sent.
private final class KeylessMediaTransport: MediaTransport, @unchecked Sendable {
    init() {
        super.init(session: URLSession(configuration: .ephemeral), apiKeyProvider: {
            throw MediaServiceError.missingAPIKey
        })
    }
}

@Suite("Honest video submission outcomes", .serialized)
@MainActor
struct VideoSubmissionOutcomeTests {
    private func makeService(
        transport: MediaTransport,
        database: DatabaseManager = DatabaseManager()
    ) -> (VideoGenService, JobController) {
        let controller = JobController(database: database)
        return (VideoGenService(transport: transport, jobController: controller), controller)
    }

    @Test("a transport failure after the submit was sent records exactly one outcomeUnknown")
    func sendFailureRecordsExactlyOneOutcomeUnknown() async throws {
        let (service, controller) = makeService(
            transport: ThrowingSendMediaTransport(error: MediaServiceError.transport("simulated connection drop")))
        let request = VideoGenRequest(model: "test/video-model", prompt: "clip")

        do {
            _ = try await service.submitAndPoll(request)
            Issue.record("Expected the submit to throw.")
        } catch let error as MediaServiceError {
            #expect(error == .transport("simulated connection drop"))
        }

        let jobs = controller.allJobs()
        #expect(jobs.count == 1, "exactly one record, not one per attempt")
        let record = try #require(jobs.first)
        #expect(record.submissionState == .outcomeUnknown)
        #expect(record.pollingState == .idle)
        #expect(record.remoteID == nil)
        #expect(record.modelID == "test/video-model")
        #expect(record.recoverableError == "Network error while contacting OpenRouter: simulated connection drop")
        // An unknown outcome is never an automatic resubmission candidate.
        #expect(record.isResumable == false)
    }

    @Test("cancellation during the submit records exactly one outcomeUnknown and rethrows CancellationError")
    func cancellationRecordsExactlyOneOutcomeUnknown() async throws {
        let (service, controller) = makeService(
            transport: ThrowingSendMediaTransport(error: CancellationError()))
        let request = VideoGenRequest(model: "test/video-model", prompt: "clip")

        do {
            _ = try await service.submitAndPoll(request)
            Issue.record("Expected the submit to throw CancellationError.")
        } catch is CancellationError {
            // The original error must reach the caller unchanged.
        }

        let jobs = controller.allJobs()
        #expect(jobs.count == 1)
        let record = try #require(jobs.first)
        #expect(record.submissionState == .outcomeUnknown)
        #expect(record.remoteID == nil)
        #expect(record.modelID == "test/video-model")
        // Honesty about the error text too: no key material may appear in it.
        let recordedError = record.recoverableError ?? ""
        #expect(!recordedError.lowercased().contains("test-key"))
    }

    @Test("an HTTP 4xx rejection records a failed submission, not an unconfirmed one")
    func clientErrorRecordsRejectedSubmission() async throws {
        let transport = MockMediaTransport(responses: [
            .status(400, #"{"error":{"message":"Prompt was flagged by moderation"}}"#)
        ])
        let database = DatabaseManager()
        let (service, controller) = makeService(transport: transport, database: database)
        let request = VideoGenRequest(model: "test/video-model", prompt: "clip")

        do {
            _ = try await service.submitAndPoll(request)
            Issue.record("Expected the submit to throw.")
        } catch let error as MediaServiceError {
            // The original error reaches the caller unchanged.
            #expect(error == .http(status: 400, message: "Prompt was flagged by moderation"))
        }

        let jobs = controller.allJobs()
        #expect(jobs.count == 1)
        let record = try #require(jobs.first)
        #expect(record.submissionState == .failed)
        #expect(record.pollingState == .idle)
        #expect(record.remoteID == nil)
        #expect(record.modelID == "test/video-model")
        #expect(record.recoverableError?.contains("Prompt was flagged by moderation") == true)
        #expect(record.isResumable == false)
        // Exactly one POST: a rejection is never retried on the user's behalf.
        #expect(transport.submissions().count == 1)

        // The tray says nothing was billed, and does not count it as active.
        let presentation = JobPresentation.make(record)
        #expect(presentation.label == "Not submitted")
        #expect(presentation.detail.contains("nothing was billed"))
        #expect(presentation.status == .failed)
        #expect(JobTray.activeCount(jobs) == 0)
        #expect(JobTray.summary(jobs) == "0 active, 0 finished, 1 needs attention")

        // It survives a restart as a rejection.
        let relaunched = JobController.launched(database: database)
        #expect(relaunched.record(id: record.id)?.submissionState == .failed)
    }

    @Test("a 5xx answer or an undecodable body stays outcome-unknown")
    func serverErrorStaysOutcomeUnknown() async throws {
        for error in [MediaServiceError.http(status: 503, message: "upstream unavailable"),
                      MediaServiceError.decoding("unexpected body")] {
            let (service, controller) = makeService(transport: ThrowingSendMediaTransport(error: error))
            do {
                _ = try await service.submitAndPoll(VideoGenRequest(model: "test/video-model", prompt: "clip"))
                Issue.record("Expected the submit to throw.")
            } catch let thrown as MediaServiceError {
                #expect(thrown == error)
            }
            let record = try #require(controller.allJobs().first)
            #expect(controller.allJobs().count == 1)
            #expect(record.submissionState == .outcomeUnknown)
            #expect(JobPresentation.make(record).label == "Submission unconfirmed")
        }
    }

    @Test("only an HTTP 4xx answer counts as a definitive rejection")
    func definitiveRejectionClassification() {
        for status in [400, 401, 402, 403, 404, 413, 422, 429] {
            #expect(VideoGenService.isDefinitiveRejection(MediaServiceError.http(status: status, message: "")))
        }
        // 408 says the server gave up waiting, not that nothing was accepted.
        for status in [408, 500, 502, 503, 504] {
            #expect(!VideoGenService.isDefinitiveRejection(MediaServiceError.http(status: status, message: "")))
        }
        #expect(!VideoGenService.isDefinitiveRejection(MediaServiceError.transport("offline")))
        #expect(!VideoGenService.isDefinitiveRejection(MediaServiceError.decoding("x")))
        #expect(!VideoGenService.isDefinitiveRejection(CancellationError()))
        #expect(!VideoGenService.isDefinitiveRejection(URLError(.timedOut)))
    }

    @Test("a request-build failure records nothing — nothing was sent")
    func requestBuildFailureRecordsNothing() async throws {
        let (service, controller) = makeService(transport: KeylessMediaTransport())
        let request = VideoGenRequest(model: "test/video-model", prompt: "clip")

        do {
            _ = try await service.submitAndPoll(request)
            Issue.record("Expected the request build to throw.")
        } catch let error as MediaServiceError {
            #expect(error == .missingAPIKey)
        }

        #expect(controller.allJobs().isEmpty,
                "no POST /videos was sent, so there is no unknown outcome to record")
    }

    @Test("a successful submit records .submitted — never outcomeUnknown")
    func successKeepsSubmittedRecord() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-ok","status":"queued"}"#),
            .json(#"{"id":"job-ok","status":"completed","usage":{"cost":0.05}}"#),
        ])
        let (service, controller) = makeService(transport: transport)
        let request = VideoGenRequest(model: "test/video-model", prompt: "clip")

        let job = try await service.submitAndPoll(request, pollInterval: .milliseconds(1))
        #expect(job.isSuccess)

        let jobs = controller.allJobs()
        #expect(jobs.count == 1)
        let record = try #require(jobs.first)
        #expect(record.submissionState == .submitted)
        #expect(record.pollingState == .completed)
        #expect(record.remoteID == "job-ok")
    }
}
