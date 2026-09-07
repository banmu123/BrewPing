#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="BrewPing Desktop"
APP_DIR="build/${APP_NAME}.app"
EXEC_NAME="BrewPingDesktop"

echo "Building ${EXEC_NAME}..."
swift build --target BrewPingDesktop -c release 2>/dev/null || swift build --target BrewPingDesktop

echo "Creating ${APP_NAME}.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp ".build/arm64-apple-macosx/debug/${EXEC_NAME}" "$APP_DIR/Contents/MacOS/${EXEC_NAME}"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BrewPingDesktop</string>
    <key>CFBundleIdentifier</key>
    <string>local.brewping.desktop</string>
    <key>CFBundleName</key>
    <string>BrewPing Desktop</string>
    <key>CFBundleDisplayName</key>
    <string>BrewPing Desktop</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo ""
echo "Done: ${APP_DIR}"
echo "Run: open '${APP_DIR}'"
