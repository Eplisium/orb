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
    @StudioState("VideoView.videoBytes") private var videoBytes: [String: Data] = [:]
    @StudioState("VideoView.videoMIMEs") private var videoMIMEs: [String: String] = [:]
    @StudioState("VideoView.savedVideos") private var savedVideos: [String: SavedCreation] = [:]
    @StudioState("VideoView.downloadErrors") private var downloadErrors: [String: String] = [:]
    @StudioState("VideoView.downloading") private var downloading: Set<String> = []
    @StudioState("VideoView.isSubmitting") private var isSubmitting = false
    // Durable jobs that can be resumed (W09 step 3). Refreshed on appear and
    // whenever the service's active job changes (poll ticks, terminal states).
    @StudioState("VideoView.resumableRecords") private var resumableRecords: [JobRecord] = []

    private let accent = ORBTheme.accent

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
        .onChange(of: selectedModelId) { _, _ in
            aspectRatio = "auto"
            resolution = "auto"
            durationText = ""
            size = "auto"
            seedText = ""
            firstFrameURL = nil
            lastFrameURL = nil
            generateAudio = false
        }
    }

    private func refreshResumableRecords() {
        resumableRecords = service.resumableRecords
    }

    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StudioHeader(title: "Video", subtitle: "Text-to-video generation", icon: "video.fill", accent: accent) {
                    StudioPresetMenu(
                        studio: .video,
                        snapshot: {
                            StudioPreset.videoSettings(model: selectedModelId, aspect: aspectRatio, resolution: resolution,
                                                       duration: durationText, size: size, audio: generateAudio)
                        },
                        apply: { preset in
                            let v = VideoPresetValues(preset)
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
                StudioLabel("Prompt")
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
                        Toggle("Generate audio", isOn: $generateAudio)
                            .toggleStyle(.switch).controlSize(.small)
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

            if !KeychainManager.hasAPIKey {
                Text("Add an inference API key in Settings → Accounts & Keys to generate or resume video.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }

            Spacer()

            if let job = service.activeJob, !job.isTerminal,
               resumableRecords.contains(where: { $0.remoteID == job.id && service.isRunInFlight(for: $0) }) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Job \(job.status)… polling every 5s")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop polling") {
                        service.stopPolling()
                        refreshResumableRecords()
                    }.font(.caption)
                }
            }

            StudioPrimaryButton(title: "Generate Video", busyTitle: "Generating…", isBusy: isSubmitting,
                                isEnabled: canSubmit, accent: accent, action: submit)
                .keyboardShortcut(.return, modifiers: .command)

            Text("Video bills per job — check the model's price before submitting.")
                .font(.caption2).foregroundStyle(.secondary)
            if totalCost > 0 {
                Text("Reported spend (known charges): $\(totalCost, specifier: "%.4f")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            }
            .padding(18)
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
                Text("Pricing SKUs: " + skus.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.generateAudio == true {
                Text("Supports audio generation").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedVideoModel: VideoGenModel? {
        service.models.first(where: { $0.id == selectedModelId })
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
                    panel.allowedContentTypes = [.png, .jpeg, .gif, .heic]
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
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var jobsColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            JobTrayButton(
                reload: { service.allJobRecords },
                onResume: { resumeDurable($0) },
                onStop: { _ in service.stopPolling() }
            )
            .padding(.horizontal, 14).padding(.top, 10)
            jobsColumnBody
        }
    }

    private var jobsColumnBody: some View {
        Group {
            if jobs.isEmpty && resumableRecords.isEmpty && saved.creations.allSatisfy({ $0.kind != .video })
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
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(creation.modelID).font(.caption.monospacedDigit())
                                        if let prompt = creation.prompt { Text(prompt).font(.caption).lineLimit(2) }
                                    }
                                    Spacer()
                                    Button("Export…") { exportSaved(creation) }
                                }.padding(12).background(.orbSurface(0.03))
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
        let p = JobPresentation.make(record)
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
                // Durable records do not carry the original prompt.
                prompt: "(resumed from a previous session)",
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
                HStack(spacing: 8) {
                    if downloading.contains(record.id) { ProgressView().controlSize(.small); Text("Saving in ORB…") }
                    else if savedVideos[record.id] != nil { Label("Saved in ORB", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button(videoBytes[record.id] == nil ? "Download & save" : "Retry save") { Task { await keepVideo(record.id) } } }
                    Spacer()
                    if videoBytes[record.id] != nil || savedVideos[record.id] != nil {
                        Button("Export…") { exportVideo(record.id) }
                    }
                }
                if let failure = downloadErrors[record.id] {
                    Text("Not saved: \(failure)").font(.caption).foregroundStyle(.orange)
                }
            } else if record.job.status == "submission uncertain" {
                Text("Submission outcome unknown. Check recoverable jobs before attempting another paid run.")
                    .font(.caption).foregroundStyle(.orange)
            } else if !record.job.isTerminal {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Polling… status: \(record.job.status)").font(.caption).foregroundStyle(.secondary)
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
            : status == "failed" || status == "expired" || status == "cancelled" ? .red : .orange
        return Text(status.uppercased())
            .orbFont(size: 11, weight: .bold)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func header(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(accent.opacity(0.13)).frame(width: 34, height: 34)
                Image(systemName: icon).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).orbFont(size: 15, weight: .semibold)
                Text(subtitle).orbFont(size: 11).foregroundStyle(.secondary)
            }
        }
    }

    private var canSubmit: Bool {
        !selectedModelId.isEmpty && !service.isLoadingModels
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && KeychainManager.hasAPIKey
            && !isSubmitting && !resumableRecords.contains(where: { service.isRunInFlight(for: $0) })
    }

    private func submit() {
        guard canSubmit else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Settings → Accounts & Keys first." }
            return
        }
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
        do {
            if let firstFrameURL, selectedVideoModel?.supportedFrameImages?.contains("first_frame") == true {
                request.firstFrameImage = try MediaStudioImageFile.dataURL(for: firstFrameURL)
            }
            if let lastFrameURL, selectedVideoModel?.supportedFrameImages?.contains("last_frame") == true {
                request.lastFrameImage = try MediaStudioImageFile.dataURL(for: lastFrameURL)
            }
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
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                let finished = try await service.submitAndPoll(request) { update in
                    Task { @MainActor in
                        if let index = jobs.firstIndex(where: { $0.id == recordId }) {
                            jobs[index].job = update
                        }
                    }
                }
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
                if let index = jobs.firstIndex(where: { $0.id == recordId }),
                   jobs[index].job.id == recordId {
                    jobs[index].job = VideoJob(id: recordId, status: "submission uncertain", pollingURL: nil,
                        generationId: nil, unsignedURLs: nil, error: error.localizedDescription, cost: nil)
                }
                refreshResumableRecords()
            }
        }
    }

    private func keepVideo(_ id: String) async {
        guard savedVideos[id] == nil, !downloading.contains(id),
              let record = jobs.first(where: { $0.id == id }), record.job.isSuccess else { return }
        downloading.insert(id)
        defer { downloading.remove(id) }
        do {
            if videoBytes[id] == nil {
                let (data, contentType) = try await service.download(record.job)
                let mime = contentType?.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "video/mp4"
                guard mime == "video/mp4" || mime == "video/webm" || mime == "video/quicktime" else {
                    throw MediaServiceError.decoding("The download was not a supported video (\(mime)).")
                }
                videoBytes[id] = data
                videoMIMEs[id] = mime
            }
            guard let data = videoBytes[id] else { return }
            let creation = try await saved.save(data, mimeType: videoMIMEs[id] ?? "video/mp4", kind: .video,
                modelID: record.modelId,
                prompt: record.prompt == "(resumed from a previous session)" ? nil : record.prompt)
            savedVideos[id] = creation
            downloadErrors[id] = nil
        } catch { downloadErrors[id] = error.localizedDescription }
    }

    private func exportVideo(_ id: String) {
        guard let data = videoBytes[id] else {
            if let creation = savedVideos[id] { exportSaved(creation) }
            return
        }
        export(data, filename: "orb-video.\(videoExtension(videoMIMEs[id] ?? "video/mp4"))")
    }

    private func exportSaved(_ creation: SavedCreation) {
        Task {
            do {
                let data = try await saved.data(for: creation)
                export(data, filename: "orb-video.\(videoExtension(creation.mimeType))")
            } catch { errorMessage = "Cannot load saved video: \(error.localizedDescription)" }
        }
    }

    private func videoExtension(_ mime: String) -> String {
        switch mime {
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        default: return "mp4"
        }
    }

    private func export(_ data: Data, filename: String) {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.nameFieldStringValue = filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await Task.detached { try data.write(to: url, options: .atomic) }.value }
            catch { errorMessage = "Export failed: \(error.localizedDescription)" }
        }
    }

}

private extension VideoJob {
    /// Convenience alias — the API calls them `unsigned_urls`.
    var urls: [String] { unsignedURLs ?? [] }
}
