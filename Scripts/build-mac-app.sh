#!/bin/bash
#
# BrewPing Desktop（macOS）一键打包：构建 → 组装 .app → 签名 → 公证 → 打 dmg。
#
# 必须在 macOS 上执行（需要 Xcode 命令行工具 + 钥匙串里的 Developer ID 证书）。
#
# ─── 首次准备（每台打包机做一次）─────────────────────────────────────────────
# 1) 在 developer.apple.com 创建并下载 **Developer ID Application** 证书，
#    双击导入「登录」钥匙串。
# 2) 生成公证凭据（App 专用密码，需开启双重认证）：
#      xcrun notarytool store-credentials "brewping-notary" \
#        --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
#    想换成 App Store Connect API Key 也行，见下方 ASC_* 环境变量。
# 3) dmg 可选依赖：brew install create-dmg（没有则自动回退 hdiutil）。
#
# ─── 用法 ────────────────────────────────────────────────────────────────────
#   ./Scripts/build-mac-app.sh                     # 构建 + 签名 + 公证 + dmg
#   SKIP_NOTARIZE=1 ./Scripts/build-mac-app.sh     # 只签名（内网自测）
#   SKIP_SIGN=1 ./Scripts/build-mac-app.sh         # 只出 .app（不签名不公证）
#   VERSION=1.2.0 BUILD=42 ./Scripts/build-mac-app.sh
#
# ─── 环境变量 ────────────────────────────────────────────────────────────────
#   VERSION         版本号（默认 git describe --tags，再兜底 Info.plist 里的值）
#   BUILD           build 号（默认 1）
#   CERT            钥匙串里的证书名（默认 "Developer ID Application"，取首个匹配）
#   ENTITLEMENTS    entitlements 路径（默认 Sources/BrewPingDesktop/Resources/Desktop.entitlements）
#   TEAM_ID         Apple 团队 ID（仅打印提示用，公证走 profile 或 ASC_*）
#   NOTARY_PROFILE  keychain profile 名（默认 brewping-notary）
#   ASC_KEY_ID      App Store Connect API Key ID（有则自动创建临时 profile）
#   ASC_ISSUER_ID   ASC Issuer ID
#   ASC_PRIVATE_KEY ASC 私钥 P8 的**内容**（CI 里从 secrets 传入）
#   UNIVERSAL       1 = 构建 arm64+x86_64 通用包（默认 1）；0 = 只编本机架构
#   SKIP_SIGN       1 = 跳过签名（连带跳过公证）
#   SKIP_NOTARIZE   1 = 签名但不公证
#   SKIP_DMG        1 = 不打 dmg，只留 .app
#
# 产物都在 dist/ 下：BrewPing.app、BrewPing-<version>.dmg、.zip（公证上传用）。

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="BrewPing"
EXEC_NAME="BrewPing"
BUNDLE_ID="com.brewping.desktop"
# 打包素材（Info.plist / entitlements）刻意放在 Scripts/mac/ 而不是
# Sources/BrewPingDesktop/ 下 —— 后者是 SwiftPM target 目录，放非 Swift 文件会
# 触发「unhandled resource」警告，而这里只被打包脚本消费，不参与编译。
RES_DIR="Scripts/mac"
ICON_SRC="logo/AppIcon.icns"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

VERSION="${VERSION:-}"
BUILD="${BUILD:-1}"
CERT="${CERT:-Developer ID Application}"
ENTITLEMENTS="${ENTITLEMENTS:-$RES_DIR/Desktop.entitlements}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-BrewPingNotary}"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_PRIVATE_KEY="${ASC_PRIVATE_KEY:-}"
UNIVERSAL="${UNIVERSAL:-1}"
SKIP_SIGN="${SKIP_SIGN:-0}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
SKIP_DMG="${SKIP_DMG:-0}"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
err()  { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── 0. 前置检查 ────────────────────────────────────────────────────────────

[[ "$(uname -s)" == "Darwin" ]] || err "这个脚本只能在 macOS 上运行（需要 codesign / notarytool）。"

for cmd in swift codesign xcrun ditto; do
  command -v "$cmd" >/dev/null 2>&1 || err "缺少命令：$cmd（请安装 Xcode 命令行工具：xcode-select --install）"
done

[[ -f "$ICON_SRC" ]] || err "找不到图标 $ICON_SRC"
[[ -f "$RES_DIR/Info.plist" ]] || err "找不到 $RES_DIR/Info.plist"
[[ -f "$ENTITLEMENTS" ]] || err "找不到 entitlements $ENTITLEMENTS"

if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --dirty 2>/dev/null || true)"
fi
# 去掉 git describe 的 v 前缀；仍为空则从 plist 里读占位值
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$RES_DIR/Info.plist" 2>/dev/null || echo "1.0.0")"
fi

