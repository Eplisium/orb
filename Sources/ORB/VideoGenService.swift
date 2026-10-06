import Foundation

// MARK: - Video generation (`POST /videos` + polling)

/// One model from `GET /videos/models`.
struct VideoGenModel: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let created: Double?
    let generateAudio: Bool?
    let seed: Bool?
    let supportedAspectRatios: [String]?
    let supportedResolutions: [String]?
    let supportedDurations: [Int]?
    let supportedFrameImages: [String]?
    let supportedSizes: [String]?
    let canonicalSlug: String?
    let allowedPassthroughParameters: [String]?
    let creativity: [Int]?
    let upscaleFactor: UpscaleFactor?
    let pricingSkus: [String: String]?

    struct UpscaleFactor: Codable, Sendable, Hashable {
        let min: Double?
        let max: Double?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, created, seed, creativity
        case generateAudio = "generate_audio"
        case supportedAspectRatios = "supported_aspect_ratios"
        case supportedResolutions = "supported_resolutions"
        case supportedDurations = "supported_durations"
        case supportedFrameImages = "supported_frame_images"
        case supportedSizes = "supported_sizes"
        case canonicalSlug = "canonical_slug"
        case allowedPassthroughParameters = "allowed_passthrough_parameters"
        case upscaleFactor = "upscale_factor"
        case pricingSkus = "pricing_skus"
    }
}

struct VideoGenModelList: Decodable {
    let data: [VideoGenModel]
}

/// OpenAPI `InputReference`: a tagged image/audio/video URL content part.
enum VideoInputReference: Encodable {
    case image(url: String)
    case audio(url: String)
    case video(url: String)

    private enum Keys: String, CodingKey {
        case type
        case imageURL = "image_url"
        case audioURL = "audio_url"
        case videoURL = "video_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .image(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageReference.URLValue(url: url), forKey: .imageURL)
        case .audio(let url):
            try container.encode("audio_url", forKey: .type)
            try container.encode(ImageReference.URLValue(url: url), forKey: .audioURL)
        case .video(let url):
            try container.encode("video_url", forKey: .type)
            try container.encode(ImageReference.URLValue(url: url), forKey: .videoURL)
        }
    }
}

struct VideoGenRequest: Encodable {
    var model: String
    var prompt: String?
    var aspectRatio: String? = nil
    var resolution: String? = nil
    var size: String? = nil
    var duration: Int? = nil
    var seed: Int? = nil
    var generateAudio: Bool? = nil
    var inputReferences: [VideoInputReference]? = nil
    /// Frame images as base64 data URLs or HTTPS URLs.
    var firstFrameImage: String? = nil
    var lastFrameImage: String? = nil

    enum CodingKeys: String, CodingKey {
        case model, prompt, resolution, size, duration, seed
        case aspectRatio = "aspect_ratio"
        case generateAudio = "generate_audio"
        case frameImages = "frame_images"
        case inputReferences = "input_references"
    }

    private struct FrameImage: Encodable {
        let frameType: String
        let type = "image_url"
        let imageURL: ImageReference.URLValue
        enum CodingKeys: String, CodingKey {
            case type
            case imageURL = "image_url"
            case frameType = "frame_type"
        }
        init(frameType: String, url: String) {
            self.frameType = frameType
            imageURL = .init(url: url)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(seed, forKey: .seed)
        try container.encodeIfPresent(generateAudio, forKey: .generateAudio)
        try container.encodeIfPresent(inputReferences, forKey: .inputReferences)
        var frames: [FrameImage] = []
        if let firstFrameImage { frames.append(.init(frameType: "first_frame", url: firstFrameImage)) }
        if let lastFrameImage { frames.append(.init(frameType: "last_frame", url: lastFrameImage)) }
        if !frames.isEmpty { try container.encode(frames, forKey: .frameImages) }
    }
}

/// A video job: the submit response and every poll share this shape.
struct VideoJob: Decodable, Sendable, Equatable {
    let id: String
    let status: String
    let pollingURL: String?
    let generationId: String?
    let unsignedURLs: [String]?
    let error: String?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case id, status, error
        case pollingURL = "polling_url"
        case generationId = "generation_id"
        case unsignedURLs = "unsigned_urls"
        case usage
    }

