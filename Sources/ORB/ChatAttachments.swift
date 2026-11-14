import Foundation
import UniformTypeIdentifiers
import AppKit
import ImageIO

/// NSOpenPanel content types for chat attachments. Kept out of the view so
/// the literal list doesn't burden the view's type checker.
enum ChatAttachmentPanelTypes {
    static let allowed: [UTType] = [
        .png, .jpeg, .gif, UTType(filenameExtension: "webp") ?? .image,
        .heic, .heif, .tiff, .bmp,
        .audio, .mp3, UTType(filenameExtension: "wav") ?? .audio,
        .movie, .video,
        .pdf, .plainText, .commaSeparatedText, .json, .sourceCode, .xml, .yaml, .html, .script,
    ] + ChatTextAttachment.extensionLanguages.keys.sorted().compactMap { UTType(filenameExtension: $0) }
}

// MARK: - Chat attachment drafts
//
// Turns user-picked files into OpenRouter chat content parts. Images,
// audio, video, and documents each map to their own part type; UTF-8 text
// and source files are inlined as fenced text; anything else is rejected
// with a human-readable warning rather than a 400.

/// A file the user picked in the Chat composer, not yet sent.
struct ChatAttachmentDraft: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case image(mimeType: String)
        case audio(format: String)
        case video
        case file(mimeType: String)
        /// UTF-8 text or source code, sent inline as a fenced text part.
        /// `language` is the fence info string (nil for plain text).
        case text(language: String?)
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
        case .text: return "doc.text"
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
        case .text(let language):
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty { return ext }
            return language ?? "text"
        }
    }

    /// Tokens this attachment will roughly add to the prompt, for the
    /// context gauge (text is inlined, so it counts by size).
    var estimatedTokens: Int {
        switch kind {
        case .image: return ContextGauge.imageAllowance
        case .file: return ContextGauge.fileAllowance
        case .audio, .video: return ContextGauge.mediaAllowance
        case .text: return (min(byteCount, ChatTextAttachment.byteCap) + 3) / 4
        }
    }

    /// True for PDFs, which OpenRouter can parse for models without native
    /// file input.
    var isPDF: Bool {
        if case .file(let mime) = kind { return mime == "application/pdf" }
        return false
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
        "heif": "image/heif", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff",
    ]
    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "flac", "m4a", "ogg", "aiff", "aac",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm",
    ]
    /// Sent as `file` parts. Plain-text formats (txt, md, csv, json, …) are
    /// inlined as text instead; see `ChatTextAttachment`.
    private static let documentExtensions: [String: String] = [
        "pdf": "application/pdf",
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
            } else if let language = ChatTextAttachment.language(for: url) {
                kind = .text(language: language.isEmpty ? nil : language)
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
            // Only the inlined prefix of a long text file is sent, so only
            // that counts toward the total.
            var counted = size
            if case .text = kind {
                if let problem = ChatTextAttachment.validate(url: url) {
                    warnings.append(problem)
                    continue
                }
                counted = min(size, ChatTextAttachment.byteCap)
            }
            if usedBytes + counted > totalByteLimit {
                warnings.append("\(url.lastPathComponent) skipped: total attachment limit reached (24 MB).")
                continue
            }
            usedBytes += counted
            drafts.append(ChatAttachmentDraft(url: url, kind: kind, byteCount: size))
        }
        return (drafts, warnings)
    }

    /// Reads and encodes drafts off the main actor. Attachments can be tens
    /// of megabytes, and images are decoded and re-encoded; doing that on
    /// the main actor froze the composer.
    static func buildParts(for drafts: [ChatAttachmentDraft]) async throws -> [MessageContentPart] {
        try await Task.detached(priority: .userInitiated) {
            try parts(for: drafts)
        }.value
    }

    /// Encodes drafts into wire parts. Binary files are inlined as base64
    /// `data:` URLs, matching the OpenRouter content-part schemas; images in
    /// formats OpenRouter does not accept, or larger than
    /// `ChatImageTranscoder.maxLongEdge`, are re-encoded first.
    nonisolated static func parts(for drafts: [ChatAttachmentDraft]) throws -> [MessageContentPart] {
        try drafts.map { draft in
            let scoped = draft.url.startAccessingSecurityScopedResource()
            defer {
                if scoped { draft.url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: draft.url)
            switch draft.kind {
            case .image(let mime):
                let prepared = try ChatImageTranscoder.prepare(data: data, mimeType: mime, filename: draft.filename)
                return .imageDataPart(prepared.data, mimeType: prepared.mimeType)
            case .audio(let format):
                return .audioDataPart(data, format: format)
            case .video:
                return .video(url: "data:video/\(draft.url.pathExtension.lowercased());base64,\(data.base64EncodedString())")
            case .file(let mime):
                return .fileDataPart(filename: draft.filename, data: data, mimeType: mime)
            case .text(let language):
                return .textPart(try ChatTextAttachment.encode(data: data, filename: draft.filename, language: language))
            }
        }
    }

    private static func mimeType(for url: URL) -> String? {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return nil }
        return type.preferredMIMEType
    }
}

