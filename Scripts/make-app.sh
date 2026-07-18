#!/bin/bash
# Builds Book Shelf.app from the SPM executable.
# Usage: Scripts/make-app.sh [output-dir]   (default: repo root)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-.}"
APP="$OUT_DIR/Book Shelf.app"

echo "Building release binary…"
swift build -c release

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BookShelf "$APP/Contents/MacOS/BookShelf"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BookShelf</string>
    <key>CFBundleIdentifier</key>
    <string>local.bookshelf</string>
    <key>CFBundleName</key>
    <string>Book Shelf</string>
    <key>CFBundleDisplayName</key>
    <string>Book Shelf</string>
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
