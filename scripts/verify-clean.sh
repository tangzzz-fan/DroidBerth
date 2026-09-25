#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

DMG="${1:-}"
APPLY=0
REPLACE=0
QUARANTINE=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --replace) REPLACE=1 ;;
    --quarantine) QUARANTINE=1 ;;
  esac
done

if [ -z "$DMG" ] || [ ! -f "$DMG" ]; then
  echo "usage: verify-clean.sh /path/to/DroidDock.dmg [--apply] [--replace] [--quarantine]" >&2
  echo >&2
  echo "  Run this on a macOS 15 machine or fresh VM that has never run the app." >&2
  echo "  Without --apply it only inspects the DMG and the mounted copy." >&2
  echo "  --apply      copy the app into /Applications (required for a conclusive spctl result)" >&2
  echo "  --replace    allow overwriting an existing /Applications/$APP_NAME.app" >&2
  echo "  --quarantine simulate a browser download by stamping com.apple.quarantine" >&2
  exit 2
fi

echo "==> host"
sw_vers
echo

MOUNT="$(mktemp -d)"
ATTACHED=0
cleanup() {
  if [ "$ATTACHED" = "1" ]; then
    hdiutil detach "$MOUNT" -quiet || true
  fi
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 1/6 mount"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
ATTACHED=1
SOURCE_APP="$(find "$MOUNT" -maxdepth 1 -name '*.app' -print -quit)"
if [ -z "$SOURCE_APP" ]; then
  echo "no .app inside $DMG" >&2
  exit 1
fi
echo "    $SOURCE_APP"
echo

echo "==> 2/6 signature inventory inside the DMG"
find "$SOURCE_APP" -type f -print0 | xargs -0 file | grep 'Mach-O' | cut -d: -f1 | while read -r f; do
  printf '  %s\n' "${f#"$SOURCE_APP"/}"
  codesign -dvvv "$f" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|Signature|CodeDirectory)' | sed 's/^/      /' || true
done || true
echo

echo "==> 3/6 spctl on the mounted copy"
spctl --assess -t open --context context:primary-signature -vv "$SOURCE_APP" 2>&1 || true
echo

if [ "$APPLY" != "1" ]; then
  echo "stopping here: pass --apply to install into /Applications and finish the check."
  exit 0
fi

DEST="/Applications/$APP_NAME.app"
if [ -e "$DEST" ] && [ "$REPLACE" != "1" ]; then
  echo "$DEST already exists. A machine that has already run the app is not a clean environment." >&2
  echo "Use --replace to overwrite, or re-run on a fresh VM." >&2
  exit 1
fi

echo "==> 4/6 install into /Applications"
rm -rf "$DEST"
cp -R "$SOURCE_APP" "$DEST"
if [ "$QUARANTINE" = "1" ]; then
  xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");DroidDock;" "$DEST"
  echo "    stamped com.apple.quarantine"
fi
hdiutil detach "$MOUNT" -quiet
ATTACHED=0
echo "    $DEST"
echo

echo "==> 5/6 Gatekeeper"
spctl --assess -t open --context context:primary-signature -vv "$DEST" 2>&1 || true
echo

echo "==> 6/6 bundle self-diagnosis (the app's own sidecar)"
SIDECAR="$DEST/Contents/MacOS/$SIDECAR_NAME"
if [ -x "$SIDECAR" ]; then
  "$SIDECAR" doctor --table || true
else
  echo "    $SIDECAR not found" >&2
fi
echo

echo "verdict: accepted above means the notarized bundle survives macOS 15 deep validation."
echo "         open $DEST by double-clicking to confirm no 'unidentified developer' dialog appears."
