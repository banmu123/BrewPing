#!/bin/bash
# 构建 BrewPing Desktop 的 Mac 正式发布包（dmg）—— 完整发布流程。
#
# 流程：构建(.app) → 架构校验 → Developer ID 签名(Hardened Runtime) → 签名校验
#       → 公证 .app + staple → dmgbuild → 公证 .dmg + staple → Gatekeeper 校验
#       → SHA256 → 同步 productPage
#
# 用法：
#   ./build-dmg.sh                 # 跑完整流程（构建 + 签名 + 公证 + 打包 + 校验）
#   ./build-dmg.sh --build         # 只构建 .app（universal）
#   ./build-dmg.sh --sign          # 只签名 + 校验签名
#   ./build-dmg.sh --notarize      # 只公证 + staple（.app 与 dist 里最新的 dmg）
#   ./build-dmg.sh --verify        # 只做最终校验（codesign / spctl / stapler）
#
# 关键环境变量（都可缺省，脚本会自动推断）：
#   DEVELOPER_IDENTITY  证书全名，如 "Developer ID Application: Your Name (TEAMID)"
#                       缺省时自动取钥匙串里第一个 Developer ID Application 身份
#                       （只会匹配 Developer ID，绝不会误用 Apple Development）
#   NOTARY_PROFILE      公证 profile（默认 BrewPingNotary）
#   APP_VERSION         版本号（默认读 Scripts/mac/Info.plist 的 CFBundleShortVersionString）
#   BUILD_ARCH          arm64 / x86_64 / universal（默认 universal）
#   ALLOW_SINGLE_ARCH   1 = 允许非 universal（自测用；正式发布不要开）
#   SKIP_CODESIGN       1 = 跳过签名（仅 ad-hoc 自测）
#   DMG_SUFFIX          dmg 文件名后缀（如 "-Intel"）
#
# 公证凭据**只**通过钥匙串 profile 引用，脚本里不出现任何 Apple ID / 密码 / API Key：
#   xcrun notarytool store-credentials "BrewPingNotary" \
#     --apple-id you@example.com --team-id XXXXXXXXXX \
#     --password <app-specific-password>     # 在 account.apple.com 生成
#
# 依赖：dmgbuild（/Users/banmu/.workbuddy/binaries/python/envs/default）、背景图 build/dmg-background.png
set -e
cd "$(dirname "$0")"

APP_NAME="BrewPing Desktop"
APP_DIR="build/${APP_NAME}.app"
EXEC_NAME="BrewPingDesktop"
VOL_NAME="BrewPing Desktop"
BG_IMG="build/dmg-background.png"
DIST_DIR="dist"
PRODUCT_PAGE_INSTALL="/Users/banmu/productPage"
PYTHON="/Users/banmu/.workbuddy/binaries/python/envs/default/bin/python3"
DMGBUILD="/Users/banmu/.workbuddy/binaries/python/envs/default/bin/dmgbuild"
ENTITLEMENTS="Scripts/mac/Desktop.entitlements"
BUNDLE_ID="com.brewping.desktop"

# ---------- 参数 ----------
DO_BUILD=0; DO_SIGN=0; DO_NOTARIZE=0; DO_VERIFY=0
if [ $# -eq 0 ]; then
    DO_BUILD=1; DO_SIGN=1; DO_NOTARIZE=1; DO_VERIFY=1
else
    for arg in "$@"; do
        case "$arg" in
            --build) DO_BUILD=1 ;;
            --sign) DO_SIGN=1 ;;
            --notarize) DO_NOTARIZE=1 ;;
            --verify) DO_VERIFY=1 ;;
            --all) DO_BUILD=1; DO_SIGN=1; DO_NOTARIZE=1; DO_VERIFY=1 ;;
            -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
            *) echo "error: 未知参数 $arg（支持 --build/--sign/--notarize/--verify/--all）" >&2; exit 1 ;;
        esac
    done
fi

stage() { echo; echo "==> $*"; }

# ---------- 版本号 ----------
if [ -z "${APP_VERSION:-}" ]; then
    APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - Scripts/mac/Info.plist 2>/dev/null || true)"
    [ -n "$APP_VERSION" ] || { echo "error: 无法从 Scripts/mac/Info.plist 读取版本号，请显式设置 APP_VERSION" >&2; exit 1; }
