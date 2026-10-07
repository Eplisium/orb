import Foundation
import UniformTypeIdentifiers
import AppKit

/// NSOpenPanel content types for chat attachments. Kept out of the view so
/// the literal list doesn't burden the view's type checker.
enum ChatAttachmentPanelTypes {
    static let allowed: [UTType] = [
        .png, .jpeg, .gif, UTType(filenameExtension: "webp") ?? .image,
        .heic, UTType(filenameExtension: "bmp") ?? .image,
        .audio, .mp3, UTType(filenameExtension: "wav") ?? .audio,
        .movie, .video,
        .pdf, .plainText, .commaSeparatedText, .json,
    ]
}

// MARK: - Chat attachment drafts
//
// Turns user-picked files into OpenRouter chat content parts. Images,
// audio, video, and documents each map to their own part type; anything
// else is rejected with a human-readable warning rather than a 400.

/// A file the user picked in the Chat composer, not yet sent.
struct ChatAttachmentDraft: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case image(mimeType: String)
        case audio(format: String)
        case video
        case file(mimeType: String)
    }

    let id: UUID
    let url: URL
    let kind: Kind
    let byteCount: Int

    init(id: UUID = UUID(), url: URL, kind: Kind, byteCount: Int) {
        self.id = id
        self.url = url
        self.kind = kind
        self.byteCount = byteCount
    }

    var filename: String { url.lastPathComponent }

    var iconName: String {
        switch kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "video"
        case .file: return "doc"
        }
    }

    /// Short capability label for chips, e.g. "image", "mp3", "pdf".
    var typeLabel: String {
        switch kind {
        case .image(let mime): return mime.split(separator: "/").last.map(String.init) ?? "image"
        case .audio(let format): return format
        case .video: return url.pathExtension.lowercased().isEmpty ? "video" : url.pathExtension.lowercased()
        case .file(let mime):
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty { return ext }
            return mime.split(separator: "/").last.map(String.init) ?? "file"
        }
    }
}

enum ChatAttachmentBuilder {
    /// Files larger than this are rejected — a single base64 image bigger
    /// than this would dominate most context windows.
    static let perFileByteLimit = 12_000_000
    static let totalByteLimit = 24_000_000

    private static let imageExtensions: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "webp": "image/webp", "gif": "image/gif", "heic": "image/heic",
        "heif": "image/heif", "bmp": "image/bmp",
    ]
    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "flac", "m4a", "ogg", "aiff", "aac",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm",
    ]
    private static let documentExtensions: [String: String] = [
        "pdf": "application/pdf",
        "txt": "text/plain", "md": "text/markdown", "csv": "text/csv",
        "json": "application/json",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ]

    /// Classifies picked URLs, enforcing size limits. Returns drafts plus
    /// one warning per skipped file.
    static func classify(urls: [URL]) -> (drafts: [ChatAttachmentDraft], warnings: [String]) {
        var drafts: [ChatAttachmentDraft] = []
        var warnings: [String] = []
        var usedBytes = 0
        var seen = Set<String>()

        for url in urls {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(key).inserted else {
                warnings.append("Skipped duplicate: \(url.lastPathComponent).")
                continue
            }
            let ext = url.pathExtension.lowercased()
            let kind: ChatAttachmentDraft.Kind?
            if let mime = imageExtensions[ext] {
                kind = .image(mimeType: mime)
            } else if audioExtensions.contains(ext) {
                kind = .audio(format: ext)
            } else if videoExtensions.contains(ext) {
                kind = .video
            } else if let mime = documentExtensions[ext] {
                kind = .file(mimeType: mime)
            } else if let mime = mimeType(for: url), mime.hasPrefix("image/") {
                kind = .image(mimeType: mime)
            } else if let mime = mimeType(for: url), mime.hasPrefix("audio/") {
                kind = .audio(format: ext.isEmpty ? "wav" : ext)
            } else if let mime = mimeType(for: url), mime.hasPrefix("video/") {
                kind = .video
            } else {
                kind = nil
            }
            guard let kind else {
                warnings.append("\(url.lastPathComponent): unsupported file type.")
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                warnings.append("Could not read \(url.lastPathComponent).")
                continue
            }
            if size > perFileByteLimit {
                warnings.append("\(url.lastPathComponent) is too large (limit 12 MB).")
                continue
            }
            if usedBytes + size > totalByteLimit {
                warnings.append("\(url.lastPathComponent) skipped: total attachment limit reached (24 MB).")
                continue
            }
            usedBytes += size
            drafts.append(ChatAttachmentDraft(url: url, kind: kind, byteCount: size))
        }
        return (drafts, warnings)
    }

    /// Reads and encodes drafts off the main actor. Attachments can be tens
    /// of megabytes; reading and base64-encoding them on the main actor froze
    /// the composer.
    static func buildParts(for drafts: [ChatAttachmentDraft]) async throws -> [MessageContentPart] {
        try await Task.detached(priority: .userInitiated) {
            try parts(for: drafts)
        }.value
    }

    /// Encodes drafts into wire parts. Binary files are inlined as base64
    /// `data:` URLs, matching the OpenRouter content-part schemas.
    nonisolated static func parts(for drafts: [ChatAttachmentDraft]) throws -> [MessageContentPart] {
        try drafts.map { draft in
            let scoped = draft.url.startAccessingSecurityScopedResource()
            defer {
                if scoped { draft.url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: draft.url)
            switch draft.kind {
            case .image(let mime):
                return .imageDataPart(data, mimeType: mime)
            case .audio(let format):
                return .audioDataPart(data, format: format)
            case .video:
                return .video(url: "data:video/\(draft.url.pathExtension.lowercased());base64,\(data.base64EncodedString())")
            case .file(let mime):
                return .fileDataPart(filename: draft.filename, data: data, mimeType: mime)
            }
        }
    }

    private static func mimeType(for url: URL) -> String? {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return nil }
        return type.preferredMIMEType
    }
}

