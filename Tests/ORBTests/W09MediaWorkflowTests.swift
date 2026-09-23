import Foundation
import Testing
@testable import ORB

// W09 — media and file workflows, testable core:
//   1. video resume from durable job records (no new submission),
//   2. credential-free video download guarantee (unsigned CDN URLs),
//   3. image per-endpoint discovery (`GET /images/models/{author}/{slug}/endpoints`),
//   4. file upload validation + explicit-delete confirmation.
// No network: every flow uses the shared MockMediaTransport from
// MediaTransportTests.swift; JobController uses the test-isolated
// DatabaseManager() store.

// MARK: - 1. Video resume

@Suite("Video resume from durable jobs", .serialized)
@MainActor
struct VideoResumeTests {
    @Test("resume polls the canonical route with zero POST /videos and records the terminal state")
    func resumeQueuedJobWithoutResubmission() async throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(
            remoteID: "job-resume", modelID: "m", remoteStatus: "queued", cost: nil
        )

        // A fresh service (as after a restart) resumes the durable record.
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-resume","status":"queued"}"#),
            .json(#"{"id":"job-resume","status":"completed","usage":{"cost":0.11}}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        let record = try #require(controller.record(remoteID: "job-resume"))

        let updates = JobUpdateCollector()
        let finished = try await service.resume(record, pollInterval: .milliseconds(1)) {
            updates.append($0)
        }

        // (a) The first request is a GET to the canonical /videos/<id> route.
        let requests = transport.sentRequests()
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        #expect(first.httpMethod == "GET")
        #expect(first.url?.absoluteString == "https://openrouter.ai/api/v1/videos/job-resume")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        for request in requests.dropFirst() {
            #expect(request.url?.path == "/api/v1/videos/job-resume")
        }
        // (b) A resume never submits a new (paid) job.
        #expect(transport.submissions().isEmpty)
        // (c) The terminal update reaches the durable record.
        let terminal = try #require(controller.record(remoteID: "job-resume"))
        #expect(terminal.pollingState == .completed)
        #expect(terminal.usageCost == 0.11)
        #expect(terminal.lastRemoteStatus == "completed")
        #expect(finished.isSuccess)
        #expect(finished.cost == 0.11)
        // The UI saw the initial durable state plus both poll updates.
        #expect(updates.all.count == 3)
        #expect(updates.all.first?.status == "queued")
        #expect(updates.all.last?.status == "completed")
    }

    @Test("a stoppedLocally job resumes the same way")
    func stoppedLocallyJobResumes() async throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(
            remoteID: "job-stop-resume", modelID: "m", remoteStatus: "running", cost: nil
        )
        controller.recordStoppedLocally(remoteID: "job-stop-resume")
        #expect(try #require(controller.record(remoteID: "job-stop-resume")).pollingState == .stoppedLocally)

        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-stop-resume","status":"completed","usage":{"cost":0.02}}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        let record = try #require(controller.record(remoteID: "job-stop-resume"))

        let finished = try await service.resume(record, pollInterval: .milliseconds(1))

        let requests = transport.sentRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.absoluteString == "https://openrouter.ai/api/v1/videos/job-stop-resume")
        #expect(transport.submissions().isEmpty)
        let terminal = try #require(controller.record(remoteID: "job-stop-resume"))
        #expect(terminal.pollingState == .completed)
        #expect(terminal.usageCost == 0.02)
        #expect(finished.isSuccess)
    }

    @Test("a remote failure during resume keeps the recoverable error on the record")
    func resumeSurfacesRemoteFailure() async throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        _ = controller.recordVideoSubmission(
            remoteID: "job-resume-fail", modelID: "m", remoteStatus: "queued", cost: nil
        )
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"job-resume-fail","status":"failed","error":"Provider quota exceeded"}"#)
        ])
        let service = VideoGenService(transport: transport, jobController: controller)
        let record = try #require(controller.record(remoteID: "job-resume-fail"))
        do {
            _ = try await service.resume(record, pollInterval: .milliseconds(1))
            Issue.record("Expected the failed job to throw.")
        } catch is CancellationError {
            Issue.record("A remote failure must not surface as local cancellation.")
        } catch {
            #expect(error is MediaServiceError)
        }
        #expect(transport.submissions().isEmpty)
        let terminal = try #require(controller.record(remoteID: "job-resume-fail"))
        #expect(terminal.pollingState == .failed)
        #expect(terminal.recoverableError == "Provider quota exceeded")
    }

    @Test("records that cannot be resumed are refused before any request")
    func nonResumableRecordsAreRefused() async throws {
        let database = DatabaseManager()
        let controller = JobController(database: database)
        let transport = MockMediaTransport(responses: [])
        let service = VideoGenService(transport: transport, jobController: controller)

        // No remote ID: nothing to poll.
        let unknown = try #require(controller.recordUnknownSubmission(
            kind: "video", modelID: "m", error: "Submission outcome unknown."
        ))
        do {
            _ = try await service.resume(unknown, pollInterval: .milliseconds(1))
            Issue.record("Expected a record without a remote ID to be refused.")
        } catch {
            #expect(error is MediaServiceError)
        }

        // Terminal: nothing left to resume.
        _ = controller.recordVideoSubmission(
            remoteID: "job-done", modelID: "m", remoteStatus: "completed", cost: nil
        )
        let done = try #require(controller.record(remoteID: "job-done"))
        do {
            _ = try await service.resume(done, pollInterval: .milliseconds(1))
            Issue.record("Expected a terminal record to be refused.")
        } catch {
            #expect(error is MediaServiceError)
        }

        // Neither refusal reached the transport.
        #expect(transport.sentCount() == 0)
    }
}

