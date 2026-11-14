#!/bin/bash
# verify_bundle.sh — sanity-check a packaged ORB.app (Info.plist keys, version,
# signature). Used by CI and the release workflow after build_app.sh.
#
# Usage: scripts/verify_bundle.sh path/to/ORB.app
set -euo pipefail

APP="${1:?usage: verify_bundle.sh path/to/ORB.app}"
PLIST="$APP/Contents/Info.plist"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$PLIST" ] || { echo "error: $PLIST not found" >&2; exit 1; }

plutil -lint "$PLIST" >/dev/null

status=0
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion CFBundleExecutable \
           CFBundleDevelopmentRegion LSApplicationCategoryType LSMinimumSystemVersion \
           NSHumanReadableCopyright NSAppleEventsUsageDescription; do
    if ! value="$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null)" || [ -z "$value" ]; then
        echo "error: Info.plist is missing $key" >&2
        status=1
    fi
done

expected_version="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST" 2>/dev/null || true)"
if [ "$actual_version" != "$expected_version" ]; then
    echo "error: CFBundleShortVersionString is '$actual_version', VERSION is '$expected_version'" >&2
    status=1
fi

executable="$(plutil -extract CFBundleExecutable raw -o - "$PLIST" 2>/dev/null || true)"
if [ ! -x "$APP/Contents/MacOS/$executable" ]; then
    echo "error: executable Contents/MacOS/$executable is missing" >&2
    status=1
fi

codesign --verify --deep --strict "$APP"
[ "$status" -eq 0 ] && echo "Bundle OK: $APP ($actual_version)"
exit "$status"
