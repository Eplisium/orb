import SwiftUI
import Foundation

// MARK: - Shared Library (Phase 6)

extension SavedCreation.Kind {
    var title: String {
        switch self {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .transcript: return "Transcript"
        case .embedding: return "Embedding"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .transcript: return "doc.text"
        case .embedding: return "chart.dots.scatter"
        }
    }
}

struct LibraryQuery: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, model
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .model: return "Model"
            }
        }
    }

    var text = ""
    var kinds: Set<SavedCreation.Kind> = []
    var sort: Sort = .newest

    var isFiltering: Bool { !kinds.isEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty }

    func apply(to items: [SavedCreation]) -> [SavedCreation] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = items.filter { item in
            (kinds.isEmpty || kinds.contains(item.kind)) && matches(item, words)
        }
        switch sort {
        case .newest: return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return filtered.sorted { $0.createdAt < $1.createdAt }
        case .model: return filtered.sorted {
            let c = $0.modelID.localizedCaseInsensitiveCompare($1.modelID)
            return c == .orderedSame ? $0.createdAt > $1.createdAt : c == .orderedAscending
        }
        }
    }

    private func matches(_ item: SavedCreation, _ words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = ((item.prompt ?? "") + " " + item.modelID + " " + item.kind.title).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    static func counts(_ items: [SavedCreation]) -> [SavedCreation.Kind: Int] {
        items.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    func summary(shown: Int, total: Int) -> String {
        let noun = total == 1 ? "item" : "items"
        guard isFiltering else { return "\(total) \(noun)" }
        var parts = ["\(shown) of \(total) \(noun)"]
        if !kinds.isEmpty { parts.append(kinds.map(\.title).sorted().joined(separator: ", ")) }
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { parts.append("“\(t)”") }
        return parts.joined(separator: " · ")
    }

    mutating func clear() { text = ""; kinds = [] }
}

struct LibrarySelection: Equatable {
    private(set) var ids: Set<UUID> = []
    private var anchor: UUID?

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: UUID) {
        if ids.remove(id) == nil { ids.insert(id); anchor = id }
    }

    mutating func selectAll(_ all: [UUID]) { ids = Set(all); anchor = all.first }
    mutating func clear() { ids = []; anchor = nil }

    /// Hidden rows never stay selected, so a bulk action only touches what is on screen.
    mutating func prune(toVisible visible: [UUID]) {
        ids.formIntersection(visible)
        if let a = anchor, !ids.contains(a) { anchor = ids.first }
    }

    mutating func extend(to target: UUID, in ordered: [UUID]) {
        guard let a = anchor, let i = ordered.firstIndex(of: a), let j = ordered.firstIndex(of: target) else {
            ids = [target]; anchor = target; return
        }
        ids.formUnion(ordered[min(i, j)...max(i, j)])
    }
}

enum LibraryExport {
    struct Entry: Equatable { let creation: SavedCreation; let fileName: String }

    /// Names are built from kind, date and ID only. A prompt is never part of a path.
    static func fileName(for c: SavedCreation, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let short = c.id.uuidString.prefix(8).lowercased()
        return "orb-\(c.kind.rawValue)-\(f.string(from: c.createdAt))-\(short).\(creationExtension(c))"
    }

    static func unique(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name
        if taken.contains(candidate) {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var n = 2
            repeat {
                candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                n += 1
            } while taken.contains(candidate)
        }
        taken.insert(candidate)
        return candidate
    }

    static func plan(_ items: [SavedCreation], calendar: Calendar = .current) -> [Entry] {
        var taken = Set<String>()
        return items.map { Entry(creation: $0, fileName: unique(fileName(for: $0, calendar: calendar), taken: &taken)) }
    }

    static func resultText(written: Int, failed: [String]) -> String {
        let noun = written == 1 ? "item" : "items"
        if failed.isEmpty { return "Exported \(written) \(noun)" }
        if written == 0 { return "Nothing exported; \(failed.count) failed" }
        return "Exported \(written) \(noun); \(failed.count) failed (\(failed.joined(separator: ", ")))"
    }

