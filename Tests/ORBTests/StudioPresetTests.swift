import Testing
import Foundation
@testable import ORB

private func defaults() -> UserDefaults {
    let n = "orb.tests.presets.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: n)!
    d.removePersistentDomain(forName: n)
    return d
}

@Suite("Studio presets: store")
struct StudioPresetStoreTests {
    private func image(_ name: String, model: String = "a/img", count: Int = 2) -> StudioPreset {
        StudioPreset(name: name, settings: ["model": model, "count": String(count), "aspect": "16:9"])
    }

    @Test("Saves per studio, newest first, and survives a reload")
    func roundTrip() {
        let d = defaults()
        var store = StudioPresetStore(studio: .images, defaults: d)
        store.save(image("Wide"))
        store.save(image("Square"))
        #expect(store.presets.map(\.name) == ["Square", "Wide"])
        let reloaded = StudioPresetStore(studio: .images, defaults: d)
        #expect(reloaded.presets.map(\.name) == ["Square", "Wide"])
        #expect(reloaded.presets[0].settings["aspect"] == "16:9")
    }

    @Test("Studios do not see each other's presets")
    func isolation() {
        let d = defaults()
        var images = StudioPresetStore(studio: .images, defaults: d)
        images.save(image("Wide"))
        #expect(StudioPresetStore(studio: .video, defaults: d).presets.isEmpty)
    }

    @Test("Saving under an existing name replaces it instead of duplicating")
    func replace() {
        var store = StudioPresetStore(studio: .images, defaults: defaults())
        store.save(image("Wide", count: 1))
        store.save(image("wide", count: 4))
        #expect(store.presets.count == 1)
        #expect(store.presets[0].settings["count"] == "4")
    }

    @Test("Names are trimmed, capped at 40 characters, and blank names are rejected")
    func names() {
        var store = StudioPresetStore(studio: .images, defaults: defaults())
        let blank = store.save(image("   "))
        #expect(!blank)
        let hero = store.save(image("  Hero  "))
        #expect(hero)
        #expect(store.presets[0].name == "Hero")
        let long = store.save(image(String(repeating: "x", count: 80)))
        #expect(long)
        #expect(store.presets[0].name.count == 40)
    }

    @Test("At most 12 presets are kept; the oldest is dropped")
    func cap() {
        var store = StudioPresetStore(studio: .images, defaults: defaults())
        for i in 1...15 { store.save(image("p\(i)")) }
        #expect(store.presets.count == 12)
        #expect(store.presets.first?.name == "p15")
        #expect(!store.presets.contains { $0.name == "p1" })
    }

    @Test("Delete removes just that preset")
    func delete() {
        var store = StudioPresetStore(studio: .images, defaults: defaults())
        store.save(image("a")); store.save(image("b"))
        store.delete(store.presets[0].id)
        #expect(store.presets.map(\.name) == ["a"])
    }

    @Test("Corrupt stored data loads as empty rather than crashing")
    func corrupt() {
        let d = defaults()
        d.set(Data("not json".utf8), forKey: StudioPresetStore.key(for: .images))
        #expect(StudioPresetStore(studio: .images, defaults: d).presets.isEmpty)
    }
}

@Suite("Studio presets: what is stored")
struct StudioPresetContentTests {
    @Test("Image settings capture knobs only: no prompt, no seed, no references, no results")
    func imageSnapshot() {
        let s = StudioPreset.imageSettings(model: "a/img", count: 3, aspect: "1:1", resolution: "2K", quality: "high", provider: "fast")
        #expect(Set(s.keys) == ["model", "count", "aspect", "resolution", "quality", "provider"])
        #expect(s["count"] == "3")
    }

    @Test("Video settings capture knobs only")
    func videoSnapshot() {
        let s = StudioPreset.videoSettings(model: "a/vid", aspect: "16:9", resolution: "720p", duration: "8", size: "auto", audio: true)
        #expect(Set(s.keys) == ["model", "aspect", "resolution", "duration", "size", "audio"])
        #expect(s["audio"] == "true")
    }

