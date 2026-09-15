#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="BrewPing Desktop"
APP_DIR="build/${APP_NAME}.app"
EXEC_NAME="BrewPingDesktop"
APP_ICON="logo/AppIcon.icns"
# 正式发布版本号（同步写入 Info.plist；DMG 命名见 build-dmg.sh）
APP_VERSION="${APP_VERSION:-1.0.0}"

# 1 = 应用常驻 Dock（不写 LSUIElement）；0 = 纯菜单栏应用，不出现在 Dock
SHOW_IN_DOCK="${SHOW_IN_DOCK:-1}"

# 构建架构：
#   arm64     默认，Apple Silicon（与历史行为一致）
#   x86_64    Intel Mac（交叉编译）
#   universal arm64 + x86_64（Universal 2，正式发布用）
BUILD_ARCH="${BUILD_ARCH:-arm64}"
case "$BUILD_ARCH" in
    arm64|x86_64|universal) ;;
    *) echo "error: BUILD_ARCH 必须是 arm64 / x86_64 / universal" >&2; exit 1 ;;
esac
echo "BUILD_ARCH=${BUILD_ARCH}"

echo "Building ${EXEC_NAME}..."
# 🚨 不要用 `swift build --target BrewPingDesktop`：
#    那只会编译 BrewPingDesktop 这个 target 本身，依赖库 BrewPingCore
#    （HTTPAPI / ApprovalGate / DangerPattern 等全在里面）**不会被重新编译**，
#    结果是改完 Core 后打出来的 .app 仍然跑旧逻辑（2026-09-11 实际踩到：
#    iOS 切授权模式一直没反应，因为 .app 里根本没有 /api/approvals 路由）。
#    必须全量构建。
# 🚨 必须带 --disable-sandbox：本机沙盒会拦截 SwiftPM 的写操作，缺了它构建会静默失败。
# 🚨 正式发布只允许 Release 构建：失败直接退出，禁止 fallback 到 Debug。
# 🚨 universal 不能用 `swift build --arch arm64 --arch x86_64` 直构：
#    多架构模式需要 xcbuild（完整 Xcode 才有；本机 xcode-select 指向 CLT，
#    Xcode.app 也是精简安装没有 xcbuild，实测报错）。
#    改用两次单架构构建 + lipo 合并 —— 与 Xcode Universal 2 产物等价。
if [ "$BUILD_ARCH" = "universal" ]; then
    swift build -c release --disable-sandbox --arch arm64
    ARM_BIN="$(swift build -c release --disable-sandbox --arch arm64 --show-bin-path 2>/dev/null | tail -n 1)/${EXEC_NAME}"
    swift build -c release --disable-sandbox --arch x86_64
    X86_BIN="$(swift build -c release --disable-sandbox --arch x86_64 --show-bin-path 2>/dev/null | tail -n 1)/${EXEC_NAME}"
    [ -f "$ARM_BIN" ] || { echo "error: arm64 slice not found: $ARM_BIN" >&2; exit 1; }
    [ -f "$X86_BIN" ] || { echo "error: x86_64 slice not found: $X86_BIN" >&2; exit 1; }
    mkdir -p build
    SRC_BIN="build/${EXEC_NAME}.universal"
    lipo -create -output "$SRC_BIN" "$ARM_BIN" "$X86_BIN"
    echo "lipo merged slices: $(lipo -archs "$SRC_BIN")"
else
    swift build -c release --disable-sandbox --arch "$BUILD_ARCH"
    BIN_DIR="$(swift build -c release --disable-sandbox --arch "$BUILD_ARCH" --show-bin-path 2>/dev/null | tail -n 1)"
    [ -n "$BIN_DIR" ] && [ -f "${BIN_DIR}/${EXEC_NAME}" ] || {
        echo "error: build product not found (config=release, arch=${BUILD_ARCH}, dir=${BIN_DIR})" >&2
        exit 1
    }
    SRC_BIN="${BIN_DIR}/${EXEC_NAME}"
fi
echo "Using binary: ${SRC_BIN}"

echo "Creating ${APP_NAME}.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$SRC_BIN" "$APP_DIR/Contents/MacOS/${EXEC_NAME}"

# 应用图标：必须在 Resources 里放 .icns，并在 Info.plist 里用 CFBundleIconFile 指过去，
# 否则 Finder / Dock / 安装包都只会显示系统通用图标。
if [ ! -f "$APP_ICON" ]; then
    echo "error: 找不到图标 ${APP_ICON}，请先执行：" >&2
    echo "       python3 tools/make-appicon.py" >&2
    exit 1
fi
cp "$APP_ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" << PLIST
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
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
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
