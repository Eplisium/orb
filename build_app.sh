#!/bin/bash
# build_app.sh — package the SwiftPM ORB executable into a macOS .app bundle.
#
# Usage:
#   bash build_app.sh [options] [AppName]
#
# Options:
#   --release        Package the release configuration (same as CONFIG=release).
#   --debug          Package the debug configuration (default).
#   --adhoc          Ad-hoc sign (`codesign -s -`) and never create or import a
#                    signing identity. Automatic when $CI is set.
#   --build          Run `swift build` for the chosen configuration first.
#   --output DIR     Write the bundle into DIR (default: the repository root).
#   -h, --help       Show this help.
#
# Environment:
#   CONFIG=debug|release   Build configuration (overridden by --release/--debug).
#   CI=...                 Any non-empty value implies --adhoc.
#
# Prerequisite: `swift build [-c release]` has succeeded, or pass --build.
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

# --- Configuration ---
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-debug}"
ADHOC=0
RUN_BUILD=0
OUTPUT_DIR="$PROJECT_DIR"
APP_NAME="ORB"
if [ -n "${CI:-}" ]; then ADHOC=1; fi

while [ $# -gt 0 ]; do
    case "$1" in
        --release) CONFIG="release" ;;
        --debug) CONFIG="debug" ;;
        --adhoc) ADHOC=1 ;;
        --build) RUN_BUILD=1 ;;
        --output)
            [ $# -ge 2 ] || { echo "Error: --output needs a directory" >&2; exit 2; }
            OUTPUT_DIR="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Error: unknown option $1" >&2; usage >&2; exit 2 ;;
        *) APP_NAME="$1" ;;
    esac
    shift
done

case "$CONFIG" in
    debug|release) ;;
    *) echo "Error: CONFIG must be debug or release (got '$CONFIG')" >&2; exit 2 ;;
esac

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
BUNDLE_ID="com.eplisium.orb"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.icns"

# --- Version ---
# Marketing version comes from VERSION; the build number is the commit count so
# every commit on a branch produces a monotonically increasing CFBundleVersion.
if [ -f "$PROJECT_DIR/VERSION" ]; then
    SHORT_VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
else
    SHORT_VERSION="0.0.0"
fi
if ! [[ "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Error: VERSION must look like 1.2.3 (got '$SHORT_VERSION')" >&2
    exit 1
fi
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$PROJECT_DIR"

# --- Locate (optionally build) the binary ---
if [ "$RUN_BUILD" = 1 ]; then
    echo "==> swift build -c $CONFIG"
    swift build -c "$CONFIG" --product "$APP_NAME"
fi
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
if [ ! -x "$BINARY" ]; then
    echo "Error: $BINARY not found. Run 'swift build -c $CONFIG' first (or pass --build)." >&2
    exit 1
fi
echo "Found binary: $BINARY"
echo "Version: $SHORT_VERSION ($BUILD_NUMBER), configuration: $CONFIG"

# --- Remove old bundle ---
rm -rf "$APP_BUNDLE"

# --- Create .app bundle structure ---
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# --- Copy binary ---
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundles (none today) must ship next to the executable.
for resource_bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$resource_bundle" ] || continue
    case "$(basename "$resource_bundle")" in
        *Tests*.bundle) continue ;;
    esac
    cp -R "$resource_bundle" "$APP_BUNDLE/Contents/Resources/"
done

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
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>orb</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# --- App icon ---
# The rendered icon is committed; regenerate only if it has been deleted.
if [ ! -f "$ICON_SOURCE" ]; then
    echo "==> Resources/AppIcon.icns missing; rendering it with scripts/make_icon.swift"
    swift "$PROJECT_DIR/scripts/make_icon.swift" "$ICON_SOURCE"
fi
cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# --- Codesign ---
if [ "$ADHOC" = 1 ]; then
    # Ad-hoc signatures change on every build, so Keychain ACLs and TCC grants
    # do not carry over between builds. Fine for CI and downloaded artifacts.
    echo "Codesigning (ad-hoc)..."
    codesign --force --deep --sign - "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
    echo "Signed: ad-hoc ✓"
else
    # A stable self-signed identity keeps Keychain ACLs and TCC grants alive
    # across local rebuilds (ad-hoc produces a new identity every time).
    CERT_NAME="ORB Code Signing"
    CERT_DIR="$PROJECT_DIR/codesign"
    find_identity() {
        security find-identity -p codesigning 2>/dev/null \
            | grep -o "[0-9A-F]\{40\} \"$CERT_NAME\"" | grep -o "[0-9A-F]\{40\}" | head -1 || true
    }
    IDENTITY="$(find_identity)"

    if [ -z "$IDENTITY" ]; then
        echo "==> Creating self-signed code-signing identity (one-time)"
        mkdir -p "$CERT_DIR"
        if [ ! -f "$CERT_DIR/orb.p12" ]; then
            openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
                -days 3650 -nodes -subj "/CN=$CERT_NAME/O=ORB" \
                -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" 2>/dev/null
            openssl pkcs12 -export -out "$CERT_DIR/orb.p12" \
                -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" -passout pass:orb 2>/dev/null
        fi
        security import "$CERT_DIR/orb.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
            -T /usr/bin/codesign -P orb 2>/dev/null || true
        IDENTITY="$(find_identity)"
    fi

    RCODESIGN="$(command -v rcodesign || echo "$HOME/bin/rcodesign")"
    echo "Codesigning ($CERT_NAME)..."
    if [ -x "$RCODESIGN" ] && [ -f "$CERT_DIR/cert.pem" ] && [ -f "$CERT_DIR/orb.p12" ]; then
        LEAF_SHA1=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -fingerprint -sha1 \
            | sed 's/.*=//; s/:://g; s/://g' | tr 'A-F' 'a-f')
        REQ_TEXT="$(mktemp)"
        REQ_BIN="$(mktemp)"
        printf 'identifier "%s" and certificate leaf = H"%s"' "$BUNDLE_ID" "$LEAF_SHA1" > "$REQ_TEXT"
        csreq -r "$REQ_TEXT" -b "$REQ_BIN"
        SIGN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        "$RCODESIGN" sign --signing-time "$SIGN_TS" \
            --p12-file "$CERT_DIR/orb.p12" --p12-password orb \
            --code-requirements-file "$REQ_BIN" "$APP_BUNDLE"
        rm -f "$REQ_TEXT" "$REQ_BIN"
        codesign --verify --deep --strict "$APP_BUNDLE" && echo "Signed: stable dev identity ✓"
    else
        echo "WARNING: rcodesign or the codesign/ identity files are missing"
        echo "         (rcodesign: https://github.com/indygreg/apple-platform-rs/releases)."
        echo "WARNING: falling back to ad-hoc signing (Keychain/TCC prompts return after rebuilds)."
        codesign --force --deep --sign - "$APP_BUNDLE"
    fi
fi

# --- Report ---
echo ""
echo "=== App bundle created ==="
echo "Location: $APP_BUNDLE"
echo "Version:  $SHORT_VERSION ($BUILD_NUMBER)"
echo "Size:     $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""
echo "Bundle structure:"
find "$APP_BUNDLE" -type f | sort | sed "s|$APP_BUNDLE/||"
echo ""
echo "To launch: open \"$APP_BUNDLE\""