// MARK: - Image transcoding

/// Converts picked images into something every OpenRouter vision provider
/// accepts. The image-understanding guide lists only PNG, JPEG, WebP and GIF,
/// so HEIC/HEIF (iPhone photos), BMP and TIFF are re-encoded, and anything
/// with a long edge over `maxLongEdge` is downscaled — a full-resolution
/// photo is resent as base64 on every later turn.
enum ChatImageTranscoder {
    static let supportedMIMETypes: Set<String> = ["image/png", "image/jpeg", "image/webp", "image/gif"]
    static let maxLongEdge = 2048
    static let jpegQuality = 0.85

    struct Output: Equatable, Sendable {
        let data: Data
        let mimeType: String
    }

    enum TranscodeError: LocalizedError, Equatable {
        case undecodable(String)
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .undecodable(let name): return "\(name) could not be read as an image"
            case .encodeFailed(let name): return "\(name) could not be converted to JPEG or PNG"
            }
        }
    }

    /// Returns the bytes to send. Supported images within the size cap pass
    /// through untouched (no quality loss); animated GIFs always pass through
    /// so they keep their animation.
    nonisolated static func prepare(data: Data, mimeType: String, filename: String = "image") throws -> Output {
        let mime = mimeType.lowercased()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            // Unknown-but-supported bytes are the provider's call; anything
            // else would be rejected upstream, so say so now.
            if supportedMIMETypes.contains(mime) { return Output(data: data, mimeType: mime) }
            throw TranscodeError.undecodable(filename)
        }
        let longEdge = pixelLongEdge(source)
        let supported = supportedMIMETypes.contains(mime)
        if mime == "image/gif", CGImageSourceGetCount(source) > 1 {
            return Output(data: data, mimeType: mime)
        }
        if supported, let longEdge, longEdge <= maxLongEdge {
            return Output(data: data, mimeType: mime)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bakes in EXIF orientation: iPhone HEICs are often stored sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge ?? maxLongEdge, maxLongEdge),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw TranscodeError.undecodable(filename)
        }
        let usePNG = hasAlpha(source, image)
        let type = (usePNG ? UTType.png : UTType.jpeg).identifier as CFString
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw TranscodeError.encodeFailed(filename)
        }
        let properties: [CFString: Any] = usePNG ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TranscodeError.encodeFailed(filename) }
        return Output(data: output as Data, mimeType: usePNG ? "image/png" : "image/jpeg")
    }

    private static func pixelLongEdge(_ source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }

    /// Prefers the file's own flag. HEIC files usually carry none and decode
    /// into an alpha-carrying buffer, so then the pixels decide: PNG only
    /// when something is actually transparent.
    private static func hasAlpha(_ source: CGImageSource, _ image: CGImage) -> Bool {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let flag = properties[kCGImagePropertyHasAlpha] as? Bool {
            return flag
        }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return hasTransparentPixel(image)
        }
    }

    private static func hasTransparentPixel(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var index = 3
        let end = width * height * 4
        while index < end {
            if bytes[index] != 255 { return true }
            index += 4
        }
        return false
    }
}

// MARK: - Text and source-code attachments

/// UTF-8 text and source files are sent as a fenced text part, so every
/// model can read them (OpenRouter documents file parsing for PDFs only).
enum ChatTextAttachment {
    /// The largest prefix inlined per file; the rest is dropped with a notice.
    static let byteCap = 200_000
    /// First line of every inlined file part; also how sent messages find
    /// the filename again (`filename(in:)`).
    static let headerPrefix = "File: "

