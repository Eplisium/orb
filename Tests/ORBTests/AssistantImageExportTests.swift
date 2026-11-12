import AppKit
import Testing
@testable import ORB

@Suite("Assistant image export", .serialized)
@MainActor
struct AssistantImageExportTests {
    private func image() throws -> NSImage {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 {
            for y in 0..<2 { rep.setColor(.red, atX: x, y: y) }
        }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(rep)
        return image
    }

    private func fixture() throws -> (URL, SavedCreationsStore) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("ORB-card-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = DatabaseManager(path: ":memory:")
        let assets = AssetStore(baseDirectory: root.appendingPathComponent("Assets"), database: db)
        return (root, try SavedCreationsStore(assetStore: assets, indexURL: root.appendingPathComponent("creations.json")))
    }

    @Test("E07: suggested suffix describes the re-encoded bytes",
          arguments: ["image/png", "image/jpeg", "image/webp", "image/gif", "image/svg+xml"])
    func encodedFormat(mime: String) throws {
        let attachment = ChatImageAttachment(dataURL: "data:\(mime);base64,AA==")
        let export = try AssistantImageExport(image: image(), attachment: attachment)
        let jpeg = mime == "image/jpeg"
        #expect(export.fileExtension == (jpeg ? "jpg" : "png"))
        #expect(export.contentType.identifier == (jpeg ? "public.jpeg" : "public.png"))
        #expect(Array(export.data.prefix(jpeg ? 3 : 8)) ==
                (jpeg ? [0xff, 0xd8, 0xff] : [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
        #expect(NSBitmapImageRep(data: export.data) != nil)
    }

    @Test("E06: write failure throws instead of reporting export success")
    func failedWrite() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = try AssistantImageExport(image: image(), attachment: ChatImageAttachment(dataURL: ""))
        let existing = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)
        #expect(throws: Error.self) { try export.write(to: root, store: store) }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
    }

    @Test("E06: card export cannot overwrite managed asset or manifest", arguments: ["asset", "manifest"])
    func protectsLibrary(target: String) async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try await store.save(Data("saved".utf8), mimeType: "text/plain", kind: .transcript,
                                        modelID: "fixture", prompt: nil)
        let destination = target == "asset" ? try store.fileURL(for: item) : root.appendingPathComponent("creations.json")
        let before = try Data(contentsOf: destination)
        let export = try AssistantImageExport(image: image(), attachment: ChatImageAttachment(dataURL: ""))
        #expect(throws: Error.self) { try export.write(to: destination, store: store) }
        #expect(try Data(contentsOf: destination) == before)
    }

    @Test("Card export replaces an ordinary file without first saving to Library")
    func successfulWrite() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("export.png")
        try Data("old".utf8).write(to: destination)
        let export = try AssistantImageExport(image: image(), attachment: ChatImageAttachment(dataURL: ""))
        try export.write(to: destination, store: store)
        #expect(try Data(contentsOf: destination) == export.data)
        #expect(store.creations.isEmpty)
    }

    @Test("Undecodable image cannot produce an export")
    func invalidImage() {
        #expect(throws: Error.self) {
            try AssistantImageExport(image: NSImage(), attachment: ChatImageAttachment(dataURL: ""))
        }
    }
}
