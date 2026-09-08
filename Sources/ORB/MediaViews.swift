import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Images studio
//
// Dedicated `POST /images` playground: model picker, prompt, size/quality
// knobs, reference images, gallery with save, and cost tracking.

struct ImagesView: View {
    @StateObject private var service = ImageGenService()
    @State private var prompt = ""
    @State private var selectedModelId = ""
    @State private var imageCount = 1
    @State private var aspectRatio = "auto"
    @State private var resolution = "auto"
    @State private var quality = "auto"
    @State private var seedText = ""
    @State private var referenceURLs: [URL] = []
    @State private var errorMessage: String?
    @State private var results: [GeneratedImage] = []
    @State private var totalCost = 0.0
    @FocusState private var inputFocused: Bool

    private let accent = Color.pink

    struct GeneratedImage: Identifiable {
        let id = UUID()
        let attachment: ChatImageAttachment
        let modelId: String
        let createdAt = Date()
    }

    var body: some View {
        HStack(spacing: 0) {
            controlsColumn
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
            galleryColumn
        }
        .task {
            await service.fetchModels()
            if selectedModelId.isEmpty { selectedModelId = service.models.first?.id ?? "" }
        }
    }

    // MARK: Controls

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "Images", subtitle: "Text-to-image generation", icon: "photo.fill")

            modelPicker

            VStack(alignment: .leading, spacing: 6) {
                Text("PROMPT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 90)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Count").font(.caption).foregroundStyle(.secondary)
                    Stepper("\(imageCount)", value: $imageCount, in: 1...4)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aspect").font(.caption).foregroundStyle(.secondary)
                    Picker("Aspect", selection: $aspectRatio) {
                        ForEach(["auto", "1:1", "16:9", "9:16", "3:2", "2:3", "4:3", "3:4"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality").font(.caption).foregroundStyle(.secondary)
                    Picker("Quality", selection: $quality) {
                        ForEach(["auto", "low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution").font(.caption).foregroundStyle(.secondary)
                    Picker("Resolution", selection: $resolution) {
                        ForEach(["auto", "512", "1K", "2K", "4K"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seed (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("random", text: $seedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            referenceRow

            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }

            Spacer()

            Button(action: generate) {
                HStack {
                    if service.isGenerating { ProgressView().controlSize(.small).tint(.white) }
                    Text(service.isGenerating ? "Generating…" : "Generate")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(canGenerate ? accent : Color.gray.opacity(0.45))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(!canGenerate)
            .keyboardShortcut(.return, modifiers: .command)

            if totalCost > 0 {
                Text("Session spend: $\(totalCost, specifier: "%.4f")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            if service.isLoadingModels {
                ProgressView().controlSize(.small)
            } else if service.models.isEmpty {
                Text(service.modelsError ?? "No image models found.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await service.fetchModels() } }
                    .font(.caption)
            } else {
                Picker("Model", selection: $selectedModelId) {
                    ForEach(service.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
                if let model = service.models.first(where: { $0.id == selectedModelId }),
                   let desc = model.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private var referenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REFERENCE IMAGES (OPTIONAL)").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button(action: chooseReferences) {
                    Label("Add", systemImage: "plus")
                        .font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Text(referenceURLs.isEmpty ? "Guide image-to-image runs" : "\(referenceURLs.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !referenceURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(referenceURLs, id: \.self) { url in
                            HStack(spacing: 4) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { referenceURLs.removeAll { $0 == url } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }.buttonStyle(.plain)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(accent.opacity(0.10))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    // MARK: Gallery

    private var galleryColumn: some View {
        Group {
            if results.isEmpty {
                emptyGallery
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(results) { result in
                            galleryCard(result)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyGallery: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.10)).frame(width: 96, height: 96)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 32)).foregroundStyle(accent)
            }
            Text("Generate images")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Pick a model, describe the picture, and generate. Results land here with save buttons.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func galleryCard(_ result: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistantImageRow(images: [result.attachment], accent: accent)
            Text(result.modelId)
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func header(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(accent.opacity(0.13)).frame(width: 34, height: 34)
                Image(systemName: icon).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedModelId.isEmpty && !service.isGenerating
            && KeychainManager.hasAPIKey
    }

    private func chooseReferences() {
        let panel = NSOpenPanel()
        panel.title = "Reference Images"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic]
        if panel.runModal() == .OK { referenceURLs.append(contentsOf: panel.urls) }
    }

    private func referenceDataURLs() throws -> [String]? {
        guard !referenceURLs.isEmpty else { return nil }
        return try referenceURLs.prefix(8).map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            return "data:image/\(url.pathExtension.lowercased());base64,\(data.base64EncodedString())"
        }
    }

    private func generate() {
        guard canGenerate else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Account first." }
            return
        }
        errorMessage = nil
        let modelId = selectedModelId
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let references = try referenceDataURLs()
                var request = ImageGenRequest(model: modelId, prompt: promptText)
                request.n = imageCount > 1 ? imageCount : nil
                request.aspectRatio = aspectRatio == "auto" ? nil : aspectRatio
                request.resolution = resolution == "auto" ? nil : resolution
                request.quality = quality == "auto" ? nil : quality
                request.outputFormat = "png"
                if let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) { request.seed = seed }
                request.inputReferences = references
                let attachments = try await service.generate(request)
                for attachment in attachments {
                    results.insert(GeneratedImage(attachment: attachment, modelId: modelId), at: 0)
                }
                totalCost += service.lastUsage?.cost ?? 0
            } catch is CancellationError {
                // User navigated away; leave prior results alone.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Video studio

struct VideoView: View {
    @StateObject private var service = VideoGenService()
    @State private var prompt = ""
    @State private var selectedModelId = ""
    @State private var aspectRatio = "auto"
    @State private var resolution = "auto"
    @State private var durationText = ""
    @State private var generateAudio = false
    @State private var errorMessage: String?
    @State private var jobs: [VideoJobRecord] = []
    @State private var totalCost = 0.0

    private let accent = Color.indigo

    struct VideoJobRecord: Identifiable {
        let id: String
        var job: VideoJob
        let prompt: String
        let modelId: String
    }

    var body: some View {
        HStack(spacing: 0) {
            controlsColumn
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
            jobsColumn
        }
        .task {
            await service.fetchModels()
            if selectedModelId.isEmpty { selectedModelId = service.models.first?.id ?? "" }
        }
    }

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "Video", subtitle: "Text-to-video generation", icon: "video.fill")

            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
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
                Text("PROMPT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 80)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aspect").font(.caption).foregroundStyle(.secondary)
                    Picker("Aspect", selection: $aspectRatio) {
                        Text("auto").tag("auto")
                        ForEach(supportedAspects(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution").font(.caption).foregroundStyle(.secondary)
                    Picker("Resolution", selection: $resolution) {
                        Text("auto").tag("auto")
                        ForEach(supportedResolutions(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duration (s, optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("model default", text: $durationText)
                        .textFieldStyle(.roundedBorder).frame(width: 110)
                }
                Toggle("Audio", isOn: $generateAudio)
                    .help("Generate audio alongside the video when the model supports it.")
            }

            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }

            Spacer()

            if let job = service.activeJob, !job.isTerminal {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Job \(job.status)… polling every 5s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Button(action: submit) {
                HStack {
                    if service.activeJob?.isTerminal == false { ProgressView().controlSize(.small).tint(.white) }
                    Text(service.activeJob?.isTerminal == false ? "Generating…" : "Generate Video")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(canSubmit ? accent : Color.gray.opacity(0.45))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)

            Text("Video bills per job — check the model's price before submitting.")
                .font(.caption2).foregroundStyle(.secondary)
            if totalCost > 0 {
                Text("Session spend: $\(totalCost, specifier: "%.4f")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private func modelCapabilities(_ model: VideoGenModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let durations = model.supportedDurations, !durations.isEmpty {
                Text("Durations: \(durations.map(String.init).joined(separator: ", "))s")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.generateAudio == true {
                Text("Supports audio generation").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func supportedAspects() -> [String] {
        service.models.first(where: { $0.id == selectedModelId })?.supportedAspectRatios ?? []
    }

    private func supportedResolutions() -> [String] {
        service.models.first(where: { $0.id == selectedModelId })?.supportedResolutions ?? []
    }

    private var jobsColumn: some View {
        Group {
            if jobs.isEmpty {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(accent.opacity(0.10)).frame(width: 96, height: 96)
                        Image(systemName: "film").font(.system(size: 32)).foregroundStyle(accent)
                    }
                    Text("Generate video")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Video jobs take minutes. Submit one and it polls here until the download is ready.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
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

    private func jobCard(_ record: VideoJobRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.modelId).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                statusPill(record.job.status)
            }
            Text(record.prompt).font(.system(size: 12)).lineLimit(3)
            if let cost = record.job.cost {
                Text("Cost: $\(cost, specifier: "%.4f")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if record.job.isSuccess {
                HStack(spacing: 8) {
                    if let urlString = record.job.urls.first, let url = URL(string: urlString) {
                        Link("Open video URL", destination: url).font(.caption)
                    }
                    Spacer()
                    Button("Save Video…") { saveVideo(record) }
                        .font(.caption)
                }
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
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusPill(_ status: String) -> some View {
        let color: Color = status == "completed" ? .green
            : status == "failed" || status == "expired" || status == "cancelled" ? .red : .orange
        return Text(status.uppercased())
            .font(.system(size: 9, weight: .bold))
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
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var canSubmit: Bool {
        !selectedModelId.isEmpty && !service.isLoadingModels
            && KeychainManager.hasAPIKey
            && (service.activeJob?.isTerminal ?? true)
    }

    private func submit() {
        guard canSubmit else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Account first." }
            return
        }
        errorMessage = nil
        let modelId = selectedModelId
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = VideoGenRequest(model: modelId)
        request.prompt = promptText.isEmpty ? nil : promptText
        request.aspectRatio = aspectRatio == "auto" ? nil : aspectRatio
        request.resolution = resolution == "auto" ? nil : resolution
        if let seconds = Int(durationText.trimmingCharacters(in: .whitespaces)), seconds > 0 {
            request.duration = seconds
        }
        request.generateAudio = generateAudio ? true : nil
        let recordId = UUID().uuidString
        jobs.insert(VideoJobRecord(
            id: recordId,
            job: VideoJob(id: recordId, status: "pending", pollingURL: nil, generationId: nil, unsignedURLs: nil, error: nil, cost: nil),
            prompt: promptText.isEmpty ? "(no prompt)" : promptText,
            modelId: modelId
        ), at: 0)
        Task {
            do {
                let finished = try await service.submitAndPoll(request) { update in
                    Task { @MainActor in
                        if let index = jobs.firstIndex(where: { $0.id == recordId }) {
                            jobs[index].job = update
                        }
                    }
                }
                totalCost += finished.cost ?? 0
            } catch is CancellationError {
                if let index = jobs.firstIndex(where: { $0.id == recordId }) {
                    jobs[index].job = VideoJob(id: recordId, status: "cancelled", pollingURL: nil, generationId: nil, unsignedURLs: nil, error: "Cancelled.", cost: nil)
                }
            } catch {
                errorMessage = error.localizedDescription
                if let index = jobs.firstIndex(where: { $0.id == recordId }) {
                    jobs[index].job = VideoJob(id: recordId, status: "failed", pollingURL: nil, generationId: nil, unsignedURLs: nil, error: error.localizedDescription, cost: nil)
                }
            }
        }
    }

    private func saveVideo(_ record: VideoJobRecord) {
        Task {
            do {
                let (data, _) = try await service.download(record.job)
                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.title = "Save Video"
                    panel.nameFieldStringValue = "orb-video.mp4"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? data.write(to: url)
                    }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

private extension VideoJob {
    /// Convenience alias — the API calls them `unsigned_urls`.
    var urls: [String] { unsignedURLs ?? [] }
}