    /// File extension → fence language ("" for plain text).
    static let extensionLanguages: [String: String] = [
        "txt": "", "text": "", "log": "", "md": "markdown", "markdown": "markdown", "rst": "", "csv": "csv",
        "tsv": "", "json": "json", "jsonl": "json", "ndjson": "json", "yaml": "yaml", "yml": "yaml",
        "toml": "toml", "ini": "ini", "cfg": "ini", "conf": "", "env": "", "xml": "xml", "plist": "xml",
        "html": "html", "htm": "html", "css": "css", "scss": "scss", "less": "less", "svg": "xml",
        "swift": "swift", "py": "python", "pyi": "python", "rb": "ruby", "php": "php", "js": "javascript",
        "mjs": "javascript", "cjs": "javascript", "jsx": "jsx", "ts": "typescript", "tsx": "tsx",
        "vue": "vue", "go": "go", "rs": "rust", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
        "hpp": "cpp", "hh": "cpp", "m": "objc", "mm": "objc", "java": "java", "kt": "kotlin", "kts": "kotlin",
        "cs": "csharp", "scala": "scala", "dart": "dart", "lua": "lua", "pl": "perl", "r": "r", "sql": "sql",
        "sh": "bash", "bash": "bash", "zsh": "zsh", "fish": "fish", "ps1": "powershell", "bat": "bat",
        "gradle": "groovy", "dockerfile": "dockerfile", "makefile": "makefile", "tf": "hcl", "proto": "protobuf",
        "graphql": "graphql", "gql": "graphql", "diff": "diff", "patch": "diff", "tex": "latex",
        "ex": "elixir", "exs": "elixir", "erl": "erlang", "hs": "haskell", "clj": "clojure", "zig": "zig",
        "nim": "nim", "jl": "julia", "vim": "vim", "srt": "", "vtt": "", "gitignore": "", "editorconfig": "ini",
    ]
    /// Well-known extensionless names.
    static let filenameLanguages: [String: String] = [
        "dockerfile": "dockerfile", "makefile": "makefile", "gemfile": "ruby", "podfile": "ruby",
        "rakefile": "ruby", "procfile": "", "license": "", "readme": "", ".gitignore": "", ".env": "",
        ".zshrc": "bash", ".bashrc": "bash", ".profile": "bash",
    ]

