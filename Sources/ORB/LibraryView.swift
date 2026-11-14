import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// Local outputs are intentionally not mixed with OpenRouter's remote Files API.
func creationExtension(_ creation: SavedCreation) -> String {
    // Same table the asset store names files with; only a type it does not
    // know falls back to a plain-text name.
    MediaFileExtension.forMIMEType(creation.mimeType) ?? "txt"
}

@MainActor
func exportCreation(_ creation: SavedCreation, store: SavedCreationsStore) throws {
    let panel = NSSavePanel()
    panel.title = "Export Saved Creation"
    panel.nameFieldStringValue = "orb-\(creation.id.uuidString).\(creationExtension(creation))"
    if panel.runModal() == .OK, let url = panel.url {
        try store.export(creation, to: url)
    }
}

struct SavedCreationsLibraryView: View {
    @ObservedObject private var store = SavedCreationsStore.shared
    @AppStorage("orb.library.layout") private var layout = LibraryLayout.grid.rawValue
    @State private var query = LibraryQuery()
    @State private var selection = LibrarySelection()
    @State private var errorMessage: String?
    @State private var gridWidth: CGFloat = 0
    /// Set by "Show in Library" from a studio or the job tray (STUDIO-4).
    @StudioState(StudioNavigation.libraryFocusKey) private var focusID: UUID? = nil
    @EnvironmentObject private var shell: ShellController
    @State private var pendingDelete: [SavedCreation]?
    @State private var undoPresentation = LibraryUndoPresentation()
    @State private var maintenanceObserver = UUID()
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
            if let error = undoPresentation.errorMessage {
                PlaygroundErrorBanner(message: error) { undoPresentation.clearError() }
            }
            if let loadError = store.loadError {
                Label(loadError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(ORBFont.caption).foregroundStyle(ORBTheme.danger)
            }
            if !store.reclamationStatus.isEmpty {
                Text(store.reclamationStatus).font(ORBFont.caption).foregroundStyle(.secondary)
            }
            if store.cleanupWarning != nil || store.exportWarning != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let warning = store.cleanupWarning {
                        Text(warning).font(ORBFont.caption).foregroundStyle(ORBTheme.danger)
                    }
                    if let warning = store.exportWarning {
                        Text(warning).font(ORBFont.caption).foregroundStyle(ORBTheme.danger)
                    }
                    Button("Retry cleanup / export") { Task { await store.retryMaintenance() } }
                }
            }
            content
        }
        .padding(16)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { store.startForegroundMaintenance(observer: maintenanceObserver) }
        .onKeyPress(.space) {
            guard let target = LibraryPreview.target(selection: selection.ids, anchor: selection.anchorID,
                                                     visible: visible) else { return .ignored }
            open(target, previewSelection: true); return .handled
        }
        // Finder keys (STUDIO-7): Esc clears, ⌘A selects all, arrows move.
        .onExitCommand { selection.clear() }
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection.selectAll(visible.map(\.id)) }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let columns = isGrid ? LibraryPreview.gridColumns(width: gridWidth) : 1
            let offset: Int
            switch press.key {
            case .leftArrow: offset = isGrid ? -1 : 0
            case .rightArrow: offset = isGrid ? 1 : 0
            case .upArrow: offset = -columns
            default: offset = columns
            }
            guard offset != 0 else { return .ignored }
            selection.move(by: offset, in: visible.map(\.id), extending: press.modifiers.contains(.shift))
            return .handled
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
            Text("Undo is available for 8 seconds. Unowned files in managed storage are then reclaimed. Shared files and legacy storage are retained; see the Library storage status.")
        }
        .overlay(alignment: .bottom) {
            if let removed = undoPresentation.current {
                UndoToastView(
                    message: LibraryDelete.message(count: removed.creations.count),
                    token: removed.token.id,
                    expiresAt: removed.expiresAt,
                    isBusy: undoPresentation.isRestoring,
                    undo: { undoDelete(removed) },
                    dismiss: { finalizeDelete(removed) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear {
            store.stopForegroundMaintenance(observer: maintenanceObserver)
            if let removed = undoPresentation.current { finalizeDelete(removed) }
        }
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
                Button("Refresh") { Task { await store.retryMaintenance() } }
                    .help("Reload Library from SQLite and retry cleanup and JSON export")
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
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if isGrid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                                ForEach(visible) { cell($0).id($0.id) }
                            }
                            .padding(.trailing, 2)
                        } else {
                            LazyVStack(spacing: 6) { ForEach(visible) { row($0).id($0.id) } }
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { gridWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, width in gridWidth = width }
                    })
                    // Clicking empty space clears the selection, as in Finder.
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { selection.clear(); focused = true }
                }
                .onChange(of: selection.anchorID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
                .task(id: focusID) { applyFocus(proxy) }
            }
        }
    }

    /// Finder-like click (STUDIO-7). One gesture reads the click count, so a
    /// single click selects immediately instead of waiting out a double-tap.
    private func tap(_ c: SavedCreation) {
        let mods = NSEvent.modifierFlags
        if NSApp.currentEvent?.clickCount == 2 {
            selection.select(c.id)
            open(c)
        } else {
            selection.click(c.id, command: mods.contains(.command), shift: mods.contains(.shift),
                            in: visible.map(\.id))
        }
        focused = true
    }

    /// Selects and scrolls to a creation requested by "Show in Library".
    private func applyFocus(_ proxy: ScrollViewProxy) {
        guard let id = focusID else { return }
        if store.creations.contains(where: { $0.id == id }) {
            query.clear()
            selection.select(id)
            proxy.scrollTo(id, anchor: .center)
        }
        focusID = nil
    }

    private func label(_ c: SavedCreation) -> String { c.prompt.flatMap { $0.isEmpty ? nil : $0 } ?? c.kind.title }

    private func cell(_ c: SavedCreation) -> some View {
        let on = selection.contains(c.id)
        let accent = ORBTheme.accent
        let fill: Color = on ? accent.opacity(0.14) : Color.clear
        let ring: AnyShapeStyle = on ? AnyShapeStyle(accent) : AnyShapeStyle(.orbSurface(0.08))
        let subtitle = CreationIdentity.metadata(for: c, includeKind: false)
        let shape = RoundedRectangle(cornerRadius: 10)

        let card = VStack(alignment: .leading, spacing: 6) {
            LibraryThumbnail(creation: c, store: store)
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(.orbSurface(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(CreationIdentity.title(for: c)).font(ORBFont.footnote.weight(.medium)).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Text(subtitle).font(ORBFont.caption).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(fill, in: shape)
        .overlay(shape.stroke(ring, lineWidth: on ? 2 : 1))
        .contentShape(Rectangle())

        return card
            .creationDrag(c, store: store)
            .onTapGesture { tap(c) }
            .contextMenu { itemMenu(c) }
            .help(label(c))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(CreationIdentity.accessibilityLabel(for: c))
            .accessibilityHint(c.prompt ?? "")
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityAction(named: "Open") { open(c) }
            .accessibilityAction(named: on ? "Deselect" : "Select") { selection.toggle(c.id) }
    }

    private func row(_ c: SavedCreation) -> some View {
        let on = selection.contains(c.id)
        return HStack(spacing: 12) {
            LibraryThumbnail(creation: c, store: store, maxPixel: 120)
                .frame(width: 44, height: 44)
                .background(.orbSurface(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if on {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, ORBTheme.accent)
                            .padding(2)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(CreationIdentity.title(for: c)).font(ORBFont.footnote.weight(.medium)).lineLimit(1)
                Text(CreationIdentity.metadata(for: c))
                    .font(ORBFont.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(label(c))
            Spacer()
            Button("Open") { open(c) }
            Button("Export…") { export(c) }
        }
        .padding(10)
        .background(on ? ORBTheme.accent.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { tap(c) }
        .creationDrag(c, store: store)
        .contextMenu { itemMenu(c) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CreationIdentity.accessibilityLabel(for: c))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func itemMenu(_ c: SavedCreation) -> some View {
        Button("Export…") { export(c) }
        CreationActionItems(creation: c, store: store,
                            openInStudio: { StudioNavigation.openInStudio($0, shell: shell) })
        Divider()
        Button(selection.contains(c.id) ? "Deselect" : "Select") { selection.toggle(c.id) }
        Button("Delete…", role: .destructive) {
            pendingDelete = selection.contains(c.id) ? visible.filter { selection.contains($0.id) } : [c]
        }
        if let prompt = c.prompt, !prompt.isEmpty { Button("Copy Prompt") { AppToasts.copy(prompt, what: "Prompt") } }
    }

    // MARK: Actions

    private func open(_ creation: SavedCreation, previewSelection: Bool = false) {
        guard LibraryPreview.canQuickLook(creation) else {
            errorMessage = "Raw PCM audio has no container or sample-rate metadata for safe playback. Export the .pcm bytes instead."
            return
        }
        do {
            // Space previews the whole selection; double-click previews one item.
            // Files are cloned from the library, never read into memory.
            // The clicked/anchor item is shown first, then the rest in order.
            let group = previewSelection && selection.contains(creation.id) && selection.count > 1
                ? [creation] + visible.filter { $0.id != creation.id && selection.contains($0.id) && LibraryPreview.canQuickLook($0) }
                : [creation]
            let urls = try group.map { try CreationActions.stagedFileURL(for: $0, in: store) }
            guard QuickLookPreview.shared.show(fileURLs: urls) else { throw CocoaError(.fileReadUnknown) }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Copies the stored file to the chosen location (no in-memory read).
    private func export(_ creation: SavedCreation) {
        let panel = NSSavePanel()
        panel.title = "Export Saved Creation"
        panel.nameFieldStringValue = LibraryExport.fileName(for: creation)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(creation, to: url) }
        catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ items: [SavedCreation]) {
        pendingDelete = nil
        // Preserve the previous Undo if this deletion fails. Only a committed
        // replacement finalizes the old presentation, and never a busy restore.
        Task {
            do {
                let removed = try await store.removeWithUndo(ids: Set(items.map(\.id)))
                guard !removed.creations.isEmpty else { return }
                selection.clear()
                // A delete begun while another was committing can arrive later.
                // Finalize the displayed generation, never an in-flight restore.
                if let previous = undoPresentation.current { finalizeDelete(previous) }
                undoPresentation.present(removed)
            } catch {
                errorMessage = "Couldn't delete: \(error.localizedDescription). Nothing was removed."
            }
        }
    }

    private func undoDelete(_ removed: LibraryRemoval) {
        guard undoPresentation.current?.token == removed.token,
              let captured = undoPresentation.beginUndo(at: Date()) else { return }
        Task {
            do {
                try await store.restore(captured.token)
                undoPresentation.completeUndo(captured.token, error: nil)
            } catch { undoPresentation.completeUndo(captured.token, error: error) }
        }
    }

    private func finalizeDelete(_ removed: LibraryRemoval) {
        guard undoPresentation.dismiss(removed.token) else { return }
        Task {
            do {
                try await store.finalize(removed.token)
                undoPresentation.completeDismiss(removed.token, error: nil)
            } catch { undoPresentation.completeDismiss(removed.token, error: error) }
        }
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
        // Copy stored files directly (validated paths; nothing read into memory).
        let outcome = LibraryExport.copy(LibraryExport.plan(chosen), to: folder, store: store)
        let text = LibraryExport.resultText(written: outcome.written, failed: outcome.failed)
        if outcome.failed.isEmpty { AppToasts.center.show(text, kind: .success) }
        else { errorMessage = text }
    }
}

enum LibraryLayout: String { case grid, list }

/// Thumbnails are decoded lazily for images and videos (poster frame);
/// other kinds show their symbol. Decoding is a downsampled ImageIO thumbnail of the stored file,
/// cached in memory — no full decode or checksum per cell.
struct LibraryThumbnail: View {
    let creation: SavedCreation
    let store: SavedCreationsStore
    var maxPixel: Int = 320
    @State private var image: NSImage?

    var body: some View {
        // Color.clear defines the size; the image is only an overlay, so a
        // scaledToFill image can never widen its grid cell.
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: creation.kind.symbol).font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .overlay {
                if creation.kind == .video, image != nil {
                    Image(systemName: "play.circle.fill")
                        .font(ORBFont.title2)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .accessibilityHidden(true)
                }
            }
            .task(id: creation.id) {
                guard creation.kind == .image || creation.kind == .video, image == nil else { return }
                if let hit = CreationThumbnails.shared.cached(id: creation.id, maxPixel: maxPixel) { image = hit; return }
                guard let url = try? store.fileURL(for: creation) else { return }
                if creation.kind == .video {
                    image = await CreationThumbnails.shared.videoPoster(id: creation.id, fileURL: url,
                                                                        mimeType: creation.mimeType, maxPixel: maxPixel)
                } else {
                    image = await CreationThumbnails.shared.thumbnail(id: creation.id, fileURL: url, maxPixel: maxPixel)
                }
            }
    }
}
