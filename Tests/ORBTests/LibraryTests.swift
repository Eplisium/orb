import Testing
import SwiftUI
import Foundation
@testable import ORB

private func item(_ kind: SavedCreation.Kind, model: String = "a/m", prompt: String? = nil,
                  mime: String = "image/png", at: TimeInterval = 0) -> SavedCreation {
    SavedCreation(id: UUID(), kind: kind, modelID: model, prompt: prompt, mimeType: mime,
                  createdAt: Date(timeIntervalSince1970: at), assetPath: "ab/cd", checksum: "x")
}

@Suite("Library: filtering and search")
struct LibraryQueryTests {
    private let items = [
        item(.image, model: "x/flux", prompt: "A red fox in snow", at: 30),
        item(.video, model: "y/vid", prompt: "Waves at dusk", mime: "video/mp4", at: 20),
        item(.transcript, model: "z/whisper", prompt: nil, mime: "application/json", at: 10),
    ]

    @Test("No query and no type filter keeps everything, newest first")
    func all() {
        let r = LibraryQuery().apply(to: items)
        #expect(r.map(\.kind) == [.image, .video, .transcript])
    }

    @Test("Type filter narrows to the chosen kinds")
    func kinds() {
        var q = LibraryQuery(); q.kinds = [.video, .transcript]
        #expect(q.apply(to: items).map(\.kind) == [.video, .transcript])
    }

    @Test("Search matches prompt or model, case-insensitively and across words")
    func search() {
        var q = LibraryQuery(); q.text = "FOX snow"
        #expect(q.apply(to: items).map(\.kind) == [.image])
        q.text = "whisper"
        #expect(q.apply(to: items).map(\.kind) == [.transcript])
        q.text = "nothing matches this"
        #expect(q.apply(to: items).isEmpty)
    }

    @Test("Sort options: oldest first and by model")
    func sorting() {
        var q = LibraryQuery(); q.sort = .oldest
        #expect(q.apply(to: items).map(\.kind) == [.transcript, .video, .image])
        q.sort = .model
        #expect(q.apply(to: items).map(\.modelID) == ["x/flux", "y/vid", "z/whisper"])
    }

    @Test("Counts per kind, ignoring the current filter, so chips can show totals")
    func counts() {
        let c = LibraryQuery.counts(items + [item(.image)])
        #expect(c[.image] == 2 && c[.video] == 1 && c[.audio] == nil)
    }

    @Test("Active-filter description reads out what is applied")
    func description() {
        #expect(LibraryQuery().summary(shown: 3, total: 3) == "3 items")
        var q = LibraryQuery(); q.kinds = [.image]; q.text = "fox"
        #expect(q.summary(shown: 1, total: 3) == "1 of 3 items · Image · “fox”")
        #expect(LibraryQuery().summary(shown: 1, total: 1) == "1 item")
        #expect(q.isFiltering)
        #expect(!LibraryQuery().isFiltering)
    }

    @Test("Clearing resets text and kinds but keeps the sort")
    func clear() {
        var q = LibraryQuery(); q.kinds = [.audio]; q.text = "x"; q.sort = .oldest
        q.clear()
        #expect(q.kinds.isEmpty && q.text.isEmpty && q.sort == .oldest)
    }
}

@Suite("Library: selection")
struct LibrarySelectionTests {
    private let ids = (0..<5).map { _ in UUID() }

    @Test("Toggle, select all visible, and clear")
    func basics() {
        var s = LibrarySelection()
        s.toggle(ids[0]); s.toggle(ids[1])
        #expect(s.count == 2 && s.contains(ids[0]))
        s.toggle(ids[0])
        #expect(!s.contains(ids[0]))
        s.selectAll(ids)
        #expect(s.count == 5)
        s.clear()
        #expect(s.isEmpty)
    }

    @Test("Pruning drops IDs that are no longer visible, so a filter never leaves hidden selections")
    func prune() {
        var s = LibrarySelection(); s.selectAll(ids)
        s.prune(toVisible: Array(ids.prefix(2)))
        #expect(s.count == 2)
    }

    @Test("Range select from the anchor to a clicked row, in either direction")
    func range() {
        var s = LibrarySelection()
        s.toggle(ids[1])
        s.extend(to: ids[3], in: ids)
        #expect(s.ids == Set(ids[1...3]))
        var t = LibrarySelection(); t.toggle(ids[3]); t.extend(to: ids[1], in: ids)
        #expect(t.ids == Set(ids[1...3]))
    }

    @Test("Range select with no anchor just selects the target")
    func rangeNoAnchor() {
        var s = LibrarySelection(); s.extend(to: ids[2], in: ids)
        #expect(s.ids == [ids[2]])
    }
}

