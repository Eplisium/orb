import Foundation
import UniformTypeIdentifiers

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
