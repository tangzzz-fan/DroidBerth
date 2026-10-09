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

echo "==> 1/3 stage the Rust sidecar into macos/Sidecar/"
TARGET_TRIPLE="$TRIPLE" "$ROOT/macos/Scripts/build-sidecar.sh"

echo
echo "==> 2/3 generate the Xcode project"
# USER 未设置时 XcodeGen 报 "Couldn't find current username" 且静默不生成工程。
cd "$SWIFT_DIR"
USER="$(id -un)" "$XCODEGEN" generate

echo
echo "==> 3/3 xcodebuild ($CONFIGURATION)"
xcodebuild \
  -project "$SWIFT_DIR/DroidBerth.xcodeproj" \
  -scheme DroidBerth \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$SWIFT_DIR/build/dd" \
  build

echo
echo "identity : $IDENTITY"
echo "artifacts:"
[ -d "$APP_PATH" ] && echo "  app: $APP_PATH"
[ -d "$DMG_DIR" ] && ls -1 "$DMG_DIR" 2>/dev/null | sed 's/^/  dmg: /'
echo
echo "next: scripts/checklist.sh"
