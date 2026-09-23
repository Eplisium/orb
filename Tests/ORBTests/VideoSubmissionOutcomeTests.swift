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
