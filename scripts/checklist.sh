#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

CANDIDATES=(
  "${1:-}"
  "$APP_PATH/Contents/MacOS/$SIDECAR_NAME"
  "$ROOT/src-tauri/binaries/$SIDECAR_NAME-$TARGET_ARM"
  "$ROOT/sidecar/$SIDECAR_NAME/target/release/$SIDECAR_NAME"
)

SIDECAR=""
for c in "${CANDIDATES[@]}"; do
  if [ -n "$c" ] && [ -x "$c" ]; then
    SIDECAR="$c"
    break
  fi
done

if [ -z "$SIDECAR" ]; then
  echo "no sidecar binary found. Run scripts/build.sh first." >&2
  exit 1
fi

echo "sidecar : $SIDECAR"
echo

"$SIDECAR" doctor --table
STATUS=$?

echo
if [ -d "$APP_PATH" ]; then
  echo "app bundle : $APP_PATH"
  echo "dmg        : $(ls -1 "$DMG_DIR" 2>/dev/null | tr '\n' ' ')"
fi

exit $STATUS
