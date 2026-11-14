import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Speech studio (TTS + STT)

struct SpeechView: View {
    @ObservedObject private var service = StudioServices.shared.speech
    @StudioState("SpeechView.speechModels") private var speechModels = ModalityModelChoices()
    @StudioState("SpeechView.transcriptionModels") private var transcriptionModels = ModalityModelChoices()
    @ObservedObject private var creations = SavedCreationsStore.shared
    @StudioState("SpeechView.mode") private var mode: Mode = .tts
    @StudioState("SpeechView.text") private var text = ""
    @StudioState("SpeechView.voice") private var voice = ""
    @StudioState("SpeechView.speed") private var speed = 1.0
    @StudioState("SpeechView.audioFormat") private var audioFormat = "mp3"
    @StudioState("SpeechView.language") private var language = ""
    @StudioState("SpeechView.transcriptionFormat") private var transcriptionFormat = "json"
    @StudioState("SpeechView.timestampMode") private var timestampMode = "none"
    @StudioState("SpeechView.lastTranscription") private var lastTranscription: TranscriptionResponse? = nil
    @StudioState("SpeechView.pendingTranscript") private var pendingTranscript: (data: Data, mime: String, model: String, filename: String)? = nil
    @StudioState("SpeechView.errorMessage") private var errorMessage: String? = nil
    @StudioState("SpeechView.transcript") private var transcript = ""
    @StudioState("SpeechView.selectedAudioURL") private var selectedAudioURL: URL? = nil
    @StudioState("SpeechView.lastAudio") private var lastAudio: SavedCreation? = nil
    @StudioState("SpeechView.pendingAudio") private var pendingAudio: (data: Data, mimeType: String, modelID: String, prompt: String)? = nil
    @StudioState("SpeechView.isSaving") private var isSaving = false
    /// One player per studio: stopped when the page is left (STUDIO-8).
    @StudioState("SpeechView.playback") private var playback = StudioAudioPlayback()
    @StudioState("SpeechView.promptHistoryRevision") private var promptHistoryRevision = 0
    @State private var audioDropTargeted = false
    @EnvironmentObject private var shell: ShellController
    private let promptHistory = StudioPromptHistory(studio: .speech)

    enum Mode: String, CaseIterable { case tts = "Text → Speech", stt = "Speech → Text" }

