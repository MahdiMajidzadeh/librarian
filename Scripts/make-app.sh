#!/bin/bash
# Builds Librarian.app from the SPM executable.
# Usage: Scripts/make-app.sh [output-dir]   (default: repo root)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-.}"
APP="$OUT_DIR/Librarian.app"

echo "Building release binary…"
swift build -c release

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BookShelf "$APP/Contents/MacOS/Librarian"

if [ -f icon.png ]; then
    echo "Generating AppIcon.icns from icon.png…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Librarian</string>
    <key>CFBundleIdentifier</key>
    <string>local.librarian</string>
    <key>CFBundleName</key>
    <string>Librarian</string>
    <key>CFBundleDisplayName</key>
    <string>Librarian</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string></string>
</dict>
</plist>
PLIST

echo "Done: $APP"
echo "Run it with:  open \"$APP\""