    @Test("Applying reads values back with safe defaults for anything missing")
    func apply() {
        let p = StudioPreset(name: "x", settings: ["count": "3", "aspect": "1:1"])
        let a = ImagePresetValues(p, maxCount: 10)
        #expect(a.count == 3 && a.aspect == "1:1")
        #expect(a.resolution == "auto" && a.quality == "auto" && a.model.isEmpty)
    }

    @Test("A stored image count is clamped to the studio's allowed range")
    func clamp() {
        #expect(ImagePresetValues(StudioPreset(name: "x", settings: ["count": "999"]), maxCount: 10).count == 10)
        #expect(ImagePresetValues(StudioPreset(name: "x", settings: ["count": "-4"]), maxCount: 10).count == 1)
        #expect(ImagePresetValues(StudioPreset(name: "x", settings: ["count": "abc"]), maxCount: 10).count == 1)
    }

    @Test("Video preset reads the audio flag")
    func videoApply() {
        let on = VideoPresetValues(StudioPreset(name: "x", settings: ["audio": "true", "duration": "6"]))
        #expect(on.generateAudio && on.duration == "6")
        #expect(!VideoPresetValues(StudioPreset(name: "x", settings: [:])).generateAudio)
    }

    @Test("Descriptions summarise a preset in words")
    func description() {
        let p = StudioPreset(name: "Wide", settings: ["model": "acme/flux-2", "aspect": "16:9", "count": "2"])
        #expect(p.summary.contains("flux-2") && p.summary.contains("16:9"))
        #expect(StudioPreset(name: "Empty", settings: [:]).summary == "Default settings")
    }
}

@Suite("Studio presets: speech and embeddings")
struct SpeechEmbeddingsPresetTests {
    @Test("Speech preset round-trips and clamps a bad speed")
    func speech() {
        let s = StudioPreset.speechSettings(mode: "tts", model: "a/tts", voice: "alloy", speed: 1.25, format: "mp3",
                                            language: "", transcriptionFormat: "json", timestamps: "none")
        let v = SpeechPresetValues(StudioPreset(name: "x", settings: s))
        #expect(v.mode == "tts" && v.model == "a/tts" && v.voice == "alloy" && v.speed == 1.25)
        var bad = s; bad["speed"] = "99"
        #expect(SpeechPresetValues(StudioPreset(name: "x", settings: bad)).speed == 1.0)
    }

    @Test("Embeddings preset drops non-numeric dimensions and unknown input types")
    func embeddings() {
        var s = StudioPreset.embeddingsSettings(model: "m", dimensions: "1024", inputType: "query", rerankModel: "r", topN: "5")
        let ok = EmbeddingsPresetValues(StudioPreset(name: "x", settings: s))
        #expect(ok.dimensions == "1024" && ok.inputType == "query" && ok.topN == "5")
        s["dimensions"] = "12; drop"; s["inputType"] = "weird"; s["topN"] = "-1"
        let bad = EmbeddingsPresetValues(StudioPreset(name: "x", settings: s))
        #expect(bad.dimensions.isEmpty && bad.inputType.isEmpty && bad.topN.isEmpty)
    }

    @Test("Speech and embeddings presets are stored separately from other studios")
    func isolated() {
        let d = defaults()
        var store = StudioPresetStore(studio: .speech, defaults: d)
        store.save(StudioPreset(name: "Narrator", settings: ["mode": "tts"]))
        #expect(StudioPresetStore(studio: .embeddings, defaults: d).presets.isEmpty)
        #expect(StudioPresetStore(studio: .speech, defaults: d).presets.count == 1)
    }
}

@Suite("Studio presets: menu label and reset handling")
struct StudioPresetResetTests {
    @Test("Menu label interpolates name and summary instead of showing escaped text")
    func menuLabel() {
        let p = StudioPreset(name: "Wide", settings: ["model": "a/img", "aspect": "16:9"])
        #expect(p.menuLabel == "Wide  —  img · 16:9")
        #expect(!p.menuLabel.contains("\\("))
    }

