#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="BrewPing Desktop"
APP_DIR="build/${APP_NAME}.app"
EXEC_NAME="BrewPingDesktop"

echo "Building ${EXEC_NAME}..."
BUILD_CONFIG="release"
if ! swift build --target BrewPingDesktop -c release 2>/dev/null; then
    echo "Release build unavailable, falling back to debug..."
    BUILD_CONFIG="debug"
    swift build --target BrewPingDesktop
fi

# 从实际构建配置对应的产物目录取二进制（release/debug 路径不同）
BIN_DIR="$(swift build --target BrewPingDesktop -c "$BUILD_CONFIG" --show-bin-path 2>/dev/null | tail -n 1)"
if [ -z "$BIN_DIR" ] || [ ! -f "${BIN_DIR}/${EXEC_NAME}" ]; then
    echo "error: build product not found (config=${BUILD_CONFIG}, dir=${BIN_DIR})" >&2
    exit 1
fi
echo "Using binary: ${BIN_DIR}/${EXEC_NAME}"

echo "Creating ${APP_NAME}.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "${BIN_DIR}/${EXEC_NAME}" "$APP_DIR/Contents/MacOS/${EXEC_NAME}"

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
    <key>NSLocalNetworkUsageDescription</key>
    <string>BrewPing accepts commands from your iPhone and Apple Watch on the local network.</string>
</dict>
</plist>
PLIST

echo ""
echo "Done: ${APP_DIR}"
echo "Run: open '${APP_DIR}'"
