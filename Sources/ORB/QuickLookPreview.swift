import AppKit
import Quartz

/// Shows library items in the system Quick Look panel. Files are written to the
/// caches directory (never next to user data) and removed again when the panel closes.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()

    private var urls: [URL] = []
    /// False when showing caller-owned files that must not be deleted.
    private var ownsFiles = true

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ORB/CreationPreviews", isDirectory: true)
    }

    /// Writes `data` and shows it. Returns false if the file could not be written.
    @discardableResult
    func show(_ items: [(creation: SavedCreation, data: Data)]) -> Bool {
        guard !items.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            var written: [URL] = []
            for item in items {
                let url = Self.directory.appendingPathComponent(LibraryPreview.fileName(for: item.creation))
                try item.data.write(to: url, options: .atomic)
                written.append(url)
            }
            urls = written
        } catch {
            return false
        }
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    /// Shows files that already exist on disk (e.g. staged creation links).
    /// They are not deleted on close — the staging area is pruned separately.
    @discardableResult
    func show(fileURLs: [URL]) -> Bool {
        guard !fileURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return false }
        cleanUp()
        urls = fileURLs
        ownsFiles = false
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func cleanUp() {
        guard ownsFiles else { urls = []; ownsFiles = true; return }
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { cleanUp() }
    }
}
