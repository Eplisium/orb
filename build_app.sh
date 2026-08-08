#!/bin/bash
# build_app.sh — Package a Swift Package Manager binary into a macOS .app bundle
# Usage: Place in your project root, then run: bash build_app.sh
# Prerequisites: swift build must have succeeded (run it first)
set -e

# --- Configuration ---
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="${1:-$(basename "$PROJECT_DIR")}"  # Default to dir name, or pass as arg
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
BUNDLE_ID="com.eplisium.openrouter-browser"

# --- Find the built binary ---
# Exclude dSYM/DWARF paths — SPM creates .build/.../debug/MyApp.dSYM/Contents/Resources/DWARF/MyApp
# which also matches the name but is NOT the executable binary
BINARY=$(find "$BUILD_DIR" -name "$APP_NAME" -type f -not -path "*/dSYM/*" -not -path "*/DWARF/*" | head -1)
if [ -z "$BINARY" ]; then
    echo "Error: Built binary not found. Run 'swift build' first."
    exit 1
fi
echo "Found binary: $BINARY"

# --- Remove old bundle ---
rm -rf "$APP_BUNDLE"

# --- Create .app bundle structure ---
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# --- Copy binary ---
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# --- Create Info.plist ---
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# --- Generate app icon ---
echo "Generating app icon..."
export PROJECT_DIR APP_NAME
swift - << 'ICONSWIFT'
import AppKit
import CoreGraphics

let size = CGSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

// Background gradient — OpenRouter purple/blue theme
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.35, green: 0.20, blue: 0.65, alpha: 1.0),
    NSColor(srgbRed: 0.15, green: 0.10, blue: 0.40, alpha: 1.0)
])
grad?.draw(in: NSRect(origin: .zero, size: size), angle: -45)

// Central circle (router node)
let center = CGPoint(x: 512, y: 512)
let circleRadius: CGFloat = 180
let circleRect = NSRect(x: center.x - circleRadius, y: center.y - circleRadius,
                         width: circleRadius * 2, height: circleRadius * 2)
let circlePath = NSBezierPath(ovalIn: circleRect)
NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.95).setFill()
circlePath.fill()

// Inner "OR" text
let orText = "OR" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 140, weight: .heavy),
    .foregroundColor: NSColor(srgbRed: 0.30, green: 0.15, blue: 0.60, alpha: 1.0)
]
let textSize = orText.size(withAttributes: attrs)
orText.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2 - 10), withAttributes: attrs)

// Satellite nodes around the center
let nodePositions: [(CGFloat, CGFloat)] = [
    (200, 800), (824, 800), (150, 350), (874, 350),
    (300, 150), (724, 150), (512, 900)
]
for (nx, ny) in nodePositions {
    let nodeRadius: CGFloat = 45
    let nodeRect = NSRect(x: nx - nodeRadius, y: ny - nodeRadius,
                          width: nodeRadius * 2, height: nodeRadius * 2)
    let nodePath = NSBezierPath(ovalIn: nodeRect)
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.7).setFill()
    nodePath.fill()

    // Line from center to node
    let linePath = NSBezierPath()
    linePath.move(to: center)
    linePath.line(to: CGPoint(x: nx, y: ny))
    linePath.lineWidth = 4
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.3).setStroke()
    linePath.stroke()
}

img.unlockFocus()

// Build iconset with all required sizes
let iconsetPath = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetPath)
try! FileManager.default.createDirectory(at: iconsetPath, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let sized = NSImage(size: CGSize(width: px, height: px))
    sized.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: CGSize(width: px, height: px)))
    sized.unlockFocus()
    let sizedTiff = sized.tiffRepresentation!
    let sizedRep = NSBitmapImageRep(data: sizedTiff)!
    // NOTE: properties parameter is REQUIRED in Swift 6.3 — no default value
    let sizedPng = sizedRep.representation(using: .png, properties: [:])!
    let path = iconsetPath.appendingPathComponent("\(name).png")
    try! sizedPng.write(to: path)
}

// Convert to .icns using iconutil
let projectDir = ProcessInfo.processInfo.environment["PROJECT_DIR"] ?? FileManager.default.currentDirectoryPath
let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "MyApp"
let icnsPath = URL(fileURLWithPath: "\(projectDir)/\(appName).app/Contents/Resources/AppIcon.icns")

let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconsetPath.path, "-o", icnsPath.path]
proc.launch()
proc.waitUntilExit()

try? FileManager.default.removeItem(at: iconsetPath)
print("Icon generated at \(icnsPath.path)")
ICONSWIFT

# --- Add icon reference to Info.plist ---
if [ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    echo "Icon added to bundle"
fi

# --- Codesign (ad-hoc, no certificate needed) ---
echo "Codesigning..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 || echo "Codesign warning (may still work)"

# --- Report ---
echo ""
echo "=== App bundle created ==="
echo "Location: $APP_BUNDLE"
echo "Size: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""
echo "Bundle structure:"
find "$APP_BUNDLE" -type f | sort | sed "s|$APP_BUNDLE/||"
echo ""
echo "To launch: open $APP_BUNDLE"