fi
DMG_SUFFIX="${DMG_SUFFIX:-}"
OUT_DMG="${DIST_DIR}/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg"
echo "版本: ${APP_VERSION}   输出: ${OUT_DMG}"

# ---------- 前置检查 ----------
stage "前置检查"
for cmd in xcrun codesign ditto hdiutil shasum plutil lipo; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: 缺少命令 $cmd" >&2; exit 1; }
done
[ -f "$ENTITLEMENTS" ] || { echo "error: 缺少 entitlements: $ENTITLEMENTS" >&2; exit 1; }
if [ "$DO_BUILD" = "1" ] || [ "$DO_NOTARIZE" = "1" ]; then
    [ -x "$DMGBUILD" ] || { echo "error: 缺少 dmgbuild: $DMGBUILD" >&2; exit 1; }
    [ -f tools/dmgbuild-settings.py ] || { echo "error: 缺少 tools/dmgbuild-settings.py" >&2; exit 1; }
fi

# 签名身份：优先用 DEVELOPER_IDENTITY，否则自动取第一个 Developer ID Application
#（只匹配 "Developer ID Application"，不会误选 Apple Development）
if [ -z "${DEVELOPER_IDENTITY:-}" ] && [ "${SKIP_CODESIGN:-0}" != "1" ]; then
    DEVELOPER_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
        | grep 'Developer ID Application' | head -1 \
        | sed -E 's/^.*"([^"]+)".*$/\1/' || true)"
    [ -n "$DEVELOPER_IDENTITY" ] || {
        echo "error: 钥匙串里没有 Developer ID Application 证书。" >&2
        echo "       正式发布必须用 Developer ID（不能用 Apple Development）。" >&2
        echo "       自测可设 SKIP_CODESIGN=1。" >&2
        exit 1
    }
    echo "自动识别签名身份: ${DEVELOPER_IDENTITY}"
fi
if [ -n "${DEVELOPER_IDENTITY:-}" ]; then
    security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_IDENTITY" \
        || { echo "error: 钥匙串里找不到签名身份: $DEVELOPER_IDENTITY" >&2; exit 1; }
    echo "签名身份: ${DEVELOPER_IDENTITY} ✓"
fi

# 公证 profile
NOTARY_PROFILE="${NOTARY_PROFILE:-BrewPingNotary}"
if [ "$DO_NOTARIZE" = "1" ] || [ "$DO_BUILD" = "1" ] || [ "$DO_VERIFY" = "1" ]; then
    if [ -n "${DEVELOPER_IDENTITY:-}" ] || [ "$DO_NOTARIZE" = "1" ]; then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
            || { echo "error: notary profile 不可用: $NOTARY_PROFILE" >&2
                 echo "       先执行：xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id ... --team-id ... --password <app-specific-password>" >&2
                 exit 1; }
        echo "公证 profile: ${NOTARY_PROFILE} ✓"
    fi
fi

# ---------- 1. 构建 ----------
if [ "$DO_BUILD" = "1" ]; then
    stage "构建 .app（BUILD_ARCH=${BUILD_ARCH:-universal}）"
    BUILD_ARCH="${BUILD_ARCH:-universal}" APP_VERSION="$APP_VERSION" ./build-app.sh
fi

[ -d "$APP_DIR" ] || { echo "error: 找不到 $APP_DIR，请先运行 ./build-app.sh 或加 --build" >&2; exit 1; }

# ---------- 2. 架构校验 ----------
stage "架构校验"
ARCHS="$(lipo -archs "$APP_DIR/Contents/MacOS/${EXEC_NAME}" 2>/dev/null || echo unknown)"
echo "    主二进制架构: ${ARCHS}"
if [ "${ALLOW_SINGLE_ARCH:-0}" != "1" ]; then
    case "$ARCHS" in
        *arm64*x86_64*|*x86_64*arm64*) echo "    universal ✓" ;;
        *) echo "error: 不是 universal（${ARCHS}）。正式发布应包含 arm64 + x86_64。" >&2
           echo "       自测可设 ALLOW_SINGLE_ARCH=1。" >&2
           exit 1 ;;
    esac
fi

