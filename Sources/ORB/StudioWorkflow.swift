import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Studio workflow helpers (wave 1)
//
// Pure, testable pieces shared by the five studios: prompt history,
// "Open in Studio" re-run plans, drag-and-drop filtering, embedding maths,
// audio playback, and navigation to a Library item.

// MARK: Prompt history (STUDIO-13)

/// Recent prompts per studio: last 25 distinct trimmed prompts, newest
/// first, recorded on a successful submit. Stored in UserDefaults.
struct StudioPromptHistory {
    enum Studio: String, CaseIterable { case images, video, speech, embeddings }
    static let limit = 25

    let studio: Studio
    var defaults: UserDefaults = .standard

    private var key: String { "orb.studio.promptHistory.\(studio.rawValue)" }

    var prompts: [String] { defaults.stringArray(forKey: key) ?? [] }

    /// Pure update: blank prompts are ignored, a repeat moves to the front,
    /// and the list is capped at `limit`.
    static func adding(_ prompt: String, to list: [String], limit: Int = limit) -> [String] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        var next = list.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        return Array(next.prefix(max(0, limit)))
    }

    func record(_ prompt: String) {
        let next = Self.adding(prompt, to: prompts)
        if next != prompts { defaults.set(next, forKey: key) }
    }

    func clear() { defaults.removeObject(forKey: key) }

    /// One-line menu title for a prompt.
    static func menuTitle(_ prompt: String, maxLength: Int = 60) -> String {
        let flat = prompt.replacingOccurrences(of: "\n", with: " ")
        return flat.count > maxLength ? String(flat.prefix(maxLength - 1)) + "…" : flat
    }
}

/// Clock-icon menu of recent prompts, shown next to a studio's "Prompt" label.
struct StudioPromptHistoryMenu: View {
    let history: StudioPromptHistory
    let onPick: (String) -> Void
    /// Bumped by the parent after recording, so the menu re-reads defaults.
    var revision: Int = 0

