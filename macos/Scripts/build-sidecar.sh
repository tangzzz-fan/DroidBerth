#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/env.sh"

TRIPLE="${TARGET_TRIPLE:-aarch64-apple-darwin}"
STAGE="$ROOT/macos/Sidecar"
SIDECAR_SRC="$ROOT/sidecar/droidberth-adb"

require_rust

mkdir -p "$STAGE"

echo "==> building droidberth-adb for $TRIPLE"
cargo build --release --manifest-path "$SIDECAR_SRC/Cargo.toml" --target "$TRIPLE"

BUILT="$SIDECAR_SRC/target/$TRIPLE/release/droidberth-adb"
[ -x "$BUILT" ] || { echo "build produced no binary at $BUILT" >&2; exit 1; }

cp "$BUILT" "$STAGE/droidberth-adb"
printf '    %s\n' "$STAGE/droidberth-adb"

ADB_SRC=""
for candidate in \
  "$ROOT/src-tauri/binaries/adb-$TRIPLE" \
  "$ROOT/vendor/platform-tools/adb"; do
  if [ -x "$candidate" ]; then ADB_SRC="$candidate"; break; fi
done

if [ -n "$ADB_SRC" ]; then
  cp "$ADB_SRC" "$STAGE/adb"
  printf '    %s  (from %s)\n' "$STAGE/adb" "${ADB_SRC#"$ROOT"/}"
else
  echo "warn: no adb binary found to stage; V4 will report adb as missing" >&2
fi

echo
echo "staged for the Xcode bundle (deliberately left unsigned):"
ls -1 "$STAGE"
