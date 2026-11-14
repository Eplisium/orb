import AppKit
import AVFoundation
import ImageIO

// MARK: - Library / studio thumbnails
//
// Thumbnails are decoded from the stored file with ImageIO's thumbnail API
// (downsampled at decode time, no full-size bitmap, no checksum pass) and
// cached in memory by creation ID + pixel size.

final class CreationThumbnails: @unchecked Sendable {
    static let shared = CreationThumbnails()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    func cached(id: UUID, maxPixel: Int) -> NSImage? {
        cache.object(forKey: Self.key(id, maxPixel))
    }

    /// Decodes (off the main actor) and caches a thumbnail for an image file.
    func thumbnail(id: UUID, fileURL: URL, maxPixel: Int) async -> NSImage? {
        let key = Self.key(id, maxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) {
            Self.decode(fileURL: fileURL, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Poster frame for a video file (STUDIO-1), generated off the main
    /// actor with AVAssetImageGenerator and cached like image thumbnails.
    /// Managed files have no extension, so the MIME type is passed through.
    func videoPoster(id: UUID, fileURL: URL, mimeType: String?, maxPixel: Int) async -> NSImage? {
        let key = Self.key(id, maxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) {
            await Self.decodeVideoPoster(fileURL: fileURL, mimeType: mimeType, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func decodeVideoPoster(fileURL: URL, mimeType: String?, maxPixel: Int) async -> NSImage? {
        var options: [String: Any] = [:]
        if let mimeType, !mimeType.isEmpty, fileURL.pathExtension.isEmpty {
            options[AVURLAssetOverrideMIMETypeKey] = mimeType
        }
        let asset = AVURLAsset(url: fileURL, options: options)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let side = CGFloat(max(1, maxPixel))
        generator.maximumSize = CGSize(width: side, height: side)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        // A frame slightly in, so a fade-from-black opening is not the poster.
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let seconds = duration.isFinite && duration > 0 ? min(1, duration / 3) : 0
        guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        let cgImage = result.image
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func removeAll() { cache.removeAllObjects() }

    /// Downsampled decode; never materialises the full-size image.
    static func decode(fileURL: URL, maxPixel: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func key(_ id: UUID, _ maxPixel: Int) -> NSString {
        "\(id.uuidString)@\(maxPixel)" as NSString
    }
}
