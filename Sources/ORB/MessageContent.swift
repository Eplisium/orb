import Foundation

// MARK: - Multimodal chat content
//
// OpenRouter chat messages carry either a plain string or an array of typed
// content parts (text, image_url, file, input_audio, video_url). ORB used to
// send text only, which locked out all 258 vision models, 46 audio models,
// 79 video models, and 158 file-capable models for anything but words.

/// Image detail tier. `original` is an OpenRouter extension requesting true
/// original-resolution media; providers without that tier see `high`.
enum ImageDetail: String, Codable, Sendable, Equatable, Hashable {
    case auto, low, high, original
}

/// Anthropic-style cache breakpoint for a text part.
struct PromptCacheControl: Codable, Sendable, Equatable, Hashable {
    let type: String
    init(type: String = "ephemeral") { self.type = type }
}

/// One typed content part inside a multimodal `content` array.
enum MessageContentPart: Codable, Sendable, Equatable, Hashable {
    case text(text: String, cacheControl: PromptCacheControl? = nil)
    case image(url: String, detail: ImageDetail? = nil)
    case file(filename: String? = nil, fileData: String? = nil, fileId: String? = nil)
    case audio(data: String, format: String)
    case video(url: String)

    // MARK: Convenience constructors

    static func textPart(_ text: String) -> MessageContentPart { .text(text: text) }

    /// An image from remote URL or `data:` URL.
    static func imageURLPart(url: String, detail: ImageDetail? = nil) -> MessageContentPart {
        .image(url: url, detail: detail)
    }

    /// Raw image bytes encoded as a `data:` URL part.
    static func imageDataPart(_ data: Data, mimeType: String, detail: ImageDetail? = nil) -> MessageContentPart {
        .image(url: "data:\(mimeType);base64,\(data.base64EncodedString())", detail: detail)
    }

    /// A document (PDF, DOCX, …) as a base64 `data:` URL.
    static func fileDataPart(filename: String, data: Data, mimeType: String) -> MessageContentPart {
        .file(filename: filename, fileData: "data:\(mimeType);base64,\(data.base64EncodedString())")
    }

    /// A file previously uploaded via `POST /files`.
    static func fileIdPart(filename: String? = nil, fileId: String) -> MessageContentPart {
        .file(filename: filename, fileId: fileId)
    }

    /// Raw audio bytes for `input_audio` models (wav, mp3, flac, …).
    static func audioDataPart(_ data: Data, format: String) -> MessageContentPart {
        .audio(data: data.base64EncodedString(), format: format)
    }

    // MARK: Codable

    private enum TypeTag: String, Codable {
        case text, imageURL = "image_url", file, inputAudio = "input_audio", videoURL = "video_url"
    }

    private enum Keys: String, CodingKey {
        case type, text, imageURL = "image_url", file, inputAudio = "input_audio", videoURL = "video_url"
        case cacheControl = "cache_control"
    }

    private struct ImagePayload: Codable, Equatable, Hashable {
        var url: String
        var detail: ImageDetail?
    }

    private struct FilePayload: Codable, Equatable, Hashable {
        var filename: String?
        var fileData: String?
        var fileId: String?

        enum CodingKeys: String, CodingKey {
            case filename
            case fileData = "file_data"
            case fileId = "file_id"
        }
    }

    private struct AudioPayload: Codable, Equatable, Hashable {
        var data: String
        var format: String
    }

