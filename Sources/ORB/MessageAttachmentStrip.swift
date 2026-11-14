import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sent attachments under a user message
//
// A user turn shows what it carried: image thumbnails (click for full
// screen) and a chip per document, inlined text file, audio clip or video,
// so the user can check they attached the right thing before reading the
// answer.

/// One visible attachment of a sent message.
enum SentAttachmentItem: Equatable {
    /// `index` is the part's position, used as a stable thumbnail cache key.
    case image(index: Int, dataURL: String)
    case remoteImage(url: String)
    case file(name: String, typeLabel: String)
    case text(name: String)
    case audio(format: String)
    case video

    var iconName: String {
        switch self {
        case .image, .remoteImage: return "photo"
        case .file: return "doc"
        case .text: return "doc.text"
        case .audio: return "waveform"
        case .video: return "video"
        }
    }

    var title: String {
        switch self {
        case .image: return "Image"
        case .remoteImage(let url): return URL(string: url).map(\.lastPathComponent).flatMap { $0.isEmpty || $0 == "/" ? nil : $0 } ?? "Image link"
        case .file(let name, _): return name
        case .text(let name): return name
        case .audio(let format): return "Audio (\(format))"
        case .video: return "Video"
        }
    }

    /// Short type badge on a chip.
    var badge: String? {
        switch self {
        case .file(_, let label): return label
        case .text(let name):
            let ext = (name as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "text" : ext
        default: return nil
        }
    }
}

enum SentAttachmentSummary {
    /// Visible attachments in send order. Text parts are attachments only
    /// when they are inlined files (`ChatTextAttachment` header); any other
    /// text part is message prose and is not repeated here.
    static func items(_ parts: [MessageContentPart]) -> [SentAttachmentItem] {
        parts.enumerated().compactMap { index, part in
            switch part {
            case .text(let text, _):
                return ChatTextAttachment.filename(in: text).map { .text(name: $0) }
            case .image(let url, _):
                return url.hasPrefix("data:") ? .image(index: index, dataURL: url) : .remoteImage(url: url)
            case .file(let filename, let fileData, _):
                return .file(name: filename.flatMap { $0.isEmpty ? nil : $0 } ?? "Document", typeLabel: typeLabel(filename: filename, dataURL: fileData))
            case .audio(_, let format):
                return .audio(format: format)
            case .video:
                return .video
            }
        }
    }

    static func typeLabel(filename: String?, dataURL: String?) -> String {
        if let ext = filename.map({ ($0 as NSString).pathExtension.lowercased() }), !ext.isEmpty { return ext }
        if let dataURL, dataURL.hasPrefix("data:") {
            let mime = dataURL.dropFirst(5).prefix { $0 != ";" && $0 != "," }
            if let ext = UTType(mimeType: String(mime))?.preferredFilenameExtension { return ext }
            if let last = mime.split(separator: "/").last { return String(last) }
        }
        return "file"
    }
}

/// Thumbnails and chips for a sent user message's attachments.
struct MessageAttachmentStrip: View {
    let messageID: UUID
    let parts: [MessageContentPart]

    var body: some View {
        let items = SentAttachmentSummary.items(parts)
        if !items.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .image(let index, let dataURL):
                        SentImageThumbnail(cacheKey: "\(messageID.uuidString)#\(index)", dataURL: dataURL)
                    default:
                        SentAttachmentChip(item: item)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(items.count) attachment\(items.count == 1 ? "" : "s")")
        }
    }
}

private struct SentAttachmentChip: View {
    let item: SentAttachmentItem

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: item.iconName)
                .orbFont(size: 11)
                .foregroundStyle(.secondary)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            if let badge = item.badge {
                Text(badge)
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orbSurface(0.08))
                    .clipShape(Capsule())
            }
        }
        .orbFont(size: 11, weight: .medium)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.orbSurface(0.06))
        .clipShape(Capsule())
        .help(item.title)
        .accessibilityElement(children: .combine)
    }
}

/// Decodes a small thumbnail off the main actor; the full image is decoded
/// only when the user opens it.
private struct SentImageThumbnail: View {
    let cacheKey: String
    let dataURL: String

    @State private var thumbnail: NSImage?
    @State private var failed = false

    static let side: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.orbSurface(0.06))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .orbFont(size: 13)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.orbSurface(0.10), lineWidth: 0.5) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { openFullScreen() }
        .help("Click to view full screen")
        .accessibilityElement()
        .accessibilityLabel("Image attachment")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openFullScreen() }
        .task(id: cacheKey) {
            if let cached = SentImageThumbnailCache.image(for: cacheKey) {
                thumbnail = cached
                return
            }
            let source = dataURL
            let pixels = Int(Self.side * 2)
            let png = await Task.detached(priority: .utility) {
                SentImageThumbnailCache.thumbnailPNG(dataURL: source, maxPixelSize: pixels)
            }.value
            if let png, let image = NSImage(data: png) {
                SentImageThumbnailCache.store(image, for: cacheKey)
                thumbnail = image
            } else {
                failed = true
            }
        }
    }

    private func openFullScreen() {
        guard let data = ChatImageAttachment(dataURL: dataURL).inlineData, let image = NSImage(data: data) else { return }
        FullScreenImageViewer.shared.show(image)
    }
}

enum SentImageThumbnailCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    static func image(for key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    static func store(_ image: NSImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    /// A PNG thumbnail of a `data:` image URL, or nil when it can't decode.
    nonisolated static func thumbnailPNG(dataURL: String, maxPixelSize: Int) -> Data? {
        guard let data = ChatImageAttachment(dataURL: dataURL).inlineData,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