    var body: some View {
        let prompts = history.prompts
        Menu {
            if prompts.isEmpty {
                Text("No recent prompts")
            } else {
                ForEach(prompts, id: \.self) { prompt in
                    Button(StudioPromptHistory.menuTitle(prompt)) { onPick(prompt) }
                }
                Divider()
                Button("Clear History") { history.clear() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recent prompts")
        .accessibilityLabel("Recent prompts")
        .id(revision)
    }
}

// MARK: Open in Studio (STUDIO-13)

/// How to re-run a saved creation: which section and which studio boxes.
struct StudioReusePlan: Equatable {
    let section: SidebarSection
    /// `StudioStore` box keys → String values to write.
    let values: [String: String]
    /// Speech also switches its mode to text-to-speech.
    let speechMode: SpeechView.Mode?

    /// Embeddings and transcripts are excluded (no prompt → output mapping).
    static func plan(for creation: SavedCreation) -> StudioReusePlan? {
        let prompt = creation.prompt ?? ""
        switch creation.kind {
        case .image:
            return StudioReusePlan(section: .images,
                                   values: ["ImagesView.prompt": prompt, "ImagesView.selectedModelId": creation.modelID],
                                   speechMode: nil)
        case .video:
            return StudioReusePlan(section: .video,
                                   values: ["VideoView.prompt": prompt, "VideoView.selectedModelId": creation.modelID],
                                   speechMode: nil)
        case .audio:
            return StudioReusePlan(section: .speech,
                                   values: ["SpeechView.text": prompt, "SpeechView.modelId": creation.modelID],
                                   speechMode: .tts)
        case .transcript, .embedding:
            return nil
        }
    }

    @MainActor
    func apply(store: StudioStore? = nil) {
        let store = store ?? .shared
        for (key, value) in values {
            store.box(key, initial: { "" }).value = value
        }
        if let speechMode { store.box("SpeechView.mode", initial: { SpeechView.Mode.tts }).value = speechMode }
    }
}

@MainActor
enum StudioNavigation {
    /// Box the Library reads to select and scroll to one creation.
    static let libraryFocusKey = "SavedCreationsLibraryView.focusID"
    static let showingCreationsKey = "FilesView.showingCreations"

    /// Opens ORB's Library (not Finder) with the creation selected (STUDIO-4).
    static func showInLibrary(_ creationID: UUID?, shell: ShellController, store: StudioStore? = nil) {
        let store = store ?? .shared
        store.box(showingCreationsKey, initial: { true }).value = true
        store.box(libraryFocusKey, initial: { UUID?.none }).value = creationID
        shell.send(.section(.files))
    }

    static func openInStudio(_ creation: SavedCreation, shell: ShellController, store: StudioStore? = nil) {
        guard let plan = StudioReusePlan.plan(for: creation) else { return }
        plan.apply(store: store)
        shell.send(.section(plan.section))
    }
}

// MARK: Drag and drop (STUDIO-14)

enum StudioDropFilter {
    enum Kind { case image, audio, anyFile }

    /// Image types the studios accept (validator also accepts WebP).
    static let imageTypes: [UTType] = [.png, .jpeg, .gif, .heic, .webP]

    /// Keeps only local file URLs whose type conforms to `kind`, de-duplicated
    /// in drop order. Directories are rejected.
    static func accept(urls: [URL], kind: Kind) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            guard url.isFileURL, !url.hasDirectoryPath, seen.insert(url.standardizedFileURL.path).inserted else { return false }
            let type = UTType(filenameExtension: url.pathExtension)
            switch kind {
            case .image: return type.map { t in imageTypes.contains { t.conforms(to: $0) } } ?? false
            case .audio: return type?.conforms(to: .audio) ?? false
            case .anyFile: return true
            }
        }
    }

    /// Appends dropped references to an existing list without duplicates,
    /// honouring the reference limit. Returns the new list and how many
    /// were refused because the limit was reached.
    static func merge(_ dropped: [URL], into existing: [URL], limit: Int) -> (urls: [URL], refused: Int) {
        var result = existing
        var refused = 0
        for url in dropped where !result.contains(url) {
            if result.count >= limit { refused += 1; continue }
            result.append(url)
        }
        return (result, refused)
    }
}

extension View {
    /// File drop target with an accent outline while targeted.
    func studioFileDrop(kind: StudioDropFilter.Kind, isTargeted: Binding<Bool>,
                        perform: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let accepted = StudioDropFilter.accept(urls: urls, kind: kind)
            guard !accepted.isEmpty else { return false }
            perform(accepted)
            return true
        } isTargeted: { isTargeted.wrappedValue = $0 }
        .overlay {
            if isTargeted.wrappedValue {
                RoundedRectangle(cornerRadius: ORBMetrics.radiusMD)
                    .stroke(ORBTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: Embedding maths (STUDIO-9)

enum EmbeddingMath {
    static func l2Norm(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    /// Cosine similarity, or nil for a zero vector, a dimension mismatch or
    /// non-finite input (never NaN).
    static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return nil }
        let value = dot / (na.squareRoot() * nb.squareRoot())
        guard value.isFinite else { return nil }
        return min(1, max(-1, value))
    }

    /// Symmetric N×N cosine matrix (diagonal 1 for non-zero vectors).
    static func cosineMatrix(_ vectors: [[Double]]) -> [[Double?]] {
        let n = vectors.count
        var m = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
        for i in 0..<n {
            for j in i..<n {
                let value = cosine(vectors[i], vectors[j])
                m[i][j] = value; m[j][i] = value
            }
        }
        return m
    }

    /// Most similar distinct pair (i < j), if any pair is comparable.
    static func mostSimilarPair(_ matrix: [[Double?]]) -> (i: Int, j: Int, score: Double)? {
        var best: (Int, Int, Double)?
        for i in matrix.indices {
            for j in matrix.indices where j > i {
                if let s = matrix[i][j], s > (best?.2 ?? -.infinity) { best = (i, j, s) }
            }
        }
        return best.map { (i: $0.0, j: $0.1, score: $0.2) }
    }
}

/// Display data precomputed once per embed result, so `body` never re-joins
/// thousands of doubles (STUDIO-9). Matrix capped at `matrixLimit` inputs.
struct EmbeddingResultSummary: Equatable {
    struct Row: Equatable, Identifiable {
        let id: Int
        let input: String
        let dimensions: Int
        let norm: Double
        let preview: String
        let json: String
    }
    static let matrixLimit = 20

    let rows: [Row]
    let matrix: [[Double?]]
    let bestPair: String?
    let matrixTruncated: Bool

    static let empty = EmbeddingResultSummary(rows: [], matrix: [], bestPair: nil, matrixTruncated: false)

    static func make(_ vectors: [(input: String, embedding: [Double])]) -> EmbeddingResultSummary {
        let rows = vectors.enumerated().map { index, vector in
            Row(id: index, input: vector.input, dimensions: vector.embedding.count,
                norm: EmbeddingMath.l2Norm(vector.embedding),
                preview: vector.embedding.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                    + (vector.embedding.count > 8 ? ", …" : ""),
                json: "[" + vector.embedding.map { String($0) }.joined(separator: ",") + "]")
        }
        let capped = Array(vectors.prefix(matrixLimit)).map(\.embedding)
        let matrix = capped.count >= 2 ? EmbeddingMath.cosineMatrix(capped) : []
        let best = EmbeddingMath.mostSimilarPair(matrix).map {
            "Most similar: #\($0.i + 1) and #\($0.j + 1) (cosine \(String(format: "%.3f", $0.score)))"
        }
        return EmbeddingResultSummary(rows: rows, matrix: matrix, bestPair: best,
                                      matrixTruncated: vectors.count > matrixLimit)
    }

    /// Computed off the main actor for large results.
    static func compute(_ vectors: [(input: String, embedding: [Double])]) async -> EmbeddingResultSummary {
        let copy = vectors.map { ($0.input, $0.embedding) }
        return await Task.detached(priority: .userInitiated) {
            make(copy.map { (input: $0.0, embedding: $0.1) })
        }.value
    }
}

// MARK: Audio playback (STUDIO-8)

/// What `StudioAudioPlayback` needs from a player; AVAudioPlayer in the app,
/// a fake in tests.
@MainActor
protocol StudioAudioEngine: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

@MainActor
final class AVAudioEngineAdapter: NSObject, StudioAudioEngine, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: () -> Void = {}
    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }
    var isPlaying: Bool { player.isPlaying }
    var currentTime: TimeInterval { get { player.currentTime } set { player.currentTime = newValue } }
    var duration: TimeInterval { player.duration }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish() }
    }
}

