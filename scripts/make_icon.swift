// make_icon.swift — render ORB's app icon and write Resources/AppIcon.icns.
//
// Usage (from the repository root):
//     swift scripts/make_icon.swift [output.icns]
//
// The rendered icon is committed at Resources/AppIcon.icns, so a normal build
// never runs this. build_app.sh only invokes it when that file is missing.
// Re-run it (and commit the result) after changing the artwork below.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1
    ? arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns"

// Render into an explicit 1024x1024 bitmap so the result does not depend on
// the backing scale factor of whatever display (if any) the host has.
func renderMaster() -> NSBitmapImageRep {
    let pixels = 1024
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGSize(width: 1024, height: 1024)

    // Background gradient — OpenRouter purple/blue theme
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.20, blue: 0.65, alpha: 1.0),
        NSColor(srgbRed: 0.15, green: 0.10, blue: 0.40, alpha: 1.0)
    ])
    grad?.draw(in: NSRect(origin: .zero, size: size), angle: -45)

    let center = CGPoint(x: 512, y: 512)

    // Satellite nodes and spokes (drawn first so the centre node covers them)
    let nodePositions: [(CGFloat, CGFloat)] = [
        (200, 800), (824, 800), (150, 350), (874, 350),
        (300, 150), (724, 150), (512, 900)
    ]
    for (nx, ny) in nodePositions {
        let linePath = NSBezierPath()
        linePath.move(to: center)
        linePath.line(to: CGPoint(x: nx, y: ny))
        linePath.lineWidth = 4
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.3).setStroke()
        linePath.stroke()

        let nodeRadius: CGFloat = 45
        let nodeRect = NSRect(x: nx - nodeRadius, y: ny - nodeRadius,
                              width: nodeRadius * 2, height: nodeRadius * 2)
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.7).setFill()
        NSBezierPath(ovalIn: nodeRect).fill()
    }

    // Central circle (router node)
    let circleRadius: CGFloat = 180
    let circleRect = NSRect(x: center.x - circleRadius, y: center.y - circleRadius,
                            width: circleRadius * 2, height: circleRadius * 2)
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95).setFill()
    NSBezierPath(ovalIn: circleRect).fill()

    // Inner "ORB" text
    let orbText = "ORB" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 120, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0.30, green: 0.15, blue: 0.60, alpha: 1.0)
    ]
    let textSize = orbText.size(withAttributes: attrs)
    orbText.draw(at: CGPoint(x: center.x - textSize.width / 2,
                             y: center.y - textSize.height / 2 - 10),
                 withAttributes: attrs)
    return rep
}

func scaled(_ master: NSBitmapImageRep, to pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    context?.imageInterpolation = .high
    NSGraphicsContext.current = context
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    return png
}

let master = renderMaster()
let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory
    .appendingPathComponent("ORB-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try scaled(master, to: pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}

let outputURL = URL(fileURLWithPath: outputPath)
try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with status \(process.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(outputURL.path)")