@Suite("Library: bulk export planning")
struct LibraryExportPlanTests {
    @Test("File names come from kind, date and a short ID, never from the prompt")
    func names() {
        let c = item(.image, prompt: "../../etc/passwd; rm -rf /", mime: "image/png", at: 1_790_866_800)
        let name = LibraryExport.fileName(for: c, calendar: utc)
        #expect(name.hasSuffix(".png"))
        #expect(name.hasPrefix("orb-image-2026-10-01-"))
        #expect(!name.contains("/") && !name.contains("passwd") && !name.contains(" "))
    }

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }

    @Test("Colliding names are made unique instead of overwriting")
    func collisions() {
        var taken: Set<String> = ["orb-image-a.png"]
        #expect(LibraryExport.unique("orb-image-a.png", taken: &taken) == "orb-image-a-2.png")
        #expect(LibraryExport.unique("orb-image-a.png", taken: &taken) == "orb-image-a-3.png")
        #expect(LibraryExport.unique("fresh.png", taken: &taken) == "fresh.png")
    }

    @Test("Plan pairs every creation with a distinct destination name")
    func plan() {
        let a = item(.image, at: 5), b = item(.image, at: 5)
        let plan = LibraryExport.plan([a, b], calendar: utc)
        #expect(plan.count == 2)
        #expect(Set(plan.map(\.fileName)).count == 2)
    }

    @Test("Result text states exactly how many were written and which failed")
    func result() {
        #expect(LibraryExport.resultText(written: 3, failed: []) == "Exported 3 items")
        #expect(LibraryExport.resultText(written: 1, failed: []) == "Exported 1 item")
        #expect(LibraryExport.resultText(written: 2, failed: ["a.png"]) == "Exported 2 items; 1 failed (a.png)")
        #expect(LibraryExport.resultText(written: 0, failed: ["a", "b"]) == "Nothing exported; 2 failed")
    }

    @Test("Writing goes to a chosen folder, never overwrites, and reports failures")
    func write() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orb-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = item(.transcript, mime: "application/json", at: 1), b = item(.transcript, mime: "application/json", at: 1)
        let plan = LibraryExport.plan([a, b], calendar: utc)
        let payload: (SavedCreation) throws -> Data = { c in
            if c.id == b.id { throw CocoaError(.fileReadUnknown) }
            return Data("hi".utf8)
        }
        let outcome = LibraryExport.write(plan, to: dir, data: payload)
        #expect(outcome.written == 1 && outcome.failed.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
        // A second run must not overwrite the first file.
        let again = LibraryExport.write([plan[0]], to: dir, data: { _ in Data("different".utf8) })
        #expect(again.written == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }
}

@Suite("Library: Quick Look")
struct LibraryPreviewTests {
    @Test("Space previews the selected item; with several selected it previews the first visible one")
    func target() {
        let a = item(.image), b = item(.video)
        #expect(LibraryPreview.target(selection: [b.id], visible: [a, b])?.id == b.id)
        #expect(LibraryPreview.target(selection: [a.id, b.id], visible: [a, b])?.id == a.id)
        #expect(LibraryPreview.target(selection: [], visible: [a, b]) == nil)
    }

    @Test("Preview file name keeps the right extension so Quick Look recognises the type")
    func previewName() {
        let c = item(.video, mime: "video/mp4")
        #expect(LibraryPreview.fileName(for: c).hasSuffix(".mp4"))
        #expect(!LibraryPreview.canQuickLook(item(.audio, mime: "audio/pcm")), "raw PCM has no container")
        #expect(LibraryPreview.canQuickLook(item(.audio, mime: "audio/wav")))
    }
}

@MainActor
@Suite("Library: render smoke", .serialized)
struct LibraryRenderTests {
    @Test("Chips, cost bar and thumbnail placeholder render in light and dark")
    func renders() {
        for scheme in [ColorScheme.light, .dark] {
            let views: [AnyView] = [
                AnyView(Button("Image 3") {}.buttonStyle(StudioChipButtonStyle(isSelected: true))),
                AnyView(Button("Video 1") {}.buttonStyle(StudioChipButtonStyle(isSelected: false))),
                AnyView(CostCeilingBar(progress: CostCeilingProgress(spent: 0.45, ceiling: 0.5))),
                AnyView(CostCeilingBar(progress: CostCeilingProgress(spent: 0.7, ceiling: 0.5))),
            ]
            for v in views {
                let r = ImageRenderer(content: v.environment(\.colorScheme, scheme).frame(width: 320))
                r.scale = 1
                #expect(r.nsImage != nil)
            }
        }
    }
}
