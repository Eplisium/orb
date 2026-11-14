import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Video studio

struct VideoView: View {
    @ObservedObject private var service = StudioServices.shared.video
    @StateObject private var saved = SavedCreationsStore.shared
    @StudioState("VideoView.prompt") private var prompt = ""
    @StudioState("VideoView.selectedModelId") private var selectedModelId = ""
    @StudioState("VideoView.aspectRatio") private var aspectRatio = "auto"
    @StudioState("VideoView.resolution") private var resolution = "auto"
    @StudioState("VideoView.durationText") private var durationText = ""
    @StudioState("VideoView.size") private var size = "auto"
    @StudioState("VideoView.seedText") private var seedText = ""
    @StudioState("VideoView.firstFrameURL") private var firstFrameURL: URL? = nil
    @StudioState("VideoView.lastFrameURL") private var lastFrameURL: URL? = nil
    @StudioState("VideoView.generateAudio") private var generateAudio = false
    @StudioState("VideoView.errorMessage") private var errorMessage: String? = nil
    @StudioState("VideoView.jobs") private var jobs: [VideoJobRecord] = []
    @StudioState("VideoView.totalCost") private var totalCost = 0.0
    @StudioState("VideoView.savedVideos") private var savedVideos: [String: SavedCreation] = [:]
    @StudioState("VideoView.downloadErrors") private var downloadErrors: [String: String] = [:]
    @StudioState("VideoView.downloading") private var downloading: Set<String> = []
    /// POST /videos requests not yet answered (STUDIO-6). Only these lock
    /// the button; a submitted job keeps polling in the tray.
    @StudioState("VideoView.postingSubmits") private var postingSubmits = 0
    // Every known, resumable and downloadable job from ONE storage read,
    // refreshed on appear, poll ticks and storage revisions — never from
    // `body` (STUDIO-5).
    @StudioState("VideoView.jobSnapshot") private var jobSnapshot = VideoGenService.JobRecordSnapshot.empty
    @StudioState("VideoView.promptHistoryRevision") private var promptHistoryRevision = 0
    @State private var dropTargetFirst = false
    @State private var dropTargetLast = false
    @EnvironmentObject private var shell: ShellController

    /// Preset staged by Apply for a different model; consumed by the model-change reset.
    @State private var pendingPreset: VideoPresetValues? = nil
    @State private var conflictToResolve: JobConflictReview?
    @State private var conflictResolutionError: String?

    private struct JobConflictReview: Identifiable {
        let id: UUID
        let conflict: JobPersistenceConflict
    }

    private let accent = ORBTheme.accent
    private let promptHistory = StudioPromptHistory(studio: .video)
    private var resumableRecords: [JobRecord] { jobSnapshot.resumable }
    private var downloadableRecords: [JobRecord] { jobSnapshot.downloadable }

    struct VideoJobRecord: Identifiable {
        let id: String
        var job: VideoJob
        let prompt: String
        let modelId: String
    }

    var body: some View {
        HStack(spacing: 0) {
            controlsColumn
            Rectangle().fill(.orbSurface(0.07)).frame(width: 1)
            jobsColumn
        }
        .task {
            await service.fetchModels()
            if selectedModelId.isEmpty { selectedModelId = service.models.first?.id ?? "" }
            refreshResumableRecords()
        }
        // Poll ticks and terminal transitions flow through activeJob, so the
        // recoverable listing stays current while a run is in flight.
        .onChange(of: service.activeJob) { _, _ in
            refreshResumableRecords()
        }
        .onChange(of: service.jobRecordsRevision) { _, _ in
            refreshResumableRecords()
        }
        .onChange(of: selectedModelId) { _, _ in
            let o = PresetReset.videoOptions(afterChangingTo: selectedModelId, pending: pendingPreset)
            pendingPreset = nil
            aspectRatio = o.aspect
            resolution = o.resolution
            durationText = o.duration
            size = o.size
            seedText = ""
            firstFrameURL = nil
            lastFrameURL = nil
            generateAudio = o.generateAudio
        }
        .sheet(item: $conflictToResolve) { review in
            conflictReviewSheet(review)
        }
    }