// MARK: - Capability diagnostics

/// Explains what the selected model can do with attachments, shown under
/// the composer so a text-only model never silently drops an image.
enum AttachmentCapability {
    static func warnings(model: ModelInfo?, drafts: [ChatAttachmentDraft]) -> [String] {
        guard let model, !drafts.isEmpty else { return [] }
        var out: [String] = []
        let hasImage = drafts.contains { if case .image = $0.kind { return true }; return false }
        let hasAudio = drafts.contains { if case .audio = $0.kind { return true }; return false }
        let hasVideo = drafts.contains { if case .video = $0.kind { return true }; return false }
        let hasFile = drafts.contains { if case .file = $0.kind { return true }; return false }
        if hasImage, !model.supportsImages { out.append("This model cannot see images — they will be ignored upstream.") }
        if hasAudio, !model.supportsAudioInput { out.append("This model cannot hear audio — it will be ignored upstream.") }
        if hasVideo, !model.supportsVideoInput { out.append("This model cannot watch video — it will be ignored upstream.") }
        if hasFile, !model.supportsFileInput { out.append("This model takes no file input — documents will be ignored upstream.") }
        return out
    }
}

// MARK: - Pasted attachments (⌘V)

/// Turns pasteboard contents into attachment files: copied Finder files pass
/// through as URLs; raw image data (screenshots via ⌃⇧⌘4, images copied from
/// a browser) is written as a PNG into a private temp folder.
enum PasteboardAttachments {
    /// True when ⌘V should attach rather than paste text: file URLs or image
    /// data, and no plain text competing for the paste.
    static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasImage = pasteboard.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier])
        let hasText = pasteboard.string(forType: .string)?.isEmpty == false
        return hasFiles || (hasImage && !hasText)
    }

    static func urls(from pasteboard: NSPasteboard, directory: URL = defaultDirectory) throws -> [URL] {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            return files
        }
        guard let png = pngData(from: pasteboard) else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Pasted image \(stamp)-\(UUID().uuidString.prefix(4)).png")
        try png.write(to: url, options: .atomic)
        return [url]
    }

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ORB-pasted", isDirectory: true)
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Intercepts ⌘V while `isActive()` (the composer has focus) when the
/// pasteboard holds files or an image, and hands them over as URLs. Text
/// pastes fall through to the text field untouched.
@MainActor
final class ComposerPasteMonitor {
    private var monitor: Any?

    func install(isActive: @escaping @MainActor () -> Bool, onAttach: @escaping @MainActor ([URL]) -> Void,
                 onError: @escaping @MainActor (String) -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            return MainActor.assumeIsolated {
                let pasteboard = NSPasteboard.general
                guard isActive(), PasteboardAttachments.hasAttachments(pasteboard) else { return event }
                do {
                    let urls = try PasteboardAttachments.urls(from: pasteboard)
                    guard !urls.isEmpty else { return event }
                    onAttach(urls)
                } catch {
                    onError("Could not paste the image: \(error.localizedDescription)")
                }
                return nil
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