    /// The fence language for a text-like file ("" for plain text), or nil
    /// when the file is not text.
    static func language(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if let language = extensionLanguages[ext] { return language }
        if let language = filenameLanguages[url.lastPathComponent.lowercased()] { return language }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: ext) else { return nil }
        // Rich text conforms to public.text but is not plain text.
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) || type.conforms(to: .pdf) { return nil }
        let textual: [UTType] = [.plainText, .sourceCode, .json, .xml, .yaml, .script, .html, .propertyList]
        return textual.contains(where: { type.conforms(to: $0) }) ? "" : nil
    }

    /// A user-facing reason the file cannot be attached as text, or nil.
    /// Checks only the prefix that would be sent.
    static func validate(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "Could not read \(url.lastPathComponent)."
        }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: byteCap + 4)) ?? Data()
        return decode(prefix, allowTruncatedTail: prefix.count > byteCap) == nil ? notTextMessage(url.lastPathComponent) : nil
    }

    static func notTextMessage(_ filename: String) -> String {
        "\(filename) isn't UTF-8 text, so it can't be attached. Save it as UTF-8, or attach it as a PDF."
    }

    /// The fenced text part for one file, truncated to `byteCap` with an
    /// honest notice.
    nonisolated static func encode(data: Data, filename: String, language: String?) throws -> String {
        let truncated = data.count > byteCap
        let slice = truncated ? data.prefix(byteCap) : data
        guard let text = decode(Data(slice), allowTruncatedTail: truncated) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: notTextMessage(filename)])
        }
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: text) + 1))
        var out = headerPrefix + filename + "\n" + fence + (language ?? "") + "\n" + text
        if !text.hasSuffix("\n") { out += "\n" }
        out += fence
        if truncated {
            let sent = text.utf8.count
            out += "\n[Truncated: only the first \(byteString(sent)) of \(byteString(data.count)) was attached; "
                + "\((data.count - sent).formatted()) bytes were left out.]"
        }
        return out
    }

    /// The filename of an inlined file part, or nil for any other text.
    static func filename(in text: String) -> String? {
        guard text.hasPrefix(headerPrefix), let newline = text.firstIndex(of: "\n") else { return nil }
        let name = text[text.index(text.startIndex, offsetBy: headerPrefix.count)..<newline]
        let afterHeader = text[text.index(after: newline)...]
        guard !name.isEmpty, afterHeader.hasPrefix("```") else { return nil }
        return String(name)
    }

    /// Strict UTF-8 decode. A cut at `byteCap` may split a multi-byte
    /// character, so up to three trailing bytes are dropped in that case.
    /// NUL bytes mean a binary file even when they decode.
    private static func decode(_ data: Data, allowTruncatedTail: Bool) -> String? {
        let attempts = allowTruncatedTail ? 0...3 : 0...0
        for drop in attempts where data.count >= drop {
            let candidate = data.dropLast(drop)
            if candidate.contains(0) { return nil }
            if let text = String(data: candidate, encoding: .utf8) { return text }
        }
        return nil
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0, current = 0
        for unit in text.utf8 {
            if unit == 96 { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        return longest
    }

    private static func byteString(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Capability diagnostics

/// Explains what the selected model can do with attachments, shown under
/// the composer so a text-only model never silently drops an image.
enum AttachmentCapability {
    static func warnings(model: ModelInfo?, drafts: [ChatAttachmentDraft], settings: GenerationSettings = .default) -> [String] {
        guard let model, !drafts.isEmpty else { return [] }
        var out: [String] = []
        let hasImage = drafts.contains { if case .image = $0.kind { return true }; return false }
        let hasAudio = drafts.contains { if case .audio = $0.kind { return true }; return false }
        let hasVideo = drafts.contains { if case .video = $0.kind { return true }; return false }
        let hasPDF = drafts.contains(where: \.isPDF)
        let otherDocuments = drafts.filter { if case .file = $0.kind { return !$0.isPDF }; return false }
        if hasImage, !model.supportsImages { out.append("This model cannot see images — they will be ignored upstream.") }
        if hasAudio, !model.supportsAudioInput { out.append("This model cannot hear audio — it will be ignored upstream.") }
        if hasVideo, !model.supportsVideoInput { out.append("This model cannot watch video — it will be ignored upstream.") }
        if hasPDF, !model.supportsFileInput { out.append(PDFParsingCopy.warning(engine: settings.pdfEngine)) }
        if !otherDocuments.isEmpty {
            let names = otherDocuments.map(\.filename).joined(separator: ", ")
            out.append(model.supportsFileInput
                ? "Support for \(names) varies by provider; if the reply ignores it, export it as PDF or plain text."
                : "This model takes no file input, and OpenRouter parses only PDFs — \(names) may not reach it. Export it as PDF or plain text.")
        }
        return out
    }
}

/// Composer warnings: the attach-time notes (size, duplicates, unsupported
/// types) plus capability notes recomputed from the model selected now, so
/// switching models adds or clears them in both directions.
enum ComposerWarnings {
    static func make(classify: [String], model: ModelInfo?, drafts: [ChatAttachmentDraft],
                     settings: GenerationSettings = .default) -> [String] {
        classify + AttachmentCapability.warnings(model: model, drafts: drafts, settings: settings)
    }
}

/// What OpenRouter does with a PDF for a model that cannot read files
/// natively (docs: features/multimodal/pdfs): it parses the file with the
/// configured `file-parser` engine, defaulting to Mistral OCR. The copy names
/// the engine in use and what it may cost; it never claims the PDF is ignored.
enum PDFParsingCopy {
    static func warning(engine: String?) -> String {
        let trimmed = engine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lead = "This model can't read PDFs natively, so OpenRouter will convert them to text first"
        guard !trimmed.isEmpty else {
            let engine = PDFEngine.openRouterDefault
            return "\(lead) with \(engine.displayName) (its default), \(engine.costNote)."
        }
        guard let known = PDFEngine(rawValue: trimmed.lowercased()) else {
            return "\(lead) with the “\(trimmed)” engine; parsing may be billed."
        }
        if known == .native {
            return "The PDF engine is set to “native”, which needs a model that reads files itself. "
                + "This model doesn't, so the request may fail — pick another engine or model."
        }
        return "\(lead) with \(known.displayName), \(known.costNote)."
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

    /// Returns nil when the paste was consumed as attachments, otherwise the
    /// original event so normal text paste continues.
    @MainActor
    private static func handlePaste(_ event: NSEvent, isActive: @MainActor () -> Bool,
                                    onAttach: @MainActor ([URL]) -> Void,
                                    onError: @MainActor (String) -> Void) -> NSEvent? {
        let pasteboard = NSPasteboard.general
        guard isActive(), PasteboardAttachments.hasAttachments(pasteboard) else { return event }
        do {
            let urls = try PasteboardAttachments.urls(from: pasteboard)
            guard !urls.isEmpty else { return event }
            onAttach(urls)
        } catch {
            let message = "Could not paste the image: " + error.localizedDescription
            onError(message)
        }
        return nil
    }

    func install(isActive: @escaping @MainActor () -> Bool, onAttach: @escaping @MainActor ([URL]) -> Void,
                 onError: @escaping @MainActor (String) -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let handled: NSEvent? = MainActor.assumeIsolated {
                Self.handlePaste(event, isActive: isActive, onAttach: onAttach, onError: onError)
            }
            return handled
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
