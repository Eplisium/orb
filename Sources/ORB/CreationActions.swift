import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared creation actions
//
// One set of file actions for every place a saved creation appears (Library
// grid/list, studio result cards): drag out to Finder, Copy, Reveal in
// Finder, Share. All of them work on the stored file through
// `SavedCreationsStore.fileURL(for:)` — never by reading bytes into memory.

@MainActor
enum CreationActions {
    /// Friendly-named copy of the stored file, so drags, shares and Quick
    /// Look don't surface a bare checksum filename — and can never modify the
    /// content-addressed original. On APFS `copyItem` is a copy-on-write
    /// clone, so this costs no extra space or time. Lives in Caches and is
    /// pruned after a day.
    static var stagingDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ORB/OutgoingCreations", isDirectory: true)
    }

    static func stagedFileURL(for creation: SavedCreation, in store: SavedCreationsStore) throws -> URL {
        let source = try store.fileURL(for: creation)
        let fm = FileManager.default
        let folder = stagingDirectory.appendingPathComponent(creation.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(LibraryExport.fileName(for: creation))
        if fm.fileExists(atPath: target.path) { return target }
        try fm.copyItem(at: source, to: target)
        return target
    }

    /// Removes staged files older than `maxAge` (best-effort).
    static func pruneStaging(olderThan maxAge: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > maxAge { try? fm.removeItem(at: entry) }
        }
    }

    /// Quick Look preview of the staged, friendly-named copy (STUDIO-1).
    /// Raw PCM has nothing safe to preview and is refused.
    @discardableResult
    static func open(_ creation: SavedCreation, in store: SavedCreationsStore) -> Bool {
        guard LibraryPreview.canQuickLook(creation),
              let url = try? stagedFileURL(for: creation, in: store) else { return false }
        return QuickLookPreview.shared.show(fileURLs: [url])
    }

    /// Item titles in menu order, so tests can assert the shared menu.
    static func menuTitles(for creation: SavedCreation, canOpenInStudio: Bool) -> [String] {
        var titles: [String] = []
        if LibraryPreview.canQuickLook(creation) { titles.append("Open") }
        if canOpenInStudio, StudioReusePlan.plan(for: creation) != nil { titles.append("Open in Studio") }
        titles += [creation.kind == .image ? "Copy Image" : "Copy File", "Reveal in Finder", "Share…"]
        return titles
    }

    static func reveal(_ creation: SavedCreation, in store: SavedCreationsStore) {
        guard let url = try? store.fileURL(for: creation) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies an image as image data AND as a file URL (so it pastes into
    /// both image editors and Finder); other kinds copy the file.
    @discardableResult
    static func copy(_ creation: SavedCreation, in store: SavedCreationsStore) -> Bool {
        guard let url = try? stagedFileURL(for: creation, in: store) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [url as NSURL]
        if creation.kind == .image, let image = NSImage(contentsOf: url) { objects.insert(image, at: 0) }
        let ok = pasteboard.writeObjects(objects)
        if ok { AppToasts.center.show(creation.kind == .image ? "Image copied" : "File copied", kind: .success) }
        return ok
    }

    /// Shows the system share picker anchored at the mouse in the key window.
    static func share(_ creation: SavedCreation, in store: SavedCreationsStore) {
        guard let url = try? stagedFileURL(for: creation, in: store),
              let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let point = view.convert(NSApp.keyWindow?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        picker.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    /// File-URL item provider for drag-out to Finder and other apps.
    static func itemProvider(for creation: SavedCreation, in store: SavedCreationsStore) -> NSItemProvider {
        guard let url = try? stagedFileURL(for: creation, in: store),
              let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

/// Menu items shared by Library context menus and studio card menus.
struct CreationActionItems: View {
    let creation: SavedCreation
    let store: SavedCreationsStore
    /// Re-run in the matching studio (STUDIO-13); nil hides the item.
    var openInStudio: ((SavedCreation) -> Void)? = nil

    var body: some View {
        if LibraryPreview.canQuickLook(creation) {
            Button("Open") { CreationActions.open(creation, in: store) }
        }
        if let openInStudio, StudioReusePlan.plan(for: creation) != nil {
            Button("Open in Studio") { openInStudio(creation) }
        }
        Button(creation.kind == .image ? "Copy Image" : "Copy File") { CreationActions.copy(creation, in: store) }
        Button("Reveal in Finder") { CreationActions.reveal(creation, in: store) }
        Button("Share…") { CreationActions.share(creation, in: store) }
    }
}

/// Compact "…" menu for result cards.
struct CreationActionsMenu: View {
    let creation: SavedCreation
    let store: SavedCreationsStore
    var onError: (String) -> Void = { _ in }
    var openInStudio: ((SavedCreation) -> Void)? = nil

    var body: some View {
        Menu {
            CreationActionItems(creation: creation, store: store, openInStudio: openInStudio)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
        .help("Open, copy, reveal in Finder, or share")
    }
}

extension View {
    /// Drag the creation's file out to Finder or another app.
    func creationDrag(_ creation: SavedCreation, store: SavedCreationsStore) -> some View {
        onDrag { CreationActions.itemProvider(for: creation, in: store) }
    }
}

// MARK: - In-studio video playback (STUDIO-1)

/// A saved video's poster frame; clicking it plays the video inline with
/// AVKit controls. The player plays the staged friendly-named copy, never
/// the content-addressed original, and stops when the card leaves screen.
struct SavedVideoPlayerCard: View {
    let creation: SavedCreation
    let store: SavedCreationsStore
    var height: CGFloat = 180
    @State private var player: AVPlayer?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Button(action: start) {
                        LibraryThumbnail(creation: creation, store: store, maxPixel: 640)
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(.largeTitle))
                                    .foregroundStyle(.white, .black.opacity(0.45))
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play video")
                    .help("Play")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: ORBMetrics.radiusMD))
            if let failure {
                Text(failure).font(ORBFont.caption).foregroundStyle(ORBTheme.warning)
            }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private func start() {
        do {
            let url = try CreationActions.stagedFileURL(for: creation, in: store)
            let player = AVPlayer(url: url)
            self.player = player
            failure = nil
            player.play()
        } catch {
            failure = "Couldn't play this video: \(error.localizedDescription)"
        }
    }
}