    private func video(_ model: String) -> VideoPresetValues {
        VideoPresetValues(StudioPreset(name: "v", settings: [
            "model": model, "aspect": "9:16", "resolution": "1080p", "duration": "8", "size": "1280x720", "audio": "true"]))
    }

    @Test("Video: preset for model B applied while A is selected keeps B's options")
    func videoPresetSurvivesModelChange() {
        let o = PresetReset.videoOptions(afterChangingTo: "b/vid", pending: video("b/vid"))
        #expect(o.aspect == "9:16" && o.resolution == "1080p" && o.duration == "8" && o.size == "1280x720" && o.generateAudio)
    }

    @Test("Video: ordinary model change resets to defaults")
    func videoPlainChangeResets() {
        let o = PresetReset.videoOptions(afterChangingTo: "b/vid", pending: nil)
        #expect(o == PresetReset.VideoOptions.defaults)
        #expect(!o.generateAudio && o.aspect == "auto" && o.duration == "")
    }

    @Test("Video: a stale preset for another model is ignored")
    func videoStalePendingIgnored() {
        let o = PresetReset.videoOptions(afterChangingTo: "c/vid", pending: video("b/vid"))
        #expect(o == PresetReset.VideoOptions.defaults)
    }

    @Test("Video: preset with the same model needs no staging (no change handler will fire)")
    func videoSameModel() {
        #expect(PresetReset.stagedModel(presetModel: "a/vid", current: "a/vid") == false)
        #expect(PresetReset.stagedModel(presetModel: "b/vid", current: "a/vid") == true)
        #expect(PresetReset.stagedModel(presetModel: "", current: "a/vid") == false)
    }

    private func image(model: String, provider: String = "") -> ImagePresetValues {
        ImagePresetValues(StudioPreset(name: "i", settings: [
            "model": model, "aspect": "16:9", "resolution": "2K", "quality": "high", "count": "3", "provider": provider]), maxCount: 10)
    }

    @Test("Images: preset for model B keeps its options and provider through the model reset")
    func imageModelChangeKeepsPreset() {
        let o = PresetReset.imageOptions(afterChangingTo: "b/img", pending: image(model: "b/img", provider: "p"))
        #expect(o.aspect == "16:9" && o.resolution == "2K" && o.quality == "high" && o.count == 3 && o.provider == "p")
    }

    @Test("Images: ordinary model change resets everything")
    func imageModelChangeResets() {
        #expect(PresetReset.imageOptions(afterChangingTo: "b/img", pending: nil) == .defaults)
        #expect(PresetReset.imageOptions(afterChangingTo: "c/img", pending: image(model: "b/img")) == .defaults)
    }

    @Test("Images: provider change from a preset keeps aspect/resolution/quality")
    func imageProviderFromPreset() {
        let r = PresetReset.imageProviderChange(to: "p", model: "b/img", pending: image(model: "b/img", provider: "p"))
        #expect(r.aspect == "16:9" && r.resolution == "2K" && r.quality == "high")
        #expect(r.keepPending)
    }

    @Test("Images: manual provider change resets and drops the pending preset")
    func imageProviderManual() {
        let none = PresetReset.imageProviderChange(to: "q", model: "b/img", pending: nil)
        #expect(none.aspect == "auto" && none.resolution == "auto" && none.quality == "auto" && !none.keepPending)
        let other = PresetReset.imageProviderChange(to: "q", model: "b/img", pending: image(model: "b/img", provider: "p"))
        #expect(other.aspect == "auto" && !other.keepPending)
        let otherModel = PresetReset.imageProviderChange(to: "p", model: "c/img", pending: image(model: "b/img", provider: "p"))
        #expect(otherModel.aspect == "auto" && !otherModel.keepPending)
    }
}
