#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

TRIPLE="${TARGET_TRIPLE:-$TARGET_ARM}"
export TARGET_TRIPLE="$TRIPLE"

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || true)}"
if [ -z "$XCODEGEN" ]; then
  for c in /opt/homebrew/bin/xcodegen /usr/local/bin/xcodegen; do
    [ -x "$c" ] && XCODEGEN="$c" && break
  done
fi
if [ -z "$XCODEGEN" ] || [ ! -x "$XCODEGEN" ]; then
  echo "xcodegen not found. Install it (brew install xcodegen) or set XCODEGEN=/path/to/xcodegen." >&2
  exit 1
fi

IDENTITY="$(detect_identity)"
KIND="$(identity_kind "$IDENTITY")"
export APPLE_SIGNING_IDENTITY="$IDENTITY"
export_bundle_paths

echo
echo "signing identity : $IDENTITY"
echo "identity kind    : $KIND"
echo "target           : $TRIPLE"
echo "configuration    : $CONFIGURATION"
if [ "$KIND" != "developer-id" ]; then
  echo
  echo "WARNING: this identity cannot be notarized. The build will still produce a signed,"
  echo "         hardened-runtime bundle so that the signing mechanics can be inspected."
fi
echo

cd "$ROOT"

for v in /Volumes/dmg.*; do
  [ -d "$v" ] || continue
  echo "detaching stale DMG staging volume: $v"
  hdiutil detach "$v" -force >/dev/null 2>&1 || true
done

if [ -d "$DMG_DIR" ]; then
  for f in "$DMG_DIR"/rw.*.dmg "$DMG_DIR"/*.dmg; do
    [ -e "$f" ] || continue
    echo "removing stale DMG staging file: $(basename "$f")"
    rm -f "$f"
  done
fi

echo "notarization : skipped here; run scripts/notarize.sh afterwards"
echo

# 信任链要求：构建工具绝不能看到公证凭据，否则可能出现「假成功」（见 PRD §28）。
for v in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID \
         APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH; do
  unset "$v"
done

echo "==> 1/4 generate the app icon"
# 必须在 `xcodegen generate` **之前** —— xcodegen 要求 project.yml 里列出的路径存在，
# 缺了 macos/Resources/icon.icns 它会直接报错（与 sidecar 暂存同一个形状的前置条件）。
# 纯 Python 渲染一张 1024 母版约 50 秒，所以只在脚本比产物新时才重跑。
ICON_ICNS="$SWIFT_DIR/Resources/icon.icns"
ICON_SCRIPT="$ROOT/scripts/make-icon.py"
PYTHON="${PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
if [ ! -f "$ICON_ICNS" ] || [ "$ICON_SCRIPT" -nt "$ICON_ICNS" ]; then
  "$PYTHON" "$ICON_SCRIPT" "$SWIFT_DIR/Resources"
else
  echo "    up to date, skipping (make-icon.py 未变)"
fi

echo
echo "==> 2/4 stage the Rust sidecar into macos/Sidecar/"
TARGET_TRIPLE="$TRIPLE" "$ROOT/macos/Scripts/build-sidecar.sh"

echo
echo "==> 3/4 generate the Xcode project"
# USER 未设置时 XcodeGen 报 "Couldn't find current username" 且静默不生成工程。
cd "$SWIFT_DIR"
USER="$(id -un)" "$XCODEGEN" generate

echo
echo "==> 4/4 xcodebuild ($CONFIGURATION)"
# 额外传给 xcodebuild 的 build setting，空格分隔。CI 与发布链靠它做两件脚本本身不该管的事：
#
#   XCODEBUILD_ARGS="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual"        # 无证书的 CI：ad-hoc 签名
#   XCODEBUILD_ARGS="MARKETING_VERSION=0.2.0 CURRENT_PROJECT_VERSION=42" # 发布：版本号取 tag
#
# ⚠️ **不能用环境变量代替**：实测 xcodebuild **不会**把环境变量当成 build setting ——
#    `CODE_SIGN_IDENTITY=- xcodebuild …` 仍然用钥匙串里的真证书签，
#    `MARKETING_VERSION=9.9.9 xcodebuild …` 产出的 Info.plist 仍是 0.1.0。
#    只有**命令行参数**这条路径可靠，所以留了这个显式口子（默认空，本地行为不变）。
EXTRA_ARGS=()
if [ -n "${XCODEBUILD_ARGS:-}" ]; then
  read -r -a EXTRA_ARGS <<< "$XCODEBUILD_ARGS"
  echo "    XCODEBUILD_ARGS: ${EXTRA_ARGS[*]}"
fi

xcodebuild \
  -project "$SWIFT_DIR/DroidBerth.xcodeproj" \
  -scheme DroidBerth \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$SWIFT_DIR/build/dd" \
  "${EXTRA_ARGS[@]}" \
  build

echo
echo "identity : $IDENTITY"
echo "artifacts:"
[ -d "$APP_PATH" ] && echo "  app: $APP_PATH"
[ -d "$DMG_DIR" ] && ls -1 "$DMG_DIR" 2>/dev/null | sed 's/^/  dmg: /'
echo
echo "next: scripts/checklist.sh"
