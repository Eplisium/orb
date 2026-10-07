import AppKit
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