// MARK: - 2. Credential-free video download

@Suite("Video download credential guarantee", .serialized)
@MainActor
struct VideoDownloadCredentialTests {
    @Test("download sends no Authorization header to the unsigned CDN URL")
    func downloadIsCredentialFree() async throws {
        let transport = MockMediaTransport(
            responses: [],
            rawResponses: [.bytes(Data("fake-mp4-bytes".utf8), "video/mp4")]
        )
        let service = VideoGenService(transport: transport)
        let job = VideoJob(
            id: "job-dl", status: "completed",
            unsignedURLs: ["https://cdn.openrouter.ai/videos/job-dl/file.mp4"]
        )

        let (data, mime) = try await service.download(job)

        #expect(data == Data("fake-mp4-bytes".utf8))
        #expect(mime == "video/mp4")
        let raw = transport.sentRawRequests()
        #expect(raw.count == 1)
        let request = try #require(raw.first)
        #expect(request.url?.absoluteString == "https://cdn.openrouter.ai/videos/job-dl/file.mp4")
        #expect(request.httpMethod == "GET")
        // The download is credential-free by contract (plan 7.2): no bearer
        // token, and no credential fetch, ever reached the key provider.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(transport.keyCounter?.current == 0)
    }

    @Test("download without an unsigned URL fails before any request")
    func downloadWithoutURLFailsCleanly() async throws {
        let transport = MockMediaTransport(responses: [], rawResponses: [])
        let service = VideoGenService(transport: transport)
        do {
            _ = try await service.download(VideoJob(id: "job-nodl", status: "completed"))
            Issue.record("Expected the missing-URL download to throw.")
        } catch {
            #expect(error is MediaServiceError)
        }
        #expect(transport.sentCount() == 0)
        #expect(transport.sentRawRequests().isEmpty)
    }
}

// MARK: - 3. Image endpoint discovery

