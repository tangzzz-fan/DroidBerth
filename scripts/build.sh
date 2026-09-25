#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/env.sh"

TARGET_TRIPLE="${TARGET_TRIPLE:-}"
UNIVERSAL=0
WITH_ADB=0
TAURI_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --with-adb) WITH_ADB=1 ;;
    *) TAURI_ARGS+=("$arg") ;;
  esac
done

if [ "$WITH_ADB" = "1" ]; then
  for triple in "$TARGET_ARM" "$TARGET_INTEL" "$TARGET_UNIVERSAL"; do
    if [ ! -f "$ROOT/src-tauri/binaries/adb-$triple" ]; then
      echo "binaries/adb-$triple is missing. Run scripts/build-adb.sh first." >&2
      exit 1
    fi
  done
  TAURI_ARGS+=(--config "$ROOT/src-tauri/tauri.adb.conf.json")
fi

if [ "$UNIVERSAL" = "1" ]; then
  "$ROOT/scripts/build-sidecars.sh" --universal
  TARGET_TRIPLE="$TARGET_UNIVERSAL"
else
  "$ROOT/scripts/build-sidecars.sh"
  TARGET_TRIPLE="${TARGET_TRIPLE:-$TARGET_ARM}"
fi

IDENTITY="$(detect_identity)"
KIND="$(identity_kind "$IDENTITY")"
export APPLE_SIGNING_IDENTITY="$IDENTITY"
export TARGET_TRIPLE="$TARGET_TRIPLE"
export_bundle_paths

echo
echo "signing identity : $IDENTITY"
echo "identity kind    : $KIND"
echo "target           : $TARGET_TRIPLE"
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

MACOS_DIR="$(dirname "$APP_PATH")"
if [ -d "$MACOS_DIR" ]; then
  for f in "$MACOS_DIR"/rw.*.dmg "$MACOS_DIR"/*.dmg; do
    [ -e "$f" ] || continue
    echo "removing stale DMG staging file: $(basename "$f")"
    rm -f "$f"
  done
fi

echo "notarization : skipped here; run scripts/notarize.sh afterwards"
echo

for v in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID \
         APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH; do
  unset "$v"
done

TAURI_BIN="$ROOT/node_modules/.bin/tauri"
if [ -x "$TAURI_BIN" ]; then
  if [ "${#TAURI_ARGS[@]}" -gt 0 ]; then
    "$TAURI_BIN" build --target "$TARGET_TRIPLE" "${TAURI_ARGS[@]}"
  else
    "$TAURI_BIN" build --target "$TARGET_TRIPLE"
  fi
else
  if [ "${#TAURI_ARGS[@]}" -gt 0 ]; then
    npx --yes "@tauri-apps/cli@^2" build --target "$TARGET_TRIPLE" "${TAURI_ARGS[@]}"
  else
    npx --yes "@tauri-apps/cli@^2" build --target "$TARGET_TRIPLE"
  fi
fi

echo
echo "artifacts:"
[ -d "$APP_PATH" ] && echo "  app: $APP_PATH"
[ -d "$DMG_DIR" ] && ls -1 "$DMG_DIR" | sed 's/^/  dmg: /'
echo
echo "next: scripts/checklist.sh"
