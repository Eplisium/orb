import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Unpinned requests can be routed to any endpoint. A slug pin is shown only
/// when it names exactly one advertised endpoint; otherwise its capabilities
/// and price would not describe a uniquely selected route.
struct ImageStudioCapabilities {
    let endpoints: [ImageModelEndpoint]
    let pinnedSlug: String?

    init(endpoints: [ImageModelEndpoint], pinnedSlug: String?) {
        self.endpoints = endpoints
        if let pinnedSlug, endpoints.filter({ $0.providerSlug == pinnedSlug }).count == 1 {
            self.pinnedSlug = pinnedSlug
        } else {
            self.pinnedSlug = nil
        }
    }

    var applicable: [ImageModelEndpoint] {
        guard let pinnedSlug else { return endpoints }
        return endpoints.filter { $0.providerSlug == pinnedSlug }
    }

    func supports(_ parameter: String) -> Bool {
        !applicable.isEmpty && applicable.allSatisfy { $0.supportedParameters[parameter] != nil }
    }

    func options(_ parameter: String) -> [String] {
        guard let first = applicable.first,
              case .enumValues(let values) = first.supportedParameters[parameter] else { return ["auto"] }
        let common = values.filter { value in
            applicable.allSatisfy {
                if case .enumValues(let accepted) = $0.supportedParameters[parameter] { return accepted.contains(value) }
                return false
            }
        }
        return ["auto"] + common.filter { $0 != "auto" }
    }

    var maximumCount: Int {
        guard supports("n") else { return 1 }
        let limits = applicable.compactMap { endpoint -> Int? in
            if case .range(_, let maximum) = endpoint.supportedParameters["n"] { return Int(maximum) }
            return nil
        }
        return max(1, min(10, limits.min() ?? 1))
    }

    var referenceLimit: Int? {
        guard !applicable.isEmpty else { return nil }
        let limits = applicable.map { endpoint -> Int in
            if case .range(_, let maximum) = endpoint.supportedParameters["input_references"] {
                return max(0, min(16, Int(maximum)))
            }
            return 0 // The endpoint's definitive parameter set does not list references.
        }
        return limits.min()
    }

    func referenceError(count: Int) -> String? {
        let limit = referenceLimit ?? 16
        return count > limit ? "Selected \(count) references; this route allows at most \(limit). Remove images or change provider before generating." : nil
    }
}

