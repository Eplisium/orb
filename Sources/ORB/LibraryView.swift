import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

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
func exportCreation(_ data: Data, creation: SavedCreation) throws {
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
        .focusEffectDisabled()
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(visible) { cell($0) }
                    }
                    .padding(.trailing, 2)
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
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Text(subtitle).font(ORBFont.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .task(id: creation.id) {
                guard creation.kind == .image, image == nil,
                      let data = try? await store.data(for: creation) else { return }
                image = NSImage(data: data)
            }
    }
}
