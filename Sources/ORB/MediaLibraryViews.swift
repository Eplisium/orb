import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Catalog absence is not the same as a model explicitly lacking a capability.
enum CatalogCapability: Equatable {
    case unknown, supported, unsupported

    static func voice(for model: GenerateCatalogModel?) -> Self {
        guard let voices = model?.supportedVoices else { return .unknown }
        return voices.isEmpty ? .unsupported : .supported
    }
}

@MainActor
@Observable final class ModalityModelChoices {
    private(set) var models: [GenerateCatalogModel] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private let catalog: GenerateModelCatalog
    init(catalog: GenerateModelCatalog? = nil) { self.catalog = catalog ?? GenerateModelCatalog() }

    func load(_ modality: String) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { models = try await catalog.fetch(outputModalities: [modality]) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    var status: String? {
        if isLoading { return "Discovering models…" }
        if let error { return "Model discovery unavailable: \(error). Enter a model ID manually." }
        if models.isEmpty { return "No models listed for this modality. Enter a model ID manually." }
        return nil
    }

    func preferredID(current: String) -> String {
        if models.contains(where: { $0.id == current }) { return current }
        return models.first?.id ?? current
    }
}

struct ModalityModelField: View {
    let title: String
    @Binding var modelID: String
    let choices: ModalityModelChoices
    @State private var showsManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioLabel(title)
            if !choices.models.isEmpty {
                Picker("Discovered models", selection: $modelID) {
                    if !choices.models.contains(where: { $0.id == modelID }) {
                        Text("Custom: \(modelID.isEmpty ? "enter below" : modelID)").tag(modelID)
                    }
                    ForEach(choices.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
            }
            if showsManual || choices.models.isEmpty {
                TextField("Model ID (manual fallback)", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            } else {
                HStack(spacing: 6) {
                    Text(modelID).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Enter ID manually") { showsManual = true }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let status = choices.status {
                Text(status).font(.caption2).foregroundStyle(choices.error == nil ? Color.secondary : Color.orange)
            }
        }
    }
}

// MARK: - Files manager
//
// Remote workspace uploads are separate from locally saved creations.

struct FilesView: View {
    @StateObject private var service = FileService()
    @State private var remoteFiles: [WorkspaceFile] = []
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var isFetchingPage = false
    @State private var pageError: String?
    @State private var errorMessage: String?
    @State private var showingCreations = false
    @State private var isUploading = false
    /// The file awaiting delete confirmation. The service layer refuses an
    /// unconfirmed delete, so the confirmation dialog is the only way the
    /// destructive call is ever issued.
    @State private var pendingDelete: WorkspaceFile?

    private let accent = Color.teal

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if showingCreations {
                SavedCreationsLibraryView()
            } else if isFetchingPage && remoteFiles.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if remoteFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await refreshPages() }
        .onChange(of: showingCreations) { _, selected in
            if !selected { Task { await refreshPages() } }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.filename ?? pendingDelete?.id ?? "")”? This cannot be undone.",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                if let file = pendingDelete { delete(file) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The remote file is removed and chat references to it stop working. Local creations are unaffected.")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            StudioHeader(title: "Files", subtitle: "Remote uploads · creations stay on this Mac",
                         icon: "folder.fill", accent: accent)
            Picker("Library", selection: $showingCreations) {
                Text("Uploaded files").tag(false)
                Text("Saved creations").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !showingCreations && isFetchingPage {
                ProgressView().controlSize(.small)
            } else if !showingCreations {
                Button { Task { await refreshPages() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh files")
            }
            if !showingCreations {
                Button(action: upload) {
                    Label(isUploading ? "Uploading…" : "Upload", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(StudioChipButtonStyle())
                .disabled(isUploading || !KeychainManager.hasAPIKey)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.45))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            StudioEmptyState(icon: "tray", title: "No remote uploads yet",
                             message: "Upload files (max 100 MiB) to reference them in chat. Uploaded files cannot be downloaded through the OpenRouter Files API; keep your original. Generated media is in Saved creations.",
                             accent: accent)
            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                    .frame(maxWidth: 520)
            } else if let error = pageError ?? service.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if hasMore {
                Button(isFetchingPage ? "Loading…" : "Load more") { Task { await loadMore() } }
                    .buttonStyle(StudioChipButtonStyle())
                    .disabled(isFetchingPage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                Text("Showing loaded remote files. Uploads are chat references, not backups: uploaded content cannot be downloaded through the Files API. Keep your originals.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error = pageError ?? service.lastError {
                    PlaygroundErrorBanner(message: error) { pageError = nil; service.lastError = nil }
                }
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                ForEach(remoteFiles) { file in
                    fileRow(file)
                }
                if hasMore {
                    Button(isFetchingPage ? "Loading…" : "Load more") { Task { await loadMore() } }
                        .disabled(isFetchingPage)
                }
            }
            .padding(16)
        }
    }

    private func fileRow(_ file: WorkspaceFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: file))
                .font(.system(size: 14))
                .foregroundStyle(accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename ?? file.id)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(file.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    if let bytes = file.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.id, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Copy file ID")
            Button(role: .destructive) { pendingDelete = file } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Delete file")
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07), lineWidth: 0.5) }
    }

    private func iconName(for file: WorkspaceFile) -> String {
        let mime = file.mimeType ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("csv") { return "doc.text" }
        return "doc"
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.title = "Upload File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            isUploading = true
            errorMessage = nil
            Task {
                defer { isUploading = false }
                var failures: [String] = []
                for url in panel.urls {
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                            ?? "application/octet-stream"
                        // Empty/oversized uploads are validated (and rejected
                        // with a clear message) by FileService before any
                        // request is sent.
                        _ = try await service.upload(filename: url.lastPathComponent, mimeType: mime, data: data)
                    } catch is CancellationError {
                        break
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                await refreshPages()
                if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            }
        }
    }

    private func delete(_ file: WorkspaceFile) {
        Task {
            do {
                // Reached only through the confirmation dialog; the service
                // refuses an unconfirmed delete outright.
                _ = try await service.delete(id: file.id, confirming: true)
                remoteFiles.removeAll { $0.id == file.id }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshPages() async {
        guard !isFetchingPage else { return }
        isFetchingPage = true
        defer { isFetchingPage = false }
        do {
            let page = try await service.listPage()
            remoteFiles = page.data
            nextCursor = page.cursor
            hasMore = page.hasMore == true && page.cursor != nil
            pageError = page.hasMore == true && page.cursor == nil ? "More files reported without a cursor; cannot continue safely." : nil
        } catch is CancellationError { }
        catch { pageError = error.localizedDescription }
    }

    private func loadMore() async {
        guard hasMore, let cursor = nextCursor, !isFetchingPage else { return }
        isFetchingPage = true
        defer { isFetchingPage = false }
        do {
            let page = try await service.listPage(cursor: cursor)
            let known = Set(remoteFiles.map(\.id))
            remoteFiles += page.data.filter { !known.contains($0.id) }
            nextCursor = page.cursor
            hasMore = page.hasMore == true && page.cursor != nil && page.cursor != cursor
            pageError = page.hasMore == true && !hasMore ? "Pagination returned no new cursor; stopped to avoid a loop." : nil
        } catch is CancellationError { }
        catch { pageError = error.localizedDescription }
    }
}

// Local outputs are intentionally not mixed with OpenRouter's remote Files API.
func creationExtension(_ creation: SavedCreation) -> String {
    let mime = creation.mimeType.components(separatedBy: ";")[0].lowercased()
    switch mime {
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/webp": return "webp"
    case "video/mp4": return "mp4"
    case "video/webm": return "webm"
    case "audio/wav", "audio/x-wav": return "wav"
    case "audio/pcm", "audio/l16": return "pcm"
    case "audio/aac": return "aac"
    case "audio/ogg": return "ogg"
    case "audio/mpeg", "audio/mp3": return "mp3"
    case "application/json": return "json"
    default: return "txt"
    }
}

@MainActor
private func exportCreation(_ data: Data, creation: SavedCreation) throws {
    let panel = NSSavePanel()
    panel.title = "Export Saved Creation"
    panel.nameFieldStringValue = "orb-\(creation.id.uuidString).\(creationExtension(creation))"
    if panel.runModal() == .OK, let url = panel.url {
        try data.write(to: url, options: .atomic)
    }
}

struct SavedCreationsLibraryView: View {
    @ObservedObject private var store = SavedCreationsStore.shared
    @State private var errorMessage: String?
    @State private var selected: SavedCreation?
    @State private var selectedData: Data?
    @State private var isOpening = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("Saved on this Mac · images, videos, audio, transcripts, and embeddings")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                if let loadError = store.loadError {
                    Text(loadError.localizedDescription).foregroundStyle(.red).font(.caption)
                }
                if store.creations.isEmpty {
                    ContentUnavailableView("No saved creations yet", systemImage: "square.stack",
                                           description: Text("Generate media, synthesize speech, transcribe audio, or embed text to save it here."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(store.creations) { creation in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: creation.kind))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(creation.prompt.flatMap { $0.isEmpty ? nil : $0 } ?? title(for: creation.kind))
                                .font(.subheadline).lineLimit(2)
                            Text("\(title(for: creation.kind)) · \(creation.modelID) · \(creation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Open") { open(creation) }
                        Button("Export…") { export(creation) }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if isOpening { ProgressView("Opening…") }
            }
            .padding(16)
        }
        .sheet(item: $selected) { creation in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title(for: creation.kind)).font(.headline)
                    Spacer()
                    Button("Done") { selected = nil; selectedData = nil }
                }
                if let data = selectedData {
                    if creation.kind == .image, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else if creation.kind == .transcript || creation.kind == .embedding {
                        ScrollView {
                            Text(String(decoding: data, as: UTF8.self))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ContentUnavailableView("No inline preview", systemImage: "doc",
                                               description: Text("Export to view this media in a compatible app."))
                    }
                }
                Button("Export…") { export(creation) }
            }
            .padding(20).frame(minWidth: 500, minHeight: 350)
        }
    }

    private func title(for kind: SavedCreation.Kind) -> String {
        switch kind {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .transcript: "Transcript"
        case .embedding: "Embedding"
        }
    }

    private func icon(for kind: SavedCreation.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .transcript: "doc.text"
        case .embedding: "chart.dots.scatter"
        }
    }

    private func open(_ creation: SavedCreation) {
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                let data = try await store.data(for: creation)
                if creation.kind == .audio && creationExtension(creation) == "pcm" {
                    throw MediaServiceError.decoding("Raw PCM has no container or sample-rate metadata for safe playback. Export the .pcm bytes instead.")
                }
                if creation.kind == .video || creation.kind == .audio {
                    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("ORB/CreationPreviews", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(creation.id.uuidString)
                        .appendingPathExtension(creationExtension(creation))
                    try data.write(to: url, options: .atomic)
                    guard NSWorkspace.shared.open(url) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                } else {
                    selectedData = data
                    selected = creation
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func export(_ creation: SavedCreation) {
        Task {
            do {
                let data = try await store.data(for: creation)
                try exportCreation(data, creation: creation)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Speech studio (TTS + STT)

struct SpeechView: View {
    @StateObject private var service = SpeechService()
    @State private var speechModels = ModalityModelChoices()
    @State private var transcriptionModels = ModalityModelChoices()
    @ObservedObject private var creations = SavedCreationsStore.shared
    @State private var mode: Mode = .tts
    @State private var text = ""
    @State private var voice = ""
    @State private var speed = 1.0
    @State private var audioFormat = "mp3"
    @State private var language = ""
    @State private var transcriptionFormat = "json"
    @State private var timestampMode = "none"
    @State private var lastTranscription: TranscriptionResponse?
    @State private var pendingTranscript: (data: Data, mime: String, model: String, filename: String)?
    @State private var errorMessage: String?
    @State private var transcript = ""
    @State private var selectedAudioURL: URL?
    @State private var lastAudio: SavedCreation?
    @State private var pendingAudio: (data: Data, mimeType: String, modelID: String, prompt: String)?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isSaving = false

    enum Mode: String, CaseIterable { case tts = "Text → Speech", stt = "Speech → Text" }

    private let accent = Color.orange
    @State private var modelId = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if mode == .tts { ttsBody } else { sttBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await discoverMode() }
        .onChange(of: mode) { _, newMode in
            modelId = ""
            voice = ""
            errorMessage = nil
            Task { await discoverMode() }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            StudioHeader(title: "Speech", subtitle: "Synthesize voices · transcribe audio",
                         icon: "speaker.wave.2.fill", accent: accent)
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.45))
    }

    // MARK: TTS

    private var ttsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modelField(choices: speechModels)
                VStack(alignment: .leading, spacing: 6) {
                    StudioLabel("Text")
                    StudioPromptEditor(text: $text, placeholder: "Type what you want spoken…",
                                       accessibilityLabel: "Speech text", height: 150)
                }
                StudioCard(title: "Voice") {
                    StudioGrid {
                        StudioField("Format") {
                            Picker("Format", selection: $audioFormat) {
                                Text("MP3").tag("mp3")
                                Text("PCM (raw)").tag("pcm")
                            }.labelsHidden()
                        }
                        if let model = selectedSpeechModel, let voices = model.supportedVoices, !voices.isEmpty {
                            StudioField("Voice") {
                                Picker("Voice", selection: $voice) {
                                    Text("Provider default").tag("")
                                    ForEach(voices, id: \.self) { Text($0).tag($0) }
                                }.labelsHidden()
                            }
                        }
                    }
                    if selectedSpeechModel?.supportedVoices?.isEmpty != false,
                       CatalogCapability.voice(for: selectedSpeechModel) == .unknown {
                        StudioNotice(text: "Voice support is unknown for this model; using provider default.")
                    }
                    if selectedSpeechModel?.id.hasPrefix("openai/") == true {
                        StudioField("Speed \(String(format: "%.2f", speed))×") {
                            Slider(value: $speed, in: 0.25...4.0, step: 0.05)
                        }
                    }
                }
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                StudioPrimaryButton(title: "Synthesize", busyTitle: service.isWorking ? "Synthesizing…" : "Saving…",
                                    isBusy: service.isWorking || isSaving,
                                    isEnabled: canSynthesize, accent: accent, action: synthesize)
                if let lastAudio {
                    HStack {
                        Label("Saved in app", systemImage: "checkmark.circle.fill")
                        Button("Play") { play(lastAudio) }
                        Button("Export…") { export(lastAudio) }
                    }.font(.caption)
                } else if let pendingAudio {
                    HStack {
                        Text("Generated audio is not yet saved").foregroundStyle(.orange)
                        Button("Retry save") { Task { await savePendingAudio() } }
                            .disabled(isSaving)
                        Button("Export…") {
                            exportPendingAudio(pendingAudio.data, mimeType: pendingAudio.mimeType)
                        }
                    }.font(.caption)
                }
                Text("Audio is saved in the local creations library first. Export is optional. Billed per request.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private func modelField(choices: ModalityModelChoices) -> some View {
        ModalityModelField(title: "MODEL", modelID: $modelId, choices: choices)
    }

    private var selectedSpeechModel: GenerateCatalogModel? {
        speechModels.models.first { $0.id == modelId }
    }

    private func discoverMode() async {
        let requestedMode = mode
        let choices = requestedMode == .tts ? speechModels : transcriptionModels
        await choices.load(requestedMode == .tts ? "speech" : "transcription")
        if mode == requestedMode && modelId.isEmpty { modelId = choices.preferredID(current: "") }
    }

    private var canSynthesize: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !service.isWorking && !isSaving && KeychainManager.hasAPIKey
    }

    private func synthesize() {
        guard canSynthesize else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Account first." }
            return
        }
        errorMessage = nil
        lastAudio = nil
        var request = SpeechRequest(model: modelId, input: text)
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        request.voice = CatalogCapability.voice(for: selectedSpeechModel) == .supported && selectedSpeechModel?.supportedVoices?.contains(trimmedVoice) == true ? trimmedVoice : nil
        request.responseFormat = audioFormat
        request.speed = selectedSpeechModel?.id.hasPrefix("openai/") == true && speed != 1.0 ? speed : nil
        Task {
            do {
                let (data, contentType) = try await service.synthesize(request)
                let mime = contentType?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? (request.responseFormat == "pcm" ? "audio/pcm" : "audio/mpeg")
                pendingAudio = (data, mime, request.model, request.input)
                await savePendingAudio()
            } catch is CancellationError {
                // Leave prior state alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: STT

    private var sttBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modelField(choices: transcriptionModels)
                Text("Files above 25 MB use base64 JSON upload; smaller files use multipart.").font(.caption2).foregroundStyle(.secondary)
                StudioCard(title: "Options") {
                    StudioField("Language (ISO-639-1, optional)") {
                        TextField("auto-detect", text: $language).textFieldStyle(.roundedBorder)
                    }
                    StudioGrid {
                        StudioField("Response") {
                            Picker("Response", selection: $transcriptionFormat) {
                                Text("Text JSON").tag("json")
                                Text("Verbose JSON").tag("verbose_json")
                            }.labelsHidden()
                        }
                        if transcriptionFormat == "verbose_json" {
                            StudioField("Timestamps") {
                                Picker("Timestamps", selection: $timestampMode) {
                                    Text("Provider default").tag("none")
                                    Text("Segments").tag("segment")
                                    Text("Words and segments").tag("word")
                                }.labelsHidden()
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button(action: chooseAudio) {
                        Label(selectedAudioURL?.lastPathComponent ?? "Choose Audio…", systemImage: "waveform")
                    }
                    .buttonStyle(StudioChipButtonStyle())
                    if selectedAudioURL != nil {
                        Button("Clear") { selectedAudioURL = nil }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                StudioPrimaryButton(title: "Transcribe", busyTitle: service.isWorking ? "Transcribing…" : "Saving…",
                                    isBusy: service.isWorking || isSaving,
                                    isEnabled: canTranscribe, accent: accent, action: transcribe)
                if !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        StudioLabel("Transcript")
                        Text(transcript)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                        }
                        .font(.caption)
                    }
                }
                if let response = lastTranscription {
                    if let language = response.language { Text("Language: \(language)").font(.caption) }
                    if let duration = response.duration { Text("Duration: \(duration, specifier: "%.2f")s").font(.caption) }
                    if let cost = response.usage?.cost { Text("Cost: $\(cost, specifier: "%.5f")").font(.caption) }
                    if let segments = response.segments, !segments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TIMESTAMPED SEGMENTS").font(.caption.bold())
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                Text("\(segment.start, specifier: "%.2f")–\(segment.end, specifier: "%.2f")s  \(segment.text)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    if let words = response.words, !words.isEmpty {
                        DisclosureGroup("\(words.count) timestamped words") {
                            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                                Text("\(word.start, specifier: "%.2f")–\(word.end, specifier: "%.2f")s  \(word.word)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let pendingTranscript {
                    HStack {
                        Text("Transcript available; local save failed.").foregroundStyle(.orange)
                        Button("Retry save") { Task { await saveTranscript(pendingTranscript) } }.disabled(isSaving)
                    }.font(.caption)
                }
            }
            .padding(20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private var canTranscribe: Bool {
        selectedAudioURL != nil && !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !service.isWorking && !isSaving && KeychainManager.hasAPIKey
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .mp3, UTType(filenameExtension: "wav") ?? .audio]
        if panel.runModal() == .OK { selectedAudioURL = panel.url }
    }

    private func transcribe() {
        guard canTranscribe, let url = selectedAudioURL else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Account first." }
            return
        }
        errorMessage = nil
        Task {
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                    ?? "audio/wav"
                var request = TranscriptionRequest(
                    model: modelId, filename: url.lastPathComponent,
                    mimeType: mime, audioData: data
                )
                let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
                request.language = trimmedLanguage.isEmpty ? nil : trimmedLanguage
                request.responseFormat = transcriptionFormat
                request.timestampGranularities = transcriptionFormat == "verbose_json" && timestampMode != "none"
                    ? (timestampMode == "word" ? ["word", "segment"] : ["segment"]) : nil
                let response = try await service.transcribe(request)
                transcript = response.text
                lastTranscription = response
                let structured = transcriptionFormat == "verbose_json"
                var details: [String: Any] = ["text": response.text]
                if let language = response.language { details["language"] = language }
                if let duration = response.duration { details["duration"] = duration }
                if let confidence = response.confidence { details["confidence"] = confidence }
                if let task = response.task { details["task"] = task }
                if let usage = response.usage {
                    var usageDetails: [String: Any] = [:]
                    if let cost = usage.cost { usageDetails["cost"] = cost }
                    if let tokens = usage.inputTokens { usageDetails["input_tokens"] = tokens }
                    if let tokens = usage.outputTokens { usageDetails["output_tokens"] = tokens }
                    if let tokens = usage.totalTokens { usageDetails["total_tokens"] = tokens }
                    if let seconds = usage.seconds { usageDetails["seconds"] = seconds }
                    details["usage"] = usageDetails
                }
                if let segments = response.segments {
                    details["segments"] = segments.map { segment -> [String: Any] in
                        var value: [String: Any] = ["id": segment.id, "start": segment.start,
                                                     "end": segment.end, "text": segment.text]
                        if let speaker = segment.speaker { value["speaker"] = speaker }
                        if let tokens = segment.tokens { value["tokens"] = tokens }
                        return value
                    }
                }
                if let words = response.words {
                    details["words"] = words.map { word -> [String: Any] in
                        var value: [String: Any] = ["start": word.start, "end": word.end, "word": word.word]
                        if let confidence = word.confidence { value["confidence"] = confidence }
                        if let speaker = word.speaker { value["speaker"] = speaker }
                        return value
                    }
                }
                let payload = structured ? try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]) : Data(response.text.utf8)
                let pending = (data: payload, mime: structured ? "application/json" : "text/plain",
                               model: request.model, filename: url.lastPathComponent)
                pendingTranscript = pending
                await saveTranscript(pending)
            } catch is CancellationError {
                // Leave prior transcript alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func saveTranscript(_ pending: (data: Data, mime: String, model: String, filename: String)) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await creations.save(pending.data, mimeType: pending.mime, kind: .transcript,
                                         modelID: pending.model, prompt: pending.filename)
            pendingTranscript = nil
            errorMessage = nil
        } catch { errorMessage = "Transcript returned, but local save failed: \(error.localizedDescription)" }
    }

    private func savePendingAudio() async {
        guard let pendingAudio, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            lastAudio = try await creations.save(pendingAudio.data, mimeType: pendingAudio.mimeType,
                kind: .audio, modelID: pendingAudio.modelID, prompt: pendingAudio.prompt)
            self.pendingAudio = nil
            errorMessage = nil
        } catch {
            errorMessage = "Audio was generated but could not be saved: \(error.localizedDescription)"
        }
    }

    private func exportPendingAudio(_ data: Data, mimeType: String) {
        let panel = NSSavePanel()
        panel.title = "Export Generated Audio"
        let extensionName = creationExtension(SavedCreation(id: UUID(), kind: .audio, modelID: "",
            prompt: nil, mimeType: mimeType, createdAt: Date(), assetPath: "", checksum: ""))
        panel.nameFieldStringValue = "orb-speech.\(extensionName)"
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url, options: .atomic) }
            catch { errorMessage = "Audio export failed: \(error.localizedDescription)" }
        }
    }

    private func play(_ creation: SavedCreation) {
        Task {
            do {
                guard creationExtension(creation) != "pcm" else {
                    throw MediaServiceError.decoding("Raw PCM playback needs sample-rate metadata; export the bytes instead.")
                }
                let data = try await creations.data(for: creation)
                audioPlayer = try AVAudioPlayer(data: data)
                audioPlayer?.play()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func export(_ creation: SavedCreation) {
        Task {
            do {
                let data = try await creations.data(for: creation)
                try exportCreation(data, creation: creation)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Embeddings + rerank lab

struct EmbeddingsView: View {
    @StateObject private var service = EmbeddingService()
    @State private var embeddingModels = ModalityModelChoices()
    @State private var rerankModels = ModalityModelChoices()
    @ObservedObject private var creations = SavedCreationsStore.shared
    @State private var modelId = ""
    @State private var rerankModelId = ""
    @State private var inputText = ""
    @State private var vectors: [(input: String, embedding: [Double])] = []
    @State private var requestedDimensions = ""
    @State private var inputType = ""
    @State private var embedUsage: ImageGenUsage?
    @State private var pendingEmbedding: (payload: Data, model: String, prompt: String)?
    @State private var rerankQuery = ""
    @State private var rerankDocs = ""
    @State private var rerankResults: [RerankResponse.Item] = []
    @State private var rankedDocuments: [String] = []
    @State private var topN = ""
    @State private var rerankUsage: RerankResponse.Usage?
    @State private var rerankProvider: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let accent = Color.purple

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerBar
                embedSection
                rerankSection
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await embeddingModels.load("embeddings")
            if modelId.isEmpty { modelId = embeddingModels.preferredID(current: "") }
            await rerankModels.load("rerank")
            if rerankModelId.isEmpty { rerankModelId = rerankModels.preferredID(current: "") }
        }
    }

    private var headerBar: some View {
        StudioHeader(title: "Embeddings & Rerank", subtitle: "Vectors for search · ordering for retrieval",
                     icon: "chart.dots.scatter", accent: accent)
    }

    private var embedSection: some View {
        StudioCard(title: "Embeddings") {
            ModalityModelField(title: "MODEL", modelID: $modelId, choices: embeddingModels)
            StudioField("Inputs to embed (one per line)") {
                StudioPromptEditor(text: $inputText, placeholder: "One input per line…",
                                   accessibilityLabel: "Embedding inputs", height: 90)
            }
            StudioGrid {
                StudioField("Dimensions (optional)") {
                    TextField("e.g. 1024", text: $requestedDimensions).textFieldStyle(.roundedBorder)
                }
                StudioField("Input type") {
                    Picker("Input type", selection: $inputType) {
                        Text("Provider default").tag("")
                        Text("Query").tag("query")
                        Text("Document").tag("document")
                    }.labelsHidden()
                }
            }
            Text("Float vectors requested. Dimensions and input type depend on provider support.")
                .font(.caption2).foregroundStyle(.secondary)
            StudioPrimaryButton(title: "Embed", busyTitle: service.isWorking ? "Embedding…" : "Saving…",
                                isBusy: service.isWorking || isSaving,
                                isEnabled: canEmbed, accent: accent, action: embed)
            if let usage = embedUsage {
                Text("Usage: \(usage.promptTokens.map { "\($0) input tokens" } ?? "input tokens unavailable") · \(usage.totalTokens.map { "\($0) total tokens" } ?? "total tokens unavailable") · \(usage.cost.map { String(format: "$%.5f", $0) } ?? "cost unavailable")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(vectors.enumerated()), id: \.offset) { index, vector in
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(index + 1) · \(vector.input) · \(vector.embedding.count) dimensions").font(.caption.bold())
                    Text(vector.embedding.map { String($0) }.joined(separator: ", "))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let pendingEmbedding {
                HStack {
                    Text("Vectors available but local save failed.").foregroundStyle(.orange)
                    Button("Retry save") { Task { await saveEmbedding(pendingEmbedding) } }.disabled(isSaving)
                }.font(.caption)
            }
        }
    }

    private var rerankSection: some View {
        StudioCard(title: "Rerank") {
            ModalityModelField(title: "MODEL", modelID: $rerankModelId, choices: rerankModels)
            TextField("Query", text: $rerankQuery)
                .textFieldStyle(.roundedBorder)
            StudioField("Documents (one per line)") {
                StudioPromptEditor(text: $rerankDocs, placeholder: "One document per line…",
                                   accessibilityLabel: "Rerank documents", height: 110)
            }
            StudioField("Top N (optional)") {
                TextField("e.g. 3", text: $topN).textFieldStyle(.roundedBorder)
            }
            StudioPrimaryButton(title: "Rerank", busyTitle: service.isWorking ? "Ranking…" : "Saving…",
                                isBusy: service.isWorking || isSaving,
                                isEnabled: canRerank, accent: accent, action: rerank)
            if let rerankUsage {
                Text("Usage: \(rerankUsage.searchUnits.map { "\($0) search units" } ?? "search units unavailable") · \(rerankUsage.totalTokens.map { "\($0) tokens" } ?? "tokens unavailable") · \(rerankUsage.cost.map { String(format: "$%.5f", $0) } ?? "cost unavailable")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let rerankProvider { Text("Provider: \(rerankProvider)").font(.caption).foregroundStyle(.secondary) }
            if !rerankResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rerankResults.sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }, id: \.index) { item in
                        HStack(spacing: 8) {
                            Text("#\(item.index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            if let score = item.relevanceScore {
                                Text(String(format: "%.3f", score))
                                    .font(.caption.monospacedDigit()).foregroundStyle(accent)
                            }
                            if let document = item.document?.text ?? rankedDocument(index: item.index, in: rankedDocuments) {
                                Text(document)
                                    .font(.caption).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if item.document?.image != nil {
                                Text("Image document (URL omitted)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Document index unavailable").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    private var canEmbed: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (requestedDimensions.isEmpty || (Int(requestedDimensions).map { $0 > 0 } ?? false))
            && !service.isWorking && !isSaving && KeychainManager.hasAPIKey
    }

    private var canRerank: Bool {
        !rerankQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerankDocs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerankModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (topN.isEmpty || (Int(topN).map { $0 > 0 } ?? false))
            && !service.isWorking && !isSaving && KeychainManager.hasAPIKey
    }

    private func embed() {
        guard canEmbed else { return }
        errorMessage = nil
        let model = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputs = inputText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        vectors = []
        embedUsage = nil
        pendingEmbedding = nil
        Task {
            do {
                var request = EmbeddingRequest(model: model, input: inputs)
                request.dimensions = Int(requestedDimensions)
                request.inputType = inputType.isEmpty ? nil : inputType
                request.encodingFormat = "float"
                let response = try await service.embed(request)
                let ordered = try orderedEmbeddingVectors(response.data, inputCount: inputs.count)
                vectors = zip(inputs, ordered).map { (input: $0.0, embedding: $0.1) }
                embedUsage = response.usage
                let records = zip(inputs, ordered).map { ["input": $0.0, "embedding": $0.1] as [String: Any] }
                let payload = try JSONSerialization.data(withJSONObject: ["items": records], options: [.prettyPrinted, .sortedKeys])
                let pending = (payload: payload, model: model, prompt: inputs.joined(separator: " · "))
                pendingEmbedding = pending
                await saveEmbedding(pending)
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func saveEmbedding(_ pending: (payload: Data, model: String, prompt: String)) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await creations.save(pending.payload, mimeType: "application/json", kind: .embedding,
                                         modelID: pending.model, prompt: pending.prompt)
            pendingEmbedding = nil
            errorMessage = nil
        } catch { errorMessage = "Vectors returned, but local save failed: \(error.localizedDescription)" }
    }

    private func rerank() {
        guard canRerank else { return }
        errorMessage = nil
        let docs = rerankDocs.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let model = rerankModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = rerankQuery
        rerankResults = []
        rerankUsage = nil
        rerankProvider = nil
        Task {
            do {
                let response = try await service.rerank(RerankRequest(
                    model: model, query: query, documents: docs, topN: Int(topN)
                ))
                rankedDocuments = docs
                rerankResults = response.results
                rerankUsage = response.usage
                rerankProvider = response.provider
            } catch is CancellationError {
                // Leave prior ranking alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

/// API indices refer to the exact submitted array, before any score sort.
func orderedEmbeddingVectors(_ items: [EmbeddingResponse.Item], inputCount: Int) throws -> [[Double]] {
    guard items.count == inputCount else {
        throw MediaServiceError.decoding("Embedding response count does not match the inputs.")
    }
    var mapped: [Int: [Double]] = [:]
    for (position, item) in items.enumerated() {
        let index = item.index ?? position
        guard (0..<inputCount).contains(index), mapped[index] == nil else {
            throw MediaServiceError.decoding("Embedding response index is invalid or duplicated.")
        }
        mapped[index] = item.embedding
    }
    return (0..<inputCount).map { mapped[$0]! }
}

/// API indices refer to the exact submitted array, before any score sort.
func rankedDocument(index: Int, in documents: [String]) -> String? {
    documents.indices.contains(index) ? documents[index] : nil
}