    private struct Usage: Decodable { let cost: Double? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        pollingURL = try container.decodeIfPresent(String.self, forKey: .pollingURL)
        generationId = try container.decodeIfPresent(String.self, forKey: .generationId)
        unsignedURLs = try container.decodeIfPresent([String].self, forKey: .unsignedURLs)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        cost = try container.decodeIfPresent(Usage.self, forKey: .usage)?.cost
    }

    var isTerminal: Bool {
        ["completed", "failed", "cancelled", "expired"].contains(status)
    }

    var isSuccess: Bool { status == "completed" }

    /// Direct construction for locally-tracked jobs (submit placeholders,
    /// failure records). Wire decoding uses `init(from:)`.
    init(id: String, status: String, pollingURL: String? = nil, generationId: String? = nil,
         unsignedURLs: [String]? = nil, error: String? = nil, cost: Double? = nil) {
        self.id = id
        self.status = status
        self.pollingURL = pollingURL
        self.generationId = generationId
        self.unsignedURLs = unsignedURLs
        self.error = error
        self.cost = cost
    }
}

@MainActor
final class VideoGenService: ObservableObject {
    @Published var models: [VideoGenModel] = []
    @Published var isLoadingModels = false
    @Published var modelsError: String?
    @Published var activeJob: VideoJob?
    /// Model of the job being polled, for the usage ledger.
    private var activeModelID = "unknown"
    @Published var jobError: String?

    private let transport: MediaTransport
    /// Application-owned durable job state (W06). Injectable so tests can
    /// isolate storage; the default view path uses the shared controller so
    /// job records survive navigation and app restarts.
    private let jobController: JobController
    /// The owned polling task, assigned by `submitAndPoll`, so `stopPolling()`
    /// can cancel the in-flight loop.
    private var pollTask: Task<VideoJob, Error>?
    private var pollGeneration = 0
    /// Remote ID of the job the owned poll loop is currently running for, if
    /// any. Distinct from `activeJob`, which deliberately keeps the last known
    /// state after a local stop — a stopped job is not an in-flight run.
    private var inFlightRemoteID: String? { didSet { isPolling = inFlightRemoteID != nil } }
    /// True while a job is being polled (drives the sidebar activity badge).
    @Published private(set) var isPolling = false

    init(transport: MediaTransport = MediaTransport(), jobController: JobController? = nil) {
        self.transport = transport
        // Resolved on the main actor (VideoGenService is @MainActor): the
        // default view path shares the application-owned controller.
        self.jobController = jobController ?? JobController.shared
    }