@Suite("Image endpoint discovery", .serialized)
@MainActor
struct ImageEndpointDiscoveryTests {
    // Fixture mirrors the documented `ImageModelEndpointsResponse` shape
    // (openrouter.ai/openapi.json, image-generation docs): top-level
    // `{id, endpoints}`, each endpoint carrying provider identity, the
    // definitive supported_parameters descriptors, passthrough allowlist,
    // streaming support, and billable pricing lines.
    private static let fixture = """
    {
      "id": "bytedance-seed/seedream 4.5",
      "endpoints": [
        {
          "provider_name": "Bytedance",
          "provider_slug": "bytedance",
          "provider_tag": "bytedance",
          "supported_parameters": {
            "resolution": { "type": "enum", "values": ["1K", "2K", "4K"] },
            "seed": { "type": "boolean" }
          },
          "allowed_passthrough_parameters": [],
          "supports_streaming": false,
          "pricing": [
            { "billable": "output_image", "unit": "image", "cost_usd": 0.05 }
          ]
        },
        {
          "provider_name": "Replicate",
          "provider_slug": "replicate",
          "provider_tag": null,
          "supported_parameters": {
            "output_compression": { "type": "range", "min": 0, "max": 100 }
          },
          "allowed_passthrough_parameters": ["custom_key"],
          "supports_streaming": true,
          "pricing": [
            { "billable": "output_image", "unit": "megapixel", "cost_usd": 0.01, "variant": "2k" }
          ]
        }
      ]
    }
    """

    @Test("endpoint discovery hits the documented per-model route with percent-encoded segments")
    func discoveryCapturesExactURLAndDecodes() async throws {
        let transport = MockMediaTransport(responses: [.json(Self.fixture)])
        let service = ImageGenService(transport: transport)

        // A model id with a space proves each path segment is percent-encoded
        // individually while the author/slug slash stays structural.
        let endpoints = try await service.fetchImageModelEndpoints(modelID: "bytedance-seed/seedream 4.5")

        let request = try #require(transport.sentRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString ==
                "https://openrouter.ai/api/v1/images/models/bytedance-seed/seedream%204.5/endpoints")
        #expect(request.url?.path == "/api/v1/images/models/bytedance-seed/seedream 4.5/endpoints")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        // Endpoints are sorted by provider slug.
        #expect(endpoints.map(\.providerSlug) == ["bytedance", "replicate"])
        let bytedance = try #require(endpoints.first)
        #expect(bytedance.providerName == "Bytedance")
        #expect(bytedance.providerTag == "bytedance")
        #expect(bytedance.supportsStreaming == false)
        #expect(bytedance.allowedPassthroughParameters.isEmpty)
        #expect(bytedance.pricing.count == 1)
        #expect(bytedance.pricing.first?.billable == "output_image")
        #expect(bytedance.pricing.first?.unit == "image")
        #expect(bytedance.pricing.first?.costUSD == 0.05)
        #expect(bytedance.pricing.first?.variant == nil)
        if case .enumValues(let values)? = bytedance.supportedParameters["resolution"] {
            #expect(values == ["1K", "2K", "4K"])
        } else {
            Issue.record("Expected an enum descriptor for 'resolution'.")
        }
        #expect(bytedance.supportedParameters["seed"] == .boolean)

        let replicate = try #require(endpoints.last)
        #expect(replicate.providerTag == nil)
        #expect(replicate.allowedPassthroughParameters == ["custom_key"])
        #expect(replicate.pricing.first?.variant == "2k")
        if case .range(let min, let max)? = replicate.supportedParameters["output_compression"] {
            #expect(min == 0)
            #expect(max == 100)
        } else {
            Issue.record("Expected a range descriptor for 'output_compression'.")
        }
    }

    @Test("query or fragment characters in a model id are rejected before any request")
    func invalidModelIDRejected() async throws {
        let transport = MockMediaTransport(responses: [])
        let service = ImageGenService(transport: transport)
        do {
            _ = try await service.fetchImageModelEndpoints(modelID: "author/slug?id=1")
            Issue.record("Expected the query-bearing model id to be rejected.")
        } catch {
            #expect(error is MediaServiceError)
        }
        #expect(transport.sentCount() == 0)
        #expect(transport.keyCounter?.current == 0)
    }
}

