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

/// Retry policy for transient poll failures (network errors, 5xx, 429).
/// One failed poll must not end polling while the tray still says Running.
struct PollRetryPolicy: Sendable, Equatable {
    /// Consecutive transient failures tolerated before polling gives up.
    var maxConsecutiveFailures: Int = 5
    /// First backoff delay; doubles per consecutive failure up to `maxDelay`.
    var baseDelay: Duration = .seconds(2)
    var maxDelay: Duration = .seconds(30)

    static let standard = PollRetryPolicy()

    /// Backoff before retry number `attempt` (1-based), capped.
    func delay(forAttempt attempt: Int) -> Duration {
        let factor = 1 << min(max(attempt - 1, 0), 16)
        let raw = baseDelay * factor
        return raw < maxDelay ? raw : maxDelay
    }
}

@MainActor
final class VideoGenService: ObservableObject {
    @Published var models: [VideoGenModel] = []
    @Published var isLoadingModels = false
    @Published var modelsError: String?
    /// Last job any poll loop reported (most recently updated). With several
    /// concurrent polls this is only a "something changed" signal for views.
    @Published var activeJob: VideoJob?
    @Published var jobError: String?

    private let transport: MediaTransport
    /// Application-owned durable job state (W06). Injectable so tests can
    /// isolate storage; the default view path uses the shared controller so
    /// job records survive navigation and app restarts.
    private let jobController: JobController
    private let retryPolicy: PollRetryPolicy
    /// One owned poll task per remote job, so resuming job B never stops job
    /// A. Each entry carries a generation token so a replaced loop's cleanup
    /// cannot clear its successor.
    private var pollTasks: [String: (generation: Int, task: Task<VideoJob, Error>)] = [:]
    private var pollGeneration = 0
    /// Remote IDs whose owned poll loop is running. Distinct from
    /// `activeJob`, which deliberately keeps the last known state after a
    /// local stop — a stopped job is not an in-flight run.
    @Published private(set) var inFlightRemoteIDs: Set<String> = [] {
        didSet { isPolling = !inFlightRemoteIDs.isEmpty }
    }
    /// True while any job is being polled (drives the sidebar activity badge).
    @Published private(set) var isPolling = false
    /// Remote IDs whose result is being downloaded+saved right now.
    @Published private(set) var downloadingRemoteIDs: Set<String> = []
    private var downloadTasks: [String: Task<SavedCreation, Error>] = [:]

    init(
        transport: MediaTransport = MediaTransport(),
        jobController: JobController? = nil,
        retryPolicy: PollRetryPolicy = .standard
    ) {
        self.transport = transport
        // Resolved on the main actor (VideoGenService is @MainActor): the
        // default view path shares the application-owned controller.
        self.jobController = jobController ?? JobController.shared
        self.retryPolicy = retryPolicy
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
    /// The polling loop runs in a task this service owns (keyed by remote
    /// job ID), so `stopPolling(remoteID:)` cancels exactly that loop. Other
    /// jobs keep polling. Local cancellation surfaces as `CancellationError`
    /// and never claims the remote job was cancelled; remote failures throw
    /// `MediaServiceError`.
    func submitAndPoll(
        _ request: VideoGenRequest,
        pollInterval: Duration = .seconds(5),
        onUpdate: @escaping @Sendable (VideoJob) -> Void = { _ in }
    ) async throws -> VideoJob {
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
        // Durable record keyed by the remote job ID, persisted before any
        // poll result is relied upon. A failed write never aborts the flow
        // (JobController surfaces it as lastPersistenceError).
        jobController.recordVideoSubmission(
            remoteID: job.id,
            modelID: request.model,
            remoteStatus: job.status,
            error: job.error,
            cost: job.cost,
            prompt: request.prompt
        )
        onUpdate(job)
        return try await runOwnedPollLoop(
            from: job, modelID: request.model, pollInterval: pollInterval, onUpdate: onUpdate
        )
    }

    /// Resumes polling for a durable job record (W09): restarts the owned
    /// poll loop for a job that already exists remotely, without any new
    /// submission — a resume never issues `POST /videos`. Use this after an
    /// app restart or a local stop (`JobRecord.stoppedLocally`) so the job
    /// survives the view that started it. Other jobs' polls are untouched.
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
        // Restarting the SAME job replaces its loop; other jobs keep polling.
        cancelLoop(remoteID: remoteID)
        // Seed the loop from the last known durable state; the first poll
        // goes to the canonical `videos/<remoteID>` route (or the record's
        // stored polling URL after origin validation) exactly like an
        // uninterrupted poll would.
        let initial = VideoJob(id: remoteID, status: record.lastRemoteStatus ?? "queued")
        onUpdate(initial)
        return try await runOwnedPollLoop(
            from: initial, modelID: record.modelID ?? "unknown",
            pollInterval: pollInterval, onUpdate: onUpdate
        )
    }

