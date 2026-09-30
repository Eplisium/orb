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
    @StateObject private var service = ImageGenService()
    @StateObject private var saved = SavedCreationsStore.shared
    @State private var prompt = ""
    @State private var selectedModelId = ""
    @State private var imageCount = 1
    @State private var aspectRatio = "auto"
    @State private var resolution = "auto"
    @State private var quality = "auto"
    @State private var seedText = ""
    @State private var referenceURLs: [URL] = []
    @State private var selectedProviderSlug = ""
    @State private var errorMessage: String?
    @State private var results: [GeneratedImage] = []
    @State private var endpoints: [ImageModelEndpoint] = []
    @State private var endpointError: String?
    @State private var totalCost = 0.0
    @FocusState private var inputFocused: Bool
    @AppStorage(PlaygroundModelDefaults.agentKey) private var pinnedAgentModelId = ""
    @State private var isEnhancing = false
    @State private var promptBeforeEnhance: String?
    @State private var generatingCount = 1

    private let accent = ORBTheme.accent

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
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
            galleryColumn
        }
        .task {
            await service.fetchModels()
            if selectedModelId.isEmpty { selectedModelId = service.models.first?.id ?? "" }
        }
        .task(id: selectedModelId) {
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
        .task { await loadGallery() }
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
                StudioHeader(title: "Images", subtitle: "Text-to-image generation", icon: "photo.fill", accent: accent)

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
                        Stepper("\(imageCount)", value: $imageCount, in: 1...maximumCount)
                            .disabled(maximumCount == 1)
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
                Text("Add an inference API key in Account to generate images.")
                    .font(.caption).foregroundStyle(.orange)
            }

            if let errorMessage {
                PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }

            Spacer()

            StudioPrimaryButton(title: "Generate", busyTitle: "Generating…", isBusy: service.isGenerating,
                                isEnabled: canGenerate, accent: accent, action: generate)
                .keyboardShortcut(.return, modifiers: .command)

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
            if service.models.first(where: { $0.id == selectedModelId })?.architecture?.takesReferenceImages == true {
                Text("Up to \(capabilities.referenceLimit ?? 16) references, 20 MB each. Endpoint support may vary.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Gallery

    private var galleryColumn: some View {
        Group {
            if results.isEmpty && !service.isGenerating {
                emptyGallery
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        if service.isGenerating {
                            ForEach(0..<max(1, generatingCount), id: \.self) { _ in
                                ImageGeneratingPlaceholder(accent: accent)
                            }
                        }
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

    private func galleryCard(_ result: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistantImageRow(images: [result.attachment], accent: accent,
                              onReusePrompt: { prompt = $0 })
            Text(result.modelId)
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack {
                if result.savedID != nil {
                    Label("Saved in ORB", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07), lineWidth: 0.5) }
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

    private func generate() {
        guard canGenerate else {
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Account first." }
            return
        }
        errorMessage = nil
        generatingCount = imageCount
        let modelId = selectedModelId
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let takesReferences = service.models.first(where: { $0.id == modelId })?.architecture?.takesReferenceImages == true
                let references = takesReferences ? try referenceDataURLs() : nil
                var request = ImageGenRequest(model: modelId, prompt: promptText)
                request.n = imageCount > 1 ? imageCount : nil
                request.aspectRatio = options("aspect_ratio").contains(aspectRatio) && aspectRatio != "auto" ? aspectRatio : nil
                request.resolution = options("resolution").contains(resolution) && resolution != "auto" ? resolution : nil
                request.quality = options("quality").contains(quality) && quality != "auto" ? quality : nil
                if supports("seed"), !seedText.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let seed = Int(seedText.trimmingCharacters(in: .whitespaces)) else {
                        throw MediaStudioImageFile.Failure.invalid("Seed must be a whole number.")
                    }
                    request.seed = seed
                }
                if let slug = capabilities.pinnedSlug {
                    request.provider = ImageGenerationProviderPreferences(only: [slug], allowFallbacks: false)
                }
                request.inputReferences = references
                let attachments = try await service.generate(request)
                for attachment in attachments {
                    let result = GeneratedImage(attachment: attachment, modelId: modelId)
                    results.insert(result, at: 0)
                    await persist(result.id)
                }
                totalCost += service.lastUsage?.cost ?? 0
            } catch is CancellationError {
                // User navigated away; leave prior results alone.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadGallery() async {
        for creation in saved.creations where creation.kind == .image {
            guard !results.contains(where: { $0.savedID == creation.id }) else { continue }
            do {
                let data = try await saved.data(for: creation)
                let attachment = ChatImageAttachment(dataURL: "data:\(creation.mimeType);base64,\(data.base64EncodedString())", prompt: creation.prompt)
                results.append(GeneratedImage(attachment: attachment, modelId: creation.modelID, savedID: creation.id))
            } catch { errorMessage = "Could not load a saved image: \(error.localizedDescription)" }
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

    /// Loads an existing image as the reference for an image-to-image edit.
    private func editImage(_ result: GeneratedImage) {
        guard let data = result.attachment.inlineData else { errorMessage = "Image bytes are unavailable."; return }
        // Prefer the model that made it; otherwise any model that accepts references.
        if selectedImageModel?.architecture?.takesReferenceImages != true {
            let original = service.models.first { $0.id == result.modelId && $0.architecture?.takesReferenceImages == true }
            guard let target = original ?? service.models.first(where: { $0.architecture?.takesReferenceImages == true }) else {
                errorMessage = "No available image model accepts reference images."
                return
            }
            selectedModelId = target.id
        }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orb-edit-references", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("edit-\(result.id.uuidString.prefix(8)).\(result.attachment.fileExtension)")
            try data.write(to: url, options: .atomic)
            referenceURLs = [url]
            errorMessage = nil
        } catch {
            errorMessage = "Could not prepare the image for editing: \(error.localizedDescription)"
        }
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
                            .font(.system(size: 28, weight: .medium))
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
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("Generating image")
    }
}

// MARK: - Video studio

struct VideoView: View {
    @StateObject private var service = VideoGenService()
    @StateObject private var saved = SavedCreationsStore.shared
    @State private var prompt = ""
    @State private var selectedModelId = ""
    @State private var aspectRatio = "auto"
    @State private var resolution = "auto"
    @State private var durationText = ""
    @State private var size = "auto"
    @State private var seedText = ""
    @State private var firstFrameURL: URL?
    @State private var lastFrameURL: URL?
    @State private var generateAudio = false
    @State private var errorMessage: String?
    @State private var jobs: [VideoJobRecord] = []
    @State private var totalCost = 0.0
    @State private var videoBytes: [String: Data] = [:]
    @State private var videoMIMEs: [String: String] = [:]
    @State private var savedVideos: [String: SavedCreation] = [:]
    @State private var downloadErrors: [String: String] = [:]
    @State private var downloading: Set<String> = []
    @State private var isSubmitting = false
    // Durable jobs that can be resumed (W09 step 3). Refreshed on appear and
    // whenever the service's active job changes (poll ticks, terminal states).
    @State private var resumableRecords: [JobRecord] = []

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
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
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
                StudioHeader(title: "Video", subtitle: "Text-to-video generation", icon: "video.fill", accent: accent)

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
                            Text("Model default").font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text("Add an inference API key in Account to generate or resume video.")
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
        Group {
            if jobs.isEmpty && resumableRecords.isEmpty && saved.creations.allSatisfy({ $0.kind != .video })
                && service.durablePersistenceError == nil {
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
                                }.padding(12).background(Color.primary.opacity(0.03))
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
                    .font(.system(size: 9, weight: .bold))
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.modelID ?? "video")
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                // The durable record's last known remote status, preserved
                // verbatim across local stops.
                Text("Last status: \(record.lastRemoteStatus ?? "unknown")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                resumeDurable(record)
            } label: {
                Label("Resume", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
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
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            Text(record.prompt).font(.system(size: 12)).lineLimit(3)
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
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && KeychainManager.hasAPIKey
            && !isSubmitting && !resumableRecords.contains(where: { service.isRunInFlight(for: $0) })
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