/// Play/pause/stop/scrub model for one audio clip.
@MainActor
final class StudioAudioPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedID: UUID?
    @Published private(set) var error: String?
    @Published private(set) var failedID: UUID?
    private var engine: StudioAudioEngine?
    private var timer: Timer?

    /// Raw PCM has no container or sample rate: never offer Play for it.
    static func canPlay(mimeType: String) -> Bool {
        let ext = MediaFileExtension.forMIMEType(mimeType) ?? ""
        return ext != "pcm" && mimeType.lowercased().hasPrefix("audio/") && !mimeType.lowercased().contains("pcm")
    }

    func fail(_ id: UUID, message: String) { failedID = id; error = message }

    func load(_ engine: StudioAudioEngine, id: UUID) {
        stop()
        error = nil; failedID = nil
        self.engine = engine
        loadedID = id
        duration = engine.duration
        currentTime = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let engine else { return }
        isPlaying = engine.play()
        if isPlaying { startTimer() }
    }

    func pause() {
        engine?.pause()
        isPlaying = false
        stopTimer()
        sync()
    }

    func stop() {
        engine?.stop()
        engine?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        guard let engine else { return }
        engine.currentTime = min(max(0, time), duration)
        currentTime = engine.currentTime
    }

    /// Called when the clip ends naturally.
    func finished() { stop() }

    func unload() { stop(); engine = nil; loadedID = nil; duration = 0 }

    func sync() {
        guard let engine else { return }
        currentTime = engine.currentTime
        if isPlaying && !engine.isPlaying { stop() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    static func timeText(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Play/Pause, Stop, elapsed/duration and a scrubber for a saved audio clip.
struct StudioAudioPlayerBar: View {
    let creation: SavedCreation
    let store: SavedCreationsStore
    @ObservedObject var playback: StudioAudioPlayback

    var body: some View {
        let loaded = playback.loadedID == creation.id
        VStack(alignment: .leading, spacing: 2) {
        controls(loaded: loaded)
        if let error = playback.error, playback.failedID == creation.id {
            Text(error).font(ORBFont.caption).foregroundStyle(ORBTheme.warning)
        }
        }
    }

    private func controls(loaded: Bool) -> some View {
        HStack(spacing: ORBMetrics.spacingSM) {
            Button { start(loaded: loaded) } label: {
                Image(systemName: loaded && playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(loaded && playback.isPlaying ? "Pause" : "Play")
            Button { playback.stop() } label: { Image(systemName: "stop.fill") }
                .accessibilityLabel("Stop")
                .disabled(!loaded)
            Text(StudioAudioPlayback.timeText(loaded ? playback.currentTime : 0))
                .font(ORBFont.caption.monospacedDigit()).foregroundStyle(ORBTheme.textSecondary)
            Slider(value: Binding(get: { loaded ? playback.currentTime : 0 },
                                  set: { if loaded { playback.seek(to: $0) } }),
                   in: 0...max(loaded ? playback.duration : 1, 0.01))
                .disabled(!loaded)
                .accessibilityLabel("Playback position")
            Text(StudioAudioPlayback.timeText(loaded ? playback.duration : 0))
                .font(ORBFont.caption.monospacedDigit()).foregroundStyle(ORBTheme.textSecondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func start(loaded: Bool) {
        if loaded { playback.toggle(); return }
        do {
            let url = try CreationActions.stagedFileURL(for: creation, in: store)
            let adapter = try AVAudioEngineAdapter(url: url)
            adapter.onFinish = { [weak playback] in playback?.finished() }
            playback.load(adapter, id: creation.id)
            playback.play()
        } catch {
            playback.fail(creation.id, message: "Couldn't play audio: \(error.localizedDescription)")
        }
    }
}

// MARK: Off-main file reads (STUDIO-10)

enum LocalFileRead {
    /// Reads a local file on a background task so large uploads and
    /// transcriptions never block the main actor. Security-scoped access is
    /// opened and closed inside the task.
    static func data(at url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }
}