    /// Starts the owned polling task for `job` and awaits its terminal
    /// result. Shared by submit-then-poll and resume so both flows have the
    /// same cancellation and durability semantics.
    private func runOwnedPollLoop(
        from job: VideoJob,
        modelID: String,
        pollInterval: Duration,
        onUpdate: @escaping @Sendable (VideoJob) -> Void
    ) async throws -> VideoJob {
        activeJob = job
        pollGeneration += 1
        let generation = pollGeneration
        let remoteID = job.id
        let loop: Task<VideoJob, Error> = Task {
            try await pollUntilTerminal(job, modelID: modelID, pollInterval: pollInterval, onUpdate: onUpdate)
        }
        pollTasks[remoteID] = (generation, loop)
        inFlightRemoteIDs.insert(remoteID)
        defer {
            if pollTasks[remoteID]?.generation == generation {
                pollTasks[remoteID] = nil
                inFlightRemoteIDs.remove(remoteID)
            }
        }
        return try await withTaskCancellationHandler {
            try await loop.value
        } onCancel: {
            loop.cancel()
        }
    }

    /// Polls until a terminal status. Prefers the canonical `videos/<jobId>`
    /// route; a supplied `polling_url` is used only after it resolves and
    /// passes the exact origin policy, before any credential is attached to
    /// the request. Transient failures (network, 5xx, 429) are retried with
    /// capped exponential backoff; when retries run out — or a failure is
    /// not transient — the durable record becomes `.stoppedLocally` with a
    /// recoverable error so the tray offers Resume instead of "Running".
    private func pollUntilTerminal(
        _ initial: VideoJob,
        modelID: String,
        pollInterval: Duration,
        onUpdate: @escaping @Sendable (VideoJob) -> Void
    ) async throws -> VideoJob {
        var job = initial
        var consecutiveFailures = 0
        while !job.isTerminal {
            try Task.checkCancellation()
            let wait = consecutiveFailures == 0 ? pollInterval : retryPolicy.delay(forAttempt: consecutiveFailures)
            try await Task.sleep(for: wait)
            try Task.checkCancellation()
            do {
                let next: VideoJob = try await transport.send(pollRequest(for: job))
                job = next
                consecutiveFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let mapped = Self.mediaError(error)
                consecutiveFailures += 1
                if mapped.isTransient && consecutiveFailures <= retryPolicy.maxConsecutiveFailures {
                    continue
                }
                let note = mapped.isTransient
                    ? "Stopped checking after \(consecutiveFailures) failed attempts: \(mapped.localizedDescription) The job may still be running — Resume to check again."
                    : "Stopped checking: \(mapped.localizedDescription) The job may still be running — Resume to check again."
                jobController.recordPollFailure(remoteID: job.id, error: note)
                throw mapped
            }
            activeJob = job
            jobController.recordPollUpdate(
                remoteID: job.id, remoteStatus: job.status, error: job.error, cost: job.cost
            )
            onUpdate(job)
        }
        // Terminal: persist the final state and cost regardless of outcome so
        // a completed job keeps its usage and a failure keeps its error.
        if job.isSuccess || job.cost != nil {
            UsageLedger.shared.record(.video, model: modelID, cost: job.cost, eventID: job.id)
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

    private static func mediaError(_ error: Error) -> MediaServiceError {
        if let media = error as? MediaServiceError { return media }
        if error is URLError { return .transport(error.localizedDescription) }
        return .transport(error.localizedDescription)
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

    private func contentRequest(remoteID: String, index: Int) throws -> URLRequest {
        guard !remoteID.isEmpty, !remoteID.contains("/"), !remoteID.contains("?"), !remoteID.contains("#"), index >= 0 else {
            throw MediaServiceError.invalidPath(remoteID)
        }
        return try transport.request(path: "videos/\(remoteID)/content", queryItems: [URLQueryItem(name: "index", value: String(index))])
    }

    /// Download through the canonical authenticated proxy, never unsigned URLs.
    func download(_ job: VideoJob, index: Int = 0) async throws -> (Data, String?) {
        try await transport.sendRaw(contentRequest(remoteID: job.id, index: index))
    }

    static let acceptedVideoMIMEs: Set<String> = ["video/mp4", "video/webm", "video/quicktime"]

    /// Streams the finished video to a temporary file (never fully in
    /// memory) and validates its content type. Caller owns the file.
    func downloadToFile(remoteID: String, index: Int = 0) async throws -> (URL, String) {
        let (file, contentType) = try await transport.downloadToFile(contentRequest(remoteID: remoteID, index: index))
        let mime = contentType?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "video/mp4"
        guard Self.acceptedVideoMIMEs.contains(mime) else {
            try? FileManager.default.removeItem(at: file)
            throw MediaServiceError.decoding("The download was not a supported video (\(mime)).")
        }
        return (file, mime)
    }

    /// Downloads a finished job's video and saves it in ORB exactly once.
    /// Concurrent calls for the same job share one download; a job already
    /// linked to a creation that still exists returns it without any request.
    /// The video streams to disk and moves into the library — no bytes stay
    /// in memory. The durable record keeps the creation ID, so after a
    /// restart the tray knows the result is saved.
    func downloadAndSave(remoteID: String, store: SavedCreationsStore) async throws -> SavedCreation {
        if let record = jobController.record(remoteID: remoteID),
           let savedID = record.savedCreationID {
            if let existing = store.creations.first(where: { $0.id == savedID }) { return existing }
            // The creation was deleted from Library: allow downloading again.
            jobController.clearSavedCreation(remoteID: remoteID)
        }
        if let running = downloadTasks[remoteID] { return try await running.value }
        let record = jobController.record(remoteID: remoteID)
        let task = Task<SavedCreation, Error> { @MainActor in
            let (file, mime) = try await downloadToFile(remoteID: remoteID)
            do {
                let creation = try await store.save(
                    fileAt: file, mimeType: mime, kind: .video,
                    modelID: record?.modelID ?? "unknown", prompt: record?.prompt
                )
                jobController.recordSavedCreation(remoteID: remoteID, creationID: creation.id)
                return creation
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }
        downloadTasks[remoteID] = task
        downloadingRemoteIDs.insert(remoteID)
        defer {
            downloadTasks[remoteID] = nil
            downloadingRemoteIDs.remove(remoteID)
        }
        return try await task.value
    }

    /// Cancels one job's owned poll loop. The remote job keeps running and
    /// the durable record is marked `.stoppedLocally` — explicitly distinct
    /// from remote failure/cancellation and still resumable.
    func stopPolling(remoteID: String) {
        guard pollTasks[remoteID] != nil else { return }
        jobController.recordStoppedLocally(remoteID: remoteID)
        AppToasts.jobFinished(.stoppedLocally, kind: "video")
        cancelLoop(remoteID: remoteID)
    }

    /// Cancels every owned polling task. Local stopping only ends polling;
    /// remote jobs keep running and `activeJob` keeps its last known state.
    func stopPolling() {
        var stopped = Set(pollTasks.keys)
        if let active = activeJob, !active.isTerminal { stopped.insert(active.id) }
        for remoteID in stopped {
            jobController.recordStoppedLocally(remoteID: remoteID)
        }
        if !stopped.isEmpty { AppToasts.jobFinished(.stoppedLocally, kind: "video") }
        for remoteID in Array(pollTasks.keys) { cancelLoop(remoteID: remoteID) }
    }

    private func cancelLoop(remoteID: String) {
        pollTasks[remoteID]?.task.cancel()
        pollTasks[remoteID] = nil
        inFlightRemoteIDs.remove(remoteID)
    }

    // MARK: Durable resume affordance (W09 step 3 wiring)

    /// Durable records that can still be resumed (remote ID present, polling
    /// not terminal), read from this service's own JobController. Views use
    /// this passthrough instead of reaching into `JobController.shared`, so
    /// tests and alternate hosts stay isolated from shared state.
    var resumableRecords: [JobRecord] { jobController.resumableJobs() }

    /// Finished jobs whose video was never saved in ORB (survives restarts).
    var downloadableRecords: [JobRecord] { jobController.downloadableJobs() }

    /// Every durable job (active, finished, failed) for the tray.
    var allJobRecords: [JobRecord] { jobController.allJobs() }

    /// Last persistence failure from the durable store, surfaced beside the
    /// resume affordance so a failed write is visible, never silent.
    var durablePersistenceError: String? { jobController.lastPersistenceError }

    /// True while this service's owned poll loop is running for the record's
    /// remote job. Deliberately reads the in-flight set rather than
    /// `activeJob`: after a local stop `activeJob` still holds the last
    /// known (non-terminal) state, but no run is in flight.
    func isRunInFlight(for record: JobRecord) -> Bool {
        guard let remoteID = record.remoteID else { return false }
        return inFlightRemoteIDs.contains(remoteID)
    }
}
