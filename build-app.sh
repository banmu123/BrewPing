#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="BrewPing Desktop"
APP_DIR="build/${APP_NAME}.app"
EXEC_NAME="BrewPingDesktop"
APP_ICON="logo/AppIcon.icns"

# 1 = 应用常驻 Dock（不写 LSUIElement）；0 = 纯菜单栏应用，不出现在 Dock
SHOW_IN_DOCK="${SHOW_IN_DOCK:-1}"

echo "Building ${EXEC_NAME}..."
# 🚨 不要用 `swift build --target BrewPingDesktop`：
#    那只会编译 BrewPingDesktop 这个 target 本身，依赖库 BrewPingCore
#    （HTTPAPI / ApprovalGate / DangerPattern 等全在里面）**不会被重新编译**，
#    结果是改完 Core 后打出来的 .app 仍然跑旧逻辑（2026-09-11 实际踩到：
#    iOS 切授权模式一直没反应，因为 .app 里根本没有 /api/approvals 路由）。
#    必须全量构建。
# 🚨 必须带 --disable-sandbox：本机沙盒会拦截 SwiftPM 的写操作，缺了它构建会静默失败。
BUILD_CONFIG="release"
if ! swift build -c release --disable-sandbox; then
    echo "Release build unavailable, falling back to debug..."
    BUILD_CONFIG="debug"
    swift build --disable-sandbox
fi

# 从实际构建配置对应的产物目录取二进制（release/debug 路径不同）
BIN_DIR="$(swift build -c "$BUILD_CONFIG" --disable-sandbox --show-bin-path 2>/dev/null | tail -n 1)"
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

# 应用图标：必须在 Resources 里放 .icns，并在 Info.plist 里用 CFBundleIconFile 指过去，
# 否则 Finder / Dock / 安装包都只会显示系统通用图标。
if [ ! -f "$APP_ICON" ]; then
    echo "error: 找不到图标 ${APP_ICON}，请先执行：" >&2
    echo "       python3 tools/make-appicon.py" >&2
    exit 1
fi
cp "$APP_ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>BrewPing accepts commands from your iPhone and Apple Watch on the local network.</string>
</dict>
</plist>
PLIST

# LSUIElement=true 会让进程变成「后台代理」，Dock 与 ⌘Tab 里都看不到它。
if [ "$SHOW_IN_DOCK" != "1" ]; then
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP_DIR/Contents/Info.plist"
    echo "LSUIElement=true（纯菜单栏模式，不显示 Dock 图标）"
fi

# 让 Finder / IconServices 立刻丢弃该路径下的旧图标缓存
touch "$APP_DIR" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo ""
echo "Done: ${APP_DIR}"
echo "Run: open '${APP_DIR}'"
