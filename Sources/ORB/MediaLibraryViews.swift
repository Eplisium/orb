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
                    .orbFont(size: 12, design: .monospaced)
            } else {
                HStack(spacing: 6) {
                    Text(modelID).orbFont(size: 11, design: .monospaced)
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Enter ID manually") { showsManual = true }
                        .buttonStyle(.plain).orbFont(size: 11).foregroundStyle(.secondary)
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
    @ObservedObject private var service = StudioServices.shared.files
    @StudioState("FilesView.remoteFiles") private var remoteFiles: [WorkspaceFile] = []
    @StudioState("FilesView.nextCursor") private var nextCursor: String? = nil
    @StudioState("FilesView.hasMore") private var hasMore = false
    @StudioState("FilesView.isFetchingPage") private var isFetchingPage = false
    @StudioState("FilesView.pageError") private var pageError: String? = nil
    @StudioState("FilesView.errorMessage") private var errorMessage: String? = nil
    @State private var showingCreations = false
    @StudioState("FilesView.isUploading") private var isUploading = false
    /// The file awaiting delete confirmation. The service layer refuses an
    /// unconfirmed delete, so the confirmation dialog is the only way the
    /// destructive call is ever issued.
    @State private var pendingDelete: WorkspaceFile?

    private let accent = ORBTheme.accent

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
                .orbFont(size: 14)
                .foregroundStyle(accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename ?? file.id)
                    .orbFont(size: 12, weight: .medium)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(file.id).orbFont(size: 11, design: .monospaced).foregroundStyle(.tertiary)
                    if let bytes = file.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                AppToasts.copy(file.id, what: "File ID")
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
        .background(.orbSurface(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(.orbSurface(0.07), lineWidth: 0.5) }
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
    @AppStorage("orb.library.layout") private var layout = LibraryLayout.grid.rawValue
    @State private var query = LibraryQuery()
    @State private var selection = LibrarySelection()
    @State private var errorMessage: String?
    @State private var isOpening = false
    @State private var pendingDelete: [SavedCreation]?
    @State private var undoRemoved: [SavedCreation]?
    @FocusState private var focused: Bool

    private var visible: [SavedCreation] { query.apply(to: store.creations) }
    private var isGrid: Bool { layout == LibraryLayout.grid.rawValue }
    private var kindChips: [(kind: SavedCreation.Kind, count: Int)] {
        let counts = LibraryQuery.counts(store.creations)
        return SavedCreation.Kind.allCases.compactMap { k in counts[k].map { (k, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let errorMessage { PlaygroundErrorBanner(message: errorMessage) { self.errorMessage = nil } }
            if let loadError = store.loadError {
                Label(loadError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(ORBFont.caption).foregroundStyle(ORBTheme.danger)
            }
            content
        }
        .padding(16)
        .focusable()
        .focused($focused)
        .onKeyPress(.space) {
            guard let target = LibraryPreview.target(selection: selection.ids, visible: visible) else { return .ignored }
            open(target); return .handled
        }
        .onChange(of: visible.map(\.id)) { _, ids in selection.prune(toVisible: ids) }
        .confirmationDialog(
            LibraryDelete.confirmTitle(count: pendingDelete?.count ?? 0),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let items = pendingDelete { delete(items) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("You can undo for a few seconds. After that the saved file is removed from this Mac.")
        }
        .overlay(alignment: .bottom) {
            if let removed = undoRemoved {
                UndoToastView(
                    message: LibraryDelete.message(count: removed.count),
                    undo: { undoDelete(removed) },
                    dismiss: { finalizeDelete(removed) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear { if let removed = undoRemoved { finalizeDelete(removed) } }
        .onDeleteCommand {
            let chosen = visible.filter { selection.contains($0.id) }
            if !chosen.isEmpty { pendingDelete = chosen }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search prompts and models", text: $query.text).textFieldStyle(.plain)
                    if !query.text.isEmpty {
                        Button { query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.orbSurface(0.05), in: RoundedRectangle(cornerRadius: 8))
                Picker("Sort", selection: $query.sort) {
                    ForEach(LibraryQuery.Sort.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).fixedSize()
                Picker("Layout", selection: $layout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid.rawValue)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 84)
                .accessibilityLabel("Layout")
            }
            HStack(spacing: 6) {
                ForEach(kindChips, id: \.kind) { chip in
                    let kind = chip.kind, n = chip.count
                    do {
                        let on = query.kinds.contains(kind)
                        Button {
                            if on { query.kinds.remove(kind) } else { query.kinds.insert(kind) }
                        } label: {
                            Label("\(kind.title) \(n)", systemImage: kind.symbol).font(ORBFont.caption)
                        }
                        .buttonStyle(StudioChipButtonStyle(isSelected: on, accent: ORBTheme.accent))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Spacer()
                Text(query.summary(shown: visible.count, total: store.creations.count))
                    .font(ORBFont.caption).foregroundStyle(.secondary)
                if query.isFiltering { Button("Clear") { query.clear() }.font(ORBFont.caption) }
            }
            if !selection.isEmpty { selectionBar }
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selection.count) selected").font(ORBFont.footnote.weight(.semibold))
            Button("Select All") { selection.selectAll(visible.map(\.id)) }
            Button("Deselect") { selection.clear() }
            Spacer()
            Button(role: .destructive) { pendingDelete = visible.filter { selection.contains($0.id) } } label: { Label("Delete…", systemImage: "trash") }
            Button { exportSelected() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(8)
        .background(ORBTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if store.creations.isEmpty {
            ContentUnavailableView("No saved creations yet", systemImage: "square.stack",
                description: Text("Generate media, synthesize speech, transcribe audio, or embed text to save it here."))
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if visible.isEmpty {
            ContentUnavailableView("Nothing matches", systemImage: "magnifyingglass",
                description: Text("Try a different search or clear the type filters."))
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            ScrollView {
                if isGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
                        ForEach(visible) { cell($0) }
                    }
                } else {
                    LazyVStack(spacing: 6) { ForEach(visible) { row($0) } }
                }
                if isOpening { ProgressView("Opening…").padding() }
            }
        }
    }

    private func tap(_ c: SavedCreation) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) { selection.extend(to: c.id, in: visible.map(\.id)) }
        else { selection.toggle(c.id) }
        focused = true
    }

    private func label(_ c: SavedCreation) -> String { c.prompt.flatMap { $0.isEmpty ? nil : $0 } ?? c.kind.title }

    private func cell(_ c: SavedCreation) -> some View {
        let on = selection.contains(c.id)
        let accent = ORBTheme.accent
        let fill: Color = on ? accent.opacity(0.14) : Color.clear
        let ring: AnyShapeStyle = on ? AnyShapeStyle(accent) : AnyShapeStyle(.orbSurface(0.08))
        let subtitle = "\(c.modelID) · \(c.createdAt.formatted(date: .abbreviated, time: .omitted))"
        let shape = RoundedRectangle(cornerRadius: 10)

        let card = VStack(alignment: .leading, spacing: 6) {
            LibraryThumbnail(creation: c, store: store)
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(.orbSurface(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(label(c)).font(ORBFont.footnote).lineLimit(2)
            Text(subtitle).font(ORBFont.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(fill, in: shape)
        .overlay(shape.stroke(ring, lineWidth: on ? 2 : 1))
        .contentShape(Rectangle())

        return card
            .onTapGesture(count: 2) { open(c) }
            .onTapGesture { tap(c) }
            .contextMenu { itemMenu(c) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(c.kind.title): \(label(c))")
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityAction(named: "Open") { open(c) }
            .accessibilityAction(named: on ? "Deselect" : "Select") { selection.toggle(c.id) }
    }

    private func row(_ c: SavedCreation) -> some View {
        let on = selection.contains(c.id)
        return HStack(spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : c.kind.symbol).frame(width: 28)
                .foregroundStyle(on ? ORBTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(label(c)).font(ORBFont.footnote).lineLimit(2)
                Text("\(c.kind.title) · \(c.modelID) · \(c.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(ORBFont.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Open") { open(c) }
            Button("Export…") { export(c) }
        }
        .padding(10)
        .background(on ? ORBTheme.accent.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { tap(c) }
        .contextMenu { itemMenu(c) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func itemMenu(_ c: SavedCreation) -> some View {
        Button("Open") { open(c) }
        Button("Export…") { export(c) }
        Button(selection.contains(c.id) ? "Deselect" : "Select") { selection.toggle(c.id) }
        Button("Delete…", role: .destructive) {
            pendingDelete = selection.contains(c.id) ? visible.filter { selection.contains($0.id) } : [c]
        }
        if let prompt = c.prompt, !prompt.isEmpty { Button("Copy Prompt") { AppToasts.copy(prompt, what: "Prompt") } }
    }

    // MARK: Actions

    private func open(_ creation: SavedCreation) {
        guard LibraryPreview.canQuickLook(creation) else {
            errorMessage = "Raw PCM audio has no container or sample-rate metadata for safe playback. Export the .pcm bytes instead."
            return
        }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                // Space previews the whole selection; double-click previews one item.
                let group = selection.contains(creation.id) && selection.count > 1
                    ? visible.filter { selection.contains($0.id) && LibraryPreview.canQuickLook($0) }
                    : [creation]
                var loaded: [(creation: SavedCreation, data: Data)] = []
                for item in group { loaded.append((item, try await store.data(for: item))) }
                guard QuickLookPreview.shared.show(loaded) else { throw CocoaError(.fileWriteUnknown) }
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

    private func delete(_ items: [SavedCreation]) {
        pendingDelete = nil
        // A newer delete finalizes the previous one: only one Undo is offered at a time.
        if let previous = undoRemoved { finalizeDelete(previous) }
        Task {
            do {
                let removed = try await store.remove(ids: Set(items.map(\.id)))
                guard !removed.isEmpty else { return }
                selection.clear()
                undoRemoved = removed
            } catch {
                errorMessage = "Couldn't delete: \(error.localizedDescription). Nothing was removed."
            }
        }
    }

    private func undoDelete(_ removed: [SavedCreation]) {
        undoRemoved = nil
        Task {
            do { try await store.restore(removed) }
            catch { errorMessage = "Couldn't restore: \(error.localizedDescription)" }
        }
    }

    private func finalizeDelete(_ removed: [SavedCreation]) {
        guard undoRemoved?.map(\.id) == removed.map(\.id) else { return }
        undoRemoved = nil
        Task { await store.purgeUnreferenced(removed) }
    }

    private func exportSelected() {
        let chosen = visible.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export \(chosen.count) \(chosen.count == 1 ? "item" : "items")"
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            // Read every asset first (the store verifies checksums), then write off-store.
            var loaded: [UUID: Data] = [:]
            var unreadable: [String] = []
            for c in chosen {
                do { loaded[c.id] = try await store.data(for: c) }
                catch { unreadable.append(LibraryExport.fileName(for: c)) }
            }
            let plan = LibraryExport.plan(chosen.filter { loaded[$0.id] != nil })
            let outcome = LibraryExport.write(plan, to: folder) { loaded[$0.id] ?? Data() }
            let failed = unreadable + outcome.failed
            let text = LibraryExport.resultText(written: outcome.written, failed: failed)
            if failed.isEmpty { AppToasts.center.show(text, kind: .success) }
            else { errorMessage = text }
        }
    }
}

enum LibraryLayout: String { case grid, list }

/// Thumbnails are decoded lazily and only for images; other kinds show their symbol.
struct LibraryThumbnail: View {
    let creation: SavedCreation
    let store: SavedCreationsStore
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: creation.kind.symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: creation.id) {
            guard creation.kind == .image, image == nil,
                  let data = try? await store.data(for: creation) else { return }
            image = NSImage(data: data)
        }
    }
}

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
    @StudioState("SpeechView.audioPlayer") private var audioPlayer: AVAudioPlayer? = nil
    @StudioState("SpeechView.isSaving") private var isSaving = false

    enum Mode: String, CaseIterable { case tts = "Text → Speech", stt = "Speech → Text" }

    private let accent = ORBTheme.accent
    @StudioState("SpeechView.modelId") private var modelId = ""

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
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Settings → Accounts & Keys first." }
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
                StudioNotifier.shared.finished(section: SidebarSection.speech.rawValue, title: "Speech ready", body: "Your audio was generated.")
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
                            .orbFont(size: 12)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orbSurface(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("Copy") {
                            AppToasts.copy(transcript, what: "Transcript")
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
            if !KeychainManager.hasAPIKey { errorMessage = "Add your OpenRouter API key in Settings → Accounts & Keys first." }
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
    @ObservedObject private var service = StudioServices.shared.embeddings
    @StudioState("EmbeddingsView.embeddingModels") private var embeddingModels = ModalityModelChoices()
    @StudioState("EmbeddingsView.rerankModels") private var rerankModels = ModalityModelChoices()
    @ObservedObject private var creations = SavedCreationsStore.shared
    @StudioState("EmbeddingsView.modelId") private var modelId = ""
    @StudioState("EmbeddingsView.rerankModelId") private var rerankModelId = ""
    @StudioState("EmbeddingsView.inputText") private var inputText = ""
    @StudioState("EmbeddingsView.vectors") private var vectors: [(input: String, embedding: [Double])] = []
    @StudioState("EmbeddingsView.requestedDimensions") private var requestedDimensions = ""
    @StudioState("EmbeddingsView.inputType") private var inputType = ""
    @StudioState("EmbeddingsView.embedUsage") private var embedUsage: ImageGenUsage? = nil
    @StudioState("EmbeddingsView.pendingEmbedding") private var pendingEmbedding: (payload: Data, model: String, prompt: String)? = nil
    @StudioState("EmbeddingsView.rerankQuery") private var rerankQuery = ""
    @StudioState("EmbeddingsView.rerankDocs") private var rerankDocs = ""
    @StudioState("EmbeddingsView.rerankResults") private var rerankResults: [RerankResponse.Item] = []
    @StudioState("EmbeddingsView.rankedDocuments") private var rankedDocuments: [String] = []
    @StudioState("EmbeddingsView.topN") private var topN = ""
    @StudioState("EmbeddingsView.rerankUsage") private var rerankUsage: RerankResponse.Usage? = nil
    @StudioState("EmbeddingsView.rerankProvider") private var rerankProvider: String? = nil
    @StudioState("EmbeddingsView.isSaving") private var isSaving = false
    @StudioState("EmbeddingsView.errorMessage") private var errorMessage: String? = nil

    private let accent = ORBTheme.accent

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
                     icon: "chart.dots.scatter", accent: accent) {
            StudioPresetMenu(
                studio: .embeddings,
                snapshot: {
                    StudioPreset.embeddingsSettings(model: modelId, dimensions: requestedDimensions, inputType: inputType,
                                                    rerankModel: rerankModelId, topN: topN)
                },
                apply: { preset in
                    let v = EmbeddingsPresetValues(preset)
                    if !v.model.isEmpty { modelId = v.model }
                    requestedDimensions = v.dimensions; inputType = v.inputType
                    if !v.rerankModel.isEmpty { rerankModelId = v.rerankModel }
                    topN = v.topN
                })
        }
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
                        .background(.orbSurface(0.04))
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
                StudioNotifier.shared.finished(section: SidebarSection.embeddings.rawValue, title: "Embeddings ready", body: "Your embeddings finished.")
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
