import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files manager
//
// Workspace files (`/files`): list, upload, download server-side files,
// delete. Uploaded files get IDs that chat's file parts can reference.

struct FilesView: View {
    @StateObject private var service = FileService()
    @State private var errorMessage: String?
    @State private var showSaved = false

    private let accent = Color.teal

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if service.isLoading && service.files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.files.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await service.fetchFiles() }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.13)).frame(width: 34, height: 34)
                Image(systemName: "folder.fill").foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Files").font(.system(size: 15, weight: .semibold))
                Text("Workspace uploads for chat references")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if service.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await service.fetchFiles() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh files")
            }
            Button(action: upload) {
                Label("Upload", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(accent.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!KeychainManager.hasAPIKey)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial.opacity(0.45))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("No files yet")
                .font(.headline).foregroundStyle(.secondary)
            Text("Upload PDFs, images, documents, audio, or text (max 100 MB). Reference them from chat with file parts.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                    .frame(maxWidth: 520)
            } else if let error = service.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                ForEach(service.files) { file in
                    fileRow(file)
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
                    if file.downloadable == true {
                        Text("downloadable").font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            Spacer()
            if file.downloadable == true {
                Button("Save…") { download(file) }
                    .font(.caption)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.id, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Copy file ID")
            Button(role: .destructive) { delete(file) } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Delete file")
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 9))
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
            Task {
                for url in panel.urls {
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        guard data.count <= 100_000_000 else {
                            errorMessage = "\(url.lastPathComponent) exceeds the 100 MB upload limit."
                            continue
                        }
                        let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                            ?? "application/octet-stream"
                        _ = try await service.upload(filename: url.lastPathComponent, mimeType: mime, data: data)
                    } catch is CancellationError {
                        break
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                await service.fetchFiles()
            }
        }
    }

    private func download(_ file: WorkspaceFile) {
        Task {
            do {
                let (data, _) = try await service.downloadContent(id: file.id)
                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.title = "Save File"
                    panel.nameFieldStringValue = file.filename ?? file.id
                    if panel.runModal() == .OK, let url = panel.url {
                        try? data.write(to: url)
                        showSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showSaved = false }
                    }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func delete(_ file: WorkspaceFile) {
        Task {
            do {
                try await service.delete(id: file.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Speech studio (TTS + STT)

struct SpeechView: View {
    @StateObject private var service = SpeechService()
    @State private var mode: Mode = .tts
    @State private var text = ""
    @State private var voice = ""
    @State private var speed = 1.0
    @State private var errorMessage: String?
    @State private var transcript = ""
    @State private var selectedAudioURL: URL?

    enum Mode: String, CaseIterable { case tts = "Text → Speech", stt = "Speech → Text" }

    private let accent = Color.orange
    /// Cheap, well-supported defaults. The user can override with any model ID.
    @State private var modelId = "openai/gpt-4o-mini-tts"

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if mode == .tts { ttsBody } else { sttBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.13)).frame(width: 34, height: 34)
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Speech").font(.system(size: 15, weight: .semibold))
                Text("Synthesize voices · transcribe audio")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
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
                modelField(help: "Any TTS model, e.g. openai/gpt-4o-mini-tts.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("TEXT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(size: 12))
                        .frame(minHeight: 120)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice (optional)").font(.caption).foregroundStyle(.secondary)
                        TextField("provider default", text: $voice)
                            .textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speed: \(speed, specifier: "%.2f")").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $speed, in: 0.25...4.0, step: 0.05).frame(width: 160)
                    }
                }
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                Button(action: synthesize) {
                    HStack {
                        if service.isWorking { ProgressView().controlSize(.small).tint(.white) }
                        Text(service.isWorking ? "Synthesizing…" : "Synthesize & Save…")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: 320)
                    .padding(.vertical, 9)
                    .background(canSynthesize ? accent : Color.gray.opacity(0.45))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(!canSynthesize)
                Text("Returns raw audio (mp3/pcm/wav depending on the model). Billed per request.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private func modelField(help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            TextField("model id", text: $modelId)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var canSynthesize: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelId.isEmpty && !service.isWorking && KeychainManager.hasAPIKey
    }

    private func synthesize() {
        guard canSynthesize else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Account first." }
            return
        }
        errorMessage = nil
        var request = SpeechRequest(model: modelId, input: text)
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        request.voice = trimmedVoice.isEmpty ? nil : trimmedVoice
        request.speed = speed == 1.0 ? nil : speed
        Task {
            do {
                let (data, contentType) = try await service.synthesize(request)
                await MainActor.run {
                    let ext = contentType?.contains("wav") == true ? "wav"
                        : contentType?.contains("pcm") == true ? "pcm" : "mp3"
                    let panel = NSSavePanel()
                    panel.title = "Save Audio"
                    panel.nameFieldStringValue = "orb-speech.\(ext)"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? data.write(to: url)
                    }
                }
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
                modelField(help: "Any STT model, e.g. openai/whisper-large-v3. Max 25 MB per file.")
                HStack(spacing: 10) {
                    Button(action: chooseAudio) {
                        Label(selectedAudioURL?.lastPathComponent ?? "Choose Audio…", systemImage: "waveform")
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if selectedAudioURL != nil {
                        Button("Clear") { selectedAudioURL = nil }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
                }
                Button(action: transcribe) {
                    HStack {
                        if service.isWorking { ProgressView().controlSize(.small).tint(.white) }
                        Text(service.isWorking ? "Transcribing…" : "Transcribe")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: 320)
                    .padding(.vertical, 9)
                    .background(canTranscribe ? accent : Color.gray.opacity(0.45))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(!canTranscribe)
                if !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TRANSCRIPT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
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
            }
            .padding(20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private var canTranscribe: Bool {
        selectedAudioURL != nil && !modelId.isEmpty && !service.isWorking && KeychainManager.hasAPIKey
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
                let request = TranscriptionRequest(
                    model: modelId, filename: url.lastPathComponent,
                    mimeType: mime, audioData: data
                )
                let response = try await service.transcribe(request)
                await MainActor.run { transcript = response.text }
            } catch is CancellationError {
                // Leave prior transcript alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: - Embeddings + rerank lab

struct EmbeddingsView: View {
    @StateObject private var service = EmbeddingService()
    @State private var modelId = "openai/text-embedding-3-small"
    @State private var inputText = ""
    @State private var dimensions: [Double] = []
    @State private var embedUsage: ImageGenUsage?
    @State private var rerankQuery = ""
    @State private var rerankDocs = ""
    @State private var rerankResults: [RerankResponse.Item] = []
    @State private var errorMessage: String?

    private let accent = Color.purple

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerBar
                embedSection
                Divider()
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
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(accent.opacity(0.13)).frame(width: 34, height: 34)
                Image(systemName: "vector").foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Embeddings & Rerank").font(.system(size: 15, weight: .semibold))
                Text("Vectors for search · ordering for retrieval")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var embedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EMBEDDINGS").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            TextField("Embedding model", text: $modelId)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            TextEditor(text: $inputText)
                .font(.system(size: 12))
                .frame(minHeight: 70)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
            HStack(spacing: 10) {
                Button(action: embed) {
                    Text(service.isWorking ? "Embedding…" : "Embed")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(canEmbed ? accent : Color.gray.opacity(0.45))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canEmbed)
                if !dimensions.isEmpty {
                    Text("\(dimensions.count) dims · first: \(dimensions.prefix(4).map { String(format: "%.3f", $0) }.joined(separator: ", "))…")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let usage = embedUsage, let cost = usage.cost {
                    Text("$\(cost, specifier: "%.5f")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rerankSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RERANK").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            TextField("Query", text: $rerankQuery)
                .textFieldStyle(.roundedBorder)
            Text("Documents (one per line)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $rerankDocs)
                .font(.system(size: 12))
                .frame(minHeight: 90)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
            Button(action: rerank) {
                Text(service.isWorking ? "Ranking…" : "Rerank")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(canRerank ? accent : Color.gray.opacity(0.45))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canRerank)
            if !rerankResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rerankResults.sorted { ($0.relevanceScore ?? 0) > ($1.relevanceScore ?? 0) }, id: \.index) { item in
                        HStack(spacing: 8) {
                            Text("#\(item.index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            if let score = item.relevanceScore {
                                Text(String(format: "%.3f", score))
                                    .font(.caption.monospacedDigit()).foregroundStyle(accent)
                            }
                            Spacer()
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
            && !modelId.isEmpty && !service.isWorking && KeychainManager.hasAPIKey
    }

    private var canRerank: Bool {
        !rerankQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerankDocs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !service.isWorking && KeychainManager.hasAPIKey
    }

    private func embed() {
        guard canEmbed else { return }
        errorMessage = nil
        Task {
            do {
                let response = try await service.embed(EmbeddingRequest(model: modelId, input: [inputText]))
                await MainActor.run {
                    dimensions = response.data.first?.embedding ?? []
                    embedUsage = response.usage
                }
            } catch is CancellationError {
                // Leave prior embedding alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func rerank() {
        guard canRerank else { return }
        errorMessage = nil
        let docs = rerankDocs.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        Task {
            do {
                // Rerank models live in the chat catalog; reuse the embedding
                // model field's prefix family when the user pastes one, else
                // fall back to a documented rerank-capable default is on them.
                let response = try await service.rerank(RerankRequest(
                    model: modelId, query: rerankQuery, documents: docs, topN: min(docs.count, 10)
                ))
                await MainActor.run { rerankResults = response.results }
            } catch is CancellationError {
                // Leave prior ranking alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}
