#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

APP="${1:-$APP_PATH}"
# Swift 路线：sidecar 不需要额外 entitlements（见 0926_02 §10），
# 外层 app 用 Xcode 工程里同一份 entitlements，避免「脚本与工程各签一份」的分叉。
APP_ENTITLEMENTS="$ROOT/macos/Resources/DroidBerth.entitlements"

if [ ! -d "$APP" ]; then
  echo "no app bundle at $APP" >&2
  exit 1
fi

IDENTITY="$(detect_identity)"
export APPLE_SIGNING_IDENTITY="$IDENTITY"
echo "identity     : $IDENTITY"
echo "entitlements : $APP_ENTITLEMENTS"
echo

sign() {
  local target="$1"
  local entitlements="${2:-}"
  if [ -n "$entitlements" ]; then
    codesign --force --options=runtime --timestamp \
      --entitlements "$entitlements" --sign "$IDENTITY" "$target"
  else
    codesign --force --options=runtime --timestamp \
      --sign "$IDENTITY" "$target"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

find "$APP" -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 \
  | awk '{ n = gsub(/\//, "/"); print n "\t" $0 }' | sort -rn | cut -f2- > "$WORK/macho" || true

find "$APP/Contents" \( -name '*.app' -o -name '*.framework' \) \
  | awk '{ n = gsub(/\//, "/"); print n "\t" $0 }' | sort -rn | cut -f2- > "$WORK/bundles" || true

COUNT=0
echo "==> re-signing nested Mach-O files, deepest first"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  sign "$f"
  COUNT=$((COUNT + 1))
  printf '  %s\n' "${f#"$APP"/}"
done < "$WORK/macho"
echo "    $COUNT file(s)"

echo
echo "==> re-signing nested bundles, deepest first"
while IFS= read -r b; do
  [ -n "$b" ] || continue
  sign "$b"
  printf '  %s\n' "${b#"$APP"/}"
done < "$WORK/bundles"

echo
echo "==> re-signing the outer app"
sign "$APP" "$APP_ENTITLEMENTS"

echo
echo "==> codesign --verify --deep --strict"
if codesign --verify --deep --strict --verbose=2 "$APP"; then
  echo "    OK"
else
  echo "    FAILED - see the output above" >&2
  exit 1
fi

echo
echo "==> rebuilding and signing the DMG from the re-signed app"
mkdir -p "$DMG_DIR"
DMG_OUT="$DMG_DIR/$APP_NAME-resigned.dmg"
make_signed_dmg "$APP" "$DMG_OUT"
echo "    $DMG_OUT"

echo
echo "next: scripts/notarize.sh"