    private let accent = ORBTheme.accent
    @StudioState("SpeechView.modelId") private var modelId = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            // Shared scaffold (V-3): controls + pinned action left, history right.
            StudioScaffold {
                if mode == .tts { ttsControls } else { sttControls }
            } footer: {
                footer
            } results: {
                historyPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await discoverMode() }
        .onDisappear { playback.stop() }
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
                         icon: "speaker.wave.2.fill", accent: accent) {
                StudioPresetMenu(
                    studio: .speech,
                    isApplicable: { SpeechPresetValues($0).mode == (mode == .tts ? "tts" : "stt") },
                    snapshot: {
                        StudioPreset.speechSettings(mode: mode == .tts ? "tts" : "stt", model: modelId, voice: voice,
                                                    speed: speed, format: audioFormat, language: language,
                                                    transcriptionFormat: transcriptionFormat, timestamps: timestampMode)
                    },
                    apply: { preset in
                        let v = SpeechPresetValues(preset)
                        if !v.model.isEmpty { modelId = v.model }
                        if mode == .tts {
                            voice = v.voice; speed = v.speed; audioFormat = v.format
                        } else {
                            language = v.language; transcriptionFormat = v.transcriptionFormat; timestampMode = v.timestamps
                        }
                    })
            }
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

    // MARK: Footer (pinned primary action; errors first — STUDIO-2)

    @ViewBuilder private var footer: some View {
        if let errorMessage {
            PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
        }
        if mode == .tts {
            StudioPrimaryButton(title: "Synthesize", busyTitle: service.isWorking ? "Synthesizing…" : "Saving…",
                                isBusy: service.isWorking || isSaving,
                                isEnabled: canSynthesize, accent: accent, action: synthesize)
                .keyboardShortcut(.return, modifiers: .command)
            Text(speechCostLine)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            StudioPrimaryButton(title: "Transcribe", busyTitle: service.isWorking ? "Transcribing…" : "Saving…",
                                isBusy: service.isWorking || isSaving,
                                isEnabled: canTranscribe, accent: accent, action: transcribe)
                .keyboardShortcut(.return, modifiers: .command)
            Text("Billed per request; the charge is shown with the transcript.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Per-character estimate from catalog pricing (STUDIO-12).
    private var speechCostLine: String {
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if let estimate = StudioCostEstimate.speech(promptPrice: selectedSpeechModel?.pricing?.prompt, characters: characters) {
            return "\(estimate.label). Audio is saved to the Library first; export is optional."
        }
        return "Price unknown for this model. Audio is saved to the Library first; export is optional."
    }

    // MARK: TTS

    @ViewBuilder private var ttsControls: some View {
        modelField(choices: speechModels)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StudioLabel("Text")
                Spacer(minLength: 0)
                StudioPromptHistoryMenu(history: promptHistory, onPick: { text = $0 },
                                        revision: promptHistoryRevision)
            }
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
            if audioFormat == "pcm" {
                StudioNotice(text: "Raw PCM has no header, so ORB can't play it. Export it to use in an audio editor.")
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
        if let pendingAudio {
            HStack {
                Text("Generated audio is not yet saved").foregroundStyle(.orange)
                Button("Retry save") { Task { await savePendingAudio() } }
                    .disabled(isSaving)
                Button("Export…") {
                    exportPendingAudio(pendingAudio.data, mimeType: pendingAudio.mimeType)
                }
            }.font(.caption)
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
        guard canSynthesize else { return }
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
                promptHistory.record(request.input)
                promptHistoryRevision += 1
                await savePendingAudio()
                StudioNotifier.shared.finished(section: SidebarSection.speech.rawValue, title: "Speech ready", body: "Your audio was generated.")
            } catch is CancellationError {
                // Leave prior state alone on cancellation.
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: History pane (V-3)

    private var history: [SavedCreation] {
        let kind: SavedCreation.Kind = mode == .tts ? .audio : .transcript
        return Array(creations.creations.filter { $0.kind == kind }.prefix(30))
    }

    private var historyPane: some View {
        let items = history
        return Group {
            if mode == .stt && !transcript.isEmpty || !items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if mode == .stt && !transcript.isEmpty { transcriptResult }
                        if !items.isEmpty {
                            HStack {
                                StudioSectionTitle(mode == .tts ? "Recent audio" : "Recent transcripts")
                                Button("Show all in Library") { StudioNavigation.showInLibrary(nil, shell: shell) }
                                    .font(.caption).buttonStyle(.link)
                            }
                            ForEach(items) { historyRow($0) }
                        }
                    }
                    .padding(20)
                }
            } else {
                StudioEmptyState(icon: mode == .tts ? "waveform" : "text.quote",
                                 title: mode == .tts ? "No audio yet" : "No transcripts yet",
                                 message: mode == .tts ? "Synthesized speech is saved here and in the Library."
                                                       : "Choose or drop an audio file, then Transcribe.",
                                 accent: accent)
            }
        }
    }

    private func historyRow(_ creation: SavedCreation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(creation.prompt ?? creation.modelID).font(.caption).lineLimit(2)
                    Text("\(creation.modelID) · \(creation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                CreationActionsMenu(creation: creation, store: creations, onError: { errorMessage = $0 },
                                    openInStudio: { StudioNavigation.openInStudio($0, shell: shell) })
                Button("Export…") { export(creation) }.font(.caption)
            }
            if creation.kind == .audio {
                if StudioAudioPlayback.canPlay(mimeType: creation.mimeType) {
                    StudioAudioPlayerBar(creation: creation, store: creations, playback: playback)
                } else {
                    Text("Raw PCM — export to play in an audio editor.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.orbSurface(lastAudio?.id == creation.id ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: STT

    @ViewBuilder private var sttControls: some View {
        modelField(choices: transcriptionModels)
        Text("Up to 100 MB. Files above 25 MB use base64 JSON upload; smaller files use multipart.").font(.caption2).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 4) {
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
            Text("or drop an audio file here").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Drag-and-drop audio (STUDIO-14).
        .studioFileDrop(kind: .audio, isTargeted: $audioDropTargeted) { selectedAudioURL = $0.first }
        if let pendingTranscript {
            HStack {
                Text("Transcript available; local save failed.").foregroundStyle(.orange)
                Button("Retry save") { Task { await saveTranscript(pendingTranscript) } }.disabled(isSaving)
            }.font(.caption)
        }
    }

    private var transcriptResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StudioSectionTitle("Transcript")
                Button("Copy") { AppToasts.copy(transcript, what: "Transcript") }.font(.caption)
            }
            Text(transcript)
                .orbFont(size: 12)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orbSurface(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
        guard canTranscribe, let url = selectedAudioURL else { return }
        errorMessage = nil
        Task {
            do {
                try LocalFilePreflight.check(url, limit: LocalFilePreflight.maxTranscriptionBytes, purpose: "transcription")
                // Read off the main actor (STUDIO-10).
                let data = try await LocalFileRead.data(at: url)
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
                // The picker may have changed while the request was in flight;
                // save the shape that was actually asked for.
                let structured = request.wantsStructuredTranscript
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
                StudioNotifier.shared.finished(section: SidebarSection.speech.rawValue, title: "Transcription ready", body: "Your transcript is done.")
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
            do { try creations.export(data: data, to: url) }
            catch { errorMessage = "Audio export failed: \(error.localizedDescription)" }
        }
    }

    private func export(_ creation: SavedCreation) {
        Task {
            do {
                try exportCreation(creation, store: creations)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