# ---------- 3. 签名 ----------
if [ "$DO_SIGN" = "1" ]; then
    if [ "${SKIP_CODESIGN:-0}" = "1" ]; then
        stage "跳过签名（SKIP_CODESIGN=1，仅自测）"
    else
        stage "签名（Developer ID + Hardened Runtime + 时间戳）"
        # 先签嵌套组件（当前 app 只有一个可执行文件；将来若加入 dylib/Helper/XPC 会被逐个签，
        # 由内向外，避免 --deep 一刀切导致 entitlements/options 被错误套用）
        NESTED="$(find "$APP_DIR" -type f \( -name '*.dylib' -o -path '*/Frameworks/*' -o -path '*/Helpers/*' -o -path '*/XPCServices/*' \) 2>/dev/null || true)"
        if [ -n "$NESTED" ]; then
            echo "    嵌套组件：$(echo "$NESTED" | wc -l | tr -d ' ') 个"
            echo "$NESTED" | while read -r n; do
                codesign --force --options runtime --timestamp --sign "$DEVELOPER_IDENTITY" "$n"
            done
        else
            echo "    无嵌套组件（单可执行文件）"
        fi
        # 🚨 签名必须一次干净完成：中途 kill 会留下 .cstemp 污染 seal，
        #    之后 verify 报 "a sealed resource is missing or invalid"。
        #    发生则重跑 ./build-app.sh 得到干净 .app 再签。
        codesign --force --options runtime --timestamp \
            --sign "$DEVELOPER_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            --identifier "$BUNDLE_ID" \
            "$APP_DIR"
        codesign --verify --deep --strict --verbose=2 "$APP_DIR"
        echo "    TeamIdentifier: $(codesign -dv "$APP_DIR" 2>&1 | grep '^TeamIdentifier' || echo '(无)')"
        echo "    签名校验 OK ✓"
    fi
fi

# ---------- 4. 公证 + staple .app ----------
NOTARIZED_APP=0
if [ "$DO_NOTARIZE" = "1" ] && [ -n "${DEVELOPER_IDENTITY:-}" ] && [ "${SKIP_CODESIGN:-0}" != "1" ]; then
    stage "公证 .app（profile: $NOTARY_PROFILE）"
    mkdir -p build
    ZIP="build/notary-submit.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    SUBMIT_LOG="build/notary-submit.log"
    # --wait 轮询至 Accepted/Invalid；Apple 排队偶尔超过 20 分钟属正常
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$SUBMIT_LOG" | tail -5
    SUBMIT_ID="$(grep -oE 'id: [a-f0-9-]+' "$SUBMIT_LOG" | head -1 | awk '{print $2}')"
    echo "    submission id: ${SUBMIT_ID:-unknown}"
    if ! grep -q "Accepted" "$SUBMIT_LOG"; then
        echo "error: .app 公证未通过，拉取日志：" >&2
        [ -n "$SUBMIT_ID" ] && xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | tail -40 >&2
        exit 3
    fi
    stage "Staple .app"
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    NOTARIZED_APP=1
    rm -f "$ZIP" "$SUBMIT_LOG"
fi

# ---------- 5. 打 dmg ----------
if [ "$DO_BUILD" = "1" ] || [ ! -f "$OUT_DMG" ]; then
    if [ ! -f "$BG_IMG" ]; then
        stage "生成 dmg 背景图"
        "$PYTHON" tools/make-dmg-background.py
    fi
    stage "打包 dmg（hdiutil + 自定义挂载点）"
    mkdir -p "$DIST_DIR"
    rm -f "$OUT_DMG"
    # 🚨 不再用 dmgbuild：它把镜像挂到 /Volumes 后用 ditto 写入，在「完全磁盘访问」
    # (FDA) 受限的环境里必然失败（ditto: ... Operation not permitted），且失败时
    # 只留下一个 40KB 的空镜像，极难排查。改用空白镜像 + 自定义挂载点（指向 /tmp 下），
    # 全程不碰 /Volumes，任何环境都能打包。
    # 代价：没有自定义背景图；发布形态仍是「BrewPing Desktop.app + Applications 快捷方式」。
    DMG_WORK="$(mktemp -d)"
    hdiutil create -size 200m -fs HFS+ -volname "$VOL_NAME" "$DMG_WORK/raw.dmg" >/dev/null
    hdiutil attach "$DMG_WORK/raw.dmg" -mountpoint "$DMG_WORK/mnt" >/dev/null
    cp -R "$APP_DIR" "$DMG_WORK/mnt/"
    ln -s /Applications "$DMG_WORK/mnt/Applications"
    hdiutil detach "$DMG_WORK/mnt" >/dev/null
    hdiutil convert "$DMG_WORK/raw.dmg" -format UDZO -o "$OUT_DMG" >/dev/null
    rm -rf "$DMG_WORK"
    echo "    dmg 大小: $(du -h "$OUT_DMG" | cut -f1)"
