import AppKit
import Foundation
import Testing
@testable import ORB

private func creation(_ kind: SavedCreation.Kind = .image, age: TimeInterval) -> SavedCreation {
    let checksum = String(repeating: "a", count: 64)
    return SavedCreation(id: UUID(), kind: kind, modelID: "m", prompt: nil, mimeType: "image/png",
                         createdAt: Date(timeIntervalSince1970: 1_000_000 - age),
                         assetPath: "aa/\(checksum).png", checksum: checksum)
}

@Suite("Images gallery limits")
struct ImageGalleryTests {
    @Test("shows only the latest 24 saved images, newest first, and counts the rest")
    func latestTwentyFour() {
        let images = (0..<40).map { creation(age: TimeInterval($0)) }
        let others = [creation(.video, age: 0), creation(.audio, age: 1)]
        let (items, hidden) = ImageGallery.recentSaved((images + others).shuffled(), excluding: [])
        #expect(items.count == 24)
        #expect(hidden == 16)
        #expect(items.map(\.id) == images.prefix(24).map(\.id))
        #expect(items.allSatisfy { $0.kind == .image })
    }

    @Test("session results are not duplicated in the saved section")
    func excludesSession() {
        let images = (0..<3).map { creation(age: TimeInterval($0)) }
        let (items, hidden) = ImageGallery.recentSaved(images, excluding: [images[0].id])
        #expect(items.map(\.id) == [images[1].id, images[2].id])
        #expect(hidden == 0)
    }

    @Test("a saved session result disappears when deleted in Library; unsaved ones stay")
    func reflectsDeletions() {
        let live: Set<UUID> = [UUID()]
        #expect(ImageGallery.isVisible(savedID: nil, liveIDs: live))
        #expect(ImageGallery.isVisible(savedID: live.first, liveIDs: live))
        #expect(!ImageGallery.isVisible(savedID: UUID(), liveIDs: live))
    }

    @Test("count splits into per-request chunks")
    func chunks() {
        #expect(ImageGallery.chunks(total: 10, perRequest: 4) == [4, 4, 2])
        #expect(ImageGallery.chunks(total: 3, perRequest: 0) == [1, 1, 1])
        #expect(ImageGallery.chunks(total: 0, perRequest: 4) == [])
    }
}

@Suite("Image run summary")
struct ImageRunSummaryTests {
    @Test("full success has no summary")
    func success() {
        var s = ImageRunSummary(requested: 4)
        s.delivered = 4
        #expect(s.text == nil)
    }

    @Test("partial failure names the count and distinct reasons")
    func partialFailure() {
        var s = ImageRunSummary(requested: 4)
        s.delivered = 1
        s.recordFailure("Rate limited.", images: 2)
        s.recordFailure("Content policy.", images: 1)
        s.recordFailure("Rate limited.", images: 0)
        let text = try! #require(s.text)
        #expect(text.hasPrefix("3 of 4 images failed: "))
        #expect(text.contains("Rate limited."))
        #expect(text.contains("Content policy."))
        #expect(s.failures.count == 2)
    }

    @Test("cancellation reports what arrived")
    func cancelled() {
        var s = ImageRunSummary(requested: 4)
        s.delivered = 2
        s.cancelled = 2
        #expect(s.text == "Cancelled — 2 of 4 arrived.")
    }

    @Test("provider returning fewer images than asked is surfaced")
    func shortDelivery() {
        var s = ImageRunSummary(requested: 4)
        s.delivered = 3
        #expect(s.text?.contains("3 of 4") == true)
    }
}

@Suite("Creation thumbnails")
struct CreationThumbnailTests {
    @Test("ImageIO thumbnail is downsampled to the requested size and cached")
    func downsampledAndCached() async throws {
        let size = 1200
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size / 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-thumb-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png.write(to: url)

        let thumbs = CreationThumbnails()
        let id = UUID()
        #expect(thumbs.cached(id: id, maxPixel: 200) == nil)
        let image = try #require(await thumbs.thumbnail(id: id, fileURL: url, maxPixel: 200))
        #expect(max(image.size.width, image.size.height) <= 200)
        #expect(thumbs.cached(id: id, maxPixel: 200) != nil)
        // A different requested size is a separate entry.
        #expect(thumbs.cached(id: id, maxPixel: 400) == nil)
    }

    @Test("non-image bytes produce no thumbnail")
    func garbage() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orb-thumb-bad-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not an image".utf8).write(to: url)
        #expect(CreationThumbnails.decode(fileURL: url, maxPixel: 100) == nil)
    }
}

@Suite("Library export by file copy")
struct LibraryExportCopyTests {
    @Test("copies files with unique names and never overwrites")
    func copiesWithoutOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orb-export-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.bin")
        try Data("payload".utf8).write(to: source)
        let items = [creation(age: 0), creation(age: 1)]
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let plan = LibraryExport.plan(items)
        let first = LibraryExport.copy(plan, to: out) { _ in source }
        #expect(first.written == 2 && first.failed.isEmpty)
        let again = LibraryExport.copy([plan[0]], to: out) { _ in source }
        #expect(again.written == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(names.count == 3)
        let failing = LibraryExport.copy([plan[1]], to: out) { _ in throw AssetStoreError.missing(relativePath: "x") }
        #expect(failing.written == 0 && failing.failed.count == 1)
    }
}