enum MediaStudioImageFile {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static func dataURL(for url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 20_000_000 else {
            throw Failure.invalid("Image \(url.lastPathComponent) must be nonempty and at most 20 MB.")
        }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let mime = UTType(type)?.preferredMIMEType,
              ["image/png", "image/jpeg", "image/gif", "image/heic", "image/webp"].contains(mime) else {
            throw Failure.invalid("\(url.lastPathComponent) is not a supported image (PNG, JPEG, GIF, HEIC, or WebP).")
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

// MARK: - Images studio
//
// Dedicated `POST /images` playground: model picker, prompt, size/quality
// knobs, reference images, gallery with save, and cost tracking.

struct ImagesView: View {
    @ObservedObject private var service = StudioServices.shared.images
    @StateObject private var saved = SavedCreationsStore.shared
    @StudioState("ImagesView.prompt") private var prompt = ""
    @StudioState("ImagesView.selectedModelId") private var selectedModelId = ""
    @StudioState("ImagesView.imageCount") private var imageCount = 1
    @StudioState("ImagesView.aspectRatio") private var aspectRatio = "auto"
    @StudioState("ImagesView.resolution") private var resolution = "auto"
    @StudioState("ImagesView.quality") private var quality = "auto"
    @StudioState("ImagesView.seedText") private var seedText = ""
    @StudioState("ImagesView.referenceURLs") private var referenceURLs: [URL] = []
    @StudioState("ImagesView.selectedProviderSlug") private var selectedProviderSlug = ""
    @StudioState("ImagesView.errorMessage") private var errorMessage: String? = nil
    @StudioState("ImagesView.results") private var results: [GeneratedImage] = []
    @StudioState("ImagesView.endpoints") private var endpoints: [ImageModelEndpoint] = []
    @StudioState("ImagesView.endpointError") private var endpointError: String? = nil
    @StudioState("ImagesView.totalCost") private var totalCost = 0.0
    @FocusState private var inputFocused: Bool
    @AppStorage(PlaygroundModelDefaults.agentKey) private var pinnedAgentModelId = ""
    @StudioState("ImagesView.isEnhancing") private var isEnhancing = false
    @StudioState("ImagesView.promptBeforeEnhance") private var promptBeforeEnhance: String? = nil
    @StudioState("ImagesView.pendingImages") private var pendingImages = 0
    @StudioState("ImagesView.configuredModelId") private var configuredModelId = ""
    /// The in-flight generation run, so Cancel can stop it.
    @StudioState("ImagesView.runTasks") private var runTasks: [UUID: Task<Void, Never>] = [:]
    /// Partial-failure / cancellation summary of the last run.
    @StudioState("ImagesView.runSummary") private var runSummary: String? = nil
    @EnvironmentObject private var shell: ShellController

    private let accent = ORBTheme.accent
    /// Images per press, and the ceiling of unfinished images across overlapping runs.
    private static let maxImagesPerRun = 10
    private static let maxPendingImages = 20

    struct GeneratedImage: Identifiable {
        let id = UUID()
        let attachment: ChatImageAttachment
        let modelId: String
        let createdAt = Date()
        var savedID: UUID?
        var saveError: String?
    }

    var body: some View {
        HStack(spacing: 0) {
            controlsColumn
            Rectangle().fill(.orbSurface(0.07)).frame(width: 1)
            galleryColumn
        }
        .task {
            await service.fetchModels()
            if selectedModelId.isEmpty { selectedModelId = service.models.first?.id ?? "" }
        }
        .task(id: selectedModelId) {
            // Returning to the page re-runs this task; only reset the options
            // when the model actually changed, so settings survive navigation.
            if configuredModelId == selectedModelId, !endpoints.isEmpty { return }
            configuredModelId = selectedModelId
            endpoints = []
            endpointError = nil
            aspectRatio = "auto"
            resolution = "auto"
            quality = "auto"
            imageCount = 1
            selectedProviderSlug = ""
            guard !selectedModelId.isEmpty else { return }
            do { endpoints = try await service.fetchImageModelEndpoints(modelID: selectedModelId) }
            catch { endpointError = error.localizedDescription }
        }
        .task { CreationActions.pruneStaging(); Self.cleanEditReferences(keeping: referenceURLs) }
        .onChange(of: selectedProviderSlug) { _, _ in
            if imageCount > maximumCount { imageCount = maximumCount }
            aspectRatio = "auto"
            resolution = "auto"
            quality = "auto"
        }
    }

    // MARK: Controls

    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StudioHeader(title: "Images", subtitle: "Text-to-image generation", icon: "photo.fill", accent: accent) {
                    StudioPresetMenu(
                        studio: .images,
                        snapshot: {
                            StudioPreset.imageSettings(model: selectedModelId, count: imageCount, aspect: aspectRatio,
                                                       resolution: resolution, quality: quality, provider: selectedProviderSlug)
                        },
                        apply: { preset in
                            let v = ImagePresetValues(preset, maxCount: Self.maxImagesPerRun)
                            if !v.model.isEmpty { selectedModelId = v.model }
                            imageCount = v.count; aspectRatio = v.aspect
                            resolution = v.resolution; quality = v.quality
                            selectedProviderSlug = v.provider
                        })
                }

            modelPicker
            if !endpoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    StudioLabel("Provider Routing")
                    Picker("Provider", selection: $selectedProviderSlug) {
                        Text("Automatic routing").tag("")
                        ForEach(pinOptions, id: \.providerSlug) { endpoint in
                            Text(endpoint.providerName).tag(endpoint.providerSlug)
                        }
                    }.labelsHidden()
                    Text(selectedEndpoint == nil
                         ? "Auto routing: settings require support from every listed endpoint. Prices are estimates, not a selected route."
                         : "Pinned to \(selectedEndpoint!.providerName); fallback to other providers disabled.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                StudioLabel("Prompt")
                StudioPromptEditor(text: $prompt, placeholder: "Describe the image you want…",
                                   accessibilityLabel: "Image prompt")
                enhanceRow
            }

            StudioCard(title: "Options") {
                StudioGrid {
                    StudioField("Count") {
                        Stepper("\(imageCount)", value: $imageCount, in: 1...Self.maxImagesPerRun)
                    }
                    StudioField("Aspect") {
                        Picker("Aspect", selection: $aspectRatio) {
                            ForEach(options("aspect_ratio"), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                    StudioField("Quality") {
                        Picker("Quality", selection: $quality) {
                            ForEach(options("quality"), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                    StudioField("Resolution") {
                        Picker("Resolution", selection: $resolution) {
                            ForEach(options("resolution"), id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                    }
                }
                StudioField("Seed (optional)") {
                    TextField("random", text: $seedText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!supports("seed"))
                }
            }

            referenceRow
            if !referenceURLs.isEmpty && selectedImageModel?.architecture?.takesReferenceImages != true {
                Text("This model does not accept reference images. Remove them before generating.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let warning = capabilities.referenceError(count: referenceURLs.count) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if let endpointError {
                Text("Endpoint capabilities and prices unavailable: \(endpointError). Only default settings are available.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let endpoint = selectedEndpoint, !endpoint.pricing.isEmpty {
                Text("\(endpoint.providerName) advertised rates (actual charge may vary): " + endpoint.pricing.map { "\($0.billable): $\(String(format: "%.4f", $0.costUSD))/\($0.unit)\($0.variant.map { " (\($0))" } ?? "")" }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !endpoints.isEmpty {
                Text("Provider rates differ; pin a provider to inspect its advertised pricing. Actual charge is reported after generation.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !KeychainManager.hasAPIKey {
                Text("Add an inference API key in Settings → Accounts & Keys to generate images.")
                    .font(.caption).foregroundStyle(.orange)
            }

            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }
            if let runSummary {
                PlaygroundErrorBanner(message: runSummary) { self.runSummary = nil }
            }

            Spacer()

            StudioPrimaryButton(title: "Generate", busyTitle: "Generating…", isBusy: pendingImages > 0,
                                isEnabled: canGenerate, accent: accent, action: generate)
                .keyboardShortcut(.return, modifiers: .command)
            if pendingImages > 0 {
                Button(role: .cancel) { cancelRun() } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Stop waiting for the images still generating. Requests already sent may still be billed.")
            }

            if totalCost > 0 {
                Text("Reported spend (known charges): $\(totalCost, specifier: "%.4f")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            }
            .padding(18)
        }
        .frame(width: 340)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioLabel("Model")
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
            StudioLabel("Reference Images (optional)")
            HStack(spacing: 6) {
                Button(action: chooseReferences) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(StudioChipButtonStyle())
                .disabled(service.models.first(where: { $0.id == selectedModelId })?.architecture?.takesReferenceImages != true || capabilities.referenceLimit == 0)
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
                                    Image(systemName: "xmark").orbFont(size: 11, weight: .bold)
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
            if service.models.first(where: { $0.id == selectedModelId })?.architecture?.takesReferenceImages == true {
                Text("Up to \(capabilities.referenceLimit ?? 16) references, 20 MB each. Endpoint support may vary.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Gallery

    /// Session results whose saved creation still exists (Library deletions are reflected).
    private var sessionResults: [GeneratedImage] {
        let live = Set(saved.creations.map(\.id))
        return results.filter { ImageGallery.isVisible(savedID: $0.savedID, liveIDs: live) }
    }

    /// Latest saved images not already shown as session cards (capped).
    private var recentSaved: (items: [SavedCreation], hiddenCount: Int) {
        ImageGallery.recentSaved(saved.creations, excluding: Set(results.compactMap(\.savedID)))
    }

    private var galleryColumn: some View {
        let session = sessionResults
        let recent = recentSaved
        return Group {
            if session.isEmpty && recent.items.isEmpty && pendingImages == 0 {
                emptyGallery
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        if pendingImages > 0 {
                            ForEach(0..<pendingImages, id: \.self) { _ in
                                ImageGeneratingPlaceholder(accent: accent)
                            }
                        }
                        ForEach(session) { result in
                            galleryCard(result)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 20)
                    if !recent.items.isEmpty {
                        HStack {
                            Text("RECENTLY SAVED").font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Button(recent.hiddenCount > 0 ? "Show all \(recent.items.count + recent.hiddenCount) in Library"
                                                          : "Show all in Library") { showLibrary() }
                                .font(.caption)
                        }
                        .padding(.horizontal, 20).padding(.top, 8)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(recent.items) { creation in savedCard(creation) }
                        }
                        .padding(.horizontal, 20)
                    }
                    Color.clear.frame(height: 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var enhanceRow: some View {
        HStack(spacing: 8) {
            Button { Task { await enhancePrompt() } } label: {
                if isEnhancing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Enhancing…") }
                } else {
                    Label("Enhance with AI", systemImage: "wand.and.stars")
                }
            }
            .disabled(isEnhancing || pinnedAgentModelId.isEmpty || !canEnhance)
            .help(pinnedAgentModelId.isEmpty
                  ? "Pin a model in Agent to use it for prompt enhancement."
                  : "Rewrite the prompt with \(shortModelName(pinnedAgentModelId))")
            if let original = promptBeforeEnhance, !isEnhancing {
                Button("Undo") { prompt = original; promptBeforeEnhance = nil }
            }
            Spacer()
            Text(pinnedAgentModelId.isEmpty ? "No model pinned in Agent" : shortModelName(pinnedAgentModelId))
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .font(.caption)
    }

    private var canEnhance: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func enhancePrompt() async {
        let original = prompt
        isEnhancing = true
        errorMessage = nil
        defer { isEnhancing = false }
        do {
            let improved = try await PromptEnhancer.enhance(original, modelId: pinnedAgentModelId)
            promptBeforeEnhance = original
            prompt = improved
        } catch {
            errorMessage = "Prompt enhancement failed: \(error.localizedDescription)"
        }
    }

    private var emptyGallery: some View {
        StudioEmptyState(icon: "photo.on.rectangle.angled", title: "Your image gallery",
                         message: "Pick a model and describe your image. ORB saves generated images here for later; failed saves can be retried or exported.",
                         accent: accent)
    }

    /// Lightweight card for an older saved image: lazy downsampled thumbnail
    /// from the stored file — no full decode, base64, or checksum pass.
    private func savedCard(_ creation: SavedCreation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LibraryThumbnail(creation: creation, store: saved, maxPixel: 480)
                .frame(maxWidth: .infinity).frame(height: 140)
                .background(.orbSurface(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .creationDrag(creation, store: saved)
            HStack(spacing: 6) {
                Text(creation.prompt ?? creation.modelID).font(.caption).lineLimit(1)
                Spacer()
                CreationActionsMenu(creation: creation, store: saved)
            }
        }
        .padding(8)
        .background(.orbSurface(0.035), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let text = creation.prompt, !text.isEmpty { Button("Reuse Prompt") { prompt = text } }
            Button("Edit") { editSaved(creation) }
            CreationActionItems(creation: creation, store: saved)
        }
    }

    private func showLibrary() {
        StudioStore.shared.box("FilesView.showingCreations", initial: { false }).value = true
        shell.send(.section(.files))
    }

    private func galleryCard(_ result: GeneratedImage) -> some View {
        let savedCreation = result.savedID.flatMap { id in saved.creations.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let savedCreation {
                    AssistantImageRow(images: [result.attachment], accent: accent,
                                      onReusePrompt: { prompt = $0 }, showsExport: false)
                        .creationDrag(savedCreation, store: saved)
                } else {
                    AssistantImageRow(images: [result.attachment], accent: accent,
                                      onReusePrompt: { prompt = $0 }, showsExport: false)
                }
            }
            Text(result.modelId)
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack {
                if result.savedID != nil {
                    Label("Saved in ORB", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Saved in the ORB library")
                    Button("View in Library") { showLibrary() }
                        .buttonStyle(.link)
                        .help("Open Files → Saved creations")
                    if let savedCreation { CreationActionsMenu(creation: savedCreation, store: saved) }
                } else {
                    Button("Retry save") { Task { await persist(result.id) } }
                    Text(result.saveError ?? "Not saved").foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Button { editImage(result) } label: { Label("Edit", systemImage: "wand.and.stars") }
                    .help("Use this image as a reference and describe the changes")
                Button("Export…") { exportImage(result) }
            }.font(.caption)
        }
        .padding(12)
        .background(.orbSurface(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.orbSurface(0.07), lineWidth: 0.5) }
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

    // MARK: Actions

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedModelId.isEmpty && pendingImages + imageCount <= Self.maxPendingImages
            && KeychainManager.hasAPIKey && capabilities.referenceError(count: referenceURLs.count) == nil
            && (referenceURLs.isEmpty || selectedImageModel?.architecture?.takesReferenceImages == true)
    }

    private var selectedImageModel: ImageGenModel? {
        service.models.first { $0.id == selectedModelId }
    }

    private var pinOptions: [ImageModelEndpoint] {
        endpoints.filter { candidate in endpoints.filter { $0.providerSlug == candidate.providerSlug }.count == 1 }
    }

    private var capabilities: ImageStudioCapabilities {
        ImageStudioCapabilities(endpoints: endpoints, pinnedSlug: selectedProviderSlug.isEmpty ? nil : selectedProviderSlug)
    }

    private var selectedEndpoint: ImageModelEndpoint? {
        guard let slug = capabilities.pinnedSlug else { return nil }
        return endpoints.first { $0.providerSlug == slug }
    }

    private func supports(_ parameter: String) -> Bool { capabilities.supports(parameter) }
    private var maximumCount: Int { capabilities.maximumCount }
    private func options(_ parameter: String) -> [String] { capabilities.options(parameter) }

    private func chooseReferences() {
        let panel = NSOpenPanel()
        panel.title = "Reference Images"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic]
        if panel.runModal() == .OK { referenceURLs.append(contentsOf: panel.urls.filter { !referenceURLs.contains($0) }) }
    }

    private func referenceDataURLs() throws -> [String]? {
        guard !referenceURLs.isEmpty else { return nil }
        if let warning = capabilities.referenceError(count: referenceURLs.count) {
            throw MediaStudioImageFile.Failure.invalid(warning)
        }
        return try referenceURLs.map(MediaStudioImageFile.dataURL(for:))
    }

    /// Cancels every image run in flight (overlapping runs included).
    private func cancelRun() {
        for task in runTasks.values { task.cancel() }
    }

    private func generate() {
        guard canGenerate else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Settings → Accounts & Keys first." }
            return
        }
        errorMessage = nil
        runSummary = nil
        let modelId = selectedModelId
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = imageCount
        // Providers cap `n` per request; split into concurrent requests so
        // any count works. Endpoints without `n` get one image per request.
        let chunks = ImageGallery.chunks(total: total, perRequest: maximumCount)
        pendingImages += total
        // Overlapping runs are tracked by ID so Cancel stops all of them.
        let runID = UUID()
        runTasks[runID] = Task {
            defer { runTasks[runID] = nil }
            var base: ImageGenRequest
            do {
                let takesReferences = service.models.first(where: { $0.id == modelId })?.architecture?.takesReferenceImages == true
                let references = takesReferences ? try referenceDataURLs() : nil
                base = ImageGenRequest(model: modelId, prompt: promptText)
                base.aspectRatio = options("aspect_ratio").contains(aspectRatio) && aspectRatio != "auto" ? aspectRatio : nil
                base.resolution = options("resolution").contains(resolution) && resolution != "auto" ? resolution : nil
                base.quality = options("quality").contains(quality) && quality != "auto" ? quality : nil
                if supports("seed"), !seedText.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) else {
                        throw MediaStudioImageFile.Failure.invalid("Seed must be a whole number.")
                    }
                    base.seed = seed
                }
                if let slug = capabilities.pinnedSlug {
                    base.provider = ImageGenerationProviderPreferences(only: [slug], allowFallbacks: false)
                }
                base.inputReferences = references
            } catch {
                pendingImages -= total
                errorMessage = error.localizedDescription
                return
            }
            let template = base
            var summary = ImageRunSummary(requested: total)
            await withTaskGroup(of: (Int, Result<(images: [ChatImageAttachment], usage: ImageGenUsage?), Error>).self) { group in
                for size in chunks {
                    group.addTask { @MainActor in
                        var request = template
                        request.n = size > 1 ? size : nil
                        do { return (size, .success(try await service.generateWithUsage(request))) }
                        catch { return (size, .failure(error)) }
                    }
                }
                for await (size, outcome) in group {
                    pendingImages -= size
                    switch outcome {
                    case .success(let output):
                        totalCost += output.usage?.cost ?? 0
                        summary.delivered += output.images.count
                        for attachment in output.images {
                            let result = GeneratedImage(attachment: attachment, modelId: modelId)
                            results.insert(result, at: 0)
                            await persist(result.id)
                        }
                    case .failure(let error):
                        if error is CancellationError || Task.isCancelled {
                            summary.cancelled += size
                        } else {
                            summary.recordFailure(error.localizedDescription, images: size)
                        }
                    }
                }
            }
            runSummary = summary.text
            if summary.delivered > 0 {
                StudioNotifier.shared.finished(section: SidebarSection.images.rawValue,
                    title: "Images ready", body: "\(summary.delivered) image\(summary.delivered == 1 ? "" : "s") generated with \(shortModelName(modelId)).")
            }
        }
    }

    private func persist(_ id: UUID) async {
        guard let index = results.firstIndex(where: { $0.id == id }), results[index].savedID == nil else { return }
        let result = results[index]
        guard let data = result.attachment.inlineData else {
            results[index].saveError = "Response did not contain decodable image bytes."
            return
        }
        do {
            let creation = try await saved.save(data, mimeType: result.attachment.mimeType,
                kind: .image, modelID: result.modelId, prompt: result.attachment.prompt)
            if let current = results.firstIndex(where: { $0.id == id }) {
                results[current].savedID = creation.id
                results[current].saveError = nil
            }
        } catch {
            if let current = results.firstIndex(where: { $0.id == id }) { results[current].saveError = error.localizedDescription }
        }
    }

    /// Scratch folder for edit references (only ever holds copies).
    static var editReferenceDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("orb-edit-references", isDirectory: true)
    }

    /// Removes edit-reference copies no longer selected as references.
    static func cleanEditReferences(keeping keep: [URL] = []) {
        let fm = FileManager.default
        let keepPaths = Set(keep.map { $0.standardizedFileURL.path })
        guard let entries = try? fm.contentsOfDirectory(at: editReferenceDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !keepPaths.contains(entry.standardizedFileURL.path) {
            try? fm.removeItem(at: entry)
        }
    }

    /// Picks a model that accepts references, preferring the original one.
    private func selectReferenceCapableModel(preferring modelID: String) -> Bool {
        guard selectedImageModel?.architecture?.takesReferenceImages != true else { return true }
        let original = service.models.first { $0.id == modelID && $0.architecture?.takesReferenceImages == true }
        guard let target = original ?? service.models.first(where: { $0.architecture?.takesReferenceImages == true }) else {
            errorMessage = "No available image model accepts reference images."
            return false
        }
        selectedModelId = target.id
        return true
    }

    private func useAsReference(write: (URL) throws -> Void, name: String) {
        do {
            let dir = Self.editReferenceDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Self.cleanEditReferences()
            let url = dir.appendingPathComponent(name)
            try write(url)
            referenceURLs = [url]
            errorMessage = nil
        } catch {
            errorMessage = "Could not prepare the image for editing: \(error.localizedDescription)"
        }
    }

    /// Loads an existing image as the reference for an image-to-image edit.
    private func editImage(_ result: GeneratedImage) {
        guard let data = result.attachment.inlineData else { errorMessage = "Image bytes are unavailable."; return }
        guard selectReferenceCapableModel(preferring: result.modelId) else { return }
        useAsReference(write: { try data.write(to: $0, options: .atomic) },
                       name: "edit-\(result.id.uuidString.prefix(8)).\(result.attachment.fileExtension)")
    }

    /// Uses a saved image (copied from its stored file) as an edit reference.
    private func editSaved(_ creation: SavedCreation) {
        guard selectReferenceCapableModel(preferring: creation.modelID) else { return }
        useAsReference(write: { url in
            try FileManager.default.copyItem(at: try saved.fileURL(for: creation), to: url)
        }, name: "edit-\(creation.id.uuidString.prefix(8)).\(creationExtension(creation))")
    }

    private func exportImage(_ result: GeneratedImage) {
        guard let data = result.attachment.inlineData else { errorMessage = "Image bytes are unavailable."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "orb-image.\(result.attachment.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do { try await Task.detached { try data.write(to: url, options: .atomic) }.value }
                catch { errorMessage = "Export failed: \(error.localizedDescription)" }
            }
        }
    }

}

/// Animated stand-in shown in the gallery while an image is being generated.
struct ImageGeneratingPlaceholder: View {
    let accent: Color
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let sweep = CGFloat((t.truncatingRemainder(dividingBy: 1.8)) / 1.8)
            let pulse = 0.5 + 0.5 * sin(t * 2.6)
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent.opacity(0.06 + 0.04 * pulse))
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, accent.opacity(0.28), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: -geo.size.width * 0.5 + sweep * geo.size.width * 1.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .orbFont(size: 28, weight: .medium)
                            .foregroundStyle(accent)
                            .scaleEffect(0.9 + 0.2 * pulse)
                            .opacity(0.6 + 0.4 * pulse)
                        Text("Generating…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.25 + 0.2 * pulse), lineWidth: 1) }
            }
            .padding(12)
            .background(.orbSurface(0.035), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("Generating image")
    }
}