log "BrewPing Desktop 打包  version=$VERSION build=$BUILD"
[[ -n "$TEAM_ID" ]] && info "团队 ID: $TEAM_ID" || true

# ─── 1. 构建 ────────────────────────────────────────────────────────────────

log "构建 release（$( [[ "$UNIVERSAL" == "1" ]] && echo 'arm64 + x86_64 通用' || echo '本机架构' )）"
if [[ "$UNIVERSAL" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
else
  swift build -c release
fi

BIN="$(swift build -c release --show-bin-path)/$EXEC_NAME"
[[ -x "$BIN" ]] || err "构建产物不存在：$BIN"

# ─── 2. 组装 .app ───────────────────────────────────────────────────────────

log "组装 $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
cp "$RES_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
info "已写入版本号 $VERSION ($BUILD)"

# ─── 3. 签名 ────────────────────────────────────────────────────────────────

if [[ "$SKIP_SIGN" == "1" ]]; then
  log "SKIP_SIGN=1：跳过签名与公证"
  info "注意：未签名的 .app 在别人机器上会被 Gatekeeper 拦截，仅供本机自测。"
else
  log "签名（Hardened Runtime + 时间戳）"
  # --force 覆盖旧签名；--options runtime 是公证的硬性要求；--timestamp 让签名
  # 在证书过期后依然有效。这里只有一个可执行文件，不需要 --deep。
  codesign --force --options runtime --timestamp \
    --sign "$CERT" \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$BUNDLE_ID" \
    "$APP"

  codesign --verify --strict --verbose=2 "$APP"
  info "签名校验通过：$(codesign -dv "$APP" 2>&1 | grep '^TeamIdentifier' || echo '(无团队标识)')"
fi

# ─── 4. 公证 ────────────────────────────────────────────────────────────────

if [[ "$SKIP_SIGN" == "1" || "$SKIP_NOTARIZE" == "1" ]]; then
  [[ "$SKIP_SIGN" == "1" ]] || log "SKIP_NOTARIZE=1：跳过公证"
else
  # CI 场景：用 App Store Connect API Key 现场创建 profile，免得维护钥匙串凭据。
  if [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -n "$ASC_PRIVATE_KEY" ]]; then
    log "用 App Store Connect API Key 创建公证 profile"
    ASC_KEY_FILE="$(mktemp -t brewping-asc).p8"
    printf '%s' "$ASC_PRIVATE_KEY" > "$ASC_KEY_FILE"
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \
      --key "$ASC_KEY_FILE" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
    rm -f "$ASC_KEY_FILE"
  fi

  log "公证（上传到 Apple，通常需要 1–5 分钟）"
  ZIP="$DIST/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait || {
    err "公证失败。查看详细原因：
      xcrun notarytool log \$(xcrun notarytool history --keychain-profile $NOTARY_PROFILE | awk 'NR==3{print \$1}') --keychain-profile $NOTARY_PROFILE"
  }

  log "把公证票据钉到 .app（离线也能通过 Gatekeeper）"
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP" || err "Gatekeeper 评估失败（spctl 未通过）。"
  info "Gatekeeper 评估通过"
fi

# ─── 5. 打 dmg ──────────────────────────────────────────────────────────────

if [[ "$SKIP_DMG" == "1" ]]; then
  log "SKIP_DMG=1：跳过 dmg"
else
  log "打 dmg"
  DMG="$DIST/BrewPing-$VERSION.dmg"
  rm -f "$DMG"

  if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
      --volname "$APP_NAME" \
      --window-pos 200 120 \
      --window-size 660 400 \
      --icon-size 100 \
      --icon "$APP_NAME.app" 170 190 \
      --app-drop-link 490 190 \
      --no-internet-enable \
      --hdiutil-quiet \
      "$DMG" "$APP" || err "create-dmg 失败（见上方输出）"
  else
    info "未安装 create-dmg，回退 hdiutil（无背景图与图标布局）"
    STAGE="$DIST/dmg-root"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
  fi

  info "dmg: $DMG"
  shasum -a 256 "$DMG" | tee "$DMG.sha256"
fi

# ─── 完成 ───────────────────────────────────────────────────────────────────

log "完成"
info "应用: $APP"
info "版本: $VERSION ($BUILD)"
info "产物: $(ls -1 "$DIST" 2>/dev/null | sed 's/^/         /')"