    private func conflictReviewSheet(_ review: JobConflictReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resolve local job snapshots").font(.headline)
            Text("Each choice keeps the entire selected snapshot, including cost, prompt and creation link, and discards the other reviewed changes. No submission, polling, download or billing occurs.")
                .font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    conflictSnapshot("Local candidate", record: review.conflict.candidate)
                    conflictSnapshot("SQLite", record: review.conflict.durable)
                    if let owner = review.conflict.remoteOwner {
                        conflictSnapshot("SQLite remote-ID owner (different UUID)", record: owner)
                    }
                    conflictSnapshot("Recovery journal", record: review.conflict.journal?.candidate)
                    if let generation = review.conflict.journal?.generation {
                        Text("Journal generation: \(generation.uuidString)").font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            if let error = conflictResolutionError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Keep SQLite — discard reviewed candidates", role: .destructive) {
                    resolveConflict(review, resolution: .keepDurable)
                }
                if review.conflict.canRetryCandidate {
                    Button("Use local candidate — replace SQLite and journal", role: .destructive) {
                        resolveConflict(review, resolution: .retryCandidate)
                    }
                    if review.conflict.competingJournal {
                        Button("Use journal candidate — discard local candidate", role: .destructive) {
                            resolveConflict(review, resolution: .useJournal)
                        }
                    }
                }
                HStack {
                    Button("Refresh review") {
                        service.retryPendingJobPersistence(id: review.id)
                        if let conflict = service.jobPersistenceConflicts[review.id] {
                            conflictToResolve = JobConflictReview(id: review.id, conflict: conflict)
                            conflictResolutionError = nil
                        }
                        refreshResumableRecords()
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { conflictToResolve = nil }
                }
            }
        }
        .padding(20)
        .frame(width: 660, height: 620)
    }

    private func conflictSnapshot(_ title: String, record: JobRecord?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(JobPersistenceConflict.describe(record)).font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resolveConflict(_ review: JobConflictReview, resolution: JobPersistenceResolution) {
        if service.resolveJobPersistenceConflict(id: review.id, resolution: resolution, reviewToken: review.conflict.reviewToken) {
            conflictToResolve = nil
            conflictResolutionError = nil
        } else {
            conflictResolutionError = "Resolution was not completed. Snapshots may have changed or local storage may be unavailable. Refresh the review before choosing again."
        }
        refreshResumableRecords()
    }

    private func refreshResumableRecords() {
        let next = service.jobRecordSnapshot()
        if next != jobSnapshot { jobSnapshot = next }
    }

    /// Placeholder prompt for rows whose durable record predates prompt storage.
    private static let unknownPrompt = "(resumed from a previous session)"

    /// Row status for a submit the provider refused (no job, nothing billed).
    private static let rejectedStatus = "not submitted"


    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StudioHeader(title: "Video", subtitle: "Text-to-video generation", icon: "video.fill", accent: accent) {
                    jobTray
                    StudioPresetMenu(
                        studio: .video,
                        snapshot: {
                            StudioPreset.videoSettings(model: selectedModelId, aspect: aspectRatio, resolution: resolution,
                                                       duration: durationText, size: size, audio: generateAudio)
                        },
                        apply: { preset in
                            let v = VideoPresetValues(preset)
                            pendingPreset = PresetReset.stagedModel(presetModel: v.model, current: selectedModelId) ? v : nil
                            if !v.model.isEmpty { selectedModelId = v.model }
                            aspectRatio = v.aspect; resolution = v.resolution
                            durationText = v.duration; size = v.size; generateAudio = v.generateAudio
                        })
                }

            VStack(alignment: .leading, spacing: 6) {
                StudioLabel("Model")
                if service.isLoadingModels {
                    ProgressView().controlSize(.small)
                } else if service.models.isEmpty {
                    Text(service.modelsError ?? "No video models found.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await service.fetchModels() } }.font(.caption)
                } else {
                    Picker("Model", selection: $selectedModelId) {
                        ForEach(service.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            if let model = service.models.first(where: { $0.id == selectedModelId }) {
                modelCapabilities(model)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    StudioLabel("Prompt")
                    Spacer(minLength: 0)
                    StudioPromptHistoryMenu(history: promptHistory, onPick: { prompt = $0 },
                                            revision: promptHistoryRevision)
                }
                StudioPromptEditor(text: $prompt, placeholder: "Describe the video you want…",
                                   accessibilityLabel: "Video prompt")
            }

            StudioCard(title: "Options") {
                StudioGrid {
                    StudioField("Aspect") {
                        Picker("Aspect", selection: $aspectRatio) {
                            Text("auto").tag("auto")
                            ForEach(supportedAspects(), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                    StudioField("Resolution") {
                        Picker("Resolution", selection: $resolution) {
                            Text("auto").tag("auto")
                            ForEach(supportedResolutions(), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                    StudioField("Duration") {
                        if let durations = selectedVideoModel?.supportedDurations, !durations.isEmpty {
                            Picker("Duration", selection: $durationText) {
                                Text("Model default").tag("")
                                ForEach(durations, id: \.self) { Text("\($0) s").tag(String($0)) }
                            }.labelsHidden()
                        } else {
                            Text("Model default").orbFont(size: 12).foregroundStyle(.secondary)
                        }
                    }
                    StudioField("Size") {
                        Picker("Size", selection: $size) {
                            Text("auto").tag("auto")
                            ForEach(selectedVideoModel?.supportedSizes ?? [], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().disabled(selectedVideoModel?.supportedSizes?.isEmpty != false)
                    }
                }
                StudioGrid {
                    StudioField("Seed (optional)") {
                        TextField("random", text: $seedText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(selectedVideoModel?.seed != true)
                    }
                    StudioField("Audio") {
                        // The field title already says "Audio"; a short state label cannot wrap in the grid cell.
                        HStack(spacing: 6) {
                            Toggle("Generate audio", isOn: $generateAudio)
                                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            Text(generateAudio ? "On" : "Off").font(.caption).foregroundStyle(.secondary)
                        }
                            .disabled(selectedVideoModel?.generateAudio != true)
                            .help("Audio may change the per-job price. When off, send generate_audio: false explicitly.")
                    }
                }
                if size != "auto" {
                    StudioNotice(text: "Exact size overrides aspect and resolution.")
                }
            }
            HStack(spacing: 10) {
                frameSelector("First frame", kind: "first_frame", selection: $firstFrameURL)
                frameSelector("Last frame", kind: "last_frame", selection: $lastFrameURL)
            }

            }
            .padding(18)
        }
        // Pinned footer: the primary action stays fully visible however tall the form grows
        // (it used to sit at the end of the scroll content, half-clipped by the window edge).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StudioPinnedFooter {
            // Errors sit at the top of the pinned footer, always on screen
            // (STUDIO-2): the form above can be taller than the window.
            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }
            if !service.inFlightRemoteIDs.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(service.inFlightRemoteIDs.count == 1 ? "1 job polling every 5s"
                         : "\(service.inFlightRemoteIDs.count) jobs polling every 5s")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop all") {
                        service.stopPolling()
                        refreshResumableRecords()
                    }.font(.caption)
                }
            }

            StudioPrimaryButton(title: "Generate Video", busyTitle: "Submitting…", isBusy: postingSubmits > 0,
                                isEnabled: canSubmit, accent: accent, action: submit)
                .keyboardShortcut(.return, modifiers: .command)

            Text(costLine)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if service.inFlightRemoteIDs.count >= VideoSubmitGate.maxConcurrentJobs {
                Text("Up to \(VideoSubmitGate.maxConcurrentJobs) jobs can poll at once. Wait for one to finish, or stop checking one.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if totalCost > 0 {
                Text("Reported spend (known charges): $\(totalCost, specifier: "%.4f")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            }
        }
        .frame(width: 340)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private func modelCapabilities(_ model: VideoGenModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let durations = model.supportedDurations, !durations.isEmpty {
                Text("Durations: \(durations.map(String.init).joined(separator: ", "))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let skus = model.pricingSkus, !skus.isEmpty {
                Text("Rates: " + StudioCostEstimate.videoRateLines(skus).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.generateAudio == true {
                Text("Supports audio generation").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedVideoModel: VideoGenModel? {
        service.models.first(where: { $0.id == selectedModelId })
    }

    /// Pre-submit estimate from SKU pricing × duration (STUDIO-12). Never a
    /// guessed number: unknown pricing says so.
    private var costEstimate: StudioCostEstimate? {
        guard let model = selectedVideoModel else { return nil }
        let duration = Int(durationText) ?? model.supportedDurations?.first
        let res = resolution == "auto" ? nil : resolution
        let audio: Bool? = model.generateAudio == true ? generateAudio : nil
        return StudioCostEstimate.video(skus: model.pricingSkus, durationSeconds: duration, resolution: res,
                                        audio: audio, usesFrames: firstFrameURL != nil || lastFrameURL != nil)
    }

    private var costLine: String {
        if let costEstimate {
            let defaulted = durationText.isEmpty ? " (default duration assumed)" : ""
            return "\(costEstimate.label)\(defaulted). Billed per job; the actual charge is reported when it finishes."
        }
        return "Price unknown for these settings — check the model's rates before submitting. Billed per job."
    }

    private func supportedAspects() -> [String] {
        service.models.first(where: { $0.id == selectedModelId })?.supportedAspectRatios ?? []
    }

    private func supportedResolutions() -> [String] {
        service.models.first(where: { $0.id == selectedModelId })?.supportedResolutions ?? []
    }

    private func frameSelector(_ title: String, kind: String, selection: Binding<URL?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button(selection.wrappedValue == nil ? "Choose…" : "Replace…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = StudioDropFilter.imageTypes
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK { selection.wrappedValue = panel.url }
                }
                .disabled(selectedVideoModel?.supportedFrameImages?.contains(kind) != true)
                if selection.wrappedValue != nil {
                    Button { selection.wrappedValue = nil } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Remove \(title.lowercased())")
                }
            }.font(.caption)
            if let url = selection.wrappedValue {
                Text(url.lastPathComponent).font(.caption2).lineLimit(1)
            } else if selectedVideoModel?.supportedFrameImages?.contains(kind) == true {
                Text("or drop an image").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .studioFileDrop(kind: .image, isTargeted: kind == "first_frame" ? $dropTargetFirst : $dropTargetLast) { urls in
            guard selectedVideoModel?.supportedFrameImages?.contains(kind) == true, let url = urls.first else { return }
            selection.wrappedValue = url
        }
    }

    /// Media job tray, in the studio header beside Presets (V-3). Fed from
    /// the cached snapshot, never a storage read in `body` (STUDIO-5).
    private var jobTray: some View {
        JobTrayButton(
            jobs: jobSnapshot.all,
            onResume: { resumeDurable($0) },
            onStop: { record in
                if let remoteID = record.remoteID { service.stopPolling(remoteID: remoteID) }
                refreshResumableRecords()
            },
            onDownload: { record in Task { await downloadDurable(record) } },
            // Opens ORB's Library on the saved item — not Finder (STUDIO-4).
            onOpen: { record in StudioNavigation.showInLibrary(record.savedCreationID, shell: shell) },
            onDismiss: { record in
                if service.dismissJob(record) { refreshResumableRecords() }
            },
            isDownloading: { record in record.remoteID.map { service.downloadingRemoteIDs.contains($0) } ?? false },
            hasLiveRun: { service.isRunInFlight(for: $0) }
        )
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var jobsColumn: some View {
        jobsColumnBody
    }

    private var jobsColumnBody: some View {
        Group {
            if jobs.isEmpty && resumableRecords.isEmpty && downloadableRecords.isEmpty
                && saved.creations.allSatisfy({ $0.kind != .video })
                && service.durablePersistenceError == nil {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(accent.opacity(0.10)).frame(width: 96, height: 96)
                        Image(systemName: "film").orbFont(size: 32).foregroundStyle(accent)
                    }
                    Text("Generate video")
                        .orbFont(size: 24, weight: .semibold, design: .rounded)
                    Text("Video jobs take minutes. Submit one and it polls here until the download is ready.")
                        .orbFont(size: 13).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        durableJobsSection
                        if saved.creations.contains(where: { $0.kind == .video }) {
                            Text("SAVED VIDEOS").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(saved.creations.filter { $0.kind == .video }) { creation in
                                savedVideoCard(creation)
                            }
                        }
                        ForEach(jobs) { record in
                            jobCard(record)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Durable resume (W09 step 3)

    /// Recoverable durable jobs plus the persistence-failure notice. Resuming
    /// restarts the owned poll loop — never a new submission.
    @ViewBuilder
    private var durableJobsSection: some View {
        if let warning = service.jobPersistenceWarning {
            VStack(alignment: .leading, spacing: 8) {
                Label("JOB RECOVERY · \(service.unsavedJobRecordCount) UNSAVED", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption.bold()).foregroundStyle(.orange)
                Text(warning).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry saving all job records") {
                    service.retryPendingJobPersistence()
                    refreshResumableRecords()
                }
                .controlSize(.small)
                ForEach(service.jobPersistenceIssueRecords) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.remoteID ?? "Unknown submission · \(record.id.uuidString.prefix(8))")
                                .font(.caption.monospacedDigit()).lineLimit(1)
                            if let error = service.jobPersistenceErrors[record.id] {
                                Text(error).font(.caption2).foregroundStyle(.secondary)
                            }
                            if service.unsavedJobRecords.contains(where: { $0.id == record.id }) {
                                Text(service.memoryOnlyJobRecordIDs.contains(record.id)
                                    ? "Latest changes: memory only" : "Latest changes: local recovery journal")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            if let conflict = service.jobPersistenceConflicts[record.id] {
                                Text("Recovered: \(record.pollingState.rawValue) · Durable: \((conflict.remoteOwner ?? conflict.durable)?.pollingState.rawValue ?? "absent")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let conflict = service.jobPersistenceConflicts[record.id] {
                            Button("Resolve locally…") {
                                conflictResolutionError = nil
                                conflictToResolve = JobConflictReview(id: record.id, conflict: conflict)
                            }
                                .controlSize(.small)
                        }
                        Button("Retry saving") {
                            service.retryPendingJobPersistence(id: record.id)
                            refreshResumableRecords()
                        }
                        .controlSize(.small)
                        .help("Save this local record only; never submit a new paid job")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !downloadableRecords.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("FINISHED, NOT SAVED")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                ForEach(downloadableRecords) { record in
                    downloadableRow(record)
                }
            }
        }
        if !resumableRecords.isEmpty || service.durablePersistenceError != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERABLE JOBS")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                ForEach(resumableRecords) { record in
                    resumableRow(record)
                }
                if let persistenceError = service.durablePersistenceError {
                    Label(persistenceError, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func resumableRow(_ record: JobRecord) -> some View {
        let p = JobPresentation.make(record, hasLiveRun: service.isRunInFlight(for: record))
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ORBStatusPill(status: p.status)
                    Text(record.modelID ?? "video").font(.caption.monospacedDigit()).lineLimit(1)
                }
                Text(p.detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Last status: \(record.lastRemoteStatus ?? "unknown") · \(JobTray.ageText(from: record.createdAt))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if p.actions.contains(.resume) {
                Button {
                    resumeDurable(record)
                } label: {
                    Label("Resume", systemImage: "arrow.clockwise").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Double-resume guard: disabled while this service's poll loop is
                // already running for this record's remote job.
                .disabled(service.isRunInFlight(for: record) || !KeychainManager.hasAPIKey)
                .help(service.isRunInFlight(for: record)
                    ? "Already polling this job"
                    : "Resume polling without submitting a new job")
            }
        }
        .padding(10)
        .background(.orbSurface(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func downloadableRow(_ record: JobRecord) -> some View {
        let busy = record.remoteID.map { service.downloadingRemoteIDs.contains($0) } ?? false
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ORBStatusPill(status: .complete)
                    Text(record.modelID ?? "video").font(.caption.monospacedDigit()).lineLimit(1)
                }
                if let prompt = record.prompt { Text(prompt).font(.caption).lineLimit(2) }
                Text("Finished \(JobTray.ageText(from: record.updatedAt)) · the provider may expire it, so download soon.")
                    .font(.caption2).foregroundStyle(.tertiary)
                if let remoteID = record.remoteID, let failure = downloadErrors[remoteID] {
                    Text("Not saved: \(failure)").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await downloadDurable(record) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!KeychainManager.hasAPIKey)
            }
        }
        .padding(10)
        .background(.orbSurface(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    /// Downloads and saves a finished durable job exactly once.
    private func downloadDurable(_ record: JobRecord) async {
        guard let remoteID = record.remoteID else { return }
        do {
            let creation = try await service.downloadAndSave(remoteID: remoteID, store: saved)
            downloadErrors[remoteID] = nil
            for row in jobs where row.job.id == remoteID { savedVideos[row.id] = creation }
        } catch is CancellationError {
        } catch {
            downloadErrors[remoteID] = error.localizedDescription
        }
        refreshResumableRecords()
    }

    /// Resumes a durable record through the service, routing poll updates into
    /// the same job-row update path the submit flow uses.
    private func resumeDurable(_ record: JobRecord) {
        guard !service.isRunInFlight(for: record) else { return }
        errorMessage = nil
        let rowID = record.id.uuidString
        if !jobs.contains(where: { $0.id == rowID }) {
            jobs.insert(VideoJobRecord(
                id: rowID,
                job: VideoJob(
                    id: record.remoteID ?? "",
                    status: record.lastRemoteStatus ?? "queued"
                ),
                prompt: record.prompt ?? Self.unknownPrompt,
                modelId: record.modelID ?? "video"
            ), at: 0)
        }
        Task {
            do {
                let finished = try await service.resume(record) { update in
                    Task { @MainActor in
                        if let index = jobs.firstIndex(where: { $0.id == rowID }) {
                            jobs[index].job = update
                        }
                    }
                }
                totalCost += finished.cost ?? 0
                if let index = jobs.firstIndex(where: { $0.id == rowID }) { jobs[index].job = finished }
                await keepVideo(rowID)
                StudioNotifier.shared.finished(section: SidebarSection.video.rawValue, title: "Video ready", body: "Your video finished and was saved in ORB.")
            } catch is CancellationError {
                // Local stop or navigation: the record stays resumable.
                jobs.removeAll { $0.id == rowID }
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshResumableRecords()
        }
    }

    private func jobCard(_ record: VideoJobRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.modelId).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                statusPill(record.job.status)
            }
            Text(record.prompt).orbFont(size: 12).lineLimit(3)
            if let cost = record.job.cost {
                Text("Cost: $\(cost, specifier: "%.4f")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if record.job.isSuccess {
                if let creation = savedVideos[record.id] {
                    SavedVideoPlayerCard(creation: creation, store: saved)
                }
                HStack(spacing: 8) {
                    if downloading.contains(record.id) || service.downloadingRemoteIDs.contains(record.job.id) {
                        ProgressView().controlSize(.small); Text("Saving in ORB…")
                    }
                    else if savedVideos[record.id] != nil { Label("Saved in ORB", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Download & save") { Task { await keepVideo(record.id) } } }
                    Spacer()
                    if let creation = savedVideos[record.id] {
                        CreationActionsMenu(creation: creation, store: saved, onError: { errorMessage = $0 },
                                            openInStudio: { StudioNavigation.openInStudio($0, shell: shell) })
                        Button("Export…") { exportSaved(creation) }
                    }
                }
                if let failure = downloadErrors[record.id] {
                    Text("Not saved: \(failure)").font(.caption).foregroundStyle(.orange)
                }
            } else if record.job.status == Self.rejectedStatus {
                Text("The provider rejected the request, so no job exists and nothing was billed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if record.job.status == "submission uncertain" {
                Text("Submission outcome unknown. Check recoverable jobs before attempting another paid run.")
                    .font(.caption).foregroundStyle(.orange)
            } else if !record.job.isTerminal {
                HStack(spacing: 8) {
                    if service.inFlightRemoteIDs.contains(record.job.id) {
                        ProgressView().controlSize(.small)
                        Text("Polling… status: \(record.job.status)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop checking") {
                            service.stopPolling(remoteID: record.job.id)
                            refreshResumableRecords()
                        }.font(.caption)
                    } else {
                        Text("Not being checked · last status: \(record.job.status)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let error = record.job.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.orbSurface(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusPill(_ status: String) -> some View {
        let color: Color = status == "completed" ? .green
            : status == "failed" || status == "expired" || status == "cancelled" || status == Self.rejectedStatus ? .red : .orange
        return Text(status.uppercased())
            .orbFont(size: 11, weight: .bold)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func savedVideoCard(_ creation: SavedCreation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SavedVideoPlayerCard(creation: creation, store: saved, height: 150)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let prompt = creation.prompt { Text(prompt).font(.caption).lineLimit(2) }
                    Text(creation.modelID).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                CreationActionsMenu(creation: creation, store: saved, onError: { errorMessage = $0 },
                                    openInStudio: { StudioNavigation.openInStudio($0, shell: shell) })
                Button("Export…") { exportSaved(creation) }
            }
        }
        .padding(12)
        .background(.orbSurface(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var canSubmit: Bool {
        VideoSubmitGate.canSubmit(
            hasModel: !selectedModelId.isEmpty && !service.isLoadingModels,
            hasPrompt: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasKey: KeychainManager.hasAPIKey,
            postingSubmits: postingSubmits,
            pollingJobs: service.inFlightRemoteIDs.count
        )
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil
        let modelId = selectedModelId
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = VideoGenRequest(model: modelId)
        request.prompt = promptText.isEmpty ? nil : promptText
        request.size = size == "auto" || selectedVideoModel?.supportedSizes?.contains(size) != true ? nil : size
        request.aspectRatio = request.size == nil && supportedAspects().contains(aspectRatio) ? aspectRatio : nil
        request.resolution = request.size == nil && supportedResolutions().contains(resolution) ? resolution : nil
        if let seconds = Int(durationText), selectedVideoModel?.supportedDurations?.contains(seconds) == true {
            request.duration = seconds
        }
        request.generateAudio = selectedVideoModel?.generateAudio == true ? generateAudio : nil
        let firstFrame = selectedVideoModel?.supportedFrameImages?.contains("first_frame") == true ? firstFrameURL : nil
        let lastFrame = selectedVideoModel?.supportedFrameImages?.contains("last_frame") == true ? lastFrameURL : nil
        do {
            if selectedVideoModel?.seed == true, !seedText.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) else {
                    throw MediaStudioImageFile.Failure.invalid("Seed must be a whole number.")
                }
                request.seed = seed
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let recordId = UUID().uuidString
        jobs.insert(VideoJobRecord(
            id: recordId,
            job: VideoJob(id: recordId, status: "pending", pollingURL: nil, generationId: nil, unsignedURLs: nil, error: nil, cost: nil),
            prompt: promptText.isEmpty ? "(no prompt)" : promptText,
            modelId: modelId
        ), at: 0)
        let submitRequest = request
        postingSubmits += 1
        Task {
            // The button is released once the POST is answered (or fails);
            // polling continues in the tray (STUDIO-6).
            var released = false
            @MainActor func release() { if !released { released = true; postingSubmits -= 1 } }
            defer { release() }
            // Frame files are read and base64-encoded off the main actor
            // (STUDIO-10). A local read failure sent nothing: drop the row.
            let frames: [String]
            do {
                frames = try await MediaStudioImageFile.dataURLsOffMain([firstFrame, lastFrame].compactMap { $0 })
            } catch {
                errorMessage = error.localizedDescription
                jobs.removeAll { $0.id == recordId }
                return
            }
            do {
                var request = submitRequest
                var next = frames.makeIterator()
                if firstFrame != nil { request.firstFrameImage = next.next() }
                if lastFrame != nil { request.lastFrameImage = next.next() }
                let finished = try await service.submitAndPoll(request, reportingSubmission: { _ in
                    release()
                    promptHistory.record(promptText)
                    promptHistoryRevision += 1
                }, onUpdate: { update in
                    Task { @MainActor in
                        if let index = jobs.firstIndex(where: { $0.id == recordId }) {
                            jobs[index].job = update
                        }
                    }
                })
                totalCost += finished.cost ?? 0
                if let index = jobs.firstIndex(where: { $0.id == recordId }) { jobs[index].job = finished }
                await keepVideo(recordId)
                StudioNotifier.shared.finished(section: SidebarSection.video.rawValue, title: "Video ready", body: "Your video finished and was saved in ORB.")
            } catch is CancellationError {
                // Stopping local polling does not cancel the remote paid job.
                // Keep the durable resumable record instead of a fake cancelled state.
                jobs.removeAll { $0.id == recordId }
            } catch {
                errorMessage = error.localizedDescription
                // Poll/network failure does not mean the paid remote job failed.
                // Keep its last known status and durable resume affordance.
                // A row still carrying its local ID never got a remote job:
                // either the provider refused it outright, or the outcome is unknown.
                if let index = jobs.firstIndex(where: { $0.id == recordId }),
                   jobs[index].job.id == recordId {
                    let status = VideoGenService.isDefinitiveRejection(error) ? Self.rejectedStatus : "submission uncertain"
                    jobs[index].job = VideoJob(id: recordId, status: status, pollingURL: nil,
                        generationId: nil, unsignedURLs: nil, error: error.localizedDescription, cost: nil)
                }
                refreshResumableRecords()
            }
        }
    }

    /// Downloads (streamed to disk) and saves a finished row's video once.
    private func keepVideo(_ id: String) async {
        guard savedVideos[id] == nil, !downloading.contains(id),
              let record = jobs.first(where: { $0.id == id }), record.job.isSuccess else { return }
        downloading.insert(id)
        defer { downloading.remove(id) }
        do {
            let creation = try await service.downloadAndSave(remoteID: record.job.id, store: saved)
            savedVideos[id] = creation
            downloadErrors[id] = nil
        } catch is CancellationError {
        } catch { downloadErrors[id] = error.localizedDescription }
        refreshResumableRecords()
    }

    /// Exports by copying the stored file — never re-reading it into memory.
    private func exportSaved(_ creation: SavedCreation) {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.nameFieldStringValue = "orb-video.\(videoExtension(creation.mimeType))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try saved.export(creation, to: url) }
        catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }

    private func videoExtension(_ mime: String) -> String {
        switch mime {
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        default: return "mp4"
        }
    }

}

private extension VideoJob {
    /// Convenience alias — the API calls them `unsigned_urls`.
    var urls: [String] { unsignedURLs ?? [] }
}

/// Submit gating for the Video studio (STUDIO-6). Only an unanswered POST
/// locks the button — a submitted job polls in the tray — and at most
/// `maxConcurrentJobs` jobs poll at once.
enum VideoSubmitGate {
    static let maxConcurrentJobs = 4

    static func canSubmit(hasModel: Bool, hasPrompt: Bool, hasKey: Bool,
                          postingSubmits: Int, pollingJobs: Int) -> Bool {
        hasModel && hasPrompt && hasKey && postingSubmits == 0 && pollingJobs < maxConcurrentJobs
    }
}
