#!/bin/bash
# 构建 BrewPing Desktop 的 Mac 安装包（dmg）。
#
# 与 build-app.sh 配合使用：先跑 build-app.sh 生成 .app，再跑本脚本打包。
#
# 本脚本做三件事：
#   1. ad-hoc 深签名（解决"文件已损坏"）：
#      swift build 的产物只是 linker-signed，Resources/AppIcon.icns 等资源
#      不在签名覆盖范围内。浏览器下载的 dmg 解开后带 quarantine 属性，
#      Gatekeeper 校验资源 hash 不匹配 → 弹"已损坏"。
#      `codesign --force --deep --sign -` 重签后资源校验通过，
#      不再报"已损坏"（仍会提示"无法验证开发者"，右键打开即可，属正常）。
#   2. 用 dmgbuild 设置安装界面（背景图、图标位置、窗口大小）。
#      不用 AppleScript：新版 macOS 对 Finder 自动化报 -10004 权限违例。
#      背景图由 tools/make-dmg-background.py 生成。
#   3. 替换 productPage 的两份安装包。
#
# 依赖：
#   - /Users/banmu/.workbuddy/binaries/python/envs/default（含 dmgbuild）
#   - 背景图 build/dmg-background.png（缺失时自动生成）
#
# 用法：bash build-dmg.sh
set -e
cd "$(dirname "$0")"

APP_NAME="BrewPing Desktop"
APP_DIR="build/${APP_NAME}.app"
VOL_NAME="BrewPing Desktop"
BG_IMG="build/dmg-background.png"
OUT_DMG="build/BrewPing-Desktop-0.1.0.dmg"
PRODUCT_PAGE_INSTALL="/Users/banmu/productPage"
PYTHON="/Users/banmu/.workbuddy/binaries/python/envs/default/bin/python3"
DMGBUILD="/Users/banmu/.workbuddy/binaries/python/envs/default/bin/dmgbuild"

# ---------- 1. ad-hoc 深签名 ----------
echo "==> Re-signing ${APP_NAME}.app (ad-hoc, deep)..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=1 "$APP_DIR"
echo "    signature OK"

# ---------- 2. 生成背景图（缺失时自动补） ----------
if [ ! -f "$BG_IMG" ]; then
    echo "==> Generating dmg background image..."
    "$PYTHON" tools/make-dmg-background.py
fi

# ---------- 3. dmgbuild 打包（签名 + 布局一步完成） ----------
echo "==> Building dmg with dmgbuild..."
rm -f "$OUT_DMG"
"$DMGBUILD" -s tools/dmgbuild-settings.py "$VOL_NAME" "$OUT_DMG"

# ---------- 4. 同步到 productPage ----------
echo "==> Syncing to productPage..."
cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/install/BrewPing-Desktop-0.1.0.dmg"
cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/public/install/BrewPing-Desktop-0.1.0.dmg"

echo ""
echo "Done: $OUT_DMG"
echo "Synced: $PRODUCT_PAGE_INSTALL/install/ + public/install/"
echo "Verify: open '$OUT_DMG'"