fi

# ---------- 6. 公证 + staple dmg（独立文件，必须单独公证） ----------
if [ "$DO_NOTARIZE" = "1" ] && [ "${NOTARIZE_DMG:-1}" = "1" ] && [ -n "${DEVELOPER_IDENTITY:-}" ] && [ "${SKIP_CODESIGN:-0}" != "1" ]; then
    # 🚨 dmg 本身也必须 Developer ID 签名，否则 Gatekeeper 会判
    #   "rejected / source=no usable signature"（只公证、不签名是不够的）。
    #   签名会改变 dmg 内容 → 必须签名之后再提交公证，顺序不能颠倒。
    stage "签名 .dmg"
    codesign --sign "$DEVELOPER_IDENTITY" --timestamp --force "$OUT_DMG"

    stage "公证 .dmg"
    SUBMIT_LOG="build/notary-submit-dmg.log"
    # dmg 本身是归档，可直接提交（无需 ditto 重打包）
    xcrun notarytool submit "$OUT_DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$SUBMIT_LOG" | tail -5
    if ! grep -q "Accepted" "$SUBMIT_LOG"; then
        echo "warn: dmg 公证未通过，跳过 dmg staple（dmg 内的 app 票据仍然有效）" >&2
        [ -n "$(grep -oE 'id: [a-f0-9-]+' "$SUBMIT_LOG" | head -1 | awk '{print $2}')" ] && \
            xcrun notarytool log "$(grep -oE 'id: [a-f0-9-]+' "$SUBMIT_LOG" | head -1 | awk '{print $2}')" \
                --keychain-profile "$NOTARY_PROFILE" 2>&1 | tail -20 >&2
    else
        stage "Staple dmg"
        xcrun stapler staple "$OUT_DMG"
        xcrun stapler validate "$OUT_DMG"
    fi
    rm -f "$SUBMIT_LOG"
fi

# ---------- 7. 最终校验（对最终产物，不是中间产物） ----------
if [ "$DO_VERIFY" = "1" ]; then
    stage "最终校验"
    echo "--- 架构 ---"
    echo "    $(lipo -archs "$APP_DIR/Contents/MacOS/${EXEC_NAME}")"
    echo "--- codesign（.app，deep/strict/verbose=2） ---"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" && echo "    codesign: OK ✓"
    echo "--- spctl（.app，execute，verbose=4） ---"
    spctl --assess --type execute --verbose=4 "$APP_DIR" && echo "    spctl .app: accepted ✓"
    echo "--- spctl（最终 dmg，open + primary-signature） ---"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$OUT_DMG" && echo "    spctl dmg: accepted ✓"
    echo "--- stapler ---"
    xcrun stapler validate "$APP_DIR" && echo "    stapler .app: valid ✓"
    xcrun stapler validate "$OUT_DMG" 2>/dev/null && echo "    stapler dmg: valid ✓" || echo "    stapler dmg: 未 staple（dmg 内 app 票据仍有效）"
fi

# ---------- 8. SHA256 + 同步 productPage ----------
stage "SHA256"
shasum -a 256 "$OUT_DMG" | tee "${OUT_DMG}.sha256"

if [ -d "$PRODUCT_PAGE_INSTALL" ]; then
    stage "同步到 productPage"
    cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg"
    cp -f "$OUT_DMG" "$PRODUCT_PAGE_INSTALL/public/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg"
    cp -f "${OUT_DMG}.sha256" "$PRODUCT_PAGE_INSTALL/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg.sha256"
    cp -f "${OUT_DMG}.sha256" "$PRODUCT_PAGE_INSTALL/public/install/BrewPing-${APP_VERSION}${DMG_SUFFIX}.dmg.sha256"
    echo "    synced ✓"
else
    echo "    warn: $PRODUCT_PAGE_INSTALL 不存在，跳过官网同步"
fi

stage "完成"
echo "dmg:    $OUT_DMG ($(du -h "$OUT_DMG" | cut -f1))"
echo "arch:   $(lipo -archs "$APP_DIR/Contents/MacOS/${EXEC_NAME}")"
echo "verify: open '$OUT_DMG'"
