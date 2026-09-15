#!/bin/bash
# 构建 BrewPing Desktop 的 Mac 安装包（dmg）。
#
# 与 build-app.sh 配合使用：先跑 build-app.sh 生成 .app，再跑本脚本打包。
#
# 三种模式（由环境变量决定）：
#
# 1) 完全公证分发（推荐，线上发布用）：
#      DEVELOPER_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#      NOTARY_PROFILE="brewping-notary"   # 见下方"配置 notarytool"
#      bash build-dmg.sh
#    流程：Developer ID 签名 → notarytool 公证 → stapler 装订 → dmgbuild 打包
#    用户双击 dmg 拖到 Applications 后可直接打开，不再有任何 Gatekeeper 提示。
#
# 2) ad-hoc 签名（缺省，无 Apple 证书时用）：
#      bash build-dmg.sh
#    流程：codesign --force --deep --sign - → dmgbuild 打包
#    解决"已损坏"，但首次打开仍提示"无法验证开发者"，需右键打开。
#
# 3) 仅打包（已签名 .app，跳过签名）：
#      SKIP_CODESIGN=1 bash build-dmg.sh
#
# 配置 notarytool（一次性）：
#   xcrun notarytool store-credentials "brewping-notary" \
#     --apple-id you@example.com \
#     --team-id XXXXXXXXXX \
#     --password <app-specific-password>     # 在 account.apple.com 生成
#   凭据存进钥匙串，之后脚本只引用 profile 名。
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

# ---------- 1. 签名 ----------
if [ "${SKIP_CODESIGN:-0}" = "1" ]; then
    echo "==> SKIP_CODESIGN=1, skipping signature"
elif [ -n "$DEVELOPER_IDENTITY" ]; then
    if [ -z "$NOTARY_PROFILE" ]; then
        echo "error: DEVELOPER_IDENTITY set but NOTARY_PROFILE missing" >&2
        exit 1
    fi
    echo "==> Signing with Developer ID: $DEVELOPER_IDENTITY"
    codesign --force --deep --options runtime --sign "$DEVELOPER_IDENTITY" "$APP_DIR"
    codesign --verify --deep --strict --verbose=1 "$APP_DIR"
    echo "    signature OK"
else
    echo "==> Re-signing ${APP_NAME}.app (ad-hoc, deep)..."
    codesign --force --deep --sign - "$APP_DIR"
    codesign --verify --deep --strict --verbose=1 "$APP_DIR"
    echo "    signature OK"
fi

# ---------- 2. 公证 + 装订（仅 Developer ID 模式） ----------
if [ -n "$DEVELOPER_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Submitting to notarization (profile: $NOTARY_PROFILE)..."
    # 公证提交的是 zip（dmg 也可，但 zip 更快反馈，最后再 staple dmg）
    ZIP="build/notary-submit.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    SUBMIT_LOG="build/notary-submit.log"
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$SUBMIT_LOG"
    SUBMIT_ID=$(grep -oE 'id: [a-f0-9-]+' "$SUBMIT_LOG" | head -1 | awk '{print $2}')
    echo "    notarization submission id: ${SUBMIT_ID:-unknown}"
    # 校验公证结果（失败则中止）
    if [ -n "$SUBMIT_ID" ]; then
        xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | tail -10
    fi
    echo "==> Stapling ticket to .app..."
    xcrun stapler staple "$APP_DIR"
    stapler validate "$APP_DIR" 2>&1 | tail -3
    rm -f "$ZIP"
fi

# ---------- 3. 生成背景图（缺失时自动补） ----------
if [ ! -f "$BG_IMG" ]; then
    echo "==> Generating dmg background image..."
    "$PYTHON" tools/make-dmg-background.py
fi

# ---------- 4. dmgbuild 打包 ----------
echo "==> Building dmg with dmgbuild..."
rm -f "$OUT_DMG"
"$DMGBUILD" -s tools/dmgbuild-settings.py "$VOL_NAME" "$OUT_DMG"

# ---------- 5. 给 dmg 本体也装订公证票据 ----------
# 用户下载 dmg 双击挂载后，macOS 会优先看 dmg 的票据，没装订则退回检查 .app
if [ -n "$DEVELOPER_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Stapling ticket to dmg..."
    xcrun stapler staple "$OUT_DMG"
    xcrun stapler validate "$OUT_DMG" 2>&1 | tail -3
fi

# ---------- 6. 同步到 productPage ----------
echo "==> Syncing to productPage..."
cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/install/BrewPing-Desktop-0.1.0.dmg"
cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/public/install/BrewPing-Desktop-0.1.0.dmg"

echo ""
echo "Done: $OUT_DMG"
echo "Synced: $PRODUCT_PAGE_INSTALL/install/ + public/install/"
echo "Verify: open '$OUT_DMG'"