// MARK: - 4. Files: upload validation + delete confirmation

@Suite("File upload validation and delete confirmation", .serialized)
@MainActor
struct FileValidationTests {
    @Test("empty upload is rejected locally with zero requests")
    func emptyUploadRejected() async throws {
        let transport = MockMediaTransport(responses: [])
        let service = FileService(transport: transport)
        do {
            _ = try await service.upload(filename: "empty.txt", mimeType: "text/plain", data: Data())
            Issue.record("Expected the empty upload to be rejected.")
        } catch {
            #expect(error is MediaServiceError)
        }
        #expect(transport.sentCount() == 0)
        #expect(transport.keyCounter?.current == 0)
    }

    @Test("upload exceeding the documented 100 MiB limit is rejected locally with zero requests")
    func oversizedUploadRejected() async throws {
        let transport = MockMediaTransport(responses: [])
        let service = FileService(transport: transport)
        // One byte past the documented maximum (100 MiB = 104,857,600 bytes).
        let oversized = Data(count: FileService.maxUploadBytes + 1)
        do {
            _ = try await service.upload(filename: "big.bin", mimeType: "application/octet-stream", data: oversized)
            Issue.record("Expected the oversized upload to be rejected.")
        } catch {
            #expect(error is MediaServiceError)
            #expect(error.localizedDescription.contains("limit"))
        }
        #expect(transport.sentCount() == 0)
        #expect(transport.keyCounter?.current == 0)
    }

    @Test("delete without explicit confirmation sends nothing")
    func deleteWithoutConfirmationSendsNothing() async throws {
        let transport = MockMediaTransport(responses: [])
        let service = FileService(transport: transport)
        do {
            _ = try await service.delete(id: "or_file_abc", confirming: false)
            Issue.record("Expected the unconfirmed delete to be refused.")
        } catch {
            #expect(error is MediaServiceError)
        }
        #expect(transport.sentCount() == 0)
        #expect(transport.keyCounter?.current == 0)
    }

    @Test("delete with confirmation sends DELETE /files/<id> and decodes the confirmation")
    func confirmedDeleteSendsDelete() async throws {
        let transport = MockMediaTransport(responses: [
            .json(#"{"id":"or_file_abc","type":"file_deleted","_shape":"openrouter"}"#)
        ])
        let service = FileService(transport: transport)
        service.files = [
            WorkspaceFile(
                id: "or_file_abc", filename: "report.pdf", mimeType: "application/pdf",
                sizeBytes: 12, createdAt: nil, downloadable: true
            )
        ]

        let confirmation = try await service.delete(id: "or_file_abc", confirming: true)

        let request = try #require(transport.sentRequests().first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/files/or_file_abc")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(confirmation.id == "or_file_abc")
        #expect(confirmation.fileDeleted == true)
        // The local list drops the deleted file only after the confirmed delete.
        #expect(service.files.isEmpty)
    }

    @Test("the delete confirmation decoder tolerates every documented shape")
    func deleteConfirmationShapesDecode() throws {
        let openrouter = #"{"_shape":"openrouter","id":"or_file_1","type":"file_deleted"}"#
        let openai = #"{"_shape":"openai","id":"or_file_2","object":"file","deleted":true}"#
        let anthropic = #"{"_shape":"anthropic","id":"or_file_3","type":"file_deleted"}"#
        let first = try JSONDecoder().decode(FileDeleteConfirmation.self, from: Data(openrouter.utf8))
        #expect(first.id == "or_file_1")
        #expect(first.fileDeleted)
        let second = try JSONDecoder().decode(FileDeleteConfirmation.self, from: Data(openai.utf8))
        #expect(second.id == "or_file_2")
        #expect(second.fileDeleted)
        let third = try JSONDecoder().decode(FileDeleteConfirmation.self, from: Data(anthropic.utf8))
        #expect(third.id == "or_file_3")
        #expect(third.fileDeleted)
    }
}