    private struct VideoPayload: Codable, Equatable, Hashable {
        var url: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(TypeTag.self, forKey: .type)
        switch type {
        case .text:
            self = .text(
                text: try container.decode(String.self, forKey: .text),
                cacheControl: try container.decodeIfPresent(PromptCacheControl.self, forKey: .cacheControl)
            )
        case .imageURL:
            let payload = try container.decode(ImagePayload.self, forKey: .imageURL)
            self = .image(url: payload.url, detail: payload.detail)
        case .file:
            let payload = try container.decode(FilePayload.self, forKey: .file)
            self = .file(filename: payload.filename, fileData: payload.fileData, fileId: payload.fileId)
        case .inputAudio:
            let payload = try container.decode(AudioPayload.self, forKey: .inputAudio)
            self = .audio(data: payload.data, format: payload.format)
        case .videoURL:
            let payload = try container.decode(VideoPayload.self, forKey: .videoURL)
            self = .video(url: payload.url)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let text, let cacheControl):
            try container.encode(TypeTag.text, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case .image(let url, let detail):
            try container.encode(TypeTag.imageURL, forKey: .type)
            var payload = ImagePayload(url: url, detail: nil)
            payload.detail = detail
            try container.encode(payload, forKey: .imageURL)
        case .file(let filename, let fileData, let fileId):
            try container.encode(TypeTag.file, forKey: .type)
            try container.encode(
                FilePayload(filename: filename, fileData: fileData, fileId: fileId),
                forKey: .file
            )
        case .audio(let data, let format):
            try container.encode(TypeTag.inputAudio, forKey: .type)
            try container.encode(AudioPayload(data: data, format: format), forKey: .inputAudio)
        case .video(let url):
            try container.encode(TypeTag.videoURL, forKey: .type)
            try container.encode(VideoPayload(url: url), forKey: .videoURL)
        }
    }
}

// MARK: - Assistant images (image-output models)
//
// Image-capable chat models return generated images in the assistant message
// (`images: [{image_url: {url}}]`). ORB used to drop them on the floor.

/// One image returned inside an assistant message.
struct AssistantImagePart: Codable, Sendable, Equatable, Hashable {
    /// Remote URL or `data:` URL of the generated image.
    let url: String

    private struct Payload: Codable { let url: String }
    private enum Keys: String, CodingKey { case imageURL = "image_url" }

    init(url: String) { self.url = url }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.url = try container.decode(Payload.self, forKey: .imageURL).url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Payload(url: url), forKey: .imageURL)
    }
}

/// A generated image kept on a `ChatMessage` for display, saving, and export.
struct ChatImageAttachment: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// Remote URL or `data:` URL.
    var dataURL: String
    /// The prompt that produced it, when known.
    var prompt: String?

    init(id: UUID = UUID(), dataURL: String, prompt: String? = nil) {
        self.id = id
        self.dataURL = dataURL
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey { case id, dataURL = "data_url", prompt }

    /// MIME type parsed from a `data:` URL, defaulting to PNG.
    var mimeType: String {
        guard dataURL.hasPrefix("data:") else { return "image/png" }
        let header = dataURL.dropFirst(5).prefix(while: { $0 != ";" && $0 != "," })
        return header.isEmpty ? "image/png" : String(header)
    }

    var isRemoteURL: Bool {
        dataURL.hasPrefix("http://") || dataURL.hasPrefix("https://")
    }

    var isDataURL: Bool { dataURL.hasPrefix("data:") }

    /// Raw bytes when this is a `data:` URL, nil for remote URLs.
    var inlineData: Data? {
        guard isDataURL, let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }

    var fileExtension: String {
        switch mimeType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/svg+xml": return "svg"
        default: return "png"
        }
    }
}

// MARK: - Output modalities & image config

/// Valid `modalities` request values: `["text"]`, plus `"image"` and/or
/// `"audio"` when the model can produce them.
enum OutputModality: String, Codable, CaseIterable, Sendable, Hashable {
    case text, image, audio
}

/// `image_config` for chat requests to image-output models.
struct ChatImageConfig: Codable, Equatable, Sendable, Hashable {
    var aspectRatio: String?
    var quality: String?

    enum CodingKeys: String, CodingKey {
        case aspectRatio = "aspect_ratio"
        case quality
    }

    var isConfigured: Bool { aspectRatio != nil || quality != nil }
}
