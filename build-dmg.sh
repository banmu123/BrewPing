#!/bin/bash
# 构建 BrewPing Desktop 的 Mac 安装包（dmg）——正式发布流程。
#
# 与 build-app.sh 配合使用：先跑 build-app.sh 生成 .app，再跑本脚本打包。
#
# 三种模式（由环境变量决定）：
#
# 1) 完全公证分发（推荐，线上发布用）：
#      DEVELOPER_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#      NOTARY_PROFILE="BrewPingNotary"
#      bash build-dmg.sh
#    流程：Developer ID 签名 → notarize .app → staple .app → dmgbuild
#          → notarize .dmg → staple .dmg → 校验 → SHA256 → 同步 productPage
#    注意：dmg 是独立文件，有自己的内容哈希，必须单独公证后才能 staple；
#          只 staple .app 是不够的（dmg staple 会报 Record not found）。
#    用户双击 dmg 拖到 Applications 后可直接打开，不再有任何 Gatekeeper 提示。
#
# 2) ad-hoc 签名（缺省，无 Apple 证书时用）：
#      bash build-dmg.sh
#    解决"已损坏"，但首次打开仍提示"无法验证开发者"，需右键打开。
#
# 3) 仅打包（已签名 .app，跳过签名）：
#      SKIP_CODESIGN=1 bash build-dmg.sh
#
# 配置 notarytool（一次性）：
#   xcrun notarytool store-credentials "BrewPingNotary" \
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
EXEC_NAME="BrewPingDesktop"
VOL_NAME="BrewPing Desktop"
BG_IMG="build/dmg-background.png"
APP_VERSION="${APP_VERSION:-1.0.0}"
# DMG 文件名后缀：缺省无后缀（universal 主包）；Intel 独立包用 DMG_SUFFIX="-Intel"
DMG_SUFFIX="${DMG_SUFFIX:-}"
DIST_DIR="dist"
OUT_DMG="${DIST_DIR}/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg"
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
    # --options runtime 启用 Hardened Runtime（公证必需）
    # --timestamp 嵌入安全时间戳（公证必需）
    # 🚨 签名必须一次干净完成：中途 kill 会留下 .cstemp 污染 seal，
    #    之后 verify 报 "a sealed resource is missing or invalid"。
    #    如果发生，重跑 build-app.sh 得到干净 .app 再签。
    codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_IDENTITY" "$APP_DIR"
    codesign --verify --deep --strict --verbose=1 "$APP_DIR"
    echo "    signature OK"
else
    echo "==> Re-signing ${APP_NAME}.app (ad-hoc, deep)..."
    codesign --force --deep --sign - "$APP_DIR"
    codesign --verify --deep --strict --verbose=1 "$APP_DIR"
    echo "    signature OK"
fi

# ---------- 2. 公证 + 装订 .app（仅 Developer ID 模式） ----------
NOTARIZE=0
if [ -n "$DEVELOPER_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    NOTARIZE=1
    echo "==> Notarizing .app (profile: $NOTARY_PROFILE)..."
    ZIP="build/notary-submit.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    SUBMIT_LOG="build/notary-submit.log"
    # --wait 轮询至 Accepted/Invalid；Apple 排队偶尔超过 20 分钟属正常
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$SUBMIT_LOG" | tail -5
    SUBMIT_ID=$(grep -oE 'id: [a-f0-9-]+' "$SUBMIT_LOG" | head -1 | awk '{print $2}')
    echo "    submission id: ${SUBMIT_ID:-unknown}"
    if ! grep -q "Accepted" "$SUBMIT_LOG"; then
        echo "error: notarization not Accepted, fetching log..." >&2
        [ -n "$SUBMIT_ID" ] && xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | tail -40 >&2
        exit 3
    fi
    echo "==> Stapling .app..."
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    rm -f "$ZIP" "$SUBMIT_LOG"
fi

# ---------- 3. 生成背景图（缺失时自动补） ----------
if [ ! -f "$BG_IMG" ]; then
    echo "==> Generating dmg background image..."
    "$PYTHON" tools/make-dmg-background.py
fi

# ---------- 4. dmgbuild 打包 ----------
echo "==> Building dmg with dmgbuild..."
mkdir -p "$DIST_DIR"
rm -f "$OUT_DMG"
"$DMGBUILD" -s tools/dmgbuild-settings.py "$VOL_NAME" "$OUT_DMG"

# ---------- 5. 公证 + 装订 .dmg（独立文件，必须单独公证） ----------
if [ "$NOTARIZE" = "1" ]; then
    echo "==> Notarizing .dmg..."
    SUBMIT_LOG="build/notary-submit-dmg.log"
    # dmg 本身就是归档，可直接提交（无需 ditto 重打包）
    xcrun notarytool submit "$OUT_DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$SUBMIT_LOG" | tail -5
    if ! grep -q "Accepted" "$SUBMIT_LOG"; then
        echo "warn: dmg notarization not Accepted, skipping dmg staple (app ticket inside dmg already works)" >&2
    else
        echo "==> Stapling dmg..."
        xcrun stapler staple "$OUT_DMG"
        xcrun stapler validate "$OUT_DMG"
    fi
    rm -f "$SUBMIT_LOG"
fi

# ---------- 6. 校验 ----------
echo "==> Verifications..."
echo "    main binary archs: $(lipo -archs "$APP_DIR/Contents/MacOS/${EXEC_NAME}")"
codesign --verify --deep --strict "$APP_DIR" && echo "    codesign .app: OK"
spctl --assess --type execute -vv "$APP_DIR" || true
spctl --assess --type install -vv "$OUT_DMG" || true

# ---------- 7. SHA256 + 同步到 productPage ----------
echo "==> SHA256..."
shasum -a 256 "$OUT_DMG" | tee "${OUT_DMG}.sha256"

echo "==> Syncing to productPage..."
cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg"
cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/public/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg"
cp -f "${OUT_DMG}.sha256" "$PRODUCT_PAGE_INSTALL/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg.sha256"
cp -f "${OUT_DMG}.sha256" "$PRODUCT_PAGE_INSTALL/public/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg.sha256"

echo ""
echo "Done: $OUT_DMG"
echo "Synced: $PRODUCT_PAGE_INSTALL/install/ + public/install/"
echo "Verify: open '$OUT_DMG'"