    func fetchModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            let request = try transport.request(path: "videos/models")
            let list: VideoGenModelList = try await transport.send(request)
            models = list.data.sorted { $0.name < $1.name }
        } catch is CancellationError {
            // Leave prior models in place; a cancelled refresh is not an error.
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// Submits the job, then polls until it reaches a terminal status.
    /// Calls `onUpdate` on every poll so the UI can show progress.
    ///
    /// The polling loop runs in a task this method owns and assigns to
    /// `pollTask`, so `stopPolling()` cancels the in-flight loop. Local
    /// cancellation surfaces as `CancellationError` and never claims the
    /// remote job was cancelled; remote failures throw `MediaServiceError`.
    func submitAndPoll(
        _ request: VideoGenRequest,
        pollInterval: Duration = .seconds(5),
        onUpdate: @escaping @Sendable (VideoJob) -> Void = { _ in }
    ) async throws -> VideoJob {
        stopPolling()
        let body = try JSONEncoder().encode(request)
        let submit = try transport.request(path: "videos", method: "POST", body: body)
        let job: VideoJob
        do {
            job = try await transport.send(submit)
        } catch {
            // W01/W06 honesty: the POST /videos was SENT, so the outcome is
            // genuinely unknown — a remote (possibly paid) job may or may not
            // exist. Record exactly that durably — never an automatic
            // resubmission candidate — and rethrow unchanged. Failures thrown
            // ABOVE this point (request building, JSON encoding) sent nothing
            // and must not record an unknown outcome. The localized
            // description carries no key material: these errors are built
            // from server messages and URLError descriptions, never from
            // request headers.
            jobController.recordUnknownSubmission(
                modelID: request.model,
                error: error.localizedDescription
            )
            throw error
        }
        activeJob = job
        activeModelID = request.model
        // Durable record keyed by the remote job ID, persisted before any
        // poll result is relied upon. A failed write never aborts the flow
        // (JobController surfaces it as lastPersistenceError).
        jobController.recordVideoSubmission(
            remoteID: job.id,
            modelID: request.model,
            remoteStatus: job.status,
            error: job.error,
            cost: job.cost
        )
        onUpdate(job)
        return try await runOwnedPollLoop(from: job, pollInterval: pollInterval, onUpdate: onUpdate)
    }

    /// Resumes polling for a durable job record (W09): restarts the owned
    /// poll loop for a job that already exists remotely, without any new
    /// submission — a resume never issues `POST /videos`. Use this after an
    /// app restart or a local stop (`JobRecord.stoppedLocally`) so the job
    /// survives the view that started it.
    ///
    /// - Parameter record: a durable record with a remote ID and a
    ///   non-terminal polling state (see `JobRecord.isResumable`).
    /// - Throws: `MediaServiceError.resumeUnavailable` when the record has
    ///   no remote ID to poll or already reached a terminal state — both
    ///   refusals happen before any request is sent.
    func resume(
        _ record: JobRecord,
        pollInterval: Duration = .seconds(5),
        onUpdate: @escaping @Sendable (VideoJob) -> Void = { _ in }
    ) async throws -> VideoJob {
        guard let remoteID = record.remoteID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !remoteID.isEmpty else {
            throw MediaServiceError.resumeUnavailable(
                "the job never received a remote ID, so there is nothing to poll. Resubmitting is a user decision because it can duplicate a paid job."
            )
        }
        guard !record.pollingState.isTerminal else {
            throw MediaServiceError.resumeUnavailable(
                "the job already finished (\(record.pollingState.rawValue))."
            )
        }
        stopPolling()
        activeModelID = record.modelID ?? "unknown"
        // Seed the loop from the last known durable state; the first poll
        // goes to the canonical `videos/<remoteID>` route (or the record's
        // stored polling URL after origin validation) exactly like an
        // uninterrupted poll would.
        let initial = VideoJob(id: remoteID, status: record.lastRemoteStatus ?? "queued")
        onUpdate(initial)
        return try await runOwnedPollLoop(
            from: initial, pollInterval: pollInterval, onUpdate: onUpdate
        )
    }

    /// Starts the owned polling task for `job` and awaits its terminal
    /// result. Shared by submit-then-poll and resume so both flows have the
    /// same cancellation and durability semantics.
    private func runOwnedPollLoop(
        from job: VideoJob,
        pollInterval: Duration,
        onUpdate: @escaping @Sendable (VideoJob) -> Void
    ) async throws -> VideoJob {
        activeJob = job
        pollGeneration += 1
        let generation = pollGeneration
        inFlightRemoteID = job.id
        let loop: Task<VideoJob, Error> = Task {
            try await pollUntilTerminal(job, pollInterval: pollInterval, onUpdate: onUpdate)
        }
        pollTask = loop
        defer {
            if pollGeneration == generation {
                pollTask = nil
                inFlightRemoteID = nil
            }
        }
        return try await loop.value
    }

    /// Polls until a terminal status. Prefers the canonical `videos/<jobId>`
    /// route; a supplied `polling_url` is used only after it resolves and
    /// passes the exact origin policy, before any credential is attached to
    /// the request.
    private func pollUntilTerminal(
        _ initial: VideoJob,
        pollInterval: Duration,
        onUpdate: @escaping @Sendable (VideoJob) -> Void
    ) async throws -> VideoJob {
        var job = initial
        while !job.isTerminal {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
            try Task.checkCancellation()
            job = try await transport.send(pollRequest(for: job))
            activeJob = job
            jobController.recordPollUpdate(
                remoteID: job.id, remoteStatus: job.status, error: job.error, cost: job.cost
            )
            onUpdate(job)
        }
        // Terminal: persist the final state and cost regardless of outcome so
        // a completed job keeps its usage and a failure keeps its error.
        if job.isSuccess || job.cost != nil {
            UsageLedger.shared.record(.video, model: activeModelID, cost: job.cost, eventID: job.id)
        }
        jobController.recordTerminal(
            remoteID: job.id, remoteStatus: job.status, error: job.error, cost: job.cost
        )
        AppToasts.jobFinished(JobPollingState(remoteStatus: job.status), kind: "video")
        guard job.isSuccess else {
            throw MediaServiceError.transport(job.error ?? "Video generation \(job.status).")
        }
        return job
    }

    private func pollRequest(for job: VideoJob) throws -> URLRequest {
        if let reference = job.pollingURL,
           !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Validate the exact origin policy before attaching credentials.
            let url = try MediaEndpointURL.pollingURL(reference)
            return try transport.request(url: url)
        }
        return try transport.request(path: "videos/\(job.id)")
    }

    /// Download through the canonical authenticated proxy, never unsigned URLs.
    func download(_ job: VideoJob, index: Int = 0) async throws -> (Data, String?) {
        guard !job.id.isEmpty, !job.id.contains("/"), !job.id.contains("?"), !job.id.contains("#"), index >= 0 else {
            throw MediaServiceError.invalidPath(job.id)
        }
        let request = try transport.request(path: "videos/\(job.id)/content", queryItems: [URLQueryItem(name: "index", value: String(index))])
        return try await transport.sendRaw(request)
    }

    /// Cancels the owned polling task, if any. Local stopping only ends the
    /// polling loop; the remote job keeps running and its last known state
    /// stays in `activeJob`. The durable record is marked `.stoppedLocally` —
    /// explicitly distinct from remote failure/cancellation and still
    /// resumable.
    func stopPolling() {
        if let active = activeJob, !active.isTerminal {
            jobController.recordStoppedLocally(remoteID: active.id)
            AppToasts.jobFinished(.stoppedLocally, kind: "video")
        }
        pollTask?.cancel()
        pollTask = nil
        inFlightRemoteID = nil
    }

    // MARK: Durable resume affordance (W09 step 3 wiring)

    /// Durable records that can still be resumed (remote ID present, polling
    /// not terminal), read from this service's own JobController. Views use
    /// this passthrough instead of reaching into `JobController.shared`, so
    /// tests and alternate hosts stay isolated from shared state.
    var resumableRecords: [JobRecord] { jobController.resumableJobs() }

    /// Every durable job (active, finished, failed) for the tray.
    var allJobRecords: [JobRecord] { jobController.allJobs() }

    /// Last persistence failure from the durable store, surfaced beside the
    /// resume affordance so a failed write is visible, never silent.
    var durablePersistenceError: String? { jobController.lastPersistenceError }

    /// True while this service's owned poll loop is running for the record's
    /// remote job. The resume affordance disables the control for such records
    /// so a run cannot be double-started; matching is by remote ID because a
    /// resumed run and its durable record share it. Deliberately reads the
    /// in-flight marker rather than `activeJob`: after a local stop
    /// `activeJob` still holds the last known (non-terminal) state, but no run
    /// is in flight and the job stays resumable.
    func isRunInFlight(for record: JobRecord) -> Bool {
        guard let remoteID = record.remoteID else { return false }
        return inFlightRemoteID == remoteID
    }
}
