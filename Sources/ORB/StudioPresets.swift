import SwiftUI
import Foundation

// MARK: - Per-studio presets (Phase 6)
//
// A preset stores generation knobs only. It never holds a prompt, a seed,
// reference files, results, or anything secret.

struct StudioPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var settings: [String: String]

    static func imageSettings(model: String, count: Int, aspect: String, resolution: String, quality: String, provider: String) -> [String: String] {
        ["model": model, "count": String(count), "aspect": aspect, "resolution": resolution, "quality": quality, "provider": provider]
    }

    static func videoSettings(model: String, aspect: String, resolution: String, duration: String, size: String, audio: Bool) -> [String: String] {
        ["model": model, "aspect": aspect, "resolution": resolution, "duration": duration, "size": size, "audio": audio ? "true" : "false"]
    }

    static func speechSettings(mode: String, model: String, voice: String, speed: Double, format: String,
                               language: String, transcriptionFormat: String, timestamps: String) -> [String: String] {
        ["mode": mode, "model": model, "voice": voice, "speed": String(speed), "format": format,
         "language": language, "transcriptionFormat": transcriptionFormat, "timestamps": timestamps]
    }

    static func embeddingsSettings(model: String, dimensions: String, inputType: String,
                                   rerankModel: String, topN: String) -> [String: String] {
        ["model": model, "dimensions": dimensions, "inputType": inputType, "rerankModel": rerankModel, "topN": topN]
    }

    var summary: String {
        var parts: [String] = []
        if let m = settings["model"], !m.isEmpty { parts.append(m.split(separator: "/").last.map(String.init) ?? m) }
        if let c = settings["count"], c != "1" { parts.append("×\(c)") }
        if let m = settings["mode"], !m.isEmpty { parts.insert(m, at: 0) }
        if let v = settings["voice"], !v.isEmpty { parts.append(v) }
        if let d = settings["dimensions"], !d.isEmpty { parts.append("\(d) dims") }
        for key in ["aspect", "resolution", "quality", "duration"] {
            if let v = settings[key], !v.isEmpty, v != "auto" { parts.append(key == "duration" ? "\(v)s" : v) }
        }
        return parts.isEmpty ? "Default settings" : parts.joined(separator: " · ")
    }
}

enum PresetStudio: String { case images, video, speech, embeddings }

struct StudioPresetStore {
    static let maximum = 12
    static let nameLimit = 40

    let studio: PresetStudio
    private let defaults: UserDefaults
    private(set) var presets: [StudioPreset]

    static func key(for studio: PresetStudio) -> String { "orb.studio.presets.\(studio.rawValue)" }

    init(studio: PresetStudio, defaults: UserDefaults = .standard) {
        self.studio = studio
        self.defaults = defaults
        // Corrupt data is treated as "no presets"; it is overwritten on the next save.
        presets = defaults.data(forKey: Self.key(for: studio))
            .flatMap { try? JSONDecoder().decode([StudioPreset].self, from: $0) } ?? []
    }

    @discardableResult
    mutating func save(_ preset: StudioPreset) -> Bool {
        let name = String(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        guard !name.isEmpty else { return false }
        var item = preset
        item.name = name
        presets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        presets.insert(item, at: 0)
        if presets.count > Self.maximum { presets.removeLast(presets.count - Self.maximum) }
        persist()
        return true
    }

    mutating func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.key(for: studio)) }
    }
}

struct ImagePresetValues {
    let model: String, aspect: String, resolution: String, quality: String, provider: String
    let count: Int

    init(_ p: StudioPreset, maxCount: Int) {
        model = p.settings["model"] ?? ""
        aspect = p.settings["aspect"] ?? "auto"
        resolution = p.settings["resolution"] ?? "auto"
        quality = p.settings["quality"] ?? "auto"
        provider = p.settings["provider"] ?? ""
        count = min(max(Int(p.settings["count"] ?? "") ?? 1, 1), max(maxCount, 1))
    }
}

struct VideoPresetValues {
    let model: String, aspect: String, resolution: String, duration: String, size: String
    let generateAudio: Bool

    init(_ p: StudioPreset) {
        model = p.settings["model"] ?? ""
        aspect = p.settings["aspect"] ?? "auto"
        resolution = p.settings["resolution"] ?? "auto"
        duration = p.settings["duration"] ?? ""
        size = p.settings["size"] ?? "auto"
        generateAudio = p.settings["audio"] == "true"
    }
}

struct SpeechPresetValues {
    /// "tts" or "stt"; a preset only applies in the mode it was saved from.
    let mode: String, model: String, voice: String, format: String
    let language: String, transcriptionFormat: String, timestamps: String
    let speed: Double

    init(_ p: StudioPreset) {
        mode = p.settings["mode"] ?? "tts"
        model = p.settings["model"] ?? ""
        voice = p.settings["voice"] ?? ""
        format = p.settings["format"] ?? "mp3"
        language = p.settings["language"] ?? ""
        transcriptionFormat = p.settings["transcriptionFormat"] ?? "json"
        timestamps = p.settings["timestamps"] ?? "none"
        // Out-of-range or unparsable speeds fall back to normal speed.
        let raw = Double(p.settings["speed"] ?? "") ?? 1.0
        speed = (0.25...4.0).contains(raw) ? raw : 1.0
    }
}

struct EmbeddingsPresetValues {
    let model: String, dimensions: String, inputType: String, rerankModel: String, topN: String

    init(_ p: StudioPreset) {
        model = p.settings["model"] ?? ""
        // Dimensions and top-N are digits only; anything else is dropped rather than sent.
        let dims = p.settings["dimensions"] ?? ""
        dimensions = dims.allSatisfy(\.isNumber) ? dims : ""
        let type = p.settings["inputType"] ?? ""
        inputType = ["query", "document"].contains(type) ? type : ""
        rerankModel = p.settings["rerankModel"] ?? ""
        let top = p.settings["topN"] ?? ""
        topN = top.allSatisfy(\.isNumber) ? top : ""
    }
}

/// Menu with "Save current as…" and the saved presets. The studio supplies the snapshot and the apply action.
struct StudioPresetMenu: View {
    let studio: PresetStudio
    let snapshot: () -> [String: String]
    let apply: (StudioPreset) -> Void
    var isApplicable: (StudioPreset) -> Bool = { _ in true }
    @State private var store: StudioPresetStore
    @State private var naming = false
    @State private var draftName = ""

    init(studio: PresetStudio, isApplicable: @escaping (StudioPreset) -> Bool = { _ in true },
         snapshot: @escaping () -> [String: String], apply: @escaping (StudioPreset) -> Void) {
        self.studio = studio
        self.isApplicable = isApplicable
        self.snapshot = snapshot
        self.apply = apply
        _store = State(initialValue: StudioPresetStore(studio: studio))
    }

    var body: some View {
        Menu {
            Button("Save Current Settings…", systemImage: "plus") { draftName = ""; naming = true }
            if !store.presets.isEmpty {
                Divider()
                ForEach(store.presets.filter(isApplicable)) { preset in
                    Button { apply(preset) } label: { Text("\\(preset.name)  —  \\(preset.summary)") }
                }
                Divider()
                Menu("Delete Preset") {
                    ForEach(store.presets) { preset in
                        Button(preset.name, role: .destructive) { store.delete(preset.id) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.2.square")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                if store.save(StudioPreset(name: draftName, settings: snapshot())) {
                    AppToasts.saved("Preset")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the model and generation settings only, not your prompt, seed or reference files.")
        }
    }
}