    /// Never overwrites: an existing file in the folder gets a numbered name instead.
    static func write(_ plan: [Entry], to folder: URL, data: (SavedCreation) throws -> Data) -> (written: Int, failed: [String]) {
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var written = 0
        var failed: [String] = []
        for entry in plan {
            let name = unique(entry.fileName, taken: &taken)
            do {
                try data(entry.creation).write(to: folder.appendingPathComponent(name), options: [.withoutOverwriting])
                written += 1
            } catch {
                failed.append(name)
                taken.remove(name)
            }
        }
        return (written, failed)
    }

    /// File-copy variant: each entry's stored file is copied (never read into
    /// memory). Same never-overwrite numbering as `write`.
    static func copy(_ plan: [Entry], to folder: URL, source: (SavedCreation) throws -> URL) -> (written: Int, failed: [String]) {
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var written = 0
        var failed: [String] = []
        for entry in plan {
            let name = unique(entry.fileName, taken: &taken)
            do {
                try FileManager.default.copyItem(at: source(entry.creation), to: folder.appendingPathComponent(name))
                written += 1
            } catch {
                failed.append(name)
                taken.remove(name)
            }
        }
        return (written, failed)
    }
}

enum LibraryPreview {
    /// Space previews the first selected item in visible order.
    static func target(selection: Set<UUID>, visible: [SavedCreation]) -> SavedCreation? {
        visible.first { selection.contains($0.id) }
    }

    static func fileName(for c: SavedCreation) -> String { "\(c.id.uuidString).\(creationExtension(c))" }

    /// Raw PCM has no container or sample rate, so there is nothing safe to show.
    static func canQuickLook(_ c: SavedCreation) -> Bool { creationExtension(c) != "pcm" }
}


enum LibraryDelete {
    static func confirmTitle(count: Int) -> String {
        count == 1 ? "Delete this creation?" : "Delete \(count) creations?"
    }

    static func message(count: Int) -> String {
        "Deleted \(count) creation\(count == 1 ? "" : "s")"
    }
}

// MARK: - Creation identity (list and grid share it)

/// A short, scannable title plus a stable variant tag, so variants generated
/// from one long prompt are distinguishable at a glance. The full prompt is
/// never altered; it stays available as a tooltip, in the context menu and
/// in accessibility.
enum CreationIdentity {
    static let maxTitleLength = 48

    /// First sentence/line of the prompt, shortened at a word boundary.
    /// Falls back to "<Kind> from <model>" when there is no prompt.
    static func title(for c: SavedCreation) -> String {
        let prompt = (c.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            let model = c.modelID.split(separator: "/").last.map(String.init) ?? c.modelID
            return "\(c.kind.title) from \(model)"
        }
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        var sentence = firstLine
        if let end = firstLine.firstIndex(where: { ".!?".contains($0) }),
           firstLine.distance(from: firstLine.startIndex, to: end) >= 12 {
            sentence = String(firstLine[..<end])
        }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        guard sentence.count > maxTitleLength else { return sentence }
        let cut = sentence.prefix(maxTitleLength)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
    }

    /// Six hex characters of the content checksum: identical tags mean the
    /// identical stored file; different tags mean distinct variants.
    static func variantTag(for c: SavedCreation) -> String {
        let hex = c.checksum.lowercased().filter { $0.isHexDigit }
        return hex.isEmpty ? String(c.id.uuidString.prefix(6)).lowercased() : String(hex.prefix(6))
    }

    /// "Image · gpt-image-1 · Oct 7, 3:41 PM · #a1b2c3"
    static func metadata(for c: SavedCreation, includeKind: Bool = true) -> String {
        let model = c.modelID.split(separator: "/").last.map(String.init) ?? c.modelID
        var parts: [String] = []
        if includeKind { parts.append(c.kind.title) }
        parts.append(model)
        parts.append(c.createdAt.formatted(date: .abbreviated, time: .shortened))
        parts.append("#" + variantTag(for: c))
        return parts.joined(separator: " · ")
    }

    static func accessibilityLabel(for c: SavedCreation) -> String {
        "\(c.kind.title): \(title(for: c)), \(metadata(for: c, includeKind: false))"
    }
}
